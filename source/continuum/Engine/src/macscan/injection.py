"""PHASE 3 — code-injection & dylib-hijack heuristics.

Detects the classic userland injection vectors on macOS:
  * DYLD_INSERT_LIBRARIES set globally (launchctl), in launchd job plists, in
    /etc/launchd.conf, or in shell init files — the macOS equivalent of
    LD_PRELOAD, used to load attacker code into legitimate processes.
  * The same variable present in a running process's environment.
  * Inserted libraries that live in world-writable or hidden locations.

SIP strips DYLD_INSERT_LIBRARIES for platform binaries, so its presence
targeting normal apps is the interesting case. Read-only throughout.
"""
import os
import plistlib
import re

from . import signatures, utils
from .finding import Finding

DYLD_VARS = ("DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH")

LAUNCH_DIRS = [
    "/Library/LaunchDaemons", "/Library/LaunchAgents",
    os.path.join(utils.HOME, "Library/LaunchAgents"),
]
SHELL_FILES = [
    "~/.zshenv", "~/.zshrc", "~/.zprofile", "~/.bashrc", "~/.bash_profile",
    "~/.profile", "/etc/zshenv", "/etc/zshrc", "/etc/zprofile", "/etc/bashrc",
    "/etc/profile",
]


def scan(deep=False, forensic=False):
    if not forensic:
        return []
    return (_check_global_env()
            + _check_launchd_plists()
            + _check_launchd_conf()
            + _check_shell_files()
            + _check_running_procs())


def _flag_lib(libs, where, sev_default="high"):
    """Build a finding for an inserted-library value, escalating if the dylib
    sits somewhere writable."""
    out = []
    for lib in re.split(r"[:\s]+", libs.strip()):
        if not lib:
            continue
        why = signatures.in_suspicious_location(lib)
        sev = "critical" if why else sev_default
        paths = [lib] if (lib.startswith("/") and os.path.exists(lib)) else []
        out.append(Finding(
            sev, "injection", "Library injection configured (DYLD_INSERT_LIBRARIES)",
            f"{where} injects '{lib}' into other processes"
            + (f" — {why}" if why else "") + ". This forces attacker-chosen code to "
            "load inside legitimate programs.",
            paths, removable=bool(paths) and sev == "critical"))
    return out


def _check_global_env():
    out = []
    for var in DYLD_VARS:
        rc, val, _ = utils.run(["launchctl", "getenv", var])
        if rc == 0 and val.strip():
            out += _flag_lib(val, f"a global launchctl environment variable ({var})")
    return out


def _check_launchd_plists():
    out = []
    for d in LAUNCH_DIRS:
        if not os.path.isdir(d):
            continue
        try:
            names = [n for n in os.listdir(d) if n.endswith(".plist")]
        except OSError:
            continue
        for n in names:
            p = os.path.join(d, n)
            try:
                with open(p, "rb") as fh:
                    data = plistlib.load(fh)
            except Exception:
                continue
            env = data.get("EnvironmentVariables")
            if isinstance(env, dict):
                for var in DYLD_VARS:
                    if var in env:
                        out += _flag_lib(str(env[var]), f"launchd job {p} ({var})")
    return out


def _check_launchd_conf():
    out = []
    for conf in ("/etc/launchd.conf", os.path.expanduser("~/.launchd.conf")):
        try:
            with open(conf) as f:
                text = f.read()
        except OSError:
            continue
        for line in text.splitlines():
            for var in DYLD_VARS:
                m = re.search(rf"setenv\s+{var}\s+(\S+)", line)
                if m:
                    out += _flag_lib(m.group(1), f"{conf} ({var})")
    return out


def _check_shell_files():
    out = []
    for sf in SHELL_FILES:
        path = os.path.expanduser(sf)
        try:
            with open(path) as f:
                lines = f.readlines()
        except OSError:
            continue
        for n, line in enumerate(lines, 1):
            for var in DYLD_VARS:
                m = re.search(rf"export\s+{var}=(\S+)", line)
                if m:
                    out += _flag_lib(m.group(1).strip('"\''), f"{path} line {n} ({var})")
    return out


def _check_running_procs():
    """Inspect each process's environment for DYLD injection (ps -E)."""
    rc, out_text, _ = utils.run(["ps", "-axeo", "pid=,command="], timeout=25)
    if rc != 0:
        return []
    findings = []
    for line in out_text.splitlines():
        if "DYLD_INSERT_LIBRARIES=" not in line:
            continue
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        pid, cmd = parts
        m = re.search(r"DYLD_INSERT_LIBRARIES=(\S+)", cmd)
        if not m:
            continue
        prog = cmd.split(" DYLD_INSERT_LIBRARIES")[0]
        findings += _flag_lib(m.group(1), f"running process pid {pid} ({prog[:60]})")
    return findings
