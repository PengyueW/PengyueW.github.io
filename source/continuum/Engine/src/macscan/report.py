"""Terminal and JSON reporting."""
import json
import sys

from . import utils
from .finding import SEVERITY_ORDER

COLORS = {
    "critical": "\033[1;31m",
    "high": "\033[0;31m",
    "medium": "\033[0;33m",
    "review": "\033[0;36m",
    "info": "\033[0;90m",
}
RESET = "\033[0m"
BOLD = "\033[1m"


def print_json(findings):
    json.dump([f.to_dict() for f in findings], sys.stdout, indent=2)
    print()


def print_report(findings, forensic=False):
    color = sys.stdout.isatty()

    def c(code, text):
        return f"{code}{text}{RESET}" if color else text

    blindspots = utils.blindspots()
    findings = sorted(findings, key=lambda f: (SEVERITY_ORDER.get(f.severity, 9), f.category, f.title))
    print()
    if not findings:
        if forensic and blindspots:
            print(c(COLORS["review"], "INCONCLUSIVE — no indicators found, but the "
                  f"scan had {len(set(s['path'] for s in blindspots))} blind spot(s)."))
            print("A sophisticated implant hides exactly where the scan couldn't look.")
            print("Re-run as `sudo macscan scan --forensic` with Full Disk Access.")
        else:
            print(c(BOLD, "No findings — nothing suspicious detected."))
        return
    for f in findings:
        tag = c(COLORS.get(f.severity, ""), f"[{f.severity.upper():^8}]")
        print(f"{tag} {c(BOLD, f.title)}  ({f.category})")
        if f.detail:
            print(f"           {f.detail}")
        for p in f.paths:
            print(f"           file: {p}")
        if f.remediation:
            print(f"           fix:  {f.remediation}")
        print()
    counts = {}
    for f in findings:
        counts[f.severity] = counts.get(f.severity, 0) + 1
    summary = ", ".join(f"{counts[s]} {s}" for s in SEVERITY_ORDER if s in counts)
    print(c(BOLD, f"Summary: {summary}"))
    if blindspots:
        n = len(set(s["path"] for s in blindspots))
        print(c(COLORS["review"], f"Blind spots: {n} location(s) could not be inspected "
              "(see the 'manifest' finding). The scan is inconclusive for those areas."))
    if any(f.category in ("forensic", "integrity", "kernel") and f.severity == "critical"
           for f in findings):
        print(c(COLORS["critical"], "\nPOSSIBLE STATE-SPONSORED COMPROMISE: do NOT attempt "
              "to clean in place."))
        print("Disconnect from the network, preserve the machine, and contact a "
              "professional\n(e.g. Access Now Digital Security Helpline, "
              "https://www.accessnow.org/help/).")
    removable = [f for f in findings if f.removable and f.severity in ("critical", "high")]
    if removable and not forensic:
        print(f"\n{len(removable)} finding(s) can be quarantined automatically: rerun with --remove")
        print("Quarantine is reversible: items move to ~/.macscan/quarantine and can be")
        print("brought back with 'macscan restore <id>'.")
