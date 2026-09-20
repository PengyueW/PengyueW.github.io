"""PHASE 1 — MVT-inspired forensic triage for state-sponsored spyware.

Mirrors the spirit of Amnesty International's Mobile Verification Toolkit on the
macOS surface: correlate per-process network-usage databases, sweep the
filesystem and process table for known indicators, and check DNS/hosts state
against C2 domains. Everything here is read-only; missing access is recorded as
a blind spot rather than silently skipped.
"""
import fnmatch
import glob
import os

from . import iocs, utils
from .finding import Finding

# netusage lives in the networkd state dir; DataUsage is the iOS-style analogue
# that some macOS versions also maintain. Both are root/FDA-readable.
NETUSAGE_DBS = [
    "/private/var/networkd/netusage.sqlite",
    "/private/var/networkd/db/netusage.sqlite",
]
DATAUSAGE_DBS = [
    "/private/var/wireless/Library/Databases/DataUsage.sqlite",
    "/private/var/mobile/Library/Databases/DataUsage.sqlite",
]


def scan(deep=False, forensic=False):
    if not forensic:
        return []
    findings = []
    findings += _netusage_triage()
    findings += _path_ioc_sweep()
    findings += _process_ioc_sweep()
    findings += _dns_ioc_triage()
    return findings


def _netusage_triage():
    """Look for IoC process names — or daemons masquerading as Apple — that
    have recorded network egress in the per-process usage databases."""
    out = []
    looked = False
    for db in NETUSAGE_DBS + DATAUSAGE_DBS:
        if not os.path.exists(db):
            continue
        looked = True
        # ZLIVEUSAGE/ZPROCESS schema (netusage) — join process names with bytes.
        rows, err = utils.sqlite_query_ro(
            db,
            "SELECT p.ZPROCNAME, "
            "  COALESCE(SUM(u.ZWIFIIN+u.ZWIFIOUT+u.ZWWANIN+u.ZWWANOUT),0) "
            "FROM ZLIVEUSAGE u JOIN ZPROCESS p ON u.ZHASPROCESS = p.Z_PK "
            "GROUP BY p.ZPROCNAME")
        if rows is None:
            # Try the simpler process-only table before giving up.
            rows, err = utils.sqlite_query_ro(db, "SELECT ZPROCNAME, 0 FROM ZPROCESS")
        if rows is None:
            if err == "permission denied":
                utils.record_blindspot(db, "network-usage DB needs root + Full Disk Access")
            continue
        for procname, nbytes in rows:
            out += _judge_proc(procname or "", nbytes or 0, db)
    if not looked:
        utils.record_blindspot("netusage/DataUsage", "no per-process network DB present on this macOS")
    return out


def _judge_proc(procname, nbytes, db):
    base = os.path.basename(procname)
    fam = iocs.match_process_name(base)
    if fam:
        return [Finding(
            "critical", "forensic",
            f"Spyware process with network activity ({fam})",
            f"'{procname}' recorded {nbytes} bytes of network egress in {db}. "
            "This process name is a published spyware indicator.",
            remediation="Disconnect from the network and seek professional "
                        "forensic assistance; do not attempt to clean in place.")]
    # Masquerade: an Apple-daemon name whose recorded path isn't the canonical one.
    canon = iocs.daemon_canonical_prefix(base)
    if canon and procname.startswith("/") and not procname.startswith(canon):
        return [Finding(
            "high", "forensic", "Possible system-daemon masquerade",
            f"'{procname}' uses the name of Apple daemon '{base}' but runs from an "
            f"unexpected path (expected under {canon}) and has network activity.")]
    return []


def _path_ioc_sweep():
    out = []
    for pattern, fam in iocs.PATH_IOCS:
        expanded = os.path.expanduser(pattern)
        review_only = "(review)" in fam
        for hit in glob.glob(expanded):
            sev = "review" if review_only else "critical"
            out.append(Finding(
                sev, "forensic", f"Spyware filesystem indicator ({fam})",
                hit, [hit] if not review_only else [],
                removable=False,
                remediation="Preserve this file as evidence; do not delete before "
                            "it is analyzed." if not review_only else ""))
    return out


def _process_ioc_sweep():
    out = []
    rc, text, _ = utils.run(["ps", "-axo", "pid=,comm="])
    if rc != 0:
        utils.record_blindspot("process table", "ps failed")
        return out
    for line in text.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        pid, comm = parts
        fam = iocs.match_process_name(os.path.basename(comm))
        if fam:
            out.append(Finding(
                "critical", "forensic", f"Spyware process running ({fam})",
                f"pid {pid}: {comm} matches a published spyware process indicator.",
                [comm] if comm.startswith("/") else []))
    return out


def _dns_ioc_triage():
    """Match C2 domains against /etc/hosts and the resolver's cached names."""
    out = []
    seen = set()

    def check(host, where):
        fam = iocs.match_domain(host)
        if fam and (host, fam) not in seen:
            seen.add((host, fam))
            out.append(Finding(
                "critical", "forensic", f"Spyware C2 domain referenced ({fam})",
                f"'{host}' appears in {where} and matches a known spyware domain."))

    try:
        with open("/etc/hosts") as f:
            for line in f:
                s = line.split("#")[0].split()
                for tok in s[1:]:
                    check(tok, "/etc/hosts")
    except OSError:
        pass
    # Resolver cache (best-effort; format varies and may be empty without root).
    rc, out_text, _ = utils.run(["dscacheutil", "-cachedump", "-entries", "Host"])
    if rc == 0:
        for line in out_text.splitlines():
            line = line.strip()
            if line.lower().startswith("name:"):
                for tok in line.split()[1:]:
                    check(tok, "the DNS resolver cache")
    return out
