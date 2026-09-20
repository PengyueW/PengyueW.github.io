"""Try to repair failing outlet feeds: RSS autodiscovery on the homepage, then common feed paths.
Usage: .venv/bin/python tools/discover_feeds.py  -> writes data/feed_fixes.json  (apply with --apply)"""
import asyncio, json, re, sys, sqlite3
from urllib.parse import urljoin, urlsplit
sys.path.insert(0, ".")
import feedparser, httpx
from backend.outlets import OUTLETS
from backend import config

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36"
PATHS = ["/feed", "/feed/", "/rss", "/rss/", "/rss.xml", "/feed.xml", "/feeds", "/index.rss", "/arc/outboundfeeds/rss/?outputType=xml",
         "/arc/outboundfeeds/rss/", "/rss/news", "/rss/news.xml", "/?feed=rss2", "/feeds/rss", "/rss/latest", "/latest/rss", "/rss/all.xml",
         "/rss/home", "/feed/rss", "/en/rss", "/en/feed", "/en/feed/", "/rss/index.xml", "/feeds/posts/default", "/atom.xml", "/news/rss", "/rss/en"]
LINK_RE = re.compile(r'<link[^>]+type=["\']application/(?:rss|atom)\+xml["\'][^>]*>', re.I)
HREF_RE = re.compile(r'href=["\']([^"\']+)["\']', re.I)

def good(content):
    fp = feedparser.parse(content)
    return len(fp.entries) >= 3 and not (fp.bozo and not fp.entries)

async def probe(client, url):
    try:
        r = await client.get(url)
        if r.status_code == 200 and good(r.content):
            return url
    except Exception:
        pass
    return None

async def discover(client, name, feed):
    if await probe(client, feed):
        return feed, "works with browser UA"
    base = f"{urlsplit(feed).scheme}://{urlsplit(feed).netloc}"
    home = base.replace("://feeds.", "://www.").replace("://rss.", "://www.")
    cands = []
    for h in {home, base}:
        try:
            r = await client.get(h)
            for tag in LINK_RE.findall(r.text[:300000]):
                m = HREF_RE.search(tag)
                if m:
                    cands.append(urljoin(str(r.url), m.group(1)))
        except Exception:
            pass
    for c in cands[:6]:
        if await probe(client, c):
            return c, "autodiscovery"
    for p in PATHS:
        u = base + p
        if await probe(client, u):
            return u, "common path"
    return None, "not found"

async def main():
    db = sqlite3.connect(config.DB_PATH)
    failing = {r[0] for r in db.execute("SELECT feed FROM feed_health WHERE kind='direct' AND last_ok IS NULL")}
    targets = [(o[0], o[6]) for o in OUTLETS if o[6] in failing]
    sem = asyncio.Semaphore(12)
    out = {}
    async with httpx.AsyncClient(headers={"User-Agent": UA, "Accept": "*/*"}, timeout=httpx.Timeout(15, connect=8), follow_redirects=True) as client:
        async def one(name, feed):
            async with sem:
                new, how = await discover(client, name, feed)
                out[feed] = {"name": name, "new": new, "how": how}
                print(f"{name:40s} {how:22s} {new or ''}", flush=True)
        await asyncio.gather(*(one(n, f) for n, f in targets))
    json.dump(out, open("data/feed_fixes.json", "w"), indent=1)
    print(f"\n{sum(1 for v in out.values() if v['new'])}/{len(out)} repaired")

def apply():
    fixes = json.load(open("data/feed_fixes.json"))
    src = open("backend/outlets.py").read()
    n = 0
    for old, v in fixes.items():
        if v["new"] and v["new"] != old:
            src = src.replace(f'"{old}"', f'"{v["new"]}"'); n += 1
    open("backend/outlets.py", "w").write(src)
    print(f"applied {n} url changes to backend/outlets.py")

if __name__ == "__main__":
    apply() if "--apply" in sys.argv else asyncio.run(main())
