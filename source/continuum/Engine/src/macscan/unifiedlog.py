"""PHASE 2 — Unified Log behavioural detection engine.

Queries the macOS Unified Log (`log show`) for the side effects high-end
spyware produces even when its own processes are well hidden: forced crashes of
security daemons (used to disable defenses or trigger exploitable restarts),
keychain export/dump activity, TCC database resets (silently re-granting
permissions), and unprompted camera/microphone hardware activations.

This is the slowest module — each query walks a bounded time window — so it runs
only under --forensic and every query is individually timed-out.

A native EndpointSecurity (ESF) client would observe the equivalent events in
realtime (ES_EVENT_TYPE_NOTIFY_EXEC / _OPEN / _MMAP), but that requires the
com.apple.developer.endpoint-security.client entitlement, a provisioning
profile, and a TCC grant — out of scope for a stdlib tool. The log is the
unprivileged-friendly substitute.
"""
import json
import os

from . import signatures, utils
from .finding import Finding

WINDOW = "6h"          # how far back to look
PER_QUERY_TIMEOUT = 70

# "alert" probes: any matching event is itself notable -> emit a finding.
# Each is (label, severity, predicate, explanation).
ALERT_PROBES = [
    ("security-daemon crash", "high",
     'process == "ReportCrash" AND '
     '(eventMessage CONTAINS "tccd" OR eventMessage CONTAINS "trustd" '
     'OR eventMessage CONTAINS "securityd" OR eventMessage CONTAINS "syspolicyd" '
     'OR eventMessage CONTAINS "endpointsecurityd" OR eventMessage CONTAINS "amfid")',
     "A security-enforcement daemon crashed. Exploits and anti-forensic routines "
     "frequently crash these to weaken defenses or reach a vulnerable restart path."),
    ("TCC reset / tamper", "high",
     'process == "tccd" AND (eventMessage CONTAINS[c] "reset" '
     'OR eventMessage CONTAINS[c] "deleted all")',
     "The privacy (TCC) database was reset or bulk-modified, which can silently "
     "re-grant camera/mic/screen permissions."),
    ("keychain export API", "medium",
     'eventMessage CONTAINS "SecKeychainItemExport" AND process != "log"',
     "A process called the keychain export API. Usually benign (some password "
     "managers do this) but it is also the credential-theft path — confirm which "
     "app it was."),
]

# "inventory" probes: matches are normal in volume; what matters is WHICH
# processes did it, so we dedupe to a process list and only alarm on ones in
# suspicious locations. (label, predicate, explanation)
INVENTORY_PROBES = [
    ("camera", 'subsystem == "com.apple.cmio" AND process != "log"',
     "used the camera"),
    ("microphone", 'process == "coreaudiod" AND composedMessage CONTAINS[c] "input" '
                   'AND process != "log"',
     "activated audio input"),
]


def scan(deep=False, forensic=False):
    if not forensic:
        return []
    # Confirm we can read the log at all before issuing slow queries.
    rc, _, err = utils.run(["log", "show", "--last", "1m", "--style", "json"], timeout=30)
    if rc != 0:
        utils.record_blindspot("Unified Log", "`log show` unavailable: " + (err.strip() or "error"))
        return [Finding(
            "info", "behavior", "Unified Log could not be queried",
            "Behavioural detection via `log show` was unavailable on this system, so "
            "daemon-crash / keychain / camera-mic correlation was skipped.")]

    findings = []
    for label, severity, predicate, why in ALERT_PROBES:
        events = _query(label, predicate)
        if events is None or not events:
            continue
        sample = events[:3]
        lines = "; ".join(f"{e.get('timestamp','?')} "
                          f"{e.get('processImagePath') or e.get('process','?')}"
                          for e in sample)
        findings.append(Finding(
            severity, "behavior",
            f"Unified Log: {label} ({len(events)} event(s) in last {WINDOW})",
            f"{why} Sample: {lines}"))

    for label, predicate, verb in INVENTORY_PROBES:
        events = _query(label, predicate)
        if not events:
            continue
        procs = sorted({(e.get("processImagePath") or e.get("process") or "?")
                        for e in events})
        suspicious = [p for p in procs if p.startswith("/") and signatures.in_suspicious_location(p)]
        for p in suspicious:
            findings.append(Finding(
                "high", "behavior", f"Untrusted program {verb}",
                f"{p} {verb} in the last {WINDOW} and runs from a suspicious location. "
                "This is the profile of a covert recorder.", [p]))
        normal = [p for p in procs if p not in suspicious]
        if normal:
            shown = ", ".join(os.path.basename(p) for p in normal[:12])
            findings.append(Finding(
                "info", "behavior",
                f"{len(normal)} program(s) {verb} in the last {WINDOW}",
                f"Baseline inventory (review for anything you don't recognize): {shown}"
                + ("…" if len(normal) > 12 else "")))
    return findings


def _query(label, predicate):
    rc, out, err = utils.run(
        ["log", "show", "--last", WINDOW, "--style", "json",
         "--predicate", predicate, "--info"],
        timeout=PER_QUERY_TIMEOUT)
    if rc != 0:
        utils.record_blindspot(f"Unified Log: {label}", err.strip() or "query failed")
        return None
    return _parse(out)


def _parse(out):
    out = out.strip()
    if not out:
        return []
    try:
        data = json.loads(out)
        return data if isinstance(data, list) else []
    except json.JSONDecodeError:
        # `log show` sometimes emits non-JSON preamble; fall back to line count.
        return [{"process": "?", "timestamp": "?"}
                for ln in out.splitlines() if ln.strip().startswith("{")]
