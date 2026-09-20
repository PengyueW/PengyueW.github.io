"""Detect browser hijacking: forced-extension and search/homepage policies
(the standard adware technique on macOS), managed preferences, and — in deep
mode — an inventory of high-privilege browser extensions."""
import glob
import json
import os

from . import utils
from .finding import Finding

CHROMIUM_BROWSERS = [
    ("com.google.Chrome", "Google Chrome"),
    ("com.microsoft.Edge", "Microsoft Edge"),
    ("com.brave.Browser", "Brave"),
    ("org.chromium.Chromium", "Chromium"),
]
POLICY_KEYS = [
    "ExtensionInstallForcelist",
    "HomepageLocation",
    "NewTabPageLocation",
    "DefaultSearchProviderSearchURL",
]
EXTENSION_ROOTS = [
    "~/Library/Application Support/Google/Chrome",
    "~/Library/Application Support/Microsoft Edge",
    "~/Library/Application Support/BraveSoftware/Brave-Browser",
]
BROAD_HOSTS = ("<all_urls>", "http://*/*", "https://*/*", "*://*/*")


def scan(deep=False, forensic=False):
    findings = []
    for domain, name in CHROMIUM_BROWSERS:
        for key in POLICY_KEYS:
            rc, out, _ = utils.run(["defaults", "read", domain, key])
            if rc == 0 and out.strip():
                findings.append(Finding(
                    "high", "browser", f"{name} policy '{key}' is set",
                    f"Value: {out.strip()[:300]} — adware commonly hijacks browsers "
                    "through enterprise policies (only legitimate on an "
                    "employer-managed Mac).",
                    remediation=f"defaults delete {domain} {key}  (then restart {name})"))
    managed = (glob.glob("/Library/Managed Preferences/*.plist")
               + glob.glob("/Library/Managed Preferences/*/*.plist"))
    if managed:
        names = sorted({os.path.basename(p) for p in managed})
        findings.append(Finding(
            "review", "browser", f"{len(managed)} managed preference file(s) present",
            "Normal on a company-managed Mac, an adware vector on a personal one: "
            + ", ".join(names[:10]) + ("…" if len(names) > 10 else "")))
    if deep:
        findings += _extension_inventory()
    return findings


def _extension_inventory():
    risky = []
    for root in EXTENSION_ROOTS:
        pattern = os.path.expanduser(root) + "/*/Extensions/*/*/manifest.json"
        for manifest_path in glob.glob(pattern):
            try:
                with open(manifest_path) as f:
                    manifest = json.load(f)
            except (OSError, json.JSONDecodeError):
                continue
            perms = [str(p) for p in
                     (manifest.get("permissions") or []) + (manifest.get("host_permissions") or [])]
            broad = any(h in perms for h in BROAD_HOSTS)
            powerful = any(p in perms for p in ("webRequest", "tabs", "cookies", "history"))
            if broad and powerful:
                ext_id = manifest_path.split("/Extensions/")[1].split("/")[0]
                name = manifest.get("name", "?")
                risky.append(f"{name} ({ext_id})")
    if not risky:
        return []
    return [Finding(
        "review", "browser",
        f"{len(risky)} browser extension(s) can read/modify all sites",
        "These extensions have full access to every page you visit — remove any "
        "you don't actively use: " + ", ".join(sorted(set(risky))))]
