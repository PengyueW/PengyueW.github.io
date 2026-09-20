"""System-level checks: security posture (Gatekeeper, SIP, XProtect),
/etc/hosts tampering, shell init files, configuration profiles."""
import os
import plistlib
import re

from . import signatures, utils
from .finding import Finding

WATCH_DOMAINS = (
    "apple.com", "icloud.com", "google.com", "microsoft.com", "mozilla.org",
    "malwarebytes", "sophos", "kaspersky", "bitdefender", "avast", "eset",
    "virustotal", "objective-see",
)
RC_FILES = [
    "~/.zshrc", "~/.zprofile", "~/.zshenv", "~/.zlogin",
    "~/.bashrc", "~/.bash_profile", "~/.profile",
    "/etc/zshenv", "/etc/zprofile", "/etc/zshrc", "/etc/bashrc", "/etc/profile",
]


def scan(deep=False, forensic=False):
    return (_check_posture()
            + _check_hosts()
            + _check_shell_init()
            + _check_profiles()
            + _check_mdm(forensic))


def _check_posture():
    out = []
    rc, o, _ = utils.run(["spctl", "--status"])
    if rc == 0 and "disabled" in o:
        out.append(Finding(
            "high", "system", "Gatekeeper is disabled",
            "Unsigned, unnotarized apps can run without any warning.",
            remediation="sudo spctl --master-enable"))
    rc, o, _ = utils.run(["csrutil", "status"])
    if rc == 0 and "disabled" in o.lower():
        out.append(Finding(
            "high", "system", "System Integrity Protection is disabled",
            "Malware can modify protected system files. Re-enable from macOS "
            "Recovery with 'csrutil enable'."))
    xp = utils.read_plist(
        "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist")
    if xp:
        out.append(Finding(
            "info", "system",
            f"Apple XProtect definitions: version {xp.get('CFBundleShortVersionString', '?')}",
            "Apple's built-in malware definitions; they stay current automatically "
            "while automatic updates are enabled."))
    return out


def _check_hosts():
    try:
        with open("/etc/hosts") as f:
            lines = f.readlines()
    except OSError:
        return []
    out = []
    for n, line in enumerate(lines, 1):
        s = line.split("#")[0].strip()
        if not s:
            continue
        for host in s.split()[1:]:
            if _watched(host):
                out.append(Finding(
                    "high", "system", "/etc/hosts redirects a security or update domain",
                    f"line {n}: '{s}' — malware uses this to block security tools "
                    "and OS updates.",
                    remediation="sudo nano /etc/hosts  (delete the line)"))
    return out


def _watched(host):
    """Full domains match as suffixes (so 'pineapple.community' doesn't trip
    on 'apple.com'); bare vendor words still match as substrings."""
    h = host.lower().rstrip(".")
    for d in WATCH_DOMAINS:
        if "." in d:
            if h == d or h.endswith("." + d):
                return True
        elif d in h:
            return True
    return False


def _check_shell_init():
    out = []
    for rcf in RC_FILES:
        path = os.path.expanduser(rcf)
        try:
            with open(path) as f:
                lines = f.readlines()
        except OSError:
            continue
        for n, line in enumerate(lines, 1):
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            for desc in signatures.match_cmdline(s):
                out.append(Finding(
                    "medium", "system", "Suspicious command in shell startup file",
                    f"{path} line {n}: '{s[:200]}' — {desc}. This runs every time "
                    "you open a terminal; remove it if you didn't add it."))
    return out


def _check_profiles():
    rc, o, err = utils.run(["profiles", "list"])
    if rc == -1 or (rc != 0 and "root" in (o + err).lower()):
        utils.record_blindspot("configuration profiles", "`profiles` needs root")
        return []
    if rc != 0:
        return []
    ids = re.findall(r"profileIdentifier:\s*(\S+)", o)
    if not ids:
        return []
    return [Finding(
        "review", "system", f"{len(ids)} configuration profile(s) installed",
        "Profiles can force proxies/DNS and install root certificates — fine if "
        "from your employer or school, dangerous otherwise: " + ", ".join(sorted(set(ids))),
        remediation="Review in System Settings > General > Device Management")]


def _check_mdm(forensic):
    """Flag MDM enrollment and inspect installed profile payloads for the
    high-power keys spyware/abuse uses (root certs, global proxies, DNS
    redirection, unrestricted TCC grants)."""
    out = []
    rc, o, _ = utils.run(["profiles", "status", "-type", "enrollment"])
    if rc == 0:
        enrolled = "Enrolled via DEP: Yes" in o or "MDM enrollment: Yes" in o
        user_approved = "User Approved" in o
        if enrolled:
            sev = "high" if not user_approved else "review"
            out.append(Finding(
                sev, "system", "Device is enrolled in Mobile Device Management (MDM)",
                o.strip().replace("\n", " | ") + " — MDM can install software, certificates "
                "and restrictions remotely. Expected on a company/school Mac; on a "
                "personal one it can mean unwanted remote control.",
                remediation="System Settings > General > Device Management to review/remove."))
    if not forensic:
        return out
    # Deep payload inspection of installed profiles (needs root for full output).
    rc, xml, err = utils.run(["profiles", "list", "-output", "stdout-xml"], timeout=30)
    if rc != 0:
        if rc == -1 or "root" in (err or "").lower():
            utils.record_blindspot("profile payloads", "`profiles list -output` needs root")
        return out
    try:
        data = plistlib.loads(xml.encode())
    except Exception:
        return out
    SUSPECT_KEYS = {
        "PayloadContent.PEMCertificateData": "installs a root/trust certificate",
        "com.apple.security.root": "installs a root certificate",
        "ProxyPACURL": "forces a proxy auto-config (traffic interception)",
        "ProxyServer": "forces an HTTP proxy (traffic interception)",
        "ServerAddresses": "overrides DNS servers",
        "Services": "may grant silent TCC access (PPPC payload)",
    }
    profiles = data if isinstance(data, list) else data.get("_computerlevel", [])
    blob = xml
    for key, why in SUSPECT_KEYS.items():
        if key in blob:
            out.append(Finding(
                "high", "system", "Configuration profile carries a high-power payload",
                f"An installed profile contains '{key}' — it {why}. Confirm this came "
                "from an administrator you trust.",
                remediation="Inspect with: sudo profiles list -output stdout-xml"))
    return out
