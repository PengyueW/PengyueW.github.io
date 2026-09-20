#!/usr/bin/env bash
# Builds the Android packages:
#
#   dist/WorldBrief-<version>.apk    sideload, or install from a file manager
#   dist/WorldBrief-<version>.aab    the bundle Google Play wants
#
#   packaging/android/build_android.sh [debug|release]
#
# Signing: set WORLDBRIEF_KEYSTORE (and its passwords) to sign with a real key. Without them
# the release build is signed with the local debug key, which installs fine but cannot be
# published. Create a key once with:
#   keytool -genkeypair -v -keystore worldbrief.jks -alias worldbrief \
#           -keyalg RSA -keysize 4096 -validity 10000
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
VARIANT="${1:-release}"
VERSION="$(sed -n 's/.*versionName = "\(.*\)".*/\1/p' android/app/build.gradle.kts | head -1)"

# The Android SDK: wherever the environment says, or where Android Studio puts it.
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
[ -d "$SDK" ] || SDK="$HOME/Android/Sdk"
[ -d "$SDK" ] || { echo "no Android SDK found; set ANDROID_SDK_ROOT" >&2; exit 1; }
echo "sdk.dir=$SDK" > android/local.properties

# Gradle: the wrapper if the project has one, otherwise a distribution already on this machine.
if [ -x android/gradlew ]; then
  GRADLE="./gradlew"
else
  GRADLE="$(find "$HOME/.gradle/wrapper/dists" -type f -path '*/bin/gradle' 2>/dev/null | sort | tail -1)"
  [ -n "$GRADLE" ] || GRADLE="$(command -v gradle || true)"
  [ -n "$GRADLE" ] || { echo "no Gradle found; install it or run 'gradle wrapper' in android/" >&2; exit 1; }
fi
echo "==> gradle: $GRADLE"

cd android
if [ "$VARIANT" = "debug" ]; then
  "$GRADLE" --no-daemon :app:assembleDebug
  OUT_APK="app/build/outputs/apk/debug/app-debug.apk"
  OUT_AAB=""
else
  "$GRADLE" --no-daemon :app:assembleRelease :app:bundleRelease
  OUT_APK="app/build/outputs/apk/release/app-release.apk"
  OUT_AAB="app/build/outputs/bundle/release/app-release.aab"
fi
cd "$ROOT"

mkdir -p dist
SUFFIX=""
[ "$VARIANT" = "debug" ] && SUFFIX="-debug"
cp "android/$OUT_APK" "dist/WorldBrief-$VERSION$SUFFIX.apk"
[ -n "$OUT_AAB" ] && cp "android/$OUT_AAB" "dist/WorldBrief-$VERSION.aab"

echo
echo "==> packages in dist/"
ls -lh dist/*.apk dist/*.aab 2>/dev/null || true
