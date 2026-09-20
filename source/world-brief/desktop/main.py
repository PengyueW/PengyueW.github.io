"""World Brief, as a native desktop application.

One process holds everything: the FastAPI server on a loopback port, the refresh scheduler that
keeps fetching while the window is closed, and a native window showing the same interface the
browser version shows. One click on the icon is the whole launch procedure.

    --background   start with no visible window (used by the launch-at-login entry)
    --no-window    run headless: server and scheduler only, no GUI at all
    --port N       serve on this port instead of the saved one (0 = any free port)
"""
import argparse
import logging
import logging.handlers
import os
import sys
import threading
import time
import webbrowser

# The package must be importable when PyInstaller starts us from an arbitrary directory.
if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from backend import appdirs                                   # noqa: E402
from desktop import __version__, notify, settings, singleton, tray   # noqa: E402
from desktop.server import Server                             # noqa: E402

log = logging.getLogger("worldbrief")

def setup_logging():
    directory = appdirs.user_log_dir() if appdirs.frozen() else appdirs.default_data_dir()
    try:
        directory.mkdir(parents=True, exist_ok=True)
        handler = logging.handlers.RotatingFileHandler(
            directory / "worldbrief.log", maxBytes=2_000_000, backupCount=3, encoding="utf-8")
    except OSError:
        handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    root.addHandler(handler)
    if not appdirs.frozen():
        root.addHandler(logging.StreamHandler(sys.stderr))

class App:
    """Everything the menus, the tray and the window need to ask of the running application."""

    def __init__(self, args):
        self.args = args
        self.conf = settings.load()
        self.server = None
        self.window = None
        self.icon = None
        self.lock = singleton.Singleton(on_show=self.show_window)
        self._quitting = False
        self._last_brief = None

    # ------------------------------------------------------------------ lifecycle

    def start_server(self):
        port = self.args.port if self.args.port is not None else self.conf["port"]
        self.server = Server(port).start()
        if not self.server.wait_ready():
            raise RuntimeError("the World Brief server did not become ready")
        log.info("serving on %s", self.server.url)
        if self.server.port != port:
            # Falling back to a free port is temporary on purpose: the saved port stays the one
            # to try first, so the address the phone was told about does not drift away.
            log.info("port %s was busy", port)
        return self.server.url

    def watch_briefs(self):
        """Notify once a refresh has produced a newer brief than the one we last saw."""
        from backend import pipeline

        self._last_brief = pipeline.STATUS.get("last_run")
        while not self._quitting:
            time.sleep(20)
            last = pipeline.STATUS.get("last_run")
            if last and last != self._last_brief:
                first = self._last_brief is None
                self._last_brief = last
                if settings.get("notify_on_brief", True) and not first:
                    notify.notify("World Brief", "A new brief is ready.")

    def quit(self, *_):
        if self._quitting:
            return
        self._quitting = True
        log.info("shutting down")
        tray.stop(self.icon)
        if self.window is not None:
            try:
                self.window.destroy()
            except Exception:  # noqa: BLE001
                pass
        if self.server is not None:
            self.server.stop()
        self.lock.release()
        if self.args.no_window:
            os._exit(0)

    # ------------------------------------------------------------------ actions

    def is_refreshing(self):
        from backend import pipeline
        return bool(pipeline.STATUS.get("running"))

    def refresh_now(self, *_):
        from backend import pipeline
        if pipeline.STATUS.get("running"):
            return
        threading.Thread(target=pipeline.run, daemon=True, name="manual-refresh").start()

    def open_in_browser(self, *_):
        if self.server is not None:
            webbrowser.open(self.server.url)

    def open_data_folder(self, *_):
        from backend import config
        notify.open_path(config.DATA_DIR)

    def open_log_folder(self, *_):
        from backend import config
        notify.open_path(config.LOG_DIR)

    def autostart_enabled(self):
        from desktop import autostart
        return autostart.enabled()

    def toggle_autostart(self, *_):
        from desktop import autostart
        want = not autostart.enabled()
        if autostart.set_enabled(want):
            settings.save({"autostart": want})

    def show_window(self, *_):
        """Bring the interface back — from the tray, the Dock, or a second launch."""
        if self.window is None:
            return
        try:
            self.window.show()
            self.window.restore()
            if sys.platform == "darwin":
                self._mac_unhide()
        except Exception:  # noqa: BLE001
            pass

    # ------------------------------------------------------------------ macOS niceties

    def _mac_unhide(self):
        try:
            from AppKit import NSApplication
            NSApplication.sharedApplication().unhide_(None)
            NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
        except Exception:  # noqa: BLE001
            pass

    def _mac_hide(self):
        """Hide the application rather than closing it: the Dock icon brings it straight back."""
        try:
            from AppKit import NSApplication
            NSApplication.sharedApplication().hide_(None)
            return True
        except Exception:  # noqa: BLE001
            return False

    @staticmethod
    def _mac_quit_requested():
        """Cmd-Q, the Dock's Quit and the red close button all arrive as the same event.

        The one thing that tells them apart is who asked: AppKit routes a real quit through
        applicationShouldTerminate:, so a frame with that name means the user wants out, not
        merely a window out of the way.
        """
        frame = sys._getframe()
        while frame is not None:
            if frame.f_code.co_name == "applicationShouldTerminate_":
                return True
            frame = frame.f_back
        return False

    # ------------------------------------------------------------------ window

    def on_closing(self):
        """False cancels the close, leaving the refresher running in the background."""
        if self._quitting or not settings.get("close_hides_window", True):
            return True
        if sys.platform == "darwin":
            if self._mac_quit_requested():
                self.remember_geometry()
                return True
            self._mac_hide()
            return False
        if self.icon is not None:      # only hide when there is a way back
            self.window.hide()
            return False
        return True

    def remember_geometry(self):
        try:
            w, h = int(self.window.width), int(self.window.height)
            x, y = int(self.window.x), int(self.window.y)
            if w > 400 and h > 300:
                settings.save({"window": {"width": w, "height": h, "x": x, "y": y}})
        except Exception:  # noqa: BLE001
            pass

    def build_menu(self):
        import webview.menu as m

        return [
            m.Menu("Brief", [
                m.MenuAction("Refresh now", self.refresh_now),
                m.MenuSeparator(),
                m.MenuAction("Open in browser", self.open_in_browser),
                m.MenuAction("Show data folder", self.open_data_folder),
                m.MenuAction("Show logs", self.open_log_folder),
                m.MenuSeparator(),
                m.MenuAction("Start at login (toggle)", self.toggle_autostart),
            ]),
            m.Menu("Window", [
                m.MenuAction("Reload", lambda: self.window and self.window.load_url(self.server.url)),
                m.MenuSeparator(),
                m.MenuAction("Quit World Brief", self.quit),
            ]),
        ]

    def run(self):
        """Server, scheduler and a native window. Falls back to the browser with no GUI toolkit."""
        try:
            import webview
        except ImportError:
            log.warning("no webview toolkit available; falling back to the browser")
            return self.run_in_browser()

        url = self.start_server()
        threading.Thread(target=self.watch_briefs, daemon=True, name="brief-watch").start()

        geom = self.conf["window"]
        hidden = bool(self.args.background or self.conf.get("start_minimized"))
        self.window = webview.create_window(
            appdirs.APP_NAME, url,
            width=geom.get("width") or 1280, height=geom.get("height") or 860,
            x=geom.get("x"), y=geom.get("y"),
            min_size=(940, 620), hidden=hidden and sys.platform != "darwin",
            text_select=True, confirm_close=False,
        )
        self.window.events.closing += self.on_closing

        self.icon = tray.start(self)
        notify.set_tray(self.icon)

        def on_start():
            if hidden and sys.platform == "darwin":
                time.sleep(0.4)
                self._mac_hide()

        storage = appdirs.user_data_dir() / "webview" if appdirs.frozen() else None
        kwargs = {"private_mode": False}
        if storage is not None:
            storage.mkdir(parents=True, exist_ok=True)
            kwargs["storage_path"] = str(storage)
        try:
            webview.start(on_start, menu=self.build_menu(), **kwargs)
        except Exception:  # noqa: BLE001 - a Linux box with no WebKitGTK still deserves the app
            log.exception("the native window could not be opened; falling back to the browser")
            self.window = None
            return self.run_in_browser(started=True)
        finally:
            self.remember_geometry()
            self.quit()

    def run_in_browser(self, started=False):
        """Everything the desktop app does, shown in the user's own browser instead."""
        if not started:
            self.start_server()
            threading.Thread(target=self.watch_briefs, daemon=True, name="brief-watch").start()
        self.icon = self.icon or tray.start(self)
        notify.set_tray(self.icon)
        if not (self.args.background or self.conf.get("start_minimized")):
            self.open_in_browser()
        log.info("running in browser mode at %s", self.server.url)
        try:
            while not self._quitting:
                time.sleep(1)
        except KeyboardInterrupt:
            pass
        finally:
            self.quit()

    def run_headless(self):
        self.start_server()
        log.info("headless mode; press Ctrl-C to stop")
        threading.Thread(target=self.watch_briefs, daemon=True, name="brief-watch").start()
        try:
            while True:
                time.sleep(3600)
        except KeyboardInterrupt:
            self.quit()

def parse_args(argv):
    p = argparse.ArgumentParser(prog="worldbrief", description="World Brief desktop application")
    p.add_argument("--background", action="store_true", help="start with the window hidden")
    p.add_argument("--no-window", action="store_true", help="server and scheduler only, no GUI")
    p.add_argument("--port", type=int, default=None, help="loopback port (0 = any free port)")
    p.add_argument("--version", action="version", version=f"World Brief {__version__}")
    return p.parse_args(argv)

def main(argv=None):
    args = parse_args(argv if argv is not None else sys.argv[1:])
    setup_logging()

    conf = settings.load()
    if conf.get("refresh_minutes") and not os.environ.get("NEWS_REFRESH_MINUTES"):
        os.environ["NEWS_REFRESH_MINUTES"] = str(conf["refresh_minutes"])

    app = App(args)
    if not app.lock.acquire():
        # Already running: ask that copy to come forward, and step aside.
        if app.lock.signal_existing():
            log.info("another World Brief is already running; asked it to show itself")
            return 0
        log.warning("the single-instance port is busy but nothing answered; continuing anyway")

    try:
        app.run_headless() if args.no_window else app.run()
    except Exception:  # noqa: BLE001
        log.exception("World Brief failed to start")
        if not args.no_window:
            notify.notify("World Brief", "The application failed to start. See the log for details.")
        app.quit()
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
