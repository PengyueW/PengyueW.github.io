"""Desktop notifications, using whatever the platform already provides. Never fatal."""
import os
import shutil
import subprocess
import sys

from backend import appdirs

_tray_backend = None   # set by tray.py so Windows/Linux can use the tray's own balloon

def set_tray(icon):
    global _tray_backend
    _tray_backend = icon

def _quote_applescript(text):
    return text.replace("\\", "\\\\").replace('"', '\\"')

def notify(title, message):
    try:
        if _tray_backend is not None and getattr(_tray_backend, "HAS_NOTIFICATION", False):
            _tray_backend.notify(message, title)
            return True
        if sys.platform == "darwin":
            script = (f'display notification "{_quote_applescript(message)}" '
                      f'with title "{_quote_applescript(title)}"')
            subprocess.run(["osascript", "-e", script], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
            return True
        if os.name == "nt":
            return False    # the tray balloon above is the Windows path
        if shutil.which("notify-send"):
            subprocess.run(["notify-send", "-a", appdirs.APP_NAME, title, message], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
            return True
    except (OSError, subprocess.SubprocessError):
        pass
    return False

def open_path(path):
    """Reveal a folder or file in the system file manager."""
    path = str(path)
    try:
        if sys.platform == "darwin":
            subprocess.Popen(["open", path])
        elif os.name == "nt":
            os.startfile(path)  # noqa: S606
        else:
            subprocess.Popen(["xdg-open", path])
        return True
    except (OSError, subprocess.SubprocessError):
        return False
