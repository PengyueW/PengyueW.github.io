"""Scan persistence mechanisms: launchd jobs, cron, legacy startup items, login items."""
import os
import plistlib
import re

from . import signatures, utils
from .finding import Finding

LAUNCH_DIRS = [
    ("/Library/LaunchDaemons", "system"),
    ("/Library/LaunchAgents", "system"),
    (os.path.join(utils.HOME, "Library/LaunchAgents"), "user"),
]

_SEV_RANK = {"critical": 0, "high": 1, "medium": 2, "review": 3}


def scan(deep=False, forensic=False):
    findings = []
    for directory, domain in LAUNCH_DIRS:
        if not os.path.isdir(directory):
            continue
        try:
            names = sorted(os.listdir(directory))
        except PermissionError:
            utils.record_blindspot(directory, "launchd directory listing denied")
            continue
        except OSError:
            continue
        for name in names:
            if name == ".DS_Store":
                continue
            path = os.path.join(directory, name)
            if not name.endswith(".plist"):
                if os.path.isfile(path):
                    findings.append(Finding(
                        "medium", "persistence", "Stray file in launchd directory",
                        f"{path} is not a .plist; nothing legitimate stores other files here.",
                        [path], removable=True))
                continue
            findings.extend(_check_job(path, domain, name))
    findings += _scan_cron()
    findings += _scan_legacy()
    findings += _scan_privileged_helpers()
    findings += _scan_periodic()
    findings += _scan_rosetta()
    if deep:
        findings += _scan_login_items()
        findings += _scan_btm()
    return findings


def _check_job(path, domain, name):
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except PermissionError:
        return [Finding(
            "info", "persistence", "Launchd job not readable",
            f"{path} is only readable by root; rerun the scan with sudo to inspect it.")]
    except OSError:
        if os.path.islink(path):
            return [Finding(
                "medium", "persistence", "Dangling launchd symlink",
                f"{path} points at a file that no longer exists; orphaned jobs are safe to remove.",
                [path], removable=True)]
        return []
    try:
        data = plistlib.loads(raw)
    except Exception:
        return [Finding(
            "medium", "persistence", "Malformed launchd job",
            f"{path} could not be parsed; malware sometimes ships malformed plists to evade tools.",
            [path], removable=True)]
    label = str(data.get("Label", name[:-6]))
    args = data.get("ProgramArguments")
    if not isinstance(args, list):
        args = []
    program = str(data.get("Program") or (args[0] if args else ""))
    cmdline = " ".join(str(a) for a in args)

    family = signatures.match_label(label) or signatures.match_path(program)
    if family:
        paths = [path]
        target = utils.removal_target(program)
        if target:
            paths.append(target)
        return [Finding(
            "critical", "persistence", f"Known malware persistence ({family})",
            f"{path} (label '{label}') starts: {program or cmdline}",
            paths, launchd_label=label, launchd_domain=domain, removable=True)]

    reasons = []
    if name.startswith("."):
        reasons.append(("high", "the job file itself is hidden"))
    if label.startswith("com.apple.") and program and not program.startswith(
            ("/System/", "/usr/", "/Library/Apple/")):
        status, _ = utils.codesign_info(program)
        if status not in utils.APPLE_STATUSES:
            reasons.append(("high", f"pretends to be Apple (label '{label}') but runs non-Apple code"))
    why = signatures.in_suspicious_location(program)
    if why:
        reasons.append(("high", f"executable {why}"))
    for desc in signatures.match_cmdline(cmdline):
        reasons.append(("high", f"command line {desc}"))
    if program.startswith("/") and not os.path.exists(program):
        reasons.append(("medium", f"points at a missing executable ({program}); "
                                  "orphaned jobs are safe to remove"))
    elif program.startswith(("/Users/", "/Library/")) and not program.startswith("/Library/Apple/"):
        status, _ = utils.codesign_info(program)
        if status in ("unsigned", "adhoc", "invalid"):
            reasons.append(("review", f"runs {status} code from {program}"))

    if not reasons:
        return []
    severity = sorted(reasons, key=lambda r: _SEV_RANK[r[0]])[0][0]
    detail = "; ".join(r[1] for r in reasons)
    paths = [path]
    if severity == "high":
        target = utils.removal_target(program)
        if target:
            paths.append(target)
    return [Finding(
        severity, "persistence", f"Suspicious launchd job ({label})",
        f"{path}: {detail}", paths,
        launchd_label=label, launchd_domain=domain,
        removable=severity in ("high", "medium"))]


def _scan_cron():
    out = []
    rc, text, _ = utils.run(["crontab", "-l"])
    if rc == 0:
        out += _check_cron_lines(text, "your crontab", "Remove the line with: crontab -e")
    try:
        with open("/etc/crontab") as f:
            out += _check_cron_lines(f.read(), "/etc/crontab",
                                     "Edit /etc/crontab with sudo and remove the line.")
    except OSError:
        pass
    # Per-user crontabs (including root's) live here; readable only as root.
    tabs = "/usr/lib/cron/tabs"
    if os.path.isdir(tabs):
        try:
            names = sorted(os.listdir(tabs))
        except PermissionError:
            utils.record_blindspot(tabs, "per-user crontabs need root")
            names = []
        except OSError:
            names = []
        for user in names:
            p = os.path.join(tabs, user)
            try:
                with open(p) as f:
                    out += _check_cron_lines(
                        f.read(), p,
                        f"sudo crontab -u {user} -e  (remove the line)")
            except OSError:
                utils.record_blindspot(p, "crontab not readable")
    return out


def _check_cron_lines(text, source, remediation):
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        descs = signatures.match_cmdline(s)
        m = re.search(r"(/(?:private/)?(?:tmp|var/tmp)/\S+)", s)
        if m:
            descs.append(f"runs {m.group(1)} from a temp directory")
        for desc in descs:
            out.append(Finding(
                "high", "persistence", "Suspicious cron job",
                f"{source} line {n}: '{s}' — {desc}", remediation=remediation))
    return out


def _scan_legacy():
    out = []
    for directory in ("/Library/StartupItems", "/private/var/db/emondClients"):
        if not os.path.isdir(directory):
            continue
        try:
            entries = [e for e in os.listdir(directory) if e != ".DS_Store"]
        except OSError:
            continue
        for e in entries:
            p = os.path.join(directory, e)
            out.append(Finding(
                "high", "persistence", "Legacy startup mechanism in use",
                f"{p} — this mechanism is deprecated and today used almost exclusively by malware.",
                [p], removable=True))
    return out


def _scan_privileged_helpers():
    """SMJobBless privileged helper tools run as root on demand. Each should be
    Apple- or Developer-ID-signed and named for a vendor you recognize."""
    directory = "/Library/PrivilegedHelperTools"
    if not os.path.isdir(directory):
        return []
    out = []
    try:
        names = sorted(os.listdir(directory))
    except PermissionError:
        utils.record_blindspot(directory, "privileged helper listing denied")
        return []
    except OSError:
        return []
    for name in names:
        if name == ".DS_Store":
            continue
        p = os.path.join(directory, name)
        status, authority = utils.codesign_info(p)
        family = signatures.match_path(p)
        if family:
            out.append(Finding(
                "critical", "persistence", f"Known-malicious privileged helper ({family})",
                f"{p} runs as root via Service Management.", [p], removable=True))
        elif status in ("unsigned", "adhoc", "invalid"):
            out.append(Finding(
                "high", "persistence", "Unsigned root helper tool",
                f"{p} runs as root but is {status} (authority: {authority or 'none'}). "
                "Legitimate helpers are signed by their vendor.", [p], removable=True))
        else:
            out.append(Finding(
                "review", "persistence", "Privileged helper tool installed",
                f"{p} (signed: {authority or status}) — runs as root on request. "
                "Remove if you don't recognize the vendor."))
    return out


def _scan_periodic():
    """The classic /etc/periodic system plus its override files. Attackers drop
    scripts here, or repoint periodic at their own command via periodic.conf."""
    out = []
    for d in ("/etc/periodic/daily", "/etc/periodic/weekly", "/etc/periodic/monthly",
              "/usr/local/etc/periodic"):
        if not os.path.isdir(d):
            continue
        try:
            entries = sorted(os.listdir(d))
        except OSError:
            continue
        for e in entries:
            p = os.path.join(d, e)
            # Apple's stock scripts are numbered (e.g. 110.clean-tmps); flag the
            # odd ones and anything in the user-writable local tree.
            if d.startswith("/usr/local") or not re.match(r"^\d{3}\.", e):
                out.append(Finding(
                    "medium", "persistence", "Non-standard periodic script",
                    f"{p} runs automatically on a schedule and is not a stock Apple "
                    "periodic script. Review its contents.", [p], removable=d.startswith("/usr/local")))
    for conf in ("/etc/periodic.conf", "/etc/periodic.conf.local", "/etc/defaults/periodic.conf"):
        try:
            with open(conf) as f:
                text = f.read()
        except OSError:
            continue
        for n, line in enumerate(text.splitlines(), 1):
            for desc in signatures.match_cmdline(line):
                out.append(Finding(
                    "high", "persistence", "Suspicious command in periodic config",
                    f"{conf} line {n}: '{line.strip()[:200]}' — {desc}."))
    return out


def _scan_rosetta():
    """Rosetta 2 stores Ahead-Of-Time translated binaries under a protected
    cache; abuse ('oah' persistence) plants foreign content there or installs a
    fake Rosetta runtime outside the OS path."""
    out = []
    oah = "/var/db/oah"
    if os.path.isdir(oah):
        try:
            # We can't read the SIP-protected cache contents, but its presence is
            # normal; we only flag obviously wrong sibling files.
            for root, _dirs, files in os.walk(oah):
                for fn in files:
                    if fn.endswith((".sh", ".plist", ".command")):
                        p = os.path.join(root, fn)
                        out.append(Finding(
                            "high", "persistence", "Unexpected file in Rosetta cache",
                            f"{p} — the Rosetta AOT cache should contain only translated "
                            "binaries, not scripts or plists.", [p]))
        except PermissionError:
            utils.record_blindspot(oah, "Rosetta cache is SIP-protected (expected)")
        except OSError:
            pass
    for fake in ("/usr/local/libexec/rosetta", os.path.expanduser("~/Library/Rosetta")):
        if os.path.exists(fake):
            out.append(Finding(
                "high", "persistence", "Rosetta runtime in a non-system location",
                f"{fake} — the real Rosetta lives under /Library/Apple. A copy here may "
                "be a trojaned translator.", [fake], removable=True))
    return out


def _scan_btm():
    """Background Task Management (macOS 13+) is the authoritative registry of
    login items, agents and daemons apps have registered — including ones that
    never touch the classic launchd directories. `sfltool dumpbtm` needs root."""
    rc, out, _ = utils.run(["sfltool", "dumpbtm"], timeout=30)
    if rc != 0:
        utils.record_blindspot("Background Task Management",
                               "sfltool dumpbtm needs root (macOS 13+)")
        return []
    findings, seen = [], set()
    for m in re.finditer(r"(?:Executable Path|URL):\s*(\S+)", out):
        path = m.group(1)
        if path.startswith("file://"):
            path = path[len("file://"):]
        path = path.rstrip("/")
        if not path.startswith("/") or path in seen:
            continue
        seen.add(path)
        family = signatures.match_path(path)
        why = signatures.in_suspicious_location(path)
        if family:
            findings.append(Finding(
                "critical", "persistence",
                f"Known malware registered as a background item ({family})",
                f"{path} is registered with Background Task Management and runs "
                "automatically.", [path], removable=True))
        elif why:
            findings.append(Finding(
                "high", "persistence", "Suspicious background item registered",
                f"{path} — {why}. Registered via Background Task Management; also "
                "review System Settings > General > Login Items.",
                [path], removable=True))
    return findings


def _scan_login_items():
    rc, out, _ = utils.run(
        ["osascript", "-e",
         'tell application "System Events" to get the path of every login item'],
        timeout=20)
    if rc != 0:
        return [Finding(
            "info", "persistence", "Login items could not be enumerated",
            "Approve the automation prompt (or check System Settings > General > "
            "Login Items manually) and rerun with --deep.")]
    items = [s.strip() for s in out.strip().split(",") if s.strip()]
    findings = []
    benign = []
    for item in items:
        why = signatures.in_suspicious_location(item)
        if why:
            findings.append(Finding(
                "high", "persistence", "Suspicious login item",
                f"{item} — {why}", [item], removable=True))
        else:
            benign.append(item)
    if benign:
        findings.append(Finding(
            "review", "persistence", f"{len(benign)} login item(s)",
            "Remove anything you don't recognize in System Settings > General > "
            "Login Items: " + ", ".join(benign)))
    return findings
