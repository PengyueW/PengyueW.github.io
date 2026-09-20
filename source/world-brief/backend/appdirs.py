"""Where a packaged World Brief keeps its data, and where it reads its bundled assets.

Run from a checkout, everything lives next to the source tree, exactly as before. Run from a
PyInstaller bundle, read-only assets come out of the bundle and writable state goes to the
per-user location each operating system expects, so an app installed in /Applications or
C:\\Program Files still has somewhere to put a 300 MB database.
"""
import os
import sys
from pathlib import Path

APP_NAME = "World Brief"
APP_ID = "WorldBrief"

def frozen() -> bool:
    return bool(getattr(sys, "frozen", False))

def bundle_dir() -> Path:
    """Directory holding read-only resources (frontend, i18n) in a packaged build."""
    if frozen():
        return Path(getattr(sys, "_MEIPASS", Path(sys.executable).parent))
    return Path(__file__).resolve().parent.parent

def user_data_dir() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / APP_ID
    if os.name == "nt":
        base = os.environ.get("LOCALAPPDATA") or os.environ.get("APPDATA")
        return Path(base or Path.home() / "AppData" / "Local") / APP_ID
    base = os.environ.get("XDG_DATA_HOME")
    return Path(base or Path.home() / ".local" / "share") / APP_ID.lower()

def user_log_dir() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Logs" / APP_ID
    if os.name == "nt":
        return user_data_dir() / "logs"
    base = os.environ.get("XDG_STATE_HOME")
    return Path(base or Path.home() / ".local" / "state") / APP_ID.lower()

def user_config_dir() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / APP_ID
    if os.name == "nt":
        return user_data_dir()
    base = os.environ.get("XDG_CONFIG_HOME")
    return Path(base or Path.home() / ".config") / APP_ID.lower()

def default_data_dir() -> Path:
    return user_data_dir() if frozen() else bundle_dir() / "data"
