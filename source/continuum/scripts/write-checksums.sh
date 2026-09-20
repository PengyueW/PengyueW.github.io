#!/bin/bash
# Writes dist/CHECKSUMS.txt — the published MD5 manifest for the current
# version.
#
# The hashed file is Contents/MacOS/Continuum, the app's own Mach-O binary, and
# nothing else. That is deliberate: it is exactly the file Settings ▸ Integrity
# hashes and shows, so a user can paste a line from this manifest into the app
# and get a Match. Hashing the .app directory or the .dmg instead would produce
# a number the app can never reproduce about itself.
#
# The hash covers the *signed* binary, so this must run after build.sh has
# signed the bundle — which is why build.sh calls it at the end rather than
# mid-assembly.
#
#   ./scripts/write-checksums.sh              → every target built for this version
#   ./scripts/write-checksums.sh 11 13        → only those targets
set -euo pipefail
cd "$(dirname "$0")/.."

DIST=dist
OUT="$DIST/CHECKSUMS.txt"
mkdir -p "$DIST"

app_for() {   # $1 = deployment target
    case "$1" in
        13|13.0) echo "build/Continuum.app" ;;
        *)       echo "build/Continuum-macOS$1.app" ;;
    esac
}

TARGETS="${*:-13 12.0 11.0 10.15}"

# The version being released: whatever build.sh just stamped, else the VERSION
# file. Deliberately NOT "the first bundle found" — build/ accumulates bundles
# from earlier versions, and picking one of those would head the manifest with
# a stale number and then filter out every current build below it.
VERSION="${CONTINUUM_VERSION:-}"
if [ -z "$VERSION" ] && [ -f VERSION ]; then
    VERSION="$(tr -d '[:space:]' < VERSION)"
fi
if [ -z "$VERSION" ]; then
    echo "write-checksums: no version to report (no CONTINUUM_VERSION, no VERSION file)" >&2
    exit 0
fi

{
    echo "Continuum $VERSION — MD5 checksums"
    echo "Generated $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo
    echo "Each line is the MD5 of that build's application binary:"
    echo "    Continuum.app/Contents/MacOS/Continuum"
    echo
    echo "To verify a copy you downloaded, open the app and go to"
    echo "Settings ▸ Integrity. It shows the MD5 of its own binary; paste the"
    echo "matching line below into \"Expected MD5\" and it will confirm a match."
    echo
    printf '%-34s  %-14s  %s\n' "MD5" "TARGET" "BUILD"
    printf '%-34s  %-14s  %s\n' \
        "----------------------------------" "--------------" "-----"
} > "$OUT"

FOUND=0
for t in $TARGETS; do
    APP="$(app_for "$t")"
    BIN="$APP/Contents/MacOS/Continuum"
    [ -f "$BIN" ] || continue

    # Skip bundles left over from an earlier version — listing a stale hash
    # under this version's heading would be worse than omitting it.
    APPVER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
    [ "$APPVER" = "$VERSION" ] || continue

    printf '%-34s  %-14s  %s\n' \
        "$(md5 -q "$BIN")" "macOS $t" "$(basename "$APP")" >> "$OUT"
    FOUND=$((FOUND + 1))
done

echo "• Wrote $OUT ($FOUND target(s), version $VERSION)"
