"""Runs the FastAPI app inside the desktop process, on a loopback port only this machine sees."""
import logging
import socket
import threading
import time
import urllib.error
import urllib.request

HOST = "127.0.0.1"
log = logging.getLogger("worldbrief.server")

def free_port(preferred=0):
    """The preferred port when it is free, otherwise whatever the OS hands out."""
    for candidate in ([preferred] if preferred else []) + [0]:
        s = socket.socket()
        try:
            s.bind((HOST, candidate))
            return s.getsockname()[1]
        except OSError:
            continue
        finally:
            s.close()
    raise RuntimeError("no free loopback port")

class Server:
    """A uvicorn instance on a daemon thread, with a clean shutdown."""

    def __init__(self, port=0):
        self.port = free_port(port)
        self._server = None
        self._thread = None

    @property
    def url(self):
        return f"http://{HOST}:{self.port}"

    def start(self):
        import uvicorn

        from backend.app import app

        config = uvicorn.Config(app, host=HOST, port=self.port, log_level="warning",
                                access_log=False, loop="asyncio", lifespan="on")
        self._server = uvicorn.Server(config)
        # uvicorn installs signal handlers only on the main thread; off it, it skips them.
        self._thread = threading.Thread(target=self._server.run, daemon=True, name="uvicorn")
        self._thread.start()
        return self

    def wait_ready(self, timeout=60.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self._thread and not self._thread.is_alive():
                raise RuntimeError("the World Brief server stopped while starting up")
            try:
                with urllib.request.urlopen(self.url + "/api/status", timeout=2) as r:
                    if r.status == 200:
                        return True
            except (urllib.error.URLError, OSError):
                time.sleep(0.15)
        return False

    def stop(self, timeout=8.0):
        if self._server is not None:
            self._server.should_exit = True
        if self._thread is not None:
            self._thread.join(timeout)
