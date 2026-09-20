"""Check the filesystem for known malware artifacts; deep mode audits
the code signatures of everything in the standard application folders."""
import glob
import os

from . import signatures, utils
from .finding import Finding

APP_GLOBS = [
    "/Applications/*.app",
    "/Applications/Utilities/*.app",
    os.path.expanduser("~/Applications/*.app"),
]


def scan(deep=False, forensic=False):
    findings = []
    seen = set()
    for pattern, family in signatures.expanded_paths():
        for p in glob.glob(pattern):
            if p in seen:
                continue
            seen.add(p)
            findings.append(Finding(
                "critical", "files", f"Known malware artifact ({family})",
                p, [p], removable=True))
    if deep:
        findings += _app_sweep()
    return findings


def _app_sweep():
    out = []
    apps = sorted({app for g in APP_GLOBS for app in glob.glob(g)})
    for app in apps:
        status, _ = utils.codesign_info(app)
        if status == "invalid":
            out.append(Finding(
                "high", "files", "Application signature is broken",
                f"{app} — contents were modified after signing (possible trojanized app, "
                "or a badly patched legitimate one).", [app]))
        elif status == "unsigned":
            out.append(Finding(
                "review", "files", "Unsigned application",
                f"{app} — no code signature; make sure you installed this intentionally "
                "and from a source you trust."))
    return out
