"""Scan running processes for malware: known-bad paths, deleted binaries,
unsigned code, and (deep) suspicious network listeners."""
import os

from . import signatures, utils
from .finding import Finding

TRUSTED_PREFIXES = (
    "/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/",
    "/opt/homebrew/", "/nix/",
)
MAX_CODESIGN_CHECKS = 80


def scan(deep=False, forensic=False):
    rc, out, err = utils.run(["ps", "-axo", "pid=,user=,comm="])
    if rc != 0:
        return [Finding("info", "processes", "Process listing failed", err or "ps failed")]
    by_path = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3 or not parts[2].startswith("/"):
            continue
        by_path.setdefault(parts[2], []).append(parts[0])

    findings = []
    for path, pids in sorted(by_path.items()):
        pid_list = ", ".join(pids)
        family = signatures.match_path(path)
        if family:
            findings.append(Finding(
                "critical", "processes", f"Known malware process running ({family})",
                f"{path} (pid {pid_list})", [path], removable=True))
            continue
        why = signatures.in_suspicious_location(path)
        if why:
            findings.append(Finding(
                "high", "processes", "Process running from suspicious location",
                f"{path} (pid {pid_list}) — {why}", [path], removable=True))
            continue
        if not os.path.exists(path):
            findings.append(Finding(
                "medium", "processes", "Process running from deleted executable",
                f"{path} (pid {pid_list}) — the binary was deleted after launch, "
                "a common malware trick (can also be a recently updated app)."))

    checked = 0
    for path in sorted(by_path):
        if checked >= MAX_CODESIGN_CHECKS:
            break
        if path.startswith(TRUSTED_PREFIXES) or not os.path.exists(path):
            continue
        checked += 1
        status, _ = utils.codesign_info(path)
        if status == "invalid":
            findings.append(Finding(
                "medium", "processes", "Running program has a broken code signature",
                f"{path} — modified after signing, or corrupted."))
        elif status == "unsigned":
            severity = "medium" if path.startswith(("/Users/", "/private/", "/tmp/")) else "review"
            findings.append(Finding(
                severity, "processes", "Unsigned program is running",
                f"{path} (pid {', '.join(by_path[path])}) — no code signature; "
                "fine for tools you built yourself, suspicious otherwise."))

    if deep:
        findings += _scan_listeners(by_path)
    return findings


def _scan_listeners(by_path):
    rc, out, _ = utils.run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN"], timeout=25)
    if rc != 0:
        return []
    pid_to_path = {pid: path for path, pids in by_path.items() for pid in pids}
    findings, flagged = [], set()
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 9:
            continue
        pid = parts[1]
        path = pid_to_path.get(pid, "")
        why = signatures.in_suspicious_location(path)
        if path and why and path not in flagged:
            flagged.add(path)
            findings.append(Finding(
                "high", "processes", "Suspicious program is listening for network connections",
                f"{path} (pid {pid}, {parts[8]}) — {why}", [path], removable=True))
    return findings
