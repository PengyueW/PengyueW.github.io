"""PHASE 3 — cryptographic system-state manifest + blind-spot ledger.

Runs last. Produces a signed-by-hash record of the security-relevant system
state (so a later scan, or a professional, can detect what changed) and — most
importantly for anti-spyware work — collates every blind spot the scan hit, so
the user knows exactly which parts of the system could NOT be inspected.

A forensic scan that finds nothing but lists many blind spots is reported as
INCONCLUSIVE, not clean. That honesty is the point: high-end implants live
precisely in the places an unprivileged tool can't read.
"""
import getpass
import glob
import hashlib
import json
import os
import platform
import time

from . import utils
from .finding import Finding

OUTDIR = os.path.expanduser("~/.macscan/manifests")

# Security-relevant state to fingerprint. Globs expand; directories are walked
# one level deep (every regular file). Unreadable entries become blind spots.
STATE_TARGETS = [
    "/etc/hosts",
    "/etc/sudoers",
    "/etc/sudoers.d",
    "/etc/pam.d",
    "/etc/ssh/sshd_config",
    "~/.ssh/authorized_keys",
    "/Library/LaunchDaemons",
    "/Library/LaunchAgents",
    "~/Library/LaunchAgents",
    "/Library/PrivilegedHelperTools",
    "/Library/StartupItems",
    "/etc/periodic.conf",
    "~/.zshrc", "~/.zshenv", "~/.zprofile", "~/.bash_profile",
]
MAX_FILE_BYTES = 25 * 1024 * 1024     # don't hash anything enormous


def scan(deep=False, forensic=False):
    if not forensic:
        return []
    entries, hashed = {}, 0
    for target in STATE_TARGETS:
        for path in _expand(target):
            digest, err = _sha256(path)
            if digest:
                entries[path] = digest
                hashed += 1
            elif err:
                utils.record_blindspot(path, err)

    spots = utils.blindspots()
    manifest = {
        "tool": "macscan",
        "generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "host": platform.node(),
        "os": platform.mac_ver()[0] or platform.platform(),
        "user": _safe_user(),
        "euid": os.geteuid(),
        "running_as_root": utils.is_root(),
        "files_hashed": hashed,
        "hashes": entries,
        "blind_spots": spots,
    }
    os.makedirs(OUTDIR, exist_ok=True)
    fname = os.path.join(OUTDIR, time.strftime("manifest-%Y%m%d-%H%M%S.json"))
    try:
        with open(fname, "w") as f:
            json.dump(manifest, f, indent=2, sort_keys=True)
        manifest_hash = hashlib.sha256(
            json.dumps(manifest, sort_keys=True).encode()).hexdigest()
    except OSError as e:
        return [Finding("info", "manifest", "Could not write state manifest", str(e))]

    findings = [Finding(
        "info", "manifest", "Cryptographic system-state manifest written",
        f"{hashed} security-relevant file(s) hashed -> {fname} "
        f"(manifest SHA-256: {manifest_hash[:16]}…). Keep it; a future scan can diff "
        "against it to reveal tampering.")]

    if spots:
        unique = sorted({s["path"] for s in spots})
        preview = ", ".join(unique[:12]) + ("…" if len(unique) > 12 else "")
        findings.append(Finding(
            "review", "manifest",
            f"SCAN BLIND SPOTS: {len(unique)} location(s) could not be inspected",
            "These were skipped due to permissions/SIP, so the scan is INCONCLUSIVE "
            "for them — exactly where a sophisticated implant would hide. Re-run as "
            "`sudo macscan scan --forensic` with the terminal granted Full Disk "
            f"Access to close gaps. Blind spots: {preview}. Full list is in the "
            "manifest file under 'blind_spots'."))
    return findings


def run_standalone():
    """`macscan manifest` — generate a manifest without a full scan."""
    utils.reset_blindspots()
    findings = scan(forensic=True)
    for f in findings:
        print(f"[{f.severity}] {f.title}\n    {f.detail}\n")
    return 0


def _expand(target):
    base = os.path.expanduser(target)
    results = []
    for path in glob.glob(base) or [base]:
        if os.path.isdir(path):
            try:
                children = sorted(
                    e.path for e in os.scandir(path)
                    if e.is_file(follow_symlinks=False))
            except PermissionError:
                results.append(path)   # _sha256 records it as a blind spot
                continue
            except OSError:
                continue
            results.extend(children[:500])
            if not children:
                results.append(path)
        else:
            results.append(path)
    return results


def _sha256(path):
    if os.path.isdir(path):
        # Directory we couldn't enumerate into files: note it, no hash.
        if not os.access(path, os.R_OK):
            return None, "directory not readable"
        return None, ""
    if not os.path.exists(path):
        return None, ""
    try:
        if os.path.getsize(path) > MAX_FILE_BYTES:
            return None, ""
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
        return h.hexdigest(), ""
    except PermissionError:
        return None, "permission denied"
    except OSError as e:
        return None, str(e)


def _safe_user():
    try:
        return getpass.getuser()
    except Exception:
        return "?"
