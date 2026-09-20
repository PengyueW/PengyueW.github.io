"""PHASE 3 — boot / kernel / firmware integrity.

Surfaces components that operate below the application layer, where the most
sophisticated implants hide:
  * System extensions (the modern replacement for KEXTs) from non-Apple teams.
  * Loaded third-party kernel extensions (KEXTs) — a KEXT is ring-0 code.
  * EFI firmware integrity via Apple's `eficheck` (Intel Macs; needs root).
  * NVRAM boot-args that weaken security (e.g. disabling SIP/AMFI/library
    validation).

Apple Silicon Macs don't expose eficheck (boot security is handled by the
Secure Enclave / LocalPolicy) so that check degrades to an informational note.
Everything here is read-only.
"""
from . import utils
from .finding import Finding

WEAKENING_BOOTARGS = {
    "amfi_get_out_of_my_way": "disables Apple Mobile File Integrity (code-signing enforcement)",
    "amfi=": "alters Apple Mobile File Integrity behaviour",
    "cs_enforcement_disable": "disables code-signing enforcement",
    "rootless=0": "disables System Integrity Protection",
    "-no_compat_check": "bypasses hardware compatibility checks (hackintosh/implant)",
    "kext-dev-mode": "permits unsigned kernel extensions",
    "debug=": "enables kernel debugging",
}


def scan(deep=False, forensic=False):
    if not forensic:
        return []
    return (_system_extensions()
            + _kexts()
            + _boot_args()
            + _efi())


def _system_extensions():
    rc, out, err = utils.run(["systemextensionsctl", "list"], timeout=20)
    if rc != 0:
        utils.record_blindspot("system extensions", err.strip() or "systemextensionsctl failed")
        return []
    findings = []
    for line in out.splitlines():
        line = line.strip()
        if not line or line.startswith(("---", "enabled", "*", "no extensions")):
            continue
        low = line.lower()
        if "activated" in low and "com.apple." not in low:
            findings.append(Finding(
                "review", "kernel", "Third-party system extension is active",
                f"{line} — system extensions run with deep OS privileges. Confirm the "
                "vendor (common for VPNs, AV, virtualization)."))
    return findings


def _kexts():
    rc, out, err = utils.run(["kmutil", "showloaded", "--list-only"], timeout=30)
    if rc != 0:
        rc, out, err = utils.run(["kextstat", "-l"], timeout=20)
    if rc != 0:
        utils.record_blindspot("loaded kernel extensions", err.strip() or "kext listing failed")
        return []
    findings = []
    for line in out.splitlines():
        if "com.apple." in line or not line.strip():
            continue
        # Pull the bundle id (last token containing a dot) for context.
        tokens = [t for t in line.split() if "." in t and "/" not in t]
        bundle = tokens[-1] if tokens else line.strip()[:80]
        if bundle and not bundle.startswith("com.apple"):
            findings.append(Finding(
                "high", "kernel", "Third-party kernel extension is loaded",
                f"{bundle} — runs in the kernel (ring 0) with total system access. "
                "Legitimate for some drivers/VPN/AV, but a powerful implant vector; "
                "verify the vendor and that you installed it."))
    return findings


def _boot_args():
    rc, out, _ = utils.run(["nvram", "boot-args"])
    if rc != 0:
        return []   # no boot-args set is the normal, healthy case
    value = out.strip()
    if "\t" in value:
        value = value.split("\t", 1)[1]
    findings = []
    for needle, why in WEAKENING_BOOTARGS.items():
        if needle in value:
            findings.append(Finding(
                "high", "kernel", "NVRAM boot-args weaken system security",
                f"boot-args contains '{needle}' which {why}. Full value: {value}",
                remediation="sudo nvram -d boot-args   (after confirming nothing you "
                            "rely on needs it)"))
    return findings


def _efi():
    rc, out, err = utils.run(["/usr/libexec/firmwarecheckers/eficheck/eficheck",
                              "--integrity-check"], timeout=60)
    if rc == -1:
        # Apple Silicon (no eficheck) or not permitted.
        return [Finding(
            "info", "kernel", "EFI integrity check not available",
            "eficheck is absent (normal on Apple Silicon, where firmware integrity is "
            "enforced by the Secure Enclave) or requires root. No EFI tampering check "
            "was performed.")]
    combined = (out + err).strip()
    text = combined.lower()
    if "no changes" in text or "primary hashes are correct" in text:
        return [Finding(
            "info", "kernel", "EFI firmware matches Apple's known-good hashes",
            "eficheck reported the firmware primary region is unmodified.")]
    # Needs root, or produced no usable verdict (empty output, permission error):
    # that is a blind spot, NOT evidence of tampering.
    if rc != 0 or not combined or "could not" in text or "permission" in text \
            or "denied" in text or "must be run as root" in text:
        utils.record_blindspot(
            "EFI firmware", "eficheck needs root / gave no verdict (rerun with sudo)")
        return []
    # Only a clearly negative verdict is treated as a real finding.
    if "differ" in text or "does not match" in text or "modified" in text or "failed" in text:
        return [Finding(
            "critical", "kernel", "EFI firmware does NOT match Apple's known-good hashes",
            "eficheck reported differences in the firmware. This can indicate an EFI/boot-"
            "level implant — or an unusual hardware/firmware revision. Investigate before "
            "trusting this machine. eficheck said: " + combined[:300])]
    # Unrecognized but non-empty output — report neutrally rather than alarm.
    return [Finding(
        "info", "kernel", "EFI integrity check returned an unrecognized result",
        "eficheck ran but its output could not be classified: " + combined[:200])]
