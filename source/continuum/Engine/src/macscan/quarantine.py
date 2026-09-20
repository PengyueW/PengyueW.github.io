"""Reversible removal: quarantine flagged items instead of deleting them."""
import json
import os
import shutil
import signal
import time
import uuid

from . import utils

QROOT = os.path.expanduser("~/.macscan/quarantine")


def run_removal(findings, assume_yes=False):
    targets = [f for f in findings
               if f.removable and f.paths and f.severity in ("critical", "high")]
    if not targets:
        print("\nNothing eligible for automatic removal (only critical/high findings "
              "with concrete files are auto-quarantined).")
        return
    print(f"\nThe following will be QUARANTINED (moved to {QROOT}, reversible with "
          "'macscan restore <id>'):")
    for f in targets:
        print(f"  - [{f.severity}] {f.title}")
        for p in f.paths:
            print(f"        {p}")
    if not assume_yes:
        try:
            answer = input("\nProceed? [y/N] ").strip().lower()
        except EOFError:
            answer = ""
        if answer not in ("y", "yes"):
            print("Aborted; nothing was changed.")
            return
    failures = []
    for f in targets:
        qid, errors = quarantine_finding(f)
        failures.extend(errors)
        if qid:
            print(f"Quarantined '{f.title}' -> {qid}")
    if failures:
        print("\nSome items could not be moved (rerun with sudo for system-level items):")
        for e in failures:
            print("  " + e)


def run_removal_json(findings):
    """GUI bridge: quarantine findings supplied programmatically, no prompt.

    The caller (the GUI) is responsible for showing the confirmation step;
    eligibility rules are identical to run_removal and re-checked here so a
    misbehaving front-end cannot widen the removal surface.
    """
    targets = [f for f in findings
               if f.removable and f.paths and f.severity in ("critical", "high")]
    result = {"quarantined": [], "skipped": [], "errors": []}
    for f in findings:
        if f not in targets:
            result["skipped"].append(
                {"title": f.title, "reason": "not eligible (needs removable "
                                             "critical/high finding with files)"})
    for f in targets:
        qid, errors = quarantine_finding(f)
        result["errors"].extend(errors)
        if qid:
            result["quarantined"].append({"id": qid, "title": f.title})
    print(json.dumps(result, indent=2))
    return 0 if not result["errors"] else 1


def quarantine_finding(f):
    """Quarantine one finding. Returns (quarantine_id or None, error list)."""
    existing = [p for p in f.paths if os.path.lexists(p)]
    if not existing:
        return None, [f"{f.title}: files already gone"]
    qid = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
    qdir = os.path.join(QROOT, qid)
    os.makedirs(qdir, exist_ok=True)
    if f.launchd_label:
        _bootout(f)
    items, errors = [], []
    for i, p in enumerate(f.paths):
        if not os.path.lexists(p):
            continue
        # Last line of defense: never move anything out of a protected system
        # location, even if a scanner put such a path on a finding.
        if utils.is_protected_path(p):
            errors.append(f"{p}: refused — protected system path")
            continue
        _kill_running(p)
        stored = os.path.join(qdir, f"{i:02d}__{os.path.basename(p)}")
        try:
            shutil.move(p, stored)
            items.append({"original": p, "stored": stored})
        except OSError as e:
            errors.append(f"{p}: {e}")
    manifest = {
        "id": qid,
        "time": time.strftime("%Y-%m-%d %H:%M:%S"),
        "title": f.title,
        "severity": f.severity,
        "launchd_label": f.launchd_label,
        "launchd_domain": f.launchd_domain,
        "items": items,
    }
    if not items:
        try:
            os.rmdir(qdir)
        except OSError:
            pass
        return None, errors
    with open(os.path.join(qdir, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=2)
    return qid, errors


def _bootout(f):
    """Unload a launchd job before its files are moved."""
    domain = f"gui/{os.getuid()}" if f.launchd_domain == "user" else "system"
    rc, _, _ = utils.run(["launchctl", "bootout", f"{domain}/{f.launchd_label}"])
    if rc != 0 and f.launchd_domain == "user":
        for p in f.paths:
            if p.endswith(".plist"):
                utils.run(["launchctl", "unload", "-w", p])


def _kill_running(path):
    """Kill any process whose executable is exactly this path."""
    rc, out, _ = utils.run(["ps", "-axo", "pid=,comm="])
    if rc != 0:
        return
    for line in out.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1] == path:
            try:
                os.kill(int(parts[0]), signal.SIGKILL)
            except (ProcessLookupError, PermissionError, ValueError):
                pass


def list_quarantine():
    rows = []
    if os.path.isdir(QROOT):
        for qid in sorted(os.listdir(QROOT)):
            mf = os.path.join(QROOT, qid, "manifest.json")
            if not os.path.isfile(mf):
                continue
            try:
                with open(mf) as fh:
                    rows.append((qid, json.load(fh)))
            except (OSError, json.JSONDecodeError):
                continue
    if not rows:
        print("Quarantine is empty.")
        return 0
    for qid, m in rows:
        print(f"{qid}  [{m.get('severity', '?')}] {m.get('title', '')}")
        for item in m.get("items", []):
            print(f"    {item['original']}")
    print("\nRestore with: macscan restore <id>")
    return 0


def restore(qid):
    if not qid or os.sep in qid or qid != os.path.basename(qid) or qid.startswith("."):
        print(f"Invalid quarantine id '{qid}'. See 'macscan quarantine-list'.")
        return 1
    qdir = os.path.join(QROOT, qid)
    mf = os.path.join(qdir, "manifest.json")
    if not os.path.isfile(mf):
        print(f"No quarantined item named '{qid}'. See 'macscan quarantine-list'.")
        return 1
    with open(mf) as fh:
        manifest = json.load(fh)
    errors = []
    for item in manifest["items"]:
        try:
            parent = os.path.dirname(item["original"])
            if parent:
                os.makedirs(parent, exist_ok=True)
            shutil.move(item["stored"], item["original"])
            print(f"Restored {item['original']}")
        except OSError as e:
            errors.append(f"{item['original']}: {e}")
    if errors:
        for e in errors:
            print("Failed: " + e)
        return 1
    os.remove(mf)
    try:
        os.rmdir(qdir)
    except OSError:
        pass
    if manifest.get("launchd_label"):
        print("Note: the launchd job was not re-loaded; log out and back in, or run "
              "'launchctl load' on the plist, if this was a false positive.")
    return 0
