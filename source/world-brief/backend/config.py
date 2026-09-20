"""Runtime configuration (all overridable via environment variables)."""
import os
from pathlib import Path

from . import appdirs

# In a checkout ROOT is the source tree; in a packaged app it is the read-only bundle.
ROOT = appdirs.bundle_dir()
DATA_DIR = Path(os.environ.get("NEWS_DATA_DIR") or appdirs.default_data_dir())
DATA_DIR.mkdir(parents=True, exist_ok=True)
LOG_DIR = Path(os.environ.get("NEWS_LOG_DIR") or (appdirs.user_log_dir() if appdirs.frozen() else DATA_DIR))
DB_PATH = DATA_DIR / "news.db"
EVENTS_PATH = DATA_DIR / "events.json"
FRONTEND_DIR = ROOT / "frontend"

def _int(name, default):
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default

def _bool(name, default):
    v = os.environ.get(name)
    if v is None:
        return default
    return v.strip().lower() in ("1", "true", "yes", "on")

REFRESH_MINUTES = _int("NEWS_REFRESH_MINUTES", 30)
WINDOW_HOURS = _int("NEWS_WINDOW_HOURS", 48)          # how far back events are built from
FEED_CONCURRENCY = _int("NEWS_FEED_CONCURRENCY", 24)
FEED_TIMEOUT = _int("NEWS_FEED_TIMEOUT", 20)
MAX_ITEMS_PER_FEED = _int("NEWS_MAX_ITEMS_PER_FEED", 60)

# Google News national editions guarantee at least one outlet per nation.
GNEWS_NATIONAL = _bool("NEWS_GNEWS_NATIONAL", True)
# English search feeds "about" a country: only for countries with no direct outlet unless forced.
GNEWS_SEARCH_ALL = _bool("NEWS_GNEWS_SEARCH_ALL", False)

# Full-text extraction for the lead article of the top N events (adds N HTTP requests).
FULLTEXT_TOP_N = _int("NEWS_FULLTEXT_TOP_N", 20)

# Local ML models (no external AI services). Models are trained on the scraped corpus itself.
MODEL_DIR = DATA_DIR / "models"
MODEL_DIR.mkdir(parents=True, exist_ok=True)
RETRAIN_EACH_REFRESH = _bool("NEWS_RETRAIN", True)
TOPIC_MODEL_THRESHOLD = float(os.environ.get("NEWS_TOPIC_THRESHOLD", "0.65"))
SUMMARY_SENTENCES = _int("NEWS_SUMMARY_SENTENCES", 3)

# Clustering
CLUSTER_SIM_THRESHOLD = float(os.environ.get("NEWS_CLUSTER_SIM", "0.42"))
CLUSTER_ENTITY_JACCARD = float(os.environ.get("NEWS_CLUSTER_ENTITY_JACCARD", "0.6"))

# Daily brief sizing
BRIEF_MINUTES = _int("NEWS_BRIEF_MINUTES", 15)
READING_WPM = _int("NEWS_READING_WPM", 230)

# ---------------------------------------------------------------------------------------------
# Translation (fully local: CTranslate2 + SentencePiece running Argos/OpenNMT open-source models).
# Nothing is sent to an external service; language packages are downloaded once and run offline.
TRANSLATE_DIR = DATA_DIR / "translate"
TRANSLATE_DIR.mkdir(parents=True, exist_ok=True)
TRANSLATE_ENABLED = _bool("NEWS_TRANSLATE", True)
# Keep at most this many translation models resident in RAM (~200 MB each while loaded).
TRANSLATE_MODELS_IN_MEMORY = _int("NEWS_TRANSLATE_MODELS_IN_MEMORY", 4)
TRANSLATE_BEAM = _int("NEWS_TRANSLATE_BEAM", 2)
TRANSLATE_THREADS = _int("NEWS_TRANSLATE_THREADS", 4)
TRANSLATE_MAX_CHARS = _int("NEWS_TRANSLATE_MAX_CHARS", 4000)   # per request text cap
# Where the open-source Argos language packages are listed / hosted.
TRANSLATE_INDEX_URL = os.environ.get(
    "NEWS_TRANSLATE_INDEX_URL",
    "https://raw.githubusercontent.com/argosopentech/argospm-index/main/index.json",
)
# Optional: your own self-hosted LibreTranslate (open source) as a fallback engine, e.g.
# NEWS_TRANSLATE_ENDPOINT=http://localhost:5000  — left empty, nothing leaves this machine.
TRANSLATE_ENDPOINT = os.environ.get("NEWS_TRANSLATE_ENDPOINT", "").strip().rstrip("/")
TRANSLATE_ENDPOINT_KEY = os.environ.get("NEWS_TRANSLATE_ENDPOINT_KEY", "").strip()

# Interface language served when the browser asks for nothing in particular.
DEFAULT_UI_LANG = os.environ.get("NEWS_UI_LANG", "en")

USER_AGENT = os.environ.get(
    "NEWS_USER_AGENT",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36",
)
