#!/usr/bin/env bash
# Builds the macOS distribution: "World Brief.app" and the disc image that installs it.
#
#   packaging/macos/build_macos.sh [--skip-deps]
#
# Signing and notarisation are optional. Set these to have them done automatically:
#   MACOS_SIGN_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE        a profile stored with: xcrun notarytool store-credentials
# Without them the app still installs; macOS just asks the user to confirm the first launch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' desktop/__init__.py)"
PY="$ROOT/.venv/bin/python"

echo "==> World Brief $VERSION"

if [ "${1:-}" != "--skip-deps" ]; then
  [ -x "$PY" ] || python3 -m venv .venv
  echo "==> dependencies"
  "$PY" -m pip install --upgrade pip --quiet
  "$PY" -m pip install -r requirements-desktop.txt --quiet
fi

echo "==> icons"
"$PY" packaging/make_icons.py

echo "==> pyinstaller"
rm -rf "dist/World Brief.app" dist/worldbrief
"$PY" -m PyInstaller packaging/worldbrief.spec --noconfirm --distpath dist --workpath build/pyi >/dev/null

APP="$ROOT/dist/World Brief.app"
[ -d "$APP" ] || { echo "PyInstaller produced no app bundle" >&2; exit 1; }

if [ -n "${MACOS_SIGN_IDENTITY:-}" ]; then
  echo "==> signing the app"
  codesign --force --deep --options runtime --timestamp \
    --entitlements packaging/macos/entitlements.plist \
    --sign "$MACOS_SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
fi

echo "==> disc image"
bash packaging/macos/build_dmg.sh "$APP"

DMG="$ROOT/dist/World Brief-$VERSION.dmg"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> notarising (this takes a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "==> stapled"
fi

echo
echo "==> done"
echo "    app: $APP"
echo "    dmg: $DMG"
