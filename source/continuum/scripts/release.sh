#!/bin/bash
# One-command release: build → (sign) → notarize the app → package the DMG →
# notarize the DMG → staple. The end product, dist/Continuum-<version>.dmg, is
# a fully signed + notarized image that opens on any Mac with no Gatekeeper
# warning.
#
# Requirements for a *notarized* release:
#   - a "Developer ID Application: Pengyue Wang" certificate in the keychain
#     (from the Apple Developer Program), and
#   - notary credentials (see scripts/notarize.sh).
# Without them this script still runs build + make-dmg, yielding a working
# ad-hoc/local DMG — it just skips the two notarization steps and says so.
#
#   ./scripts/release.sh            → releases the macOS 13 build only
#   ./scripts/release.sh all        → releases all four deployment targets
#                                      (13, 12, 11, 10.15), one DMG each
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" = "all" ]; then
    for t in 13 12 11 10.15; do
        echo "════▶ Releasing macOS $t"
        "$0" "$t"
        echo
    done
    exit 0
fi

DEPLOY="${1:-13}"
case "$DEPLOY" in
    13|13.0) DEPLOY=13.0 ;;
    12|12.0) DEPLOY=12.0 ;;
    11|11.0) DEPLOY=11.0 ;;
    10.15)   DEPLOY=10.15 ;;
    *) echo "Unsupported deployment target: $DEPLOY (use 13, 12, 11, 10.15 or all)" >&2
       exit 2 ;;
esac

if [ "$DEPLOY" = "13.0" ]; then
    APP="build/Continuum.app"
else
    APP="build/Continuum-macOS$DEPLOY.app"
fi

echo "──▶ 1/4  Building & signing the app (macOS $DEPLOY)"
# SKIP_DMG because this script images the app itself in step 3/4, after the
# notarization check — build.sh's own packaging step would just be thrown away.
# The version bump still happens here, once, and every later step reads the
# number back out of the built Info.plist.
SKIP_DMG=1 ./build.sh "$DEPLOY"

# Did build.sh manage a real Developer ID signature?
HAVE_DEVID=0
if codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
    HAVE_DEVID=1
fi

if [ "$HAVE_DEVID" = "1" ]; then
    echo "──▶ 2/4  Notarizing the app"
    scripts/notarize.sh "$APP"
else
    echo "──▶ 2/4  Skipping app notarization"
    echo "    No Developer ID Application signature found. Install Pengyue Wang's"
    echo "    'Developer ID Application' certificate, then re-run ./scripts/release.sh."
fi

echo "──▶ 3/4  Packaging the DMG"
scripts/make-dmg.sh "$DEPLOY"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist" 2>/dev/null || echo 1.0.0)"
if [ "$DEPLOY" = "13.0" ]; then
    DMG="dist/Continuum-$VERSION.dmg"
else
    DMG="dist/Continuum-$VERSION-macOS$DEPLOY.dmg"
fi

if [ "$HAVE_DEVID" = "1" ]; then
    echo "──▶ 4/4  Notarizing the DMG"
    scripts/notarize.sh "$DMG"
    echo
    echo "✓ Release ready — signed & notarized: $DMG"
    echo "  Distribute this file. Gatekeeper will open it cleanly on any Mac."
else
    echo "──▶ 4/4  Skipping DMG notarization"
    echo
    echo "△ Dev image ready (ad-hoc, NOT notarized): $DMG"
    echo "  Fine for local installs; not for public distribution until notarized."
fi
