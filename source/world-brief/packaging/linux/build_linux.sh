#!/usr/bin/env bash
# Builds the Linux distribution packages from the PyInstaller output:
#
#   dist/worldbrief-<version>-linux-<arch>.tar.gz    portable, unpack and run
#   dist/worldbrief_<version>_<debarch>.deb          Debian, Ubuntu, Mint
#   dist/World_Brief-<version>-<arch>.AppImage       every other distribution
#
#   packaging/linux/build_linux.sh [--skip-build]
#
# Run it on the oldest distribution you intend to support: glibc is forward compatible, not
# backward, so a binary built on Ubuntu 22.04 runs on 24.04 but not the other way round.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' desktop/__init__.py)"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  DEBARCH=amd64 ;;
  aarch64) DEBARCH=arm64 ;;
  *)       DEBARCH="$ARCH" ;;
esac
PY="${PYTHON:-${ROOT}/.venv/bin/python}"
[ -x "$PY" ] || PY=python3

# --------------------------------------------------------------------------------- compile

if [ "${1:-}" != "--skip-build" ]; then
  echo "==> icons"
  "$PY" packaging/make_icons.py
  echo "==> pyinstaller"
  "$PY" -m PyInstaller packaging/worldbrief.spec --noconfirm --distpath dist --workpath build/pyi
fi

DIST="$ROOT/dist/worldbrief"
[ -d "$DIST" ] || { echo "no build at $DIST" >&2; exit 1; }

# --------------------------------------------------------------------------------- tarball

echo "==> tar.gz"
STAGE="$ROOT/build/tar/worldbrief-$VERSION"
rm -rf "$ROOT/build/tar"; mkdir -p "$STAGE"
cp -a "$DIST/." "$STAGE/"
cp packaging/linux/worldbrief.desktop "$STAGE/"
cp packaging/icons/icon-256.png "$STAGE/worldbrief.png"
cat > "$STAGE/install.sh" <<'INNER'
#!/usr/bin/env sh
# Installs World Brief for the current user only — no root, nothing outside $HOME.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
mkdir -p "$PREFIX/lib" "$PREFIX/bin" "$PREFIX/share/applications" "$PREFIX/share/icons/hicolor/256x256/apps"
rm -rf "$PREFIX/lib/worldbrief"
cp -a "$HERE" "$PREFIX/lib/worldbrief"
ln -sf "$PREFIX/lib/worldbrief/worldbrief" "$PREFIX/bin/worldbrief"
sed "s|^Exec=worldbrief|Exec=$PREFIX/bin/worldbrief|" "$HERE/worldbrief.desktop" \
  > "$PREFIX/share/applications/worldbrief.desktop"
cp "$HERE/worldbrief.png" "$PREFIX/share/icons/hicolor/256x256/apps/worldbrief.png"
command -v update-desktop-database >/dev/null && update-desktop-database "$PREFIX/share/applications" || true
echo "World Brief installed. Launch it from your applications menu, or run: $PREFIX/bin/worldbrief"
INNER
chmod +x "$STAGE/install.sh"
tar -C "$ROOT/build/tar" -czf "$ROOT/dist/worldbrief-$VERSION-linux-$ARCH.tar.gz" "worldbrief-$VERSION"

# --------------------------------------------------------------------------------- .deb

if command -v dpkg-deb >/dev/null; then
  echo "==> deb"
  PKG="$ROOT/build/deb"
  rm -rf "$PKG"
  mkdir -p "$PKG/DEBIAN" "$PKG/opt/worldbrief" "$PKG/usr/bin" "$PKG/usr/share/applications"
  cp -a "$DIST/." "$PKG/opt/worldbrief/"
  ln -sf /opt/worldbrief/worldbrief "$PKG/usr/bin/worldbrief"
  cp packaging/linux/worldbrief.desktop "$PKG/usr/share/applications/"
  for size in 16 24 32 48 64 128 256 512; do
    d="$PKG/usr/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$d"; cp "packaging/icons/icon-$size.png" "$d/worldbrief.png"
  done
  INSTALLED_KB=$(du -sk "$PKG" | cut -f1)
  cat > "$PKG/DEBIAN/control" <<CONTROL
Package: worldbrief
Version: $VERSION
Section: news
Priority: optional
Architecture: $DEBARCH
Installed-Size: $INSTALLED_KB
Maintainer: World Brief <noreply@localhost>
Depends: libc6, libgtk-3-0
Recommends: gir1.2-webkit2-4.1 | gir1.2-webkit2-4.0, libnotify-bin
Description: Fifteen minutes a day of the world's news, from every nation's press
 World Brief collects the day's events from hundreds of national news outlets, groups the
 reports that describe the same event, and shows how differently they are framed. Clustering,
 ranking and translation all run on this machine; nothing is sent to an external service.
 .
 Install WebKitGTK for the native window. Without it the app still runs and opens in your
 default browser instead.
CONTROL
  cat > "$PKG/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
  command -v update-desktop-database >/dev/null && update-desktop-database -q /usr/share/applications || true
  command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -qf /usr/share/icons/hicolor || true
fi
POSTINST
  cat > "$PKG/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
# The user's briefs, database and language packages live in ~/.local/share/worldbrief and are
# deliberately left alone: removing the program should not throw away what it collected.
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
  command -v update-desktop-database >/dev/null && update-desktop-database -q /usr/share/applications || true
  command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -qf /usr/share/icons/hicolor || true
fi
POSTRM
  chmod 755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/postrm"
  dpkg-deb --build --root-owner-group "$PKG" "$ROOT/dist/worldbrief_${VERSION}_${DEBARCH}.deb" >/dev/null
else
  echo "==> deb skipped (dpkg-deb not installed)"
fi

# --------------------------------------------------------------------------------- AppImage

APPIMAGETOOL="${APPIMAGETOOL:-$ROOT/build/appimagetool}"
if [ ! -x "$APPIMAGETOOL" ]; then
  url="https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-$ARCH.AppImage"
  echo "==> fetching appimagetool"
  mkdir -p "$ROOT/build"
  curl -sfL "$url" -o "$APPIMAGETOOL" && chmod +x "$APPIMAGETOOL" || rm -f "$APPIMAGETOOL"
fi

if [ -x "$APPIMAGETOOL" ]; then
  echo "==> AppImage"
  APPDIR="$ROOT/build/AppDir"
  rm -rf "$APPDIR"
  mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications"
  cp -a "$DIST/." "$APPDIR/usr/bin/"
  cp packaging/linux/AppRun "$APPDIR/AppRun"; chmod +x "$APPDIR/AppRun"
  cp packaging/linux/worldbrief.desktop "$APPDIR/worldbrief.desktop"
  cp packaging/linux/worldbrief.desktop "$APPDIR/usr/share/applications/"
  cp packaging/icons/icon-256.png "$APPDIR/worldbrief.png"
  for size in 16 24 32 48 64 128 256 512; do
    d="$APPDIR/usr/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$d"; cp "packaging/icons/icon-$size.png" "$d/worldbrief.png"
  done
  # ARCH is what appimagetool stamps into the file name and the runtime it embeds.
  ARCH="$ARCH" "$APPIMAGETOOL" --no-appstream "$APPDIR" \
    "$ROOT/dist/World_Brief-$VERSION-$ARCH.AppImage" >/dev/null
else
  echo "==> AppImage skipped (appimagetool unavailable)"
fi

echo
echo "==> packages in dist/"
ls -lh "$ROOT/dist" | grep -E "tar.gz|\.deb|AppImage" || true
