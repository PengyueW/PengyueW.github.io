"""Small JSON settings file for the desktop shell, kept beside the user's data."""
import json
import threading

from backend import appdirs

DEFAULTS = {
    "port": 8011,               # 0 picks any free port
    "window": {"width": 1280, "height": 860, "x": None, "y": None, "maximized": False},
    "start_minimized": False,   # begin in the background, window hidden
    "autostart": False,         # launch when the user logs in
    "notify_on_brief": True,    # desktop notification when a new brief is ready
    "refresh_minutes": None,    # None = whatever backend.config decides
    "close_hides_window": True, # closing the window leaves the refresher running
}

_lock = threading.Lock()
_path = appdirs.user_config_dir() / "settings.json"
_cache = None

def _merge(base, override):
    out = dict(base)
    for k, v in (override or {}).items():
        if k in out and isinstance(out[k], dict) and isinstance(v, dict):
            out[k] = _merge(out[k], v)
        elif k in out:
            out[k] = v
    return out

def load():
    global _cache
    with _lock:
        if _cache is None:
            try:
                _cache = _merge(DEFAULTS, json.loads(_path.read_text("utf-8")))
            except (OSError, ValueError):
                _cache = dict(DEFAULTS)
        return dict(_cache)

def save(values):
    global _cache
    with _lock:
        _cache = _merge(_cache or DEFAULTS, values)
        try:
            _path.parent.mkdir(parents=True, exist_ok=True)
            tmp = _path.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(_cache, indent=2), "utf-8")
            tmp.replace(_path)
        except OSError:
            pass
        return dict(_cache)

def get(key, default=None):
    return load().get(key, default)

def path():
    return _path
