"""System-tray icon for Windows and Linux.

macOS is deliberately excluded: pystray's Cocoa backend wants the main run loop, which the
webview already owns. There the app lives in the Dock instead and hides rather than quitting.
"""
import os
import sys
from pathlib import Path

from backend import appdirs

def available():
    if sys.platform == "darwin":
        return False
    if not (os.name == "nt" or sys.platform.startswith("linux")):
        return False
    try:
        import PIL  # noqa: F401
        import pystray  # noqa: F401
    except ImportError:
        return False
    # A Linux session with no status-area host would show nothing at all.
    return os.name == "nt" or bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))

def _icon_image():
    from PIL import Image, ImageDraw

    for name in ("icon-256.png", "icon.png"):
        p = appdirs.bundle_dir() / "packaging" / "icons" / name
        if p.exists():
            try:
                return Image.open(p).convert("RGBA")
            except OSError:
                pass
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((4, 4, 60, 60), fill=(18, 32, 58, 255))
    d.ellipse((4, 4, 60, 60), outline=(232, 180, 90, 255), width=3)
    d.line((6, 32, 58, 32), fill=(232, 180, 90, 255), width=3)
    d.ellipse((20, 4, 44, 60), outline=(232, 180, 90, 255), width=3)
    return img

def start(controller):
    """Run a tray icon on its own thread. Returns the icon, or None when unavailable."""
    if not available():
        return None
    import pystray
    from pystray import Menu, MenuItem

    def refreshing(_item):
        return controller.is_refreshing()

    menu = Menu(
        MenuItem("Open World Brief", lambda: controller.show_window(), default=True),
        MenuItem("Refresh now", lambda: controller.refresh_now(), enabled=lambda i: not refreshing(i)),
        Menu.SEPARATOR,
        MenuItem("Open in browser", lambda: controller.open_in_browser()),
        MenuItem("Show data folder", lambda: controller.open_data_folder()),
        Menu.SEPARATOR,
        MenuItem("Start at login", lambda i: controller.toggle_autostart(),
                 checked=lambda i: controller.autostart_enabled()),
        Menu.SEPARATOR,
        MenuItem("Quit World Brief", lambda: controller.quit()),
    )
    try:
        icon = pystray.Icon(appdirs.APP_ID, _icon_image(), appdirs.APP_NAME, menu)
        icon.run_detached()
        return icon
    except Exception:  # noqa: BLE001 - a missing tray host must never stop the app
        return None

def stop(icon):
    if icon is not None:
        try:
            icon.stop()
        except Exception:  # noqa: BLE001
            pass
