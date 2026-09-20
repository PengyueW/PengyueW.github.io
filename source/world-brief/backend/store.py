"""SQLite persistence for articles, feed health and user feedback."""
import json
import sqlite3
import threading
import time
from contextlib import contextmanager

from .config import DB_PATH

_lock = threading.Lock()

SCHEMA = """
CREATE TABLE IF NOT EXISTS articles (
  url TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  summary TEXT,
  fulltext TEXT,
  published REAL NOT NULL,
  fetched REAL NOT NULL,
  outlet_id TEXT, outlet_name TEXT, outlet_country TEXT, lang TEXT,
  leaning TEXT, ownership TEXT, polarity TEXT, tier INTEGER, kind TEXT
);
CREATE INDEX IF NOT EXISTS idx_articles_published ON articles(published);
CREATE TABLE IF NOT EXISTS feed_health (
  feed TEXT PRIMARY KEY, outlet_id TEXT, name TEXT, country TEXT, kind TEXT,
  last_ok REAL, last_try REAL, last_error TEXT, items INTEGER DEFAULT 0, ok_count INTEGER DEFAULT 0, fail_count INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS feedback (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id TEXT, title TEXT, text TEXT, label INTEGER, created REAL
);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS translations (
  k TEXT PRIMARY KEY,           -- sha1(from|to|source text)
  src_lang TEXT, dst_lang TEXT, dst TEXT, engine TEXT, created REAL
);
CREATE INDEX IF NOT EXISTS idx_tr_created ON translations(created);
"""

def connect():
    conn = sqlite3.connect(DB_PATH, check_same_thread=False, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn

_conn = None

def db():
    global _conn
    if _conn is None:
        _conn = connect()
        _conn.executescript(SCHEMA)
        cols = {r[1] for r in _conn.execute("PRAGMA table_info(articles)")}
        for col in ("rules", "geo"):
            if col not in cols:
                _conn.execute(f"ALTER TABLE articles ADD COLUMN {col} TEXT")
        _conn.commit()
    return _conn

@contextmanager
def tx():
    with _lock:
        conn = db()
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise

def upsert_articles(rows):
    """rows: list of dicts with article fields. Returns number of new rows."""
    new = 0
    with tx() as conn:
        for r in rows:
            cur = conn.execute(
                """INSERT OR IGNORE INTO articles
                   (url,title,summary,fulltext,published,fetched,outlet_id,outlet_name,outlet_country,lang,leaning,ownership,polarity,tier,kind)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (r["url"], r["title"], r.get("summary", ""), r.get("fulltext"), r["published"], r["fetched"],
                 r["outlet_id"], r["outlet_name"], r["outlet_country"], r["lang"], r["leaning"], r["ownership"],
                 r["polarity"], r["tier"], r["kind"]))
            new += cur.rowcount
    return new

def set_derived(rows):
    """rows: iterable of (url, rules_json, geo_json)."""
    with tx() as conn:
        conn.executemany("UPDATE articles SET rules=?, geo=? WHERE url=?", [(r, g, u) for u, r, g in rows])

def clear_derived():
    with tx() as conn:
        conn.execute("UPDATE articles SET rules=NULL, geo=NULL")

def set_fulltext(url, text):
    with tx() as conn:
        conn.execute("UPDATE articles SET fulltext=? WHERE url=?", (text, url))

def recent_articles(hours):
    since = time.time() - hours * 3600
    with _lock:
        rows = db().execute("SELECT * FROM articles WHERE published >= ? ORDER BY published DESC", (since,)).fetchall()
    return [dict(r) for r in rows]

def article_count():
    with _lock:
        return db().execute("SELECT COUNT(*) FROM articles").fetchone()[0]

def prune(days=14):
    with tx() as conn:
        conn.execute("DELETE FROM articles WHERE published < ?", (time.time() - days * 86400,))

def record_feed(feed, outlet_id, name, country, kind, ok, items=0, error=None):
    now = time.time()
    with tx() as conn:
        conn.execute("""INSERT INTO feed_health(feed,outlet_id,name,country,kind,last_ok,last_try,last_error,items,ok_count,fail_count)
                        VALUES(?,?,?,?,?,?,?,?,?,?,?)
                        ON CONFLICT(feed) DO UPDATE SET
                          last_try=excluded.last_try,
                          last_ok=CASE WHEN excluded.last_ok IS NOT NULL THEN excluded.last_ok ELSE feed_health.last_ok END,
                          last_error=excluded.last_error, items=excluded.items,
                          ok_count=feed_health.ok_count+excluded.ok_count, fail_count=feed_health.fail_count+excluded.fail_count""",
                     (feed, outlet_id, name, country, kind, now if ok else None, now, error, items, 1 if ok else 0, 0 if ok else 1))

def prune_feed_health(keep_feeds):
    with tx() as conn:
        rows = [r[0] for r in conn.execute("SELECT feed FROM feed_health")]
        stale = [(f,) for f in rows if f not in keep_feeds]
        conn.executemany("DELETE FROM feed_health WHERE feed=?", stale)
    return len(stale)

def feed_health():
    with _lock:
        rows = db().execute("SELECT * FROM feed_health ORDER BY country, name").fetchall()
    return [dict(r) for r in rows]

# ---------------------------------------------------------------------------------------------
# Translation cache. Translating a headline costs ~20 ms; re-translating the same headline on every
# render would cost far more than storing it, and events are re-read constantly.

def get_translations(keys):
    """keys: iterable of cache keys. Returns {key: translated text}."""
    keys = list(keys)
    out = {}
    if not keys:
        return out
    with _lock:
        conn = db()
        for i in range(0, len(keys), 400):
            chunk = keys[i:i + 400]
            q = ",".join("?" * len(chunk))
            for r in conn.execute(f"SELECT k, dst FROM translations WHERE k IN ({q})", chunk):
                out[r[0]] = r[1]
    return out

def put_translations(rows):
    """rows: iterable of (key, src_lang, dst_lang, translated, engine)."""
    rows = list(rows)
    if not rows:
        return
    now = time.time()
    with tx() as conn:
        conn.executemany(
            "INSERT OR REPLACE INTO translations(k,src_lang,dst_lang,dst,engine,created) VALUES(?,?,?,?,?,?)",
            [(k, s, d, t, e, now) for k, s, d, t, e in rows])

def translation_stats():
    with _lock:
        n = db().execute("SELECT COUNT(*) FROM translations").fetchone()[0]
    return {"cached": n}

def clear_translations(dst_lang=None):
    with tx() as conn:
        if dst_lang:
            conn.execute("DELETE FROM translations WHERE dst_lang=?", (dst_lang,))
        else:
            conn.execute("DELETE FROM translations")

def prune_translations(days=30):
    with tx() as conn:
        conn.execute("DELETE FROM translations WHERE created < ?", (time.time() - days * 86400,))

def add_feedback(event_id, title, text, label):
    with tx() as conn:
        conn.execute("INSERT INTO feedback(event_id,title,text,label,created) VALUES(?,?,?,?,?)",
                     (event_id, title, text, int(label), time.time()))

def all_feedback():
    with _lock:
        rows = db().execute("SELECT * FROM feedback ORDER BY created DESC").fetchall()
    return [dict(r) for r in rows]

def set_meta(key, value):
    with tx() as conn:
        conn.execute("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                     (key, json.dumps(value)))

def get_meta(key, default=None):
    with _lock:
        row = db().execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
    return json.loads(row[0]) if row else default
