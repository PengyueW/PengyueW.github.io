"""Command-line interface and scan orchestration."""
import argparse
import sys

from . import __version__
from . import (binintegrity, browser, filescan, forensic, injection, lowlevel,
               manifest, network, persistence, processes, quarantine, report,
               system, tcc, unifiedlog, utils)
from .finding import Finding

# (label, module, tier) — tier gates execution:
#   "base"     always runs
#   "deep"     runs with --deep or --forensic (module also self-gates)
#   "forensic" runs only with --forensic
# manifest.py is intentionally LAST so it can collate every blind spot the
# earlier modules recorded.
SCANNERS = [
    ("system security posture", system, "base"),
    ("persistence (launchd, cron, helpers, periodic, Rosetta)", persistence, "base"),
    ("running processes", processes, "base"),
    ("known malware artifacts on disk", filescan, "base"),
    ("privacy permissions (screen, camera, mic, keyboard)", tcc, "base"),
    ("browser hijacking", browser, "base"),
    ("network sockets & C2 cross-reference", network, "deep"),
    ("forensic triage (state-sponsored spyware IoCs)", forensic, "forensic"),
    ("system-binary integrity verification", binintegrity, "forensic"),
    ("code-injection & dylib-hijack heuristics", injection, "forensic"),
    ("boot/kernel/firmware integrity", lowlevel, "forensic"),
    ("Unified Log behavioural detection", unifiedlog, "forensic"),
    ("cryptographic state manifest & blind-spot report", manifest, "forensic"),
]


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or (argv[0].startswith("-")
                    and argv[0] not in ("-h", "--help", "--version")):
        argv.insert(0, "scan")
    parser = argparse.ArgumentParser(
        prog="macscan",
        description="Scan this Mac for malware, adware, keyloggers, screen "
                    "recorders, and state-sponsored spyware, and quarantine what "
                    "it finds.")
    parser.add_argument("--version", action="version", version=f"macscan {__version__}")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sp = sub.add_parser("scan", help="run a scan (the default command)")
    sp.add_argument("--deep", action="store_true",
                    help="also audit login items, listening ports, /Applications "
                         "signatures, browser extensions and live network sockets")
    sp.add_argument("--forensic", action="store_true",
                    help="anti-spyware tier (implies --deep): Pegasus/Reign IoC "
                         "triage, system-binary integrity, Unified Log analysis, "
                         "injection & boot/kernel checks, cryptographic manifest. "
                         "Best run as: sudo macscan scan --forensic")
    sp.add_argument("--json", action="store_true", help="machine-readable output")
    sp.add_argument("--remove", action="store_true",
                    help="quarantine critical/high findings after confirmation "
                         "(disabled in --forensic mode: spyware removal is a "
                         "preserve-and-handoff decision, not a quarantine)")
    sp.add_argument("--yes", action="store_true",
                    help="skip the confirmation prompt for --remove")
    sub.add_parser("quarantine-list", help="list quarantined items")
    sub.add_parser("quarantine-json",
                   help="GUI bridge: read a JSON array of findings (the format "
                        "emitted by 'scan --json') on stdin and quarantine the "
                        "eligible ones; same eligibility rules as --remove. The "
                        "calling front-end must show the confirmation step.")
    rp = sub.add_parser("restore", help="restore a quarantined item")
    rp.add_argument("id", help="quarantine id from 'macscan quarantine-list'")
    sub.add_parser("manifest", help="write a cryptographic state manifest + "
                                    "blind-spot report without a full scan")
    args = parser.parse_args(argv)

    if args.cmd == "quarantine-list":
        return quarantine.list_quarantine()
    if args.cmd == "quarantine-json":
        return _quarantine_json()
    if args.cmd == "restore":
        return quarantine.restore(args.id)
    if args.cmd == "manifest":
        return manifest.run_standalone()
    return _run_scan(args)


def _quarantine_json():
    """Rebuild Finding objects from stdin JSON and quarantine eligible ones."""
    import dataclasses
    import json
    try:
        raw = json.load(sys.stdin)
        if not isinstance(raw, list):
            raise ValueError("expected a JSON array of findings")
    except (json.JSONDecodeError, ValueError) as e:
        print(json.dumps({"quarantined": [], "skipped": [],
                          "errors": [f"invalid input: {e}"]}))
        return 1
    allowed = {f.name for f in dataclasses.fields(Finding)}
    findings = []
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        data = {k: v for k, v in entry.items() if k in allowed}
        try:
            findings.append(Finding(**data))
        except TypeError:
            continue
    return quarantine.run_removal_json(findings)


def _run_scan(args):
    if sys.platform != "darwin":
        print("macscan only supports macOS.", file=sys.stderr)
        return 2

    forensic = args.forensic
    deep = args.deep or forensic
    utils.reset_blindspots()

    def log(msg):
        if not args.json:
            print(msg, file=sys.stderr)

    mode = "forensic" if forensic else ("deep" if deep else "standard")
    log(f"MacScan {__version__} — {mode} scan (read-only"
        + ("" if (args.remove and not forensic) else
           "; spyware removal is preserve-and-handoff" if forensic else
           "; use --remove to quarantine findings") + ")")
    if forensic and not utils.is_root():
        log("  note: not running as root — several forensic checks (TCC db, "
            "netusage, EFI, profiles) will be blind spots. For full coverage: "
            "sudo macscan scan --forensic")

    findings = []
    for label, module, tier in SCANNERS:
        if tier == "forensic" and not forensic:
            continue
        if tier == "deep" and not deep:
            continue
        log(f"  • {label}")
        try:
            findings.extend(module.scan(deep=deep, forensic=forensic))
        except Exception as exc:  # one broken scanner must not abort the scan
            findings.append(Finding(
                "info", "scanner", f"Scanner '{label}' crashed", repr(exc)))

    if args.json:
        report.print_json(findings)
    else:
        report.print_report(findings, forensic=forensic)

    if args.remove and not forensic:
        quarantine.run_removal(findings, assume_yes=args.yes)
    elif args.remove and forensic:
        log("\n--remove ignored in forensic mode: do not quarantine suspected "
            "state-sponsored implants in place. Preserve the machine and consult "
            "a professional (e.g. Access Now Digital Security Helpline).")

    if any(f.severity == "critical" for f in findings):
        return 2
    if any(f.severity in ("high", "medium") for f in findings):
        return 1
    return 0
