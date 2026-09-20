"""Launch World Brief when the user logs in — a LaunchAgent, a Run key, or an autostart .desktop."""
import os
import plistlib
import subprocess
import sys
from pathlib import Path

from backend import appdirs

LABEL = "com.worldbrief.app"

def _launcher():
    """The command that starts the installed app, as argv."""
    if getattr(sys, "frozen", False):
        if sys.platform == "darwin":
            # .../World Brief.app/Contents/MacOS/World Brief -> open the bundle itself
            exe = Path(sys.executable).resolve()
            for parent in exe.parents:
                if parent.suffix == ".app":
                    return ["/usr/bin/open", "-a", str(parent), "--args", "--background"]
            return [str(exe), "--background"]
        return [sys.executable, "--background"]
    return [sys.executable, "-m", "desktop.main", "--background"]

# --------------------------------------------------------------------------- macOS

def _plist_path():
    return Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"

def _mac_enable():
    p = _plist_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(plistlib.dumps({
        "Label": LABEL,
        "ProgramArguments": _launcher(),
        "RunAtLoad": True,
        "KeepAlive": False,
        "ProcessType": "Interactive",
    }))
    subprocess.run(["launchctl", "unload", str(p)], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["launchctl", "load", str(p)], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def _mac_disable():
    p = _plist_path()
    if p.exists():
        subprocess.run(["launchctl", "unload", str(p)], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        p.unlink(missing_ok=True)

# --------------------------------------------------------------------------- Windows

RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"

def _win_command():
    argv = _launcher()
    return " ".join(f'"{a}"' if " " in a else a for a in argv)

def _win_enable():
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as k:
        winreg.SetValueEx(k, appdirs.APP_ID, 0, winreg.REG_SZ, _win_command())

def _win_disable():
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as k:
            winreg.DeleteValue(k, appdirs.APP_ID)
    except FileNotFoundError:
        pass

def _win_enabled():
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as k:
            winreg.QueryValueEx(k, appdirs.APP_ID)
            return True
    except FileNotFoundError:
        return False

# --------------------------------------------------------------------------- Linux

def _desktop_entry_path():
    base = os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config"
    return Path(base) / "autostart" / "worldbrief.desktop"

def _linux_enable():
    p = _desktop_entry_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    exec_line = " ".join(_launcher())
    p.write_text(
        "[Desktop Entry]\nType=Application\nName=World Brief\n"
        f"Exec={exec_line}\nIcon=worldbrief\nTerminal=false\n"
        "X-GNOME-Autostart-enabled=true\nComment=Keep the world brief up to date\n", "utf-8")

def _linux_disable():
    _desktop_entry_path().unlink(missing_ok=True)

# --------------------------------------------------------------------------- public

def supported():
    return sys.platform == "darwin" or os.name == "nt" or sys.platform.startswith("linux")

def enabled():
    try:
        if sys.platform == "darwin":
            return _plist_path().exists()
        if os.name == "nt":
            return _win_enabled()
        return _desktop_entry_path().exists()
    except OSError:
        return False

def set_enabled(on):
    try:
        if sys.platform == "darwin":
            _mac_enable() if on else _mac_disable()
        elif os.name == "nt":
            _win_enable() if on else _win_disable()
        elif sys.platform.startswith("linux"):
            _linux_enable() if on else _linux_disable()
        else:
            return False
        return True
    except (OSError, ImportError):
        return False
