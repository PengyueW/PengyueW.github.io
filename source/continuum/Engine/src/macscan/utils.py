"""Shared helpers: subprocess wrapper, plist parsing, code-signature checks."""
import functools
import os
import plistlib
import re
import subprocess

HOME = os.path.expanduser("~")

# Statuses considered Apple-shipped code.
APPLE_STATUSES = ("platform", "app-store")
TRUSTED_STATUSES = ("platform", "app-store", "developer-id")

# Never offer these for removal: SIP-protected or system-critical roots.
# (/etc is a symlink to /private/etc on macOS; removal_target checks the
# resolved path too, so both spellings are covered.)
PROTECTED_PREFIXES = (
    "/System/", "/usr/bin/", "/usr/sbin/", "/usr/lib/", "/usr/libexec/",
    "/bin/", "/sbin/", "/etc/", "/private/etc/", "/Library/Apple/",
    "/opt/homebrew/",
)

# Helper binaries (codesign, ps, log, lsof…) must come from the system
# locations only — a user-writable PATH entry must not be able to shadow them
# with a trojan that lies to the scanner.
_SAFE_PATH = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/libexec"


def is_protected_path(path):
    """True if a path (or what it resolves to) is under a protected prefix."""
    norm = os.path.normpath(path)
    real = os.path.realpath(norm)
    return any((p + "/").startswith(PROTECTED_PREFIXES)
               for p in (norm, real))


def run(cmd, timeout=30):
    """Run a command, returning (returncode, stdout, stderr). Never raises.

    A return code of -1 means the command could not run (missing binary,
    timeout, permission error); stderr carries the reason.
    """
    try:
        env = dict(os.environ, PATH=_SAFE_PATH)
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout, env=env)
        return p.returncode, p.stdout, p.stderr
    except (subprocess.TimeoutExpired, FileNotFoundError, PermissionError, OSError) as e:
        return -1, "", str(e)


# ---- Blind-spot ledger -----------------------------------------------------
# Forensic-grade honesty: every place the scan was denied access is recorded so
# the final report can state exactly where it could not look. A spyware implant
# that hides behind SIP/TCC produces no findings but DOES produce blind spots,
# which is the signal the user needs.
_BLINDSPOTS = []


def record_blindspot(path, reason):
    """Note a location the scan could not read (permission/SIP/missing tool)."""
    _BLINDSPOTS.append({"path": str(path), "reason": str(reason)})


def blindspots():
    return list(_BLINDSPOTS)


def reset_blindspots():
    _BLINDSPOTS.clear()


def is_root():
    return os.geteuid() == 0


def read_plist(path):
    try:
        with open(path, "rb") as f:
            return plistlib.load(f)
    except Exception:
        return None


def sqlite_query_ro(path, sql, params=()):
    """Run a read-only query against a SQLite DB.

    Returns (rows, error). rows is None on failure and error explains why
    (used to distinguish 'permission denied' from 'table absent').
    """
    import sqlite3
    if not os.path.exists(path):
        return None, "not present"
    try:
        con = sqlite3.connect(f"file:{path}?mode=ro&immutable=1", uri=True, timeout=3)
        try:
            return con.execute(sql, params).fetchall(), ""
        finally:
            con.close()
    except sqlite3.OperationalError as e:
        msg = str(e)
        if "unable to open" in msg or "authorization denied" in msg or "permission" in msg:
            return None, "permission denied"
        return None, msg
    except sqlite3.Error as e:
        return None, str(e)


@functools.lru_cache(maxsize=4096)
def codesign_info(path):
    """Classify the code signature of a binary or bundle.

    Returns (status, leaf_authority) where status is one of:
    platform | app-store | developer-id | signed | adhoc | unsigned |
    invalid | missing | unknown
    """
    if not os.path.exists(path):
        return ("missing", "")
    rc, _, err = run(["codesign", "-dvv", path], timeout=20)
    if rc != 0:
        if "not signed" in err:
            return ("unsigned", "")
        return ("unknown", "")
    if "Signature=adhoc" in err or "(adhoc)" in err:
        return ("adhoc", "")
    authorities = re.findall(r"Authority=(.+)", err)
    leaf = authorities[0].strip() if authorities else ""
    rc2, _, _ = run(["codesign", "--verify", path], timeout=45)
    if rc2 == -1:
        return ("unknown", leaf)
    if rc2 != 0:
        return ("invalid", leaf)
    if leaf == "Software Signing":
        return ("platform", leaf)
    if leaf == "Apple Mac OS Application Signing":
        return ("app-store", leaf)
    if leaf.startswith("Developer ID Application"):
        return ("developer-id", leaf)
    return ("signed", leaf)


def removal_target(program):
    """Map an executable path to what should be quarantined, or None.

    Climbs to the outermost .app bundle so the whole bundle moves together,
    and refuses anything under a protected system prefix.
    """
    if not program or not program.startswith("/") or not os.path.lexists(program):
        return None
    norm = os.path.normpath(program)
    if is_protected_path(norm):
        return None
    parts = norm.split("/")
    for i, comp in enumerate(parts):
        if comp.endswith(".app"):
            return "/".join(parts[: i + 1])
    return norm
