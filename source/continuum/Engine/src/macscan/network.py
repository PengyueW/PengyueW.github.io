"""PHASE 2 — live network socket & C2 analysis.

Enumerates established and listening sockets, cross-references every remote
endpoint against the C2 indicators in iocs.py, and looks for process
masquerade: a binary using the name of an Apple system daemon while running
from outside that daemon's canonical path and holding a live network socket.
Read-only; uses lsof (no raw-socket capture, so no entitlement needed).
"""
import os
import re

from . import iocs, signatures, utils
from .finding import Finding

# host:port endpoint from lsof's NAME column, e.g. 1.2.3.4:443 or [::1]:22
_ENDPOINT = re.compile(r"->(?:\[([0-9a-fA-F:]+)\]|([\d.]+)|([^:]+)):(\d+)")


def scan(deep=False, forensic=False):
    if not (deep or forensic):
        return []
    rc, out, err = utils.run(
        ["lsof", "-nP", "-iTCP", "-sTCP:ESTABLISHED"], timeout=30)
    if rc == -1:
        utils.record_blindspot("network sockets", "lsof unavailable: " + err.strip())
        return []
    pid_paths = _pid_paths()
    findings, seen = [], set()
    for line in out.splitlines()[1:]:
        cols = line.split()
        if len(cols) < 9:
            continue
        proc_name, pid, name_field = cols[0], cols[1], cols[-1]
        host = _remote_host(name_field)
        path = pid_paths.get(pid, "")
        key = (pid, host)
        if key in seen:
            continue
        seen.add(key)

        fam = iocs.match_ip(host) or iocs.match_domain(host)
        if fam:
            findings.append(Finding(
                "critical", "network", f"Connection to known spyware C2 ({fam})",
                f"{proc_name} (pid {pid}{', ' + path if path else ''}) is connected to "
                f"{host}, a published spyware indicator.",
                remediation="Disconnect from the network immediately and preserve "
                            "the machine for forensic analysis."))
            continue
        # Process masquerade: Apple-daemon name, non-canonical path, live socket.
        canon = iocs.daemon_canonical_prefix(proc_name)
        if canon and path and path.startswith("/") and not path.startswith(canon):
            findings.append(Finding(
                "high", "network", "System-daemon name with an external connection from the wrong path",
                f"{proc_name} (pid {pid}) runs from {path} (expected under {canon}) and "
                f"holds a live connection to {host}. This is the signature of process "
                "masquerade.", [path]))
            continue
        why = signatures.in_suspicious_location(path)
        if why:
            findings.append(Finding(
                "high", "network", "Program in a suspicious location has a live connection",
                f"{proc_name} (pid {pid}) at {path} — {why}; connected to {host}.",
                [path], removable=True))
    if forensic:
        findings += _scan_listeners(pid_paths)
    return findings


def _scan_listeners(pid_paths):
    rc, out, _ = utils.run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN"], timeout=25)
    if rc != 0:
        return []
    findings, seen = [], set()
    for line in out.splitlines()[1:]:
        cols = line.split()
        if len(cols) < 9:
            continue
        proc_name, pid = cols[0], cols[1]
        path = pid_paths.get(pid, "")
        canon = iocs.daemon_canonical_prefix(proc_name)
        if canon and path and not path.startswith(canon) and path not in seen:
            seen.add(path)
            findings.append(Finding(
                "high", "network", "System-daemon name is listening from the wrong path",
                f"{proc_name} (pid {pid}) listens for connections but runs from {path} "
                f"(expected under {canon}).", [path]))
    return findings


def _remote_host(name_field):
    m = _ENDPOINT.search(name_field)
    if not m:
        return name_field
    return (m.group(1) or m.group(2) or m.group(3) or "").rstrip(".")


def _pid_paths():
    """Map pid -> executable path via ps (lsof's command column is truncated)."""
    rc, out, _ = utils.run(["ps", "-axo", "pid=,comm="])
    mapping = {}
    if rc == 0:
        for line in out.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2:
                mapping[parts[0]] = parts[1]
    return mapping
