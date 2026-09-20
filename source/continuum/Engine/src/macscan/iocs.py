"""Indicators of compromise for state-sponsored / mercenary spyware.

THIS IS A SEED LIST, NOT AN EXHAUSTIVE FEED. The indicators below are drawn
from public forensic write-ups (Amnesty International Security Lab, Citizen Lab,
Google TAG, Kaspersky GReAT). High-end spyware rotates infrastructure and
artifact names aggressively, so:

  * A hit here is a strong signal worth acting on immediately.
  * The ABSENCE of a hit proves nothing — see manifest.py blind-spot reporting.

Refresh from the canonical sources rather than trusting these as current:
  - https://github.com/AmnestyTech/investigations  (MVT IoC STIX2 files)
  - https://citizenlab.ca/  (per-campaign indicator appendices)

Each entry is (indicator, family, source-tag). Process-name and path checks are
exact/glob; domain checks are suffix matches; IP checks are exact.
"""

# Process / binary base names historically associated with these implants.
# (Many originate from iOS Pegasus forensics; included because cross-platform
# operator tooling and naming conventions recur, and several have macOS-stage
# analogues. Treat short generic names as lower-confidence.)
PROCESS_NAME_IOCS = {
    # NSO Group — Pegasus (Amnesty MVT process indicators)
    "bh": "Pegasus (NSO)",
    "roleaboutd": "Pegasus (NSO)",
    "msgacntd": "Pegasus (NSO)",
    "pcsd": "Pegasus (NSO)",
    "fmld": "Pegasus (NSO)",
    "frtipd": "Pegasus (NSO)",
    "launchafd": "Pegasus (NSO)",
    "libtouchregd": "Pegasus (NSO)",
    "mptbd": "Pegasus (NSO)",
    "natgd": "Pegasus (NSO)",
    "otpgrefd": "Pegasus (NSO)",
    "pdusedd": "Pegasus (NSO)",
    "vm_stats": "Pegasus (NSO)",
    "ABSCarryLog": "Pegasus (NSO)",
    "aggregatenotd": "Pegasus (NSO)",
    "ckkeyrollfd": "Pegasus (NSO)",
    "gatekeeperd": "Pegasus-masquerade (real gatekeeperd lives in /usr/libexec)",
    # QuaDream — Reign (Citizen Lab 'Sweet QuaDreams')
    "endpointsecurityd": "Reign-masquerade (QuaDream)",
    # Intellexa / Cytrox — Predator (Citizen Lab / Google TAG)
    "com.apple.softwareupdated.helper": "Predator-masquerade (Intellexa)",
}

# Filesystem artifacts. '~' expands; globs allowed.
# Keep this list tight and defensible — a false "Pegasus artifact" alarm is
# harmful. Do NOT add normal Apple paths here (e.g. *.staging XPC dirs).
PATH_IOCS = [
    ("~/Library/Caches/com.apple.aboutd", "Pegasus (NSO)"),
    ("/private/var/db/.RcsConfig", "Hacking Team RCS (historical)"),
    ("~/Library/Preferences/com.apple.softwareupdateservicesd.plist.*", "Predator-style staged plist (review)"),
]

# C2 / infrastructure domains — SUFFIX match (so 'foo.bar.example.com' matches
# 'example.com'). These public examples are largely sinkholed/dead; their value
# is detecting old beacons in DNS/hosts caches and network logs.
DOMAIN_IOCS = {
    # Pegasus v3/v4 network-injection & install domains (Amnesty / Citizen Lab)
    "free-news.org": "Pegasus (NSO)",
    "opposedposition.net": "Pegasus (NSO)",
    "urlpush.net": "Pegasus (NSO)",
    "breaking-news.info": "Pegasus (NSO)",
    "topmoviefacts.com": "Pegasus (NSO)",
    "smartphonefacts.com": "Pegasus (NSO)",
    # Predator (Cytrox/Intellexa) — Citizen Lab 'Pegasus vs Predator'
    "branovica.com": "Predator (Intellexa)",
    "cybheck.com": "Predator (Intellexa)",
    # QuaDream — Reign
    "messagecenter.org": "Reign (QuaDream)",
}

# Exact C2 IPs (illustrative public examples; rotate frequently).
IP_IOCS = {
    "185.106.120.206": "Pegasus (NSO) infra (historical)",
}

# Real macOS daemons whose NAME is attractive to masquerade as. We key off the
# canonical install path: a process with one of these names running from
# anywhere else is impersonating a system daemon.
APPLE_DAEMON_CANONICAL = {
    "tccd": "/System/Library/PrivateFrameworks/TCC.framework",
    "gatekeeperd": "/usr/libexec/gatekeeperd",
    "securityd": "/usr/libexec/securityd",
    "trustd": "/usr/libexec/trustd",
    "launchd": "/sbin/launchd",
    "syspolicyd": "/usr/libexec/syspolicyd",
    "endpointsecurityd": "/usr/libexec/endpointsecurityd",
    "softwareupdated": "/System/Library/PrivateFrameworks/SoftwareUpdate.framework",
    "nsurlsessiond": "/usr/libexec/nsurlsessiond",
    "mobileassetd": "/usr/libexec/mobileassetd",
    "cloudd": "/System/Library/PrivateFrameworks/CloudKitDaemon.framework",
    "bird": "/System/Library/PrivateFrameworks/CloudDocs.framework",
}


def match_process_name(name):
    return PROCESS_NAME_IOCS.get(name)


def match_domain(host):
    """Suffix-match a hostname against the domain IoC list."""
    if not host:
        return None
    h = host.lower().rstrip(".")
    for dom, fam in DOMAIN_IOCS.items():
        if h == dom or h.endswith("." + dom):
            return fam
    return None


def match_ip(ip):
    return IP_IOCS.get(ip)


def daemon_canonical_prefix(name):
    """Where a given Apple daemon name is supposed to live, or None."""
    return APPLE_DAEMON_CANONICAL.get(name)
