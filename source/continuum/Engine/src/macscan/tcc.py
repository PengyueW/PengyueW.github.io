"""Audit privacy (TCC) permissions: which programs are allowed to record the
screen, monitor the keyboard, or control the machine. This is the primary
defense against silent screen/keyboard recorders, which must hold one of
these grants to function."""
import os
import sqlite3

from . import signatures, utils
from .finding import Finding

WATCHED_SERVICES = {
    "kTCCServiceScreenCapture": "record the screen",
    "kTCCServiceCamera": "use the camera",
    "kTCCServiceMicrophone": "use the microphone",
    "kTCCServiceListenEvent": "monitor all keyboard input (keylogger capability)",
    "kTCCServiceAccessibility": "control the computer via Accessibility",
    "kTCCServicePostEvent": "send synthetic keystrokes and clicks",
    "kTCCServiceSystemPolicyAllFiles": "read all files (Full Disk Access)",
}

# Camera/mic/screen are the surveillance triad; a silent grant to one of these
# is the precondition for covert audio/video capture.
SURVEILLANCE_SERVICES = {"kTCCServiceCamera", "kTCCServiceMicrophone", "kTCCServiceScreenCapture"}

DBS = [
    (os.path.join(utils.HOME, "Library/Application Support/com.apple.TCC/TCC.db"), "user"),
    ("/Library/Application Support/com.apple.TCC/TCC.db", "system"),
]


def scan(deep=False, forensic=False):
    grants = {}
    denied = []
    for db, scope in DBS:
        if not os.path.exists(db):
            continue
        rows = _query(db)
        if rows is None:
            denied.append(scope)
            utils.record_blindspot(db, "TCC database needs Full Disk Access")
            continue
        for service, client, client_type, allowed in rows:
            if service in WATCHED_SERVICES and allowed in (2, 3):
                grants.setdefault(service, set()).add(client)

    findings = []
    for service in WATCHED_SERVICES:
        clients = sorted(grants.get(service, ()))
        if not clients:
            continue
        ability = WATCHED_SERVICES[service]
        findings.append(Finding(
            "review", "privacy", f"{len(clients)} program(s) allowed to {ability}",
            "Granted to: " + ", ".join(clients) + ". Revoke anything you don't "
            "recognize in System Settings > Privacy & Security."))
        for client in clients:
            if not client.startswith("/"):
                continue
            why = signatures.in_suspicious_location(client)
            status, _ = utils.codesign_info(client)
            suspicious = bool(why) or status in ("unsigned", "invalid", "adhoc")
            if suspicious:
                findings.append(Finding(
                    "high", "privacy", f"Suspicious program can {ability}",
                    f"{client} — {why or 'code signature is ' + status}. This is the "
                    "profile of a covert recorder; revoke the permission and "
                    "investigate.", [client]))
            elif service in SURVEILLANCE_SERVICES and status not in utils.TRUSTED_STATUSES:
                # Even a "located in a normal place" app gets called out if it can
                # see/hear you and isn't signed by a recognizable developer.
                findings.append(Finding(
                    "review", "privacy", f"Unverified program can {ability}",
                    f"{client} — signature status '{status}'. Confirm you installed "
                    "this and that it has a legitimate reason for camera/mic/screen "
                    "access.", [client]))
    if denied:
        findings.append(Finding(
            "info", "privacy", "Privacy database not fully readable",
            "Grant your terminal Full Disk Access (System Settings > Privacy & "
            "Security > Full Disk Access) and rerun for a complete audit of which "
            "programs can record the screen, camera, microphone or keyboard. "
            "Scopes skipped: " + ", ".join(denied) + "."))
    return findings


def _query(db):
    """Return access rows, or None if the database is unreadable."""
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=3)
        try:
            try:
                return con.execute(
                    "SELECT service, client, client_type, auth_value FROM access").fetchall()
            except sqlite3.OperationalError:
                # Older macOS schema
                return con.execute(
                    "SELECT service, client, client_type, allowed FROM access").fetchall()
        finally:
            con.close()
    except sqlite3.Error:
        return None
