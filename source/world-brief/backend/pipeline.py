"""Refresh pipeline: fetch -> store -> cluster -> (re)train local models -> build events -> events.json."""
import asyncio
import fcntl
import hashlib
import json
import logging
import math
import threading
import time
from collections import Counter
from contextlib import contextmanager

from . import config, store
from .classify import CATEGORY_IDS, CATEGORY_LABELS, CATEGORY_WEIGHT, CATEGORY_GRAVITY, RULES_VERSION, article_hits
from .cluster import cluster_articles
from .countries import COUNTRY_BY_CODE, COUNTRY_NAMES, REGION_BY_CODE, gnews_search_url
from .fetcher import feed_jobs, fetch_all, fetch_fulltexts
from .geo import GAZETTEER, GAZ_VERSION
from .ml import FEATURES, MODELS, SUMMARIZER, central_title, perspectives
from .textutil import word_count

log = logging.getLogger("pipeline")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")

STATUS = {"running": False, "stage": "idle", "progress": "", "last_run": None, "last_error": None, "last_duration": None}
_run_lock = threading.Lock()
LOCK_PATH = config.DATA_DIR / "refresh.lock"

@contextmanager
def _process_lock():
    """Stop a CLI refresh and the server's scheduled refresh from running at the same time:
    they would fight over CPU and each do the other's work."""
    f = open(LOCK_PATH, "w")
    try:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            yield False
            return
        yield True
    finally:
        try:
            fcntl.flock(f, fcntl.LOCK_UN)
        finally:
            f.close()

def _stage(name, progress=""):
    STATUS["stage"], STATUS["progress"] = name, progress
    log.info("stage: %s %s", name, progress)

# ------------------------------------------------------------------------------------------------
def fetch_stage():
    jobs = feed_jobs()
    from .countries import COUNTRY_BY_CODE as _cc
    store.prune_feed_health({j["feed"] for j in jobs} | {gnews_search_url(c) for c in _cc})
    _stage("fetching", f"0/{len(jobs)} feeds")
    results = asyncio.run(fetch_all(jobs, progress=lambda d, n: _stage("fetching", f"{d}/{n} feeds")))
    ok = fail = new = 0
    rows = []
    for job, arts, err in results:
        store.record_feed(job["feed"], job["id"], job["name"], job["country"], job["kind"], err is None, len(arts), err)
        if err is None:
            ok += 1
            rows.extend(arts)
        else:
            fail += 1
    # de-dup by url within this batch (the same Google News link appears in several national editions)
    seen, uniq = set(), []
    for r in rows:
        if r["url"] in seen:
            continue
        seen.add(r["url"]); uniq.append(r)
    new = store.upsert_articles(uniq)
    # Fallback: countries with no stored article in the window get an English search feed about them.
    covered = {a["outlet_country"] for a in store.recent_articles(config.WINDOW_HOURS)}
    fallback = []
    for c in COUNTRY_BY_CODE:
        if c not in covered and not any(j["id"] == f"gs-{c}" for j in jobs):
            fallback.append({"id": f"gs-{c}", "name": f"Google News search: {COUNTRY_NAMES[c]}", "country": c, "lang": "en",
                             "leaning": "aggregator (about the country)", "ownership": "aggregator", "tier": 3,
                             "feed": gnews_search_url(c), "kind": "gnews-search", "polarity": "other"})
    if fallback:
        _stage("fetching", f"fallback feeds for {len(fallback)} uncovered countries")
        extra = []
        for job, arts, err in asyncio.run(fetch_all(fallback)):
            store.record_feed(job["feed"], job["id"], job["name"], job["country"], job["kind"], err is None, len(arts), err)
            if err is None:
                ok += 1; extra.extend(arts)
            else:
                fail += 1
        new += store.upsert_articles([r for r in extra if r["url"] not in seen])
        uniq.extend(extra)
    log.info("feeds ok=%d failed=%d items=%d new=%d", ok, fail, len(uniq), new)
    return ok, fail, new

def derive_stage(articles):
    """Compute (once per article) keyword-rule hits and gazetteer locations; cache them in the DB.
    The cache is keyed on a version stamp of the rules and the gazetteer, so editing either
    recomputes everything instead of silently serving stale labels."""
    version = f"{RULES_VERSION}:{GAZ_VERSION}"
    if store.get_meta("derive_version") != version:
        store.clear_derived()
        store.set_meta("derive_version", version)
        for a in articles:
            a["rules"] = a["geo"] = None
        log.info("rules/gazetteer changed -> recomputing derived features")
    todo = []
    for a in articles:
        if a.get("rules") and a.get("geo"):
            a["_rules"] = json.loads(a["rules"]); a["_geo"] = json.loads(a["geo"])
            continue
        hits = article_hits(a)
        locs, ctry = GAZETTEER.resolve(a["title"], (a.get("summary") or "")[:800], a["outlet_country"])
        a["_geo"] = {"locs": locs, "countries": dict(ctry)}
        todo.append((a["url"], json.dumps(hits), json.dumps(a["_geo"])))
    if todo:
        store.set_derived(todo)
    log.info("derived features for %d new articles", len(todo))

# ------------------------------------------------------------------------------------------------
def _event_id(cluster, articles):
    first = min(cluster, key=lambda i: articles[i]["published"])
    return hashlib.sha1(articles[first]["url"].encode()).hexdigest()[:12]

def _reading_seconds(ev):
    # What a reader must read: headline, summary, the sides' headlines. Extracts and article lists are optional depth.
    words = word_count(ev["title"]) + sum(word_count(s["sentence"]) for s in ev["summary"]) \
        + sum(word_count(s["headline"]) for s in ev["sides"])
    return int(words / config.READING_WPM * 60) + 6

def build_events(articles, clusters, topic_scores, salience, feedback_by_id):
    now = time.time()
    events = []
    for cl in clusters:
        arts = sorted((articles[i] for i in cl), key=lambda a: (a.get("tier", 3), -a["published"]))
        idxs = list(cl)
        n_art = len(arts)
        outlets = {a["outlet_name"] for a in arts}
        covering = Counter(a["outlet_country"] for a in arts)
        pols = Counter(a["polarity"] for a in arts)
        langs = sorted({(a.get("lang") or "en") for a in arts})
        # --- categories: average of per-article scores, weighted by tier
        cat = Counter()
        for i in idxs:
            for c, s in topic_scores[i].items():
                cat[c] += s
        # Rank categories by total evidence across the cluster, then keep those close to the best.
        # (Averaging over articles punished widely covered stories: a 100-article event whose every
        # article scored 0.6 on "war" averaged below the cut-off and fell into "other".)
        best = max(cat.values()) if cat else 0.0
        conf = min(1.0, best / max(1, n_art)) if best else 0.3
        ranked = sorted(cat.items(), key=lambda x: -x[1])
        cats = [(c, round(v / best, 3)) for c, v in ranked if v >= 0.45 * best and v >= 0.8][:4] if best else []
        if not cats and ranked:                 # weak but non-zero evidence: keep the best guess
            cats = [(ranked[0][0], round(min(1.0, ranked[0][1]), 3))]
        if not cats:
            cats = [("other", 0.3)]
        primary = cats[0][0]
        # --- locations
        loc_w, loc_meta, mentioned = Counter(), {}, Counter()
        for a in arts:
            g = a.get("_geo") or {"locs": [], "countries": {}}
            locs, ctry = g["locs"], g["countries"]
            for l in locs:
                key = (l["kind"] if l["kind"] != "source-country" else "country", l["name"])
                loc_w[key] += l["weight"]
                loc_meta[key] = l
            for c, w in ctry.items():
                mentioned[c] += w
        locations = []
        for key, w in loc_w.most_common(6):
            l = dict(loc_meta[key]); l["weight"] = round(w, 2); l["kind"] = key[0]
            locations.append(l)
        countries_mentioned = [c for c, _ in mentioned.most_common(5)]
        # --- sides: by outlet country when the story spans 2+ countries with 2+ covering countries, else by leaning
        top_mentioned = set(countries_mentioned[:3])
        side_basis = "leaning"
        sides, div = [], 0.0
        if len(top_mentioned) >= 2 and sum(1 for c in covering if c in top_mentioned) >= 2:
            # The side is the country code, not a sentence: the interface writes it out in the
            # reader's own language.
            sides, div = perspectives([a for a in arts if a["outlet_country"] in top_mentioned],
                                      lambda a: a["outlet_country"])
            side_basis = "country"
        if len(sides) < 2:
            labelled = [a for a in arts if a["polarity"] not in ("other",)]
            sides, div = perspectives(labelled, lambda a: a["polarity"])
            side_basis = "leaning"
        # --- summary + extracts
        langs_present = {(a.get("lang") or "en") for a in arts}
        lang_pref = "en" if "en" in langs_present else sorted(langs_present)[0]
        docs, other_lang = [], []
        for a in arts[:20]:
            text = (a.get("fulltext") or "") or (a.get("summary") or "")
            if not text or (a.get("kind") or "").startswith("gnews"):
                continue
            # Keep the summary in the same language as the headline we are going to show.
            (docs if (a.get("lang") or "en") == lang_pref else other_lang).append((text, a["outlet_name"]))
        docs = docs[:12] or other_lang[:12]
        if not docs:   # only aggregator items: their related-headline lists are the best text we have
            docs = [((a.get("summary") or ""), a["outlet_name"]) for a in arts[:6] if a.get("summary")]
        summary = SUMMARIZER.summarize(docs, k=config.SUMMARY_SENTENCES, lang=lang_pref)
        for sent in summary:
            sent["lang"] = lang_pref
        extracts, used = [], set()
        for a in sorted(arts, key=lambda x: ((x.get("lang") or "en") != lang_pref, x.get("tier", 3))):
            s = (a.get("summary") or "").strip()
            if len(s) < 60 or a["outlet_name"] in used or (a.get("kind") or "").startswith("gnews"):
                continue
            used.add(a["outlet_name"])
            extracts.append({"outlet": a["outlet_name"], "leaning": a["leaning"], "country": a["outlet_country"],
                             "lang": a.get("lang") or "en", "text": s[:420], "url": a["url"]})
            if len(extracts) >= 4:
                break
        # --- relevance
        t_first = min(a["published"] for a in arts); t_last = max(a["published"] for a in arts)
        age_h = max(0.0, (now - t_last) / 3600)
        sal = sum(salience[i] for i in idxs) / n_art
        raw = (8 * math.log1p(n_art) + 10 * math.log1p(len(outlets)) + 8 * math.log1p(len(covering)) + 4 * math.log1p(len(pols))
               + max(CATEGORY_WEIGHT[c] for c, _ in cats) * (0.5 + 0.5 * conf) + (6 if any(a.get("tier") == 1 for a in arts) else 0)
               + 10 * math.exp(-age_h / 24) + 5 * sal + (3 if div > 0.5 else 0))
        raw *= CATEGORY_GRAVITY.get(primary, 1.0)
        # The lead article (whose full text we fetch) should be in the language of the headline.
        lead_article = next((a for a in arts if (a.get("lang") or "en") == lang_pref), arts[0])
        eid = _event_id(cl, articles)
        fb = feedback_by_id.get(eid)
        if fb is not None:
            raw += 25 if fb > 0 else -25
        ev = {
            "id": eid, "title": central_title(arts, lang_pref), "summary": summary, "lang": lang_pref,
            "categories": [{"id": c, "label": CATEGORY_LABELS[c], "score": s} for c, s in cats], "primary_category": primary,
            "locations": locations, "primary_location": locations[0] if locations else None,
            "countries_mentioned": countries_mentioned, "countries_covering": [c for c, _ in covering.most_common()],
            "regions": sorted({REGION_BY_CODE.get(c, "") for c in countries_mentioned[:3] if c in REGION_BY_CODE} - {""}),
            "time_first": t_first, "time_last": t_last, "relevance_raw": round(raw, 2), "salience": round(sal, 3),
            "article_count": n_art, "outlet_count": len(outlets), "country_count": len(covering),
            "polarities": dict(pols), "sides": sides, "divergence": div, "side_basis": side_basis, "languages": langs,
            "articles": [{"title": a["title"], "url": a["url"], "outlet": a["outlet_name"], "country": a["outlet_country"],
                          "leaning": a["leaning"], "ownership": a["ownership"], "polarity": a["polarity"], "tier": a.get("tier"),
                          "published": a["published"], "lang": a.get("lang"), "kind": a.get("kind"),
                          "extract": (a.get("summary") or "")[:280]} for a in arts[:40]],
            "extracts": extracts, "lead_url": lead_article["url"], "feedback": fb,
        }
        ev["reading_seconds"] = _reading_seconds(ev)
        events.append(ev)
    if events:
        mx = max(e["relevance_raw"] for e in events) or 1.0
        for e in events:
            e["relevance"] = round(100 * e["relevance_raw"] / mx, 1)
    events.sort(key=lambda e: -e["relevance_raw"])
    return events

def select_brief(events, minutes):
    """Greedy diverse selection that fits the daily reading budget."""
    budget = minutes * 60
    used = 0
    cat_n, ctry_n = Counter(), Counter()
    chosen = []
    for e in events:
        # One outlet saying it is not yet news; two independent outlets is the minimum bar for the brief.
        if e["outlet_count"] < 2:
            continue
        cap = max(3, int(0.35 * (len(chosen) + 1)) + 1)
        pc = e["countries_mentioned"][0] if e["countries_mentioned"] else None
        if cat_n[e["primary_category"]] >= cap or (pc and ctry_n[pc] >= cap):
            continue
        if used + e["reading_seconds"] > budget:
            continue
        chosen.append(e["id"]); used += e["reading_seconds"]
        cat_n[e["primary_category"]] += 1
        if pc:
            ctry_n[pc] += 1
    rank = {eid: i + 1 for i, eid in enumerate(chosen)}
    for e in events:
        e["in_brief"] = e["id"] in rank
        e["brief_rank"] = rank.get(e["id"])
    return len(chosen), used

# ------------------------------------------------------------------------------------------------
def run(fetch=True):
    if not _run_lock.acquire(blocking=False):
        log.info("refresh already running")
        return False
    t0 = time.time()
    STATUS.update(running=True, last_error=None)
    try:
        with _process_lock() as got:
            if not got:
                log.info("another process is refreshing; skipping this run")
                _stage("idle")
                return False
            return _run_locked(fetch, t0)
    finally:
        STATUS["running"] = False
        _run_lock.release()

def _run_locked(fetch, t0):
    try:
        if fetch:
            ok, fail, new = fetch_stage()
        else:
            ok = fail = new = 0
        _stage("loading articles")
        articles = store.recent_articles(config.WINDOW_HOURS)
        if not articles:
            raise RuntimeError("no articles fetched; check network and feed health")
        _stage("deriving features", "rules + locations for new articles")
        derive_stage(articles)
        _stage("clustering", f"{len(articles)} articles")
        clusters = cluster_articles(articles)
        # ---- train local models on the live corpus
        MODELS.load()
        _stage("featurising", f"{len(articles)} articles")
        X_all = FEATURES.transform(articles)
        if config.RETRAIN_EACH_REFRESH or not MODELS.topic.clf:
            _stage("training topic model")
            MODELS.topic.train(articles, X_all)
        _stage("classifying")
        topic_scores = MODELS.topic.predict(articles, X_all)
        outlets_per_article = [0] * len(articles)
        for cl in clusters:
            n = len({articles[i]["outlet_name"] for i in cl})
            for i in cl:
                outlets_per_article[i] = math.log1p(n)
        feedback = store.all_feedback()
        if config.RETRAIN_EACH_REFRESH or MODELS.salience.reg is None:
            _stage("training salience model")
            MODELS.salience.train(articles, outlets_per_article, feedback, X_all)
        salience = MODELS.salience.predict(articles, X_all)
        MODELS.save()
        fb_by_id = {}
        for fb in feedback:
            fb_by_id.setdefault(fb["event_id"], fb["label"])
        _stage("building events", f"{len(clusters)} clusters")
        events = build_events(articles, clusters, topic_scores, salience, fb_by_id)
        # ---- full text for the lead article of the top events, then re-summarise those
        if config.FULLTEXT_TOP_N > 0:
            _stage("fetching full text", f"top {config.FULLTEXT_TOP_N}")
            by_url = {a["url"]: a for a in articles}
            targets = [e["lead_url"] for e in events[:config.FULLTEXT_TOP_N] if not by_url[e["lead_url"]].get("fulltext")]
            texts = asyncio.run(fetch_fulltexts(targets))
            for u, t in texts.items():
                store.set_fulltext(u, t); by_url[u]["fulltext"] = t
            for e in events[:config.FULLTEXT_TOP_N]:
                lead = by_url[e["lead_url"]]
                if lead.get("fulltext"):
                    lp0 = "en" if "en" in e["languages"] else e["languages"][0]
                    docs = [(lead["fulltext"], lead["outlet_name"])] + \
                           [((a.get("extract") or ""), a["outlet"]) for a in e["articles"][1:10] if (a.get("lang") or "en") == lp0]
                    lp = "en" if "en" in e["languages"] else e["languages"][0]
                    docs = [d for d in docs if d[0]]
                    e["summary"] = SUMMARIZER.summarize(docs, k=config.SUMMARY_SENTENCES, lang=lp)
                    for sent in e["summary"]:
                        sent["lang"] = lp
                    e["reading_seconds"] = _reading_seconds(e)
        n_brief, brief_secs = select_brief(events, config.BRIEF_MINUTES)
        health = store.feed_health()
        countries_covered = sorted({a["outlet_country"] for a in articles if a["outlet_country"] in COUNTRY_BY_CODE})
        meta = {
            "generated_at": time.time(), "window_hours": config.WINDOW_HOURS, "article_count": len(articles),
            "event_count": len(events), "brief_events": n_brief, "brief_seconds": brief_secs, "brief_minutes": config.BRIEF_MINUTES,
            "feeds_ok": sum(1 for h in health if h["last_ok"] and h["last_ok"] >= h["last_try"] - 1),
            "feeds_failed": sum(1 for h in health if not h["last_ok"] or h["last_ok"] < h["last_try"] - 1),
            "countries_covered": len(countries_covered), "countries_total": len(COUNTRY_BY_CODE),
            "new_articles": new, "models": MODELS.info(), "duration_s": round(time.time() - t0, 1),
        }
        tmp = config.EVENTS_PATH.with_suffix(".tmp")
        with open(tmp, "w") as f:
            json.dump({"meta": meta, "events": events}, f, ensure_ascii=False)
        tmp.replace(config.EVENTS_PATH)
        store.prune()
        store.prune_translations()
        STATUS.update(last_run=time.time(), last_duration=meta["duration_s"])
        _stage("idle")
        log.info("refresh done: %d events, %d in brief (%.0fs)", len(events), n_brief, time.time() - t0)
        return True
    except Exception as ex:  # noqa: BLE001
        log.exception("refresh failed")
        STATUS["last_error"] = f"{type(ex).__name__}: {ex}"
        _stage("idle")
        return False

def load_events():
    try:
        with open(config.EVENTS_PATH) as f:
            return json.load(f)
    except FileNotFoundError:
        return {"meta": None, "events": []}

if __name__ == "__main__":
    import sys
    run(fetch="--no-fetch" not in sys.argv)
