"""Detection data: known-malware indicators and heuristic patterns.

Indicators come from public write-ups of macOS malware families
(Objective-See reports, vendor advisories, CISA alerts). Add new entries
here — scanner modules contain no detection data of their own.
"""
import fnmatch
import os
import re

# (glob pattern, family) — '~' is expanded at match time.
KNOWN_MALWARE_PATHS = [
    # Backdoors / worms / ransomware
    ("~/.client", "FruitFly backdoor"),
    ("~/Library/.client", "FruitFly backdoor"),
    ("/Library/AppQuest", "EvilQuest/ThiefQuest ransomware"),
    ("~/Library/AppQuest", "EvilQuest/ThiefQuest ransomware"),
    ("~/Library/kernel_service", "KeRanger ransomware"),
    ("~/Library/.kernel_pid", "KeRanger ransomware"),
    ("~/Library/.kernel_time", "KeRanger ransomware"),
    ("~/Library/.kernel_complete", "KeRanger ransomware"),
    ("/Library/Application Support/JavaW", "iWorm backdoor"),
    ("/usr/local/machook", "WireLurker"),
    ("/Library/LaunchDaemons/com.apple.machook_damon.plist", "WireLurker"),
    ("~/Library/._insu", "Silver Sparrow (marker file)"),
    ("~/Library/Application Support/agent_updater", "Silver Sparrow"),
    ("~/Library/Application Support/verx_updater", "Silver Sparrow"),
    ("~/.local/softwareupdate", "DazzleSpy backdoor (ESET)"),
    ("/Library/WebServer/share/httpd/manual/WindowServer", "CloudMensis spyware (ESET)"),
    ("~/Library/Caches/com.apple.safari.ck", "KandyKorn / Lazarus (Elastic)"),
    # Keyloggers / surveillance tools
    ("/Library/LaunchDaemons/logKextDaemon.plist", "logKext keylogger"),
    ("/Library/Application Support/Refog*", "Refog keylogger"),
    ("~/Library/LaunchAgents/com.refog*", "Refog keylogger"),
    ("/Applications/Elite Keylogger*", "Elite Keylogger"),
    # Adware / PUPs
    ("/Applications/MacKeeper.app", "MacKeeper (potentially unwanted)"),
    ("~/Library/Application Support/MacKeeper*", "MacKeeper (potentially unwanted)"),
    ("/Applications/Genieo*", "Genieo adware"),
    ("~/Library/Application Support/com.genieoinnovation*", "Genieo adware"),
    ("/Library/Frameworks/GenieoExtra.framework", "Genieo adware"),
    ("/Applications/SearchProtect*", "Conduit/SearchProtect adware"),
    ("~/Library/Application Support/Conduit*", "Conduit adware"),
    ("/Library/InputManagers/CTLoader", "Conduit adware"),
    ("/Applications/Advanced Mac Cleaner*", "Advanced Mac Cleaner (fake AV)"),
    ("~/Library/Application Support/amc", "Advanced Mac Cleaner (fake AV)"),
    ("/Applications/Mac Adware Cleaner*", "fake anti-virus PUP"),
]

# lowercase launchd Label -> family
KNOWN_BAD_LABELS = {
    "com.pcv.hlpramc": "Pirrit adware",
    "com.updater.mcy": "Adload adware",
    "com.avickupd": "Adload adware",
    "com.msp.agent": "Adload adware",
    "com.client.client": "FruitFly backdoor",
    "com.apple.questd": "EvilQuest/ThiefQuest (masquerading as Apple)",
    "com.apple.machook_damon": "WireLurker (masquerading as Apple)",
    "com.javaw": "iWorm backdoor",
    "logkextdaemon": "logKext keylogger",
    "init_agent": "Silver Sparrow",
    "init_verx": "Silver Sparrow",
    # The real WindowServer/softwareupdate jobs live under /System (which this
    # scanner never visits), so these labels in /Library or ~/Library are
    # masquerades by definition.
    "com.apple.windowserver": "CloudMensis (masquerading as Apple)",
    "com.apple.softwareupdate": "DazzleSpy (masquerading as Apple)",
}

# Command-line behaviours that are almost never legitimate in a persistence
# item or shell init file.
SUSPICIOUS_CMD_PATTERNS = [
    (re.compile(r"(curl|wget)\s+[^|;&]*\|\s*(sudo\s+)?\S*sh\b"),
     "downloads a script and pipes it straight into a shell"),
    (re.compile(r"base64\s+(-d\b|-D\b|--decode)"),
     "decodes base64 content (common obfuscation)"),
    (re.compile(r"echo\s+[A-Za-z0-9+/=]{40,}\s*\|"),
     "pipes a long base64 blob into another command"),
    (re.compile(r"osascript\s+.*do shell script", re.IGNORECASE),
     "runs a hidden shell via AppleScript"),
    (re.compile(r"python[23]?\s+-c\s+.*(__import__|exec\(|compile\()"),
     "runs obfuscated inline Python"),
    (re.compile(r"/dev/tcp/"),
     "opens a raw TCP connection from the shell (reverse-shell pattern)"),
    (re.compile(r"\bn(c|cat)\b[^|]*\s-l"),
     "starts a netcat listener"),
    (re.compile(r"xattr\s+-\w*[dr]\w*\s+\S*com\.apple\.quarantine"),
     "strips Gatekeeper quarantine attributes"),
    (re.compile(r"launchctl\s+(load|bootstrap)\s+\S*/(private/)?(tmp|var/tmp)/"),
     "loads a launchd job from a temp directory"),
    (re.compile(r"chflags\s+hidden"),
     "hides files from Finder"),
    (re.compile(r"\bsecurity\s+dump-keychain"),
     "dumps keychain credentials"),
    (re.compile(r"\bscreencapture\s+-\w*x"),
     "takes screenshots silently (covert screen capture)"),
    (re.compile(r"osascript[^|;&]*with administrator privileges", re.IGNORECASE),
     "spawns an admin-password prompt via AppleScript (credential-phishing pattern)"),
    (re.compile(r"launchctl\s+setenv\s+DYLD_"),
     "globally injects a dynamic library into newly launched apps"),
]

# World-writable directories nothing legitimate should persist or run from.
SUSPICIOUS_DIR_PREFIXES = (
    "/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/Users/Shared/",
)

# Hidden dotfolders that legitimately contain executables on developer
# machines. A hidden folder NOT on this list is treated as suspicious.
HIDDEN_DIR_ALLOWLIST = {
    ".cargo", ".rustup", ".nvm", ".npm", ".pnpm", ".yarn", ".bun", ".deno",
    ".pyenv", ".rbenv", ".rvm", ".asdf", ".sdkman", ".gem", ".local", ".cache",
    ".venv", ".virtualenvs", ".poetry", ".conda", ".tox",
    ".docker", ".orbstack", ".rd", ".colima", ".lima",
    ".vscode", ".vscode-server", ".vscode-insiders", ".cursor", ".claude",
    ".codeium", ".gradle", ".m2", ".android", ".flutter", ".pub-cache",
    ".dotnet", ".ghcup", ".stack", ".opam", ".nix-profile", ".oh-my-zsh",
    ".tmux", ".fzf", ".krew", ".volta", ".juliaup", ".goenv", ".jenv",
    ".composer", ".platformio", ".espressif", ".emacs.d", ".config", ".go",
}

_expanded_paths = None


def expanded_paths():
    global _expanded_paths
    if _expanded_paths is None:
        _expanded_paths = [(os.path.expanduser(p), fam) for p, fam in KNOWN_MALWARE_PATHS]
    return _expanded_paths


def match_path(path):
    """Return the malware family for a path, or None."""
    if not path:
        return None
    for pattern, family in expanded_paths():
        if fnmatch.fnmatch(path, pattern) or fnmatch.fnmatch(path, pattern + "/*"):
            return family
    return None


def match_label(label):
    """Return the malware family for a launchd label, or None."""
    return KNOWN_BAD_LABELS.get((label or "").lower())


def match_cmdline(text):
    """Return descriptions of every suspicious pattern found in a command line."""
    return [desc for rx, desc in SUSPICIOUS_CMD_PATTERNS if rx.search(text)]


def in_suspicious_location(path):
    """Explain why an executable's location is suspicious, or return ''."""
    if not path or not path.startswith("/"):
        return ""
    norm = os.path.normpath(path)
    for prefix in SUSPICIOUS_DIR_PREFIXES:
        if norm.startswith(prefix):
            return "located in world-writable directory " + prefix.rstrip("/")
    if norm.startswith(("/Users/", "/Library/")):
        for comp in norm.split("/"):
            if not comp.startswith("."):
                continue
            if comp in HIDDEN_DIR_ALLOWLIST:
                # Inside a known toolchain directory; its contents (including
                # nested dotfolders) are managed by that tool.
                return ""
            return f"located under hidden directory '{comp}'"
    return ""
