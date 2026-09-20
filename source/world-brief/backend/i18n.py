"""Interface languages.

The strings themselves live in `frontend/i18n/<code>.json` so the browser can fetch one file and
render without a round trip. This module is the registry: which locales exist, how complete each
one is against English, and what to serve when a browser asks for one.
"""
import json
import threading

from . import config
from .translate import ENGLISH_NAMES, LANGUAGE_NAMES, RTL, norm

I18N_DIR = config.FRONTEND_DIR / "i18n"
BASE = "en"

_lock = threading.Lock()
_cache: dict[str, tuple[float, dict]] = {}

def _path(code):
    return I18N_DIR / f"{norm(code)}.json"

def load(code):
    """Parsed locale file, reloaded when it changes on disk (so editing a translation is instant)."""
    code = norm(code)
    p = _path(code)
    try:
        m = p.stat().st_mtime
    except OSError:
        return None
    with _lock:
        hit = _cache.get(code)
        if hit and hit[0] == m:
            return hit[1]
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    with _lock:
        _cache[code] = (m, data)
    return data

def codes():
    if not I18N_DIR.is_dir():
        return []
    return sorted(p.stem for p in I18N_DIR.glob("*.json"))

def locales():
    """Every shipped interface language, with how much of it is actually translated."""
    base = load(BASE) or {}
    n_base = len(base) or 1
    out = []
    for c in codes():
        d = load(c) or {}
        # A value is either a string or a set of plural forms; both count as translated.
        done = sum(1 for k, v in d.items()
                   if k in base and (v.strip() if isinstance(v, str) else bool(v)))
        out.append({
            "code": c,
            "name": LANGUAGE_NAMES.get(c, c),
            "english_name": ENGLISH_NAMES.get(c, c),
            "dir": "rtl" if c in RTL else "ltr",
            "complete": round(100 * done / n_base),
        })
    out.sort(key=lambda x: (x["code"] != BASE, x["english_name"]))
    return out

def best_match(accept_language: str | None):
    """Pick a shipped locale for an Accept-Language header, falling back to the configured default."""
    have = set(codes())
    for part in (accept_language or "").split(","):
        tag = part.split(";")[0].strip()
        if not tag:
            continue
        c = norm(tag)
        if c in have:
            return c
    return config.DEFAULT_UI_LANG if config.DEFAULT_UI_LANG in have else BASE
