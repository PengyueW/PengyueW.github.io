#!/usr/bin/env bash
# One entry point for all four platforms. Each one can only be built on itself — a Mac cannot
# produce a Windows .exe, and PyInstaller does not cross-compile — so this picks the right
# script for the machine it is run on, and can build the Android packages anywhere.
#
#   packaging/build.sh              the desktop package for this operating system
#   packaging/build.sh android      the .apk and .aab
#   packaging/build.sh all          this machine's desktop package, plus Android
#
# For every platform at once, push a tag and let .github/workflows/release.yml do it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
TARGET="${1:-desktop}"

build_desktop() {
  case "$(uname -s)" in
    Darwin) bash packaging/macos/build_macos.sh ;;
    Linux)  bash packaging/linux/build_linux.sh ;;
    MINGW*|MSYS*|CYGWIN*)
      powershell -ExecutionPolicy Bypass -File packaging/windows/build_windows.ps1 ;;
    *) echo "unknown platform: $(uname -s)" >&2; exit 1 ;;
  esac
}

case "$TARGET" in
  desktop) build_desktop ;;
  android) bash packaging/android/build_android.sh release ;;
  all)     build_desktop; bash packaging/android/build_android.sh release ;;
  macos)   bash packaging/macos/build_macos.sh ;;
  linux)   bash packaging/linux/build_linux.sh ;;
  windows) powershell -ExecutionPolicy Bypass -File packaging/windows/build_windows.ps1 ;;
  *) echo "usage: packaging/build.sh [desktop|android|all|macos|linux|windows]" >&2; exit 1 ;;
esac
