"""Asynchronous RSS/Atom fetching for direct outlets and Google News national editions."""
import asyncio
import calendar
import html
import logging
import re
import time

import feedparser
import httpx

from . import config
from .countries import COUNTRIES, COUNTRY_BY_CODE, gnews_feed_url, gnews_search_url
from .outlets import outlet_records, DIRECT_COUNTRIES, polarity

log = logging.getLogger("fetcher")

TAG_RE = re.compile(r"<[^>]+>")
ANCHOR_RE = re.compile(r"<a[^>]*>(.*?)</a>", re.S | re.I)
WS_RE = re.compile(r"\s+")

URL_RE = re.compile(r"https?://\S+")
BOILER_RE = re.compile(
    r"\s*(read more|continue reading|read the full story|the post .{0,80} appeared first on|"
    r"this article .{0,60}|click here|subscribe|share this|follow us on)\b.*$", re.I | re.S)

def clean_text(s: str, limit: int = 1200) -> str:
    if not s:
        return ""
    s = html.unescape(TAG_RE.sub(" ", s))
    s = URL_RE.sub(" ", s)
    s = BOILER_RE.sub("", s)
    s = WS_RE.sub(" ", s).strip()
    return s[:limit]

def feed_jobs():
    """Build the list of feeds to fetch: direct outlets + one Google News edition per nation."""
    jobs = []
    for o in outlet_records():
        jobs.append(dict(o))
    if config.GNEWS_NATIONAL:
        for c in COUNTRIES:
            code = c[0]
            jobs.append({
                "id": f"gn-{code}", "name": f"Google News {c[1]} edition", "country": code, "lang": c[8].split("-")[0],
                "leaning": "aggregator (national edition)", "ownership": "aggregator", "tier": 2,
                "feed": gnews_feed_url(code), "kind": "gnews-national", "polarity": "other",
            })
            if config.GNEWS_SEARCH_ALL or code not in DIRECT_COUNTRIES:
                jobs.append({
                    "id": f"gs-{code}", "name": f"Google News search: {c[1]}", "country": code, "lang": "en",
                    "leaning": "aggregator (about the country)", "ownership": "aggregator", "tier": 3,
                    "feed": gnews_search_url(code), "kind": "gnews-search", "polarity": "other",
                })
    return jobs

def _entry_time(e):
    for key in ("published_parsed", "updated_parsed", "created_parsed"):
        t = e.get(key)
        if t:
            try:
                return calendar.timegm(t)
            except Exception:
                pass
    return None

def _strip_gnews_title(title: str):
    """Google News titles look like 'Headline - Outlet'. Return (headline, outlet or None)."""
    m = re.match(r"^(.*)\s[-–]\s([^-–]{2,60})$", title)
    if m:
        return m.group(1).strip(), m.group(2).strip()
    return title.strip(), None

def parse_feed(job, content: bytes, now: float):
    fp = feedparser.parse(content)
    if fp.bozo and not fp.entries:
        raise ValueError(str(fp.bozo_exception)[:200])
    rows = []
    cutoff = now - config.WINDOW_HOURS * 3600 - 6 * 3600
    for e in fp.entries[: config.MAX_ITEMS_PER_FEED]:
        url = (e.get("link") or "").strip()
        title = clean_text(e.get("title", ""), 300)
        if not url or not title:
            continue
        ts = _entry_time(e)
        if ts is None:
            ts = now
        if ts < cutoff or ts > now + 3600:
            continue
        summary = clean_text(e.get("summary") or e.get("description") or "", 1500)
        if e.get("content"):
            try:
                c = clean_text(e["content"][0].get("value", ""), 2500)
                if len(c) > len(summary):
                    summary = c
            except Exception:
                pass
        outlet_name, leaning, ownership, pol, tier = job["name"], job["leaning"], job["ownership"], job["polarity"], job["tier"]
        if job["kind"].startswith("gnews"):
            title, src = _strip_gnews_title(title)
            src_title = None
            try:
                src_title = e.get("source", {}).get("title")
            except Exception:
                pass
            outlet_name = src_title or src or job["name"]
            # Google descriptions are HTML lists of related headlines + outlet names: keep only the headlines.
            raw = e.get("summary") or e.get("description") or ""
            heads = [clean_text(h, 200) for h in ANCHOR_RE.findall(raw)]
            heads = [h for h in heads if h and h.lower() != title.lower()]
            summary = " ".join(h.rstrip(".") + "." for h in heads[:5])[:600]
            leaning = "unlabelled (via Google News)"
            ownership = "unknown"
            pol = "other"
            tier = 3
        rows.append({
            "url": url, "title": title, "summary": summary, "fulltext": None, "published": float(ts), "fetched": now,
            "outlet_id": job["id"], "outlet_name": outlet_name, "outlet_country": job["country"], "lang": job["lang"],
            "leaning": leaning, "ownership": ownership, "polarity": pol, "tier": tier, "kind": job["kind"],
        })
    return rows

async def fetch_one(client, sem, job, now):
    async with sem:
        try:
            r = await client.get(job["feed"])
            r.raise_for_status()
            rows = parse_feed(job, r.content, now)
            return job, rows, None
        except Exception as ex:  # noqa: BLE001
            return job, [], f"{type(ex).__name__}: {str(ex)[:160]}"

async def fetch_all(jobs, progress=None):
    now = time.time()
    sem = asyncio.Semaphore(config.FEED_CONCURRENCY)
    headers = {"User-Agent": config.USER_AGENT, "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml, */*"}
    timeout = httpx.Timeout(config.FEED_TIMEOUT, connect=10)
    results = []
    async with httpx.AsyncClient(headers=headers, timeout=timeout, follow_redirects=True, http2=False) as client:
        tasks = [fetch_one(client, sem, j, now) for j in jobs]
        done = 0
        for coro in asyncio.as_completed(tasks):
            res = await coro
            results.append(res)
            done += 1
            if progress and done % 50 == 0:
                progress(done, len(jobs))
    return results

PARA_RE = re.compile(r"<p[^>]*>(.*?)</p>", re.S | re.I)
SCRIPT_RE = re.compile(r"<(script|style|noscript)[^>]*>.*?</\1>", re.S | re.I)

NAV_WORDS = re.compile(r"cookie|subscribe|sign up|sign in|log in|iniciar sesi|registrar|all rights reserved|"
                       r"newsletter|follow us|advertisement|menu|navigation|buscar|search|share on", re.I)

def _is_prose(p: str) -> bool:
    """Reject navigation and menu blocks scraped as paragraphs: they are lists of capitalised labels
    with no sentence punctuation ("Mundo Argentina Estados Unidos Colombia ...")."""
    if len(p) < 60 or NAV_WORDS.search(p):
        return False
    words = p.split()
    if len(words) < 10:
        return False
    caps = sum(1 for w in words if w[:1].isupper())
    if caps / len(words) > 0.45:
        return False
    return p.count(".") + p.count(",") + p.count(";") >= 2

def extract_fulltext(html_text: str, limit: int = 2500) -> str:
    """Very small readability heuristic: the prose paragraphs of the page, in order."""
    body = SCRIPT_RE.sub(" ", html_text)
    paras = [clean_text(p, 2000) for p in PARA_RE.findall(body)]
    text = " ".join(p for p in paras if _is_prose(p))
    return text[:limit]

async def fetch_fulltexts(urls):
    """Fetch full article HTML for a handful of URLs and return {url: text}."""
    out = {}
    if not urls:
        return out
    headers = {"User-Agent": config.USER_AGENT}
    sem = asyncio.Semaphore(8)
    async def one(client, u):
        async with sem:
            try:
                r = await client.get(u)
                if r.status_code == 200 and "html" in r.headers.get("content-type", ""):
                    t = extract_fulltext(r.text)
                    if len(t) > 200:
                        out[u] = t
            except Exception:
                pass
    async with httpx.AsyncClient(headers=headers, timeout=httpx.Timeout(12, connect=6), follow_redirects=True) as client:
        await asyncio.gather(*(one(client, u) for u in urls))
    return out
