"""One running copy per user: a second click raises the first window instead of starting a server.

The lock is a loopback listening socket, which the operating system releases even when the
process is killed — no stale PID file to clean up.
"""
import socket
import threading

HOST = "127.0.0.1"
CONTROL_PORT = 8763          # fixed so a second launch knows where to knock
SHOW = b"show\n"

class Singleton:
    def __init__(self, on_show=None, port=CONTROL_PORT):
        self.port = port
        self.on_show = on_show
        self._sock = None

    def acquire(self):
        """True when this process is the only one; False when another already holds the lock."""
        s = socket.socket()
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 0)
        try:
            s.bind((HOST, self.port))
        except OSError:
            s.close()
            return False
        s.listen(4)
        self._sock = s
        threading.Thread(target=self._serve, daemon=True, name="singleton").start()
        return True

    def _serve(self):
        while self._sock is not None:
            try:
                conn, _ = self._sock.accept()
            except OSError:
                return
            with conn:
                try:
                    if conn.recv(64).startswith(b"show") and self.on_show:
                        self.on_show()
                except OSError:
                    pass

    def signal_existing(self):
        """Ask the instance already running to show itself. True when it answered."""
        try:
            with socket.create_connection((HOST, self.port), timeout=2) as c:
                c.sendall(SHOW)
            return True
        except OSError:
            return False

    def release(self):
        s, self._sock = self._sock, None
        if s is not None:
            try:
                s.close()
            except OSError:
                pass
