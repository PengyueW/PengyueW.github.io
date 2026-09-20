#!/usr/bin/env bash
# Builds "World Brief-<version>.dmg": a disk image with its own background, icon layout and
# volume icon, so opening it shows one instruction — drag the app onto Applications.
#
#   packaging/macos/build_dmg.sh [path/to/World Brief.app]
#
# Nothing here needs create-dmg or any other third-party tool: hdiutil and Finder ship with macOS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="${1:-$ROOT/dist/World Brief.app}"
VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$ROOT/desktop/__init__.py")"
VOLNAME="World Brief"
OUT="$ROOT/dist/World Brief-$VERSION.dmg"
STAGE="$ROOT/build/dmg"
TMPDMG="$ROOT/build/worldbrief-rw.dmg"

[ -d "$APP" ] || { echo "no app bundle at: $APP (run: pyinstaller packaging/worldbrief.spec)" >&2; exit 1; }

echo "==> staging"
rm -rf "$STAGE" "$TMPDMG" "$OUT"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/World Brief.app"
ln -s /Applications "$STAGE/Applications"

if [ -f "$ROOT/packaging/macos/dmg-background.tiff" ]; then
  cp "$ROOT/packaging/macos/dmg-background.tiff" "$STAGE/.background/background.tiff"
  BG_FILE="background.tiff"
else
  cp "$ROOT/packaging/macos/dmg-background.png" "$STAGE/.background/background.png"
  BG_FILE="background.png"
fi

# Size the image from what it holds, with room for the filesystem's own overhead.
SIZE_KB=$(du -sk "$STAGE" | cut -f1)
SIZE_MB=$(( SIZE_KB / 1024 + 120 ))

echo "==> creating read/write image (${SIZE_MB} MB)"
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" -format UDRW -size "${SIZE_MB}m" "$TMPDMG" >/dev/null

echo "==> laying out the window"
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$TMPDMG" | egrep '^/dev/' | sed 1q | awk '{print $1}')
MOUNT="/Volumes/$VOLNAME"
trap 'hdiutil detach "$DEVICE" -quiet 2>/dev/null || true' EXIT
sleep 2

# Finder owns the look of a disk image window; AppleScript is the only way to set it.
# On a build machine with no Finder (a bare CI shell) this is skipped and the image still works.
if ! osascript "$ROOT/packaging/macos/dmg_layout.applescript" "$VOLNAME" "$BG_FILE" 2>/dev/null; then
  echo "    (Finder is unavailable here; shipping the image without the custom layout)"
fi

# The volume icon goes on after Finder is done, or hdiutil folds it away before it is used.
cp "$ROOT/packaging/icons/icon.icns" "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT" 2>/dev/null || true
chmod -Rf go-w "$MOUNT" 2>/dev/null || true
sync

echo "==> compressing"
hdiutil detach "$DEVICE" -quiet
trap - EXIT
hdiutil convert "$TMPDMG" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -f "$TMPDMG"
rm -rf "$STAGE"

# Signing is optional: without an identity the image is still installable, macOS just asks first.
if [ -n "${MACOS_SIGN_IDENTITY:-}" ]; then
  echo "==> signing"
  codesign --force --sign "$MACOS_SIGN_IDENTITY" "$OUT"
fi

echo "==> $OUT"
hdiutil imageinfo "$OUT" | sed -n 's/^Format Description: /format: /p'
du -h "$OUT" | cut -f1 | sed 's/^/size: /'
