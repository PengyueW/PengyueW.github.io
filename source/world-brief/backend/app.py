"""FastAPI server: JSON API + static frontend. Run with: uvicorn backend.app:app --reload"""
import threading
import time
from collections import Counter, defaultdict
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from . import config, i18n, pipeline, store, translate
from .classify import CATEGORIES, CATEGORY_GRAVITY
from .countries import COUNTRIES, COUNTRY_BY_CODE, COUNTRY_NAMES, REGION_BY_CODE
from .outlets import outlet_records

_cache = {"data": None, "mtime": 0.0}

def events_data():
    try:
        m = config.EVENTS_PATH.stat().st_mtime
    except FileNotFoundError:
        return {"meta": None, "events": []}
    if _cache["data"] is None or m != _cache["mtime"]:
        _cache["data"] = pipeline.load_events(); _cache["mtime"] = m
    return _cache["data"]

def _scheduler():
    while True:
        try:
            pipeline.run()
        except Exception:  # noqa: BLE001
            pass
        time.sleep(config.REFRESH_MINUTES * 60)

@asynccontextmanager
async def lifespan(app):
    store.db()
    threading.Thread(target=_scheduler, daemon=True, name="refresh-scheduler").start()
    yield

app = FastAPI(title="World Brief", lifespan=lifespan)
app.mount("/static", StaticFiles(directory=str(config.FRONTEND_DIR)), name="static")

@app.get("/")
def index():
    return FileResponse(config.FRONTEND_DIR / "index.html")

@app.get("/api/status")
def status():
    d = events_data()
    return {"pipeline": pipeline.STATUS, "meta": d["meta"], "articles_in_db": store.article_count(),
            "refresh_minutes": config.REFRESH_MINUTES}

@app.post("/api/refresh")
def refresh():
    if pipeline.STATUS["running"]:
        return {"started": False, "reason": "already running"}
    threading.Thread(target=pipeline.run, daemon=True).start()
    return {"started": True}

def _summary_view(e):
    keys = ("id", "title", "summary", "categories", "primary_category", "primary_location", "locations", "countries_mentioned",
            "countries_covering", "regions", "time_first", "time_last", "relevance", "article_count", "outlet_count", "country_count",
            "polarities", "sides", "divergence", "side_basis", "languages", "lang", "extracts", "reading_seconds", "in_brief", "brief_rank",
            "lead_url", "feedback", "salience", "translation")
    v = {k: e.get(k) for k in keys}
    v["top_outlets"] = [{"outlet": a["outlet"], "country": a["country"], "leaning": a["leaning"], "url": a["url"]} for a in e["articles"][:6]]
    return v

@app.get("/api/events")
def events(brief: bool = False, category: str | None = None, country: str | None = None, region: str | None = None,
           polarity: str | None = None, hours: int | None = None, q: str | None = None, min_articles: int = 1,
           sort: str = "relevance", limit: int = Query(300, le=2000), offset: int = 0):
    d = events_data()
    evs = d["events"]
    now = time.time()
    if brief:
        evs = [e for e in evs if e.get("in_brief")]
        evs.sort(key=lambda e: e["brief_rank"])
    if category:
        evs = [e for e in evs if any(c["id"] == category for c in e["categories"])]
    if country:
        cc = country.upper()
        evs = [e for e in evs if cc in e["countries_mentioned"] or cc in e["countries_covering"]]
    if region:
        evs = [e for e in evs if region in e["regions"]]
    if polarity:
        evs = [e for e in evs if polarity in e["polarities"]]
    if hours:
        evs = [e for e in evs if e["time_last"] >= now - hours * 3600]
    if min_articles > 1:
        evs = [e for e in evs if e["article_count"] >= min_articles]
    if q:
        ql = q.lower()
        evs = [e for e in evs if ql in e["title"].lower() or any(ql in a["title"].lower() for a in e["articles"])]
    if sort == "discussed":
        evs = sorted(evs, key=lambda e: -(e["article_count"] * 2 + e["outlet_count"] * 3 + e["country_count"] * 2 + (8 if e["time_last"] > now - 6 * 3600 else 0)))
    elif sort == "newest":
        evs = sorted(evs, key=lambda e: -e["time_last"])
    elif sort == "divergence":
        # Contested framing only means something when each side has real coverage behind it.
        evs = [e for e in evs if e["article_count"] >= 4 and sum(1 for s in e["sides"] if s["n"] >= 2) >= 2]
        evs = sorted(evs, key=lambda e: -(e["divergence"] * (1 + 0.15 * min(e["country_count"], 8))
                                          * CATEGORY_GRAVITY.get(e["primary_category"], 1.0)))
    total = len(evs)
    return {"meta": d["meta"], "total": total, "events": [_summary_view(e) for e in evs[offset:offset + limit]]}

@app.get("/api/events/{event_id}")
def event(event_id: str, lang: str | None = None):
    for e in events_data()["events"]:
        if e["id"] == event_id:
            if lang and config.TRANSLATE_ENABLED:
                return translate.translate_event(e, lang)
            return e
    raise HTTPException(404, "event not found")

@app.get("/api/map")
def map_data(hours: int | None = None, category: str | None = None, min_relevance: float = 0, min_articles: int = 2):
    d = events_data()
    now = time.time()
    nodes, hot, edges = [], defaultdict(lambda: {"count": 0, "relevance": 0.0, "categories": Counter(), "events": []}), Counter()
    for e in d["events"]:
        if hours and e["time_last"] < now - hours * 3600:
            continue
        if category and not any(c["id"] == category for c in e["categories"]):
            continue
        if e["relevance"] < min_relevance or (e["article_count"] < min_articles and not e.get("in_brief")):
            continue
        loc = e.get("primary_location")
        if loc:
            nodes.append({"id": e["id"], "title": e["title"], "lat": loc["lat"], "lon": loc["lon"], "place": loc["name"],
                          "category": e["primary_category"], "relevance": e["relevance"], "articles": e["article_count"],
                          "outlets": e["outlet_count"], "countries": e["countries_mentioned"][:3], "time_last": e["time_last"],
                          "in_brief": e.get("in_brief", False), "divergence": e["divergence"]})
        for c in e["countries_mentioned"][:3]:
            if c in COUNTRY_BY_CODE:
                h = hot[c]; h["count"] += 1; h["relevance"] += e["relevance"]; h["categories"][e["primary_category"]] += 1
                if len(h["events"]) < 5:
                    h["events"].append({"id": e["id"], "title": e["title"]})
        cm = [c for c in e["countries_mentioned"][:3] if c in COUNTRY_BY_CODE]
        for i in range(len(cm)):
            for j in range(i + 1, len(cm)):
                edges[tuple(sorted((cm[i], cm[j])))] += e["relevance"]
    hotspots = []
    for c, h in hot.items():
        cc = COUNTRY_BY_CODE[c]
        hotspots.append({"country": c, "name": cc[1], "lat": cc[3], "lon": cc[4], "count": h["count"], "relevance": round(h["relevance"], 1),
                         "top_category": h["categories"].most_common(1)[0][0], "events": h["events"]})
    hotspots.sort(key=lambda h: -h["relevance"])
    edge_list = []
    for (a, b), w in edges.most_common(150):
        ca, cb = COUNTRY_BY_CODE[a], COUNTRY_BY_CODE[b]
        edge_list.append({"a": a, "b": b, "a_name": ca[1], "b_name": cb[1], "from": [ca[3], ca[4]], "to": [cb[3], cb[4]], "weight": round(w, 1)})
    return {"meta": d["meta"], "nodes": nodes, "hotspots": hotspots, "edges": edge_list}

# ---------------------------------------------------------------------------------------------
# Interface languages and article translation.

@app.get("/api/i18n/locales")
def locales():
    """The interface languages this build ships, with the direction each is written in."""
    return {"default": config.DEFAULT_UI_LANG, "locales": i18n.locales()}

def _corpus_languages():
    """Which languages today's events are actually written in — the only ones worth installing."""
    counts = Counter()
    for e in events_data()["events"]:
        counts[translate.norm(e.get("lang") or "en")] += e.get("article_count", 1)
    return counts

@app.get("/api/translate/status")
def translate_status(lang: str | None = None):
    st = translate.ENGINE.status()
    target = translate.norm(lang) if lang else None
    counts = _corpus_languages()
    total = sum(counts.values()) or 1
    corpus = []
    for code, n in counts.most_common():
        row = {"code": code, "name": translate.language_name(code), "english_name": translate.ENGLISH_NAMES.get(code, code),
               "articles": n, "share": round(100 * n / total, 1)}
        if target:
            kind, _ = translate.ENGINE.route(code, target)
            row["route"] = kind
            row["needs"] = [{"from": f, "to": t, "from_name": translate.language_name(f), "to_name": translate.language_name(t),
                             "available": bool(translate.INDEX.find(f, t))}
                            for f, t in translate.ENGINE.missing_packages(code, target)]
        corpus.append(row)
    st["corpus"] = corpus
    st["target"] = target
    return st

class PackageRef(BaseModel):
    from_code: str
    to_code: str

@app.post("/api/translate/packages")
def install_package(ref: PackageRef):
    if not translate.ENGINE.local_available:
        raise HTTPException(503, "the local translation engine is not installed (pip install ctranslate2 sentencepiece)")
    try:
        return translate.ENGINE.install(ref.from_code, ref.to_code)
    except ValueError as ex:
        raise HTTPException(404, str(ex)) from ex

@app.delete("/api/translate/packages/{from_code}/{to_code}")
def remove_package(from_code: str, to_code: str):
    translate.ENGINE.remove(from_code, to_code)
    return {"ok": True}

@app.post("/api/translate/index/refresh")
def refresh_index():
    translate.INDEX.items(refresh=True)
    return {"packages": len(translate.INDEX.items())}

@app.delete("/api/translate/cache")
def clear_translation_cache(lang: str | None = None):
    store.clear_translations(translate.norm(lang) if lang else None)
    return {"ok": True}

class TranslateRequest(BaseModel):
    texts: list[str]
    to: str
    from_lang: str | None = None
    langs: list[str] | None = None      # per-text source language, when they differ

@app.post("/api/translate")
def translate_texts(req: TranslateRequest):
    if not config.TRANSLATE_ENABLED:
        raise HTTPException(503, "translation is disabled")
    if len(req.texts) > 400:
        raise HTTPException(413, "at most 400 texts per request")
    target = translate.norm(req.to)
    if req.langs:
        if len(req.langs) != len(req.texts):
            raise HTTPException(400, "langs must be the same length as texts")
        # One call per source language keeps each batch on a single model.
        results = [None] * len(req.texts)
        by_lang = {}
        for i, lg in enumerate(req.langs):
            by_lang.setdefault(translate.norm(lg), []).append(i)
        for lg, idxs in by_lang.items():
            out = translate.ENGINE.translate([req.texts[i] for i in idxs], target, from_code=lg or None)
            for i, r in zip(idxs, out):
                results[i] = r
    else:
        results = translate.ENGINE.translate(req.texts, target, from_code=req.from_lang)
    return {"target": target, "results": results}

@app.get("/api/sources")
def sources():
    health = {h["feed"]: h for h in store.feed_health()}
    out = []
    for o in outlet_records():
        h = health.get(o["feed"], {})
        out.append({**o, "country_name": COUNTRY_NAMES.get(o["country"], o["country"]), "last_ok": h.get("last_ok"), "last_try": h.get("last_try"),
                    "last_error": h.get("last_error"), "items": h.get("items", 0), "ok_count": h.get("ok_count", 0), "fail_count": h.get("fail_count", 0)})
    gn = [{"name": h["name"], "country": h["country"], "country_name": COUNTRY_NAMES.get(h["country"], h["country"]), "kind": h["kind"],
           "last_ok": h["last_ok"], "last_try": h["last_try"], "last_error": h["last_error"], "items": h["items"], "feed": h["feed"]}
          for h in health.values() if h["kind"].startswith("gnews")]
    return {"direct": out, "google_news": gn}

@app.get("/api/categories")
def categories():
    return [{"id": c[0], "label": c[1], "weight": c[2]} for c in CATEGORIES]

@app.get("/api/countries")
def countries():
    return [{"code": c[0], "name": c[1], "region": c[2], "lat": c[3], "lon": c[4]} for c in COUNTRIES]

class Feedback(BaseModel):
    event_id: str
    label: int  # 1 = important to me, -1 = not important

@app.post("/api/feedback")
def feedback(fb: Feedback):
    ev = None
    for e in events_data()["events"]:
        if e["id"] == fb.event_id:
            ev = e; break
    if ev is None:
        raise HTTPException(404, "event not found")
    text = ev["title"] + " " + " ".join(s["sentence"] for s in ev["summary"])
    store.add_feedback(fb.event_id, ev["title"], text, fb.label)
    ev["feedback"] = fb.label
    return {"ok": True}
