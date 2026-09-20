#!/bin/bash
# Builds a polished, ready-to-distribute install DMG for Continuum:
# a Finder window with the app on the left, an Applications shortcut on the
# right, an arrow between them, and a branded gradient background — i.e. the
# familiar "drag to Applications" installer.
#
# Self-contained: uses only hdiutil / osascript / swiftc (Command Line Tools).
# Run ./build.sh first (or this script will run it for you if the app is
# missing).
#
#   ./scripts/make-dmg.sh            → dist/Continuum-<version>.dmg           (macOS 13)
#   ./scripts/make-dmg.sh 12         → dist/Continuum-<version>-macOS12.0.dmg
#   ./scripts/make-dmg.sh 11         → dist/Continuum-<version>-macOS11.0.dmg
#   ./scripts/make-dmg.sh 10.15      → dist/Continuum-<version>-macOS10.15.dmg
#   ./scripts/make-dmg.sh all        → builds all four of the above in one go
set -euo pipefail
cd "$(dirname "$0")/.."

# "all" fans out to one invocation per deployment target instead of building
# a single DMG, so every past-macOS-version app build gets its own image.
if [ "${1:-}" = "all" ]; then
    for t in 13 12 11 10.15; do
        echo "════▶ Packaging DMG for macOS $t"
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
    SUFFIX=""
else
    APP="build/Continuum-macOS$DEPLOY.app"
    SUFFIX="-macOS$DEPLOY"
fi
VOLNAME="Continuum"
BUILD=.build
DIST=dist

# The name the bundle has *inside* the image. The 12 / 11 / 10.15 builds live on
# disk as Continuum-macOS<target>.app so four targets can coexist in build/, and
# the AppleScript below has to position the icon by its real name — it used to
# ask for "Continuum.app" unconditionally, which raised
#   Finder got an error: Can't set item "Continuum.app" … (-10006)
# on every non-13 target. AppleScript aborts at the first error, so the bounds
# and background had been applied but the two icons never got positioned: that
# is why only the macOS 13 image looked right.
APP_NAME="$(basename "$APP")"

# Pull the marketing version straight from the bundle so the DMG name tracks it.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist" 2>/dev/null || echo 1.0.0)"
DMG="$DIST/Continuum-$VERSION$SUFFIX.dmg"
TMPDMG="$BUILD/Continuum-rw.dmg"

if [ ! -d "$APP" ]; then
    echo "• $APP not found — building it first"
    ./build.sh "$DEPLOY"
fi

mkdir -p "$BUILD" "$DIST"
rm -f "$DMG" "$TMPDMG"

# 1. Render the window background.
echo "• Rendering DMG background"
BG="$BUILD/dmg-background.png"
swift scripts/make_dmg_background.swift "$BG"

# Window geometry. The background image is laid out at BG_W×BG_H *logical
# points* (the .swift renderer draws in this space and bakes a 2× Retina
# bitmap), and Finder paints it into the window's CONTENT area without scaling.
# But `bounds of container window` is the whole frame, which includes the title
# bar — so the content is TITLEBAR points shorter than the frame. If we set the
# frame to the image size, the content is too short: the image rides up, the
# footer falls into an off-screen scroll region, and it looks uncentred. Sizing
# the frame to BG + TITLEBAR makes the content exactly the image size, so the
# background sits centred and the window never needs to scroll.
BG_W=640
BG_H=400
TITLEBAR=28        # Finder icon-view title bar height (points), macOS 13+.
WIN_LEFT=200
WIN_TOP=120
WIN_RIGHT=$(( WIN_LEFT + BG_W ))
WIN_BOTTOM=$(( WIN_TOP + BG_H + TITLEBAR ))

# 2. Stage the volume contents.
echo "• Staging volume"
STAGE="$BUILD/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
cp "$BG" "$STAGE/.background/background.png"
ln -s /Applications "$STAGE/Applications"
# The license travels inside the app bundle (Contents/Resources/LICENSE), so
# the installer window stays a clean two-icon drag-to-Applications layout.

# 3. Create a writable DMG from the staging folder, sized with headroom.
echo "• Creating writable image"
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" \
    -fs HFS+ -format UDRW -ov "$TMPDMG" >/dev/null

# 4. Mount it and lay out the Finder window.
echo "• Mounting and styling"
MOUNT_DIR="/Volumes/$VOLNAME"
hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$TMPDMG" \
    | grep -E '^/dev/' | head -1 | awk '{print $1}')"
sleep 2

# A styling failure is reported loudly and with the actual AppleScript error.
# It used to be swallowed by a bare `|| echo "skipped"`, which is how the
# broken icon layout on the 12 / 11 / 10.15 images went unnoticed: the DMG
# still mounts, so nothing downstream complains.
STYLE_ERR="$BUILD/dmg-style-error.txt"
rm -f "$STYLE_ERR"
if ! osascript >/dev/null 2>"$STYLE_ERR" <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {$WIN_LEFT, $WIN_TOP, $WIN_RIGHT, $WIN_BOTTOM}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set text size of theViewOptions to 13
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "$APP_NAME" of container window to {170, 230}
        set position of item "Applications" of container window to {470, 230}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
then
    echo "  ⚠️  Finder styling FAILED — the image will mount with an unstyled," >&2
    echo "      unpositioned icon layout. Error was:" >&2
    sed 's/^/      /' "$STYLE_ERR" >&2
    STYLED=no
else
    STYLED=yes
fi

sync

# 5. Detach and convert to a compressed, read-only release image.
echo "• Finalising compressed image"
hdiutil detach "$DEVICE" >/dev/null 2>&1 || hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
hdiutil convert "$TMPDMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null
rm -f "$TMPDMG"

# 6. Sign the disk image itself with the Developer ID cert (if present) so the
#    download is signed end-to-end. notarytool can notarise either way, but a
#    signed DMG is the expected release artifact.
DEVELOPER_NAME="Pengyue Wang"
DEVID_HASH="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -F "Developer ID Application" | grep -F "$DEVELOPER_NAME" \
    | head -1 | awk '{print $2}' || true)"
if [ -n "${CONTINUUM_CODESIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$CONTINUUM_CODESIGN_IDENTITY" "$DMG" \
        && echo "• Signed DMG with $CONTINUUM_CODESIGN_IDENTITY"
elif [ -n "$DEVID_HASH" ]; then
    codesign --force --timestamp --sign "$DEVID_HASH" "$DMG" \
        && echo "• Signed DMG with Developer ID Application — $DEVELOPER_NAME"
else
    echo "• DMG left unsigned (no Developer ID cert) — fine for local/dev use."
fi

echo
echo "Built $DMG"
echo "  size: $(du -h "$DMG" | cut -f1)"
echo "  window layout: $([ "$STYLED" = yes ] && echo "styled ($APP_NAME + Applications positioned)" || echo "UNSTYLED — see the error above")"

# Report the app's actual signing authority — `codesign --verify` passes for
# ad-hoc signatures too, so "valid" on its own says nothing about whether the
# image is safe to hand to someone else.
APP_AUTH="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
APP_SIG="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Signature=//p' | head -1)"
if [ -n "$APP_AUTH" ]; then
    echo "  app signed by: $APP_AUTH"
elif [ "$APP_SIG" = "adhoc" ]; then
    echo "  app signature: ad-hoc only (structurally valid, but no trusted authority)"
else
    echo "  app: unsigned"
fi

case "$APP_AUTH" in
  "Developer ID Application"*)
    echo "Next: notarize it — ./scripts/notarize.sh \"$DMG\"  (or ./scripts/release.sh)."
    echo "Hand out the .dmg only AFTER it is notarized + stapled." ;;
  *)
    echo "This is a LOCAL/DEV image — NOT Developer-ID-signed or notarized."
    echo "Do not distribute it publicly (Gatekeeper will block it on other Macs)."
    echo "For a release, install Pengyue Wang's Developer ID cert + notary creds,"
    echo "then run ./scripts/release.sh." ;;
esac
