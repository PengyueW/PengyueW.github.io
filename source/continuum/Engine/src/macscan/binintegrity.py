"""PHASE 1 — deep verification of Apple-signed system binaries.

A hypervisor- or root-level implant may replace or hook a trusted system
binary. We verify that a curated set of security-critical executables are still
Apple-*platform*-signed and pass a strict signature check anchored to Apple's
root, and we flag any that carry debugging entitlements an implant would want
(get-task-allow / task_for_pid). We also sample protected system directories
for any binary that is NOT Apple-signed, which on a healthy system should never
happen (subversion / foreign-binary detection).

On a machine with SIP enabled these files cannot be modified, so a failure here
is a strong signal. SIP being OFF is itself reported by system.py.
"""
import os

from . import utils
from .finding import Finding

# Security-critical binaries: the enforcement points an implant would target.
CRITICAL_BINARIES = [
    "/sbin/launchd",
    "/usr/libexec/trustd",
    "/usr/libexec/securityd",
    "/usr/libexec/syspolicyd",
    "/usr/libexec/gatekeeperd",
    "/usr/libexec/amfid",                 # code-signing enforcement in userspace
    "/usr/libexec/endpointsecurityd",
    "/usr/sbin/spctl",
    "/usr/bin/codesign",
    "/usr/bin/csrutil",
    "/usr/bin/log",
    "/usr/sbin/kextload",
    "/System/Library/PrivateFrameworks/TCC.framework/Support/tccd",
    "/System/Library/CoreServices/launchservicesd",
]

# Directories that should contain only Apple-platform-signed Mach-O binaries.
PROTECTED_BIN_DIRS = ["/usr/libexec", "/usr/sbin", "/usr/bin"]
SAMPLE_PER_DIR = 60

# Entitlements that, on a core system binary, indicate it can be debugged or
# can debug others — exactly what an injector needs.
DANGEROUS_ENTITLEMENTS = (
    "com.apple.security.get-task-allow",
    "task_for_pid-allow",
    "com.apple.private.cs.debugger",
)


def scan(deep=False, forensic=False):
    if not forensic:
        return []
    findings = []
    findings += _verify_critical()
    findings += _sample_protected_dirs()
    return findings


def _verify_critical():
    out = []
    for path in CRITICAL_BINARIES:
        if not os.path.exists(path):
            continue
        status, authority = utils.codesign_info(path)
        if status == "unknown":
            utils.record_blindspot(path, "codesign could not evaluate (access?)")
            continue
        if status != "platform":
            out.append(Finding(
                "critical", "integrity",
                "Critical system binary is not Apple-platform-signed",
                f"{path} reports signature status '{status}' (authority: "
                f"{authority or 'none'}). A healthy, SIP-protected system signs this "
                "with Apple's platform identity; anything else suggests subversion.",
                [path]))
            continue
        # Strict anchor check: must chain to the Apple root.
        rc, _, err = utils.run(
            ["codesign", "--verify", "--strict", "-R=anchor apple", path], timeout=30)
        if rc == 1:
            out.append(Finding(
                "critical", "integrity",
                "Critical system binary fails strict Apple-anchor verification",
                f"{path}: {err.strip() or 'signature did not validate against Apple root'}.",
                [path]))
        elif rc == -1:
            utils.record_blindspot(path, "strict codesign verify could not run")
        ents = _entitlements(path)
        bad = [e for e in DANGEROUS_ENTITLEMENTS if e in ents]
        if bad:
            out.append(Finding(
                "high", "integrity",
                "Critical system binary carries debugging entitlements",
                f"{path} declares {', '.join(bad)} — these let a process be "
                "attached to or inject into others and are unexpected here.",
                [path]))
    return out


# Mach-O magic numbers (thin + fat/universal, both endiannesses).
_MACHO_MAGIC = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",   # 32-bit
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",   # 64-bit
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",   # fat/universal
}


def _is_macho(path):
    """True only for real Mach-O executables. Scripts (#!...) and data files
    legitimately have no code signature and must not be flagged as 'foreign'."""
    try:
        with open(path, "rb") as f:
            return f.read(4) in _MACHO_MAGIC
    except OSError:
        return False


def _entitlements(path):
    rc, out, err = utils.run(
        ["codesign", "-d", "--entitlements", ":-", path], timeout=20)
    return (out or "") + (err or "")


def _sample_protected_dirs():
    out = []
    for d in PROTECTED_BIN_DIRS:
        if not os.path.isdir(d):
            continue
        try:
            names = sorted(os.listdir(d))
        except PermissionError:
            utils.record_blindspot(d, "directory listing denied")
            continue
        except OSError:
            continue
        checked = 0
        for name in names:
            if checked >= SAMPLE_PER_DIR:
                break
            p = os.path.join(d, name)
            if os.path.islink(p) or not os.path.isfile(p) or not os.access(p, os.X_OK):
                continue
            if not _is_macho(p):
                continue   # shell/perl/python scripts legitimately carry no signature
            checked += 1
            status, authority = utils.codesign_info(p)
            if status in ("unsigned", "adhoc", "invalid"):
                out.append(Finding(
                    "critical", "integrity",
                    "Foreign (non-Apple) binary in a protected system directory",
                    f"{p} is {status} (authority: {authority or 'none'}). Binaries in "
                    f"{d} should be Apple-platform-signed; a foreign one here points "
                    "to a deep compromise.",
                    [p]))
    return out
