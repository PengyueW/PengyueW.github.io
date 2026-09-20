#!/bin/bash
# Builds Continuum.app — the unified Cleaner / Disk Map / Security app — as a
# double-clickable, self-contained bundle, using only the Command Line Tools
# (no Xcode required).
#
# Layout: three feature modules (CacheCleanKit, DiskScopeKit, MacScanKit) are
# compiled as static libraries with their own module names so their internal
# type names (ContentView, ScanView, AppModel, …) never collide, then the
# Continuum shell links against all three. The Python scan engine is copied
# into Contents/Resources/macscan-engine so the app needs nothing outside
# its own bundle.
set -euo pipefail
cd "$(dirname "$0")"

# ---------------------------------------------------------------------------
# Deployment target
#
#   ./build.sh            → macOS 13 (default)
#   ./build.sh 12         → macOS 12 Monterey
#   ./build.sh 11         → macOS 11 Big Sur
#   ./build.sh 10.15      → macOS 10.15 Catalina
#   ./build.sh all        → builds all four of the above in one go
#
# One source tree serves all four. Everything version-sensitive goes through
# Sources/Compat, which uses runtime `#available` checks rather than compile-time
# conditionals — so a 10.15-targeted binary still uses NavigationSplitView,
# LabeledContent, Grid and the rest when it happens to be running on macOS 13.
# Older builds are therefore not merely *compatible* with newer machines, they
# are full-fidelity on them.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Version
#
# The single source of truth is the VERSION file. Every build bumps it, so two
# builds never share a version number and a DMG name always identifies exactly
# one binary. Which component moves is chosen with BUMP:
#
#   ./build.sh                 → 1.0.4 → 1.0.5   (patch, the default)
#   BUMP=minor ./build.sh      → 1.0.5 → 1.1.0
#   BUMP=major ./build.sh      → 1.1.0 → 2.0.0
#   BUMP=none  ./build.sh      → rebuild at the current version, no bump
#
# CONTINUUM_VERSION pins an explicit version and always suppresses the bump —
# that is also how the "all" fan-out below, and the DMG step, keep every target
# on one number instead of bumping four times.
# ---------------------------------------------------------------------------
VERSION_FILE="VERSION"
[ -f "$VERSION_FILE" ] || printf '1.0.0\n' > "$VERSION_FILE"

if [ -n "${CONTINUUM_VERSION:-}" ]; then
    VERSION="$CONTINUUM_VERSION"
else
    VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
    case "${BUMP:-patch}" in
        none)  ;;
        patch) VERSION="$(echo "$VERSION" | awk -F. '{printf "%d.%d.%d", $1, $2, $3 + 1}')" ;;
        minor) VERSION="$(echo "$VERSION" | awk -F. '{printf "%d.%d.0",  $1, $2 + 1}')" ;;
        major) VERSION="$(echo "$VERSION" | awk -F. '{printf "%d.0.0",   $1 + 1}')" ;;
        *) echo "Unknown BUMP: ${BUMP} (use patch, minor, major or none)" >&2; exit 2 ;;
    esac
    printf '%s\n' "$VERSION" > "$VERSION_FILE"
fi
export CONTINUUM_VERSION="$VERSION"

# CFBundleVersion must increase monotonically and is not allowed dots-with-
# leading-zeros semantics, so derive one integer from the three components.
BUILD_NUMBER="$(echo "$VERSION" | awk -F. '{printf "%d", $1 * 10000 + $2 * 100 + $3}')"

# "all" fans out to one invocation per deployment target so every supported
# past macOS version gets its own app bundle in one command. CONTINUUM_VERSION
# is exported above, so the four children all stamp the same version.
if [ "${1:-}" = "all" ]; then
    export CONTINUUM_ALL=1   # children skip the manifest; it is written once below
    for t in 13 12 11 10.15; do
        echo "════▶ Building macOS $t"
        "$0" "$t"
        echo
    done
    # Every bundle for this version now exists, so the checksum manifest can
    # cover all four targets at once.
    ./scripts/write-checksums.sh
    exit 0
fi

DEPLOY="${1:-13}"
case "$DEPLOY" in
    13|13.0)     DEPLOY=13.0 ;;
    12|12.0)     DEPLOY=12.0 ;;
    11|11.0)     DEPLOY=11.0 ;;
    10.15)       DEPLOY=10.15 ;;
    *) echo "Unsupported deployment target: $DEPLOY (use 13, 12, 11, 10.15 or all)" >&2
       exit 2 ;;
esac

SDK="$(xcrun --sdk macosx --show-sdk-path)"
BUILD=".build/macos$DEPLOY"

# Every build is universal. Apple Silicon did not exist before macOS 11, so the
# arm64 slice of an older build is pinned at 11.0 while the x86_64 slice carries
# the real deployment target — the standard way to ship a back-deployed app that
# still runs natively (no Rosetta) on an Apple Silicon Mac.
ARCHES="x86_64 arm64"
arch_min() {
    case "$1" in
        arm64) case "$DEPLOY" in 10.15) echo "11.0" ;; *) echo "$DEPLOY" ;; esac ;;
        *)     echo "$DEPLOY" ;;
    esac
}

if [ "$DEPLOY" = "13.0" ]; then
    APP="build/Continuum.app"
else
    APP="build/Continuum-macOS$DEPLOY.app"
fi

# ---------------------------------------------------------------------------
# Swift Concurrency back-deployment
#
# /usr/lib/swift/libswift_Concurrency.dylib only exists from macOS 12 onwards.
# Below that, swiftc links the concurrency runtime as a *weak* @rpath dylib, so
# the app loads fine and then aborts the instant it touches an actor or an
# async function:
#
#   Termination Reason: DYLD
#   can't resolve symbol _swift_defaultActor_initialize … because dependent
#   dylib @rpath/libswift_Concurrency.dylib could not be loaded
#
# The toolchain ships a back-deployment copy (x86_64 min 10.9, arm64 min 11.0)
# for exactly this. Xcode embeds it automatically; building with swiftc by hand
# means doing it ourselves: copy it into Contents/Frameworks and add
# @executable_path/../Frameworks as a *secondary* rpath. /usr/lib/swift stays
# first in the search order, so on macOS 12+ the OS copy still wins and the
# bundled one is only reached on the systems that lack it.
# ---------------------------------------------------------------------------
CONCURRENCY_BACKDEPLOY="$(dirname "$(xcrun -f swiftc)")/../lib/swift-5.5/macosx/libswift_Concurrency.dylib"
case "$DEPLOY" in
    10.15|11.0) NEEDS_CONCURRENCY=1 ;;
    *)          NEEDS_CONCURRENCY=0 ;;
esac
if [ "$NEEDS_CONCURRENCY" = "1" ] && [ ! -f "$CONCURRENCY_BACKDEPLOY" ]; then
    echo "warning: no libswift_Concurrency back-deployment dylib at" >&2
    echo "         $CONCURRENCY_BACKDEPLOY" >&2
    echo "         The macOS $DEPLOY build will crash on launch. Install the" >&2
    echo "         Command Line Tools / Xcode toolchain that ships swift-5.5." >&2
    exit 1
fi

# Extra linker flags for the shell. The helper (Contents/Resources/diskscope-scan)
# resolves ../Frameworks to the same directory, so it gets the rpath too.
backdeploy_ldflags() {
    if [ "$NEEDS_CONCURRENCY" = "1" ]; then
        printf -- "-Xlinker -rpath -Xlinker @executable_path/../Frameworks"
    fi
}

mkdir -p build

# Compat shims are compiled INTO each module rather than shared as a library, so
# every kit keeps its own internal copy and no kit has to widen its public
# surface to import them.
compat_sources() { find Sources/Compat -name '*.swift' | sort; }

compile_kit() {
    local name="$1"
    local arch="$2"
    local out="$BUILD/$arch"
    local min
    min="$(arch_min "$arch")"
    swiftc -O -parse-as-library \
        -target "${arch}-apple-macos${min}" -sdk "$SDK" \
        -module-name "$name" \
        -emit-module -emit-module-path "$out/$name.swiftmodule" \
        -emit-library -static -o "$out/lib$name.a" \
        $(find "Sources/$name" -name '*.swift' | sort) $(compat_sources)
}

KITS="CacheCleanKit DiskScopeKit MacScanKit ShredKit FreeSpaceKit UninstallKit \
DriveHealthKit HardwareKit PermissionsKit ExtensionsKit NetGuardKit SensorsKit StatsKit"

for ARCH in $ARCHES; do
    echo "── $ARCH (macOS $(arch_min "$ARCH")) ──"
    mkdir -p "$BUILD/$ARCH"

    for KIT in $KITS; do
        echo "• Compiling ${KIT}"
        compile_kit "$KIT" "$ARCH"
    done

    # Privileged Disk Map scan helper — a standalone executable run as root (via
    # the admin auth dialog) so "Read All Files" can index even root-owned items.
    echo "• Compiling diskscope-scan helper"
    swiftc -O -target "${ARCH}-apple-macos$(arch_min "$ARCH")" -sdk "$SDK" \
        $(backdeploy_ldflags) \
        -o "$BUILD/$ARCH/diskscope-scan" \
        $(find Sources/DiskScopeScan -name '*.swift' | sort)

    echo "• Compiling Continuum shell + linking"
    swiftc -O -parse-as-library \
        -target "${ARCH}-apple-macos$(arch_min "$ARCH")" -sdk "$SDK" \
        -module-name Continuum \
        -I "$BUILD/$ARCH" -L "$BUILD/$ARCH" \
        -lCacheCleanKit -lDiskScopeKit -lMacScanKit \
        -lShredKit -lFreeSpaceKit -lUninstallKit -lDriveHealthKit -lHardwareKit \
        -lPermissionsKit -lExtensionsKit -lNetGuardKit -lSensorsKit \
        -lStatsKit \
        $(backdeploy_ldflags) \
        $(find Sources/Continuum -name '*.swift' | sort) $(compat_sources) \
        -o "$BUILD/$ARCH/Continuum"
done

# Fuse the per-architecture executables into one universal binary.
echo "• Creating universal binaries"
lipo -create $(for A in $ARCHES; do printf '%s ' "$BUILD/$A/Continuum"; done) \
     -output "$BUILD/Continuum"
lipo -create $(for A in $ARCHES; do printf '%s ' "$BUILD/$A/diskscope-scan"; done) \
     -output "$BUILD/diskscope-scan"

echo "• Assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/Continuum" "$APP/Contents/MacOS/Continuum"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Stamp the deployment target into the bundle so Finder/Gatekeeper refuse to
# launch it on an older system rather than crashing on a missing symbol.
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $DEPLOY" \
    "$APP/Contents/Info.plist" >/dev/null
# Stamp the version from the VERSION file. Resources/Info.plist keeps whatever
# placeholder it was checked in with; the bundle is the thing that must be
# right, and make-dmg.sh reads the version back out of it so the DMG name, the
# About box and the checksum manifest can never disagree.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    "$APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$APP/Contents/Info.plist" >/dev/null
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ship the license inside the bundle (CC BY-NC-SA 4.0).
[ -f LICENSE ] && cp LICENSE "$APP/Contents/Resources/LICENSE"

# Bundle the localizations: one <lang>.lproj/Localizable.strings per language.
# SwiftUI Text/Label literals (and LocalizedStringKey wrappers) resolve against
# Bundle.main, so dropping these .lproj dirs into Resources localizes the UI for
# every CFBundleLocalizations language; a missing key degrades to English.
if [ -d Resources/Localizations ]; then
    echo "• Bundling localizations"
    for lproj in Resources/Localizations/*.lproj; do
        [ -d "$lproj" ] || continue
        cp -R "$lproj" "$APP/Contents/Resources/"
    done
fi

# Bundle the Python scan engine (sources only — no __pycache__).
mkdir -p "$APP/Contents/Resources/macscan-engine/src/macscan"
cp Engine/macscan "$APP/Contents/Resources/macscan-engine/macscan"
cp Engine/src/macscan/*.py "$APP/Contents/Resources/macscan-engine/src/macscan/"
chmod +x "$APP/Contents/Resources/macscan-engine/macscan"

# Ship the Swift Concurrency runtime for targets whose OS predates it.
if [ "$NEEDS_CONCURRENCY" = "1" ]; then
    echo "• Embedding libswift_Concurrency (back-deployment)"
    mkdir -p "$APP/Contents/Frameworks"
    cp "$CONCURRENCY_BACKDEPLOY" "$APP/Contents/Frameworks/libswift_Concurrency.dylib"
    chmod 644 "$APP/Contents/Frameworks/libswift_Concurrency.dylib"
    # The x86_64 slice of the shipped back-deployment dylib records its own
    # dependency on the standard library as @rpath/libswiftCore.dylib (the
    # arm64 slice uses the absolute /usr/lib/swift path). That would resolve
    # only by luck of rpath ordering — Contents/Frameworks is searched too and
    # holds no libswiftCore — so pin it to the OS copy, which exists on every
    # supported target. A no-op on the arm64 slice.
    install_name_tool -change @rpath/libswiftCore.dylib \
        /usr/lib/swift/libswiftCore.dylib \
        "$APP/Contents/Frameworks/libswift_Concurrency.dylib" 2>/dev/null || true
fi

# Bundle the privileged scan helper.
cp "$BUILD/diskscope-scan" "$APP/Contents/Resources/diskscope-scan"
chmod +x "$APP/Contents/Resources/diskscope-scan"

# Harden against trivial reverse-engineering: strip local/debug symbol names
# from the shipped executables so a `nm`/`strings` pass yields far less. `-x`
# keeps only external symbols required for loading; safe for standalone
# executables. Must run BEFORE codesign so the signature seals the stripped
# binary (re-signing happens below).
echo "• Stripping symbols"
strip -x "$APP/Contents/MacOS/Continuum" 2>/dev/null || true
strip -x "$APP/Contents/Resources/diskscope-scan" 2>/dev/null || true

# Hardened runtime + non-sandboxed entitlements: the profile in which Full
# Disk Access grants real visibility.
#
# Signing identity selection, in order of preference:
#   1. $CONTINUUM_CODESIGN_IDENTITY if set,
#   2. else a "Developer ID Application: Pengyue Wang" cert if installed —
#      the identity required for public distribution + notarization,
#   3. else a stable self-signed identity named "Continuum Local Codesign"
#      (create it once with scripts/make-signing-identity.sh),
#   4. else ad-hoc ("-").
# Ad-hoc has no stable identity, so every rebuild changes the app's code hash
# and macOS invalidates the previous build's FDA grant (stale entries pile up
# in System Settings). A stable identity → grant FDA once, it sticks, one entry.
DEVELOPER_NAME="Pengyue Wang"
SIGN_NAME="Continuum Local Codesign"
# Match the Developer ID leaf by hash (column 2 of find-identity) so a parenthe-
# sised Team ID or special characters in the name never break the lookup.
# `|| true` keeps a no-match grep from aborting the script under `set -o pipefail`.
DEVID_HASH="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -F "Developer ID Application" | grep -F "$DEVELOPER_NAME" \
    | head -1 | awk '{print $2}' || true)"
if [ -n "${CONTINUUM_CODESIGN_IDENTITY:-}" ]; then
    IDENTITY="$CONTINUUM_CODESIGN_IDENTITY"
elif [ -n "$DEVID_HASH" ]; then
    IDENTITY="$DEVID_HASH"
elif security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_NAME"; then
    IDENTITY="$SIGN_NAME"
else
    IDENTITY="-"
fi

# A secure timestamp is mandatory for notarization; ad-hoc signatures can't be
# timestamped, so the flag is added only for real identities.
ts_flag() { if [ "$1" != "-" ]; then printf -- "--timestamp"; fi; }

# Nested code must be signed before the enclosing bundle (inner-out). The scan
# helper is a standalone executable, so it gets its own signature — and, since
# it is its own process, it needs the same disable-library-validation
# entitlement as the shell to be allowed to map the bundled Concurrency runtime.
sign_one() {   # $1 = identity
    if [ "$NEEDS_CONCURRENCY" = "1" ]; then
        codesign --force --options runtime $(ts_flag "$1") --sign "$1" \
            "$APP/Contents/Frameworks/libswift_Concurrency.dylib" 2>/dev/null || return 1
    fi
    codesign --force --options runtime $(ts_flag "$1") \
        --entitlements Entitlements/Continuum-Hardened.entitlements --sign "$1" \
        "$APP/Contents/Resources/diskscope-scan" 2>/dev/null
}
sign_one "$IDENTITY" || { [ "$IDENTITY" != "-" ] && sign_one -; } || true

# Sign the whole bundle as one unit. If a real identity fails for any reason,
# fall back to ad-hoc so a build never breaks over signing.
if ! codesign --force --options runtime $(ts_flag "$IDENTITY") \
        --entitlements Entitlements/Continuum-Hardened.entitlements \
        --sign "$IDENTITY" "$APP" 2>/dev/null; then
    if [ "$IDENTITY" != "-" ]; then
        echo "• Signing with “$IDENTITY” failed — falling back to ad-hoc"
        IDENTITY="-"
        sign_one -   # keep the helper's signer consistent with the bundle
    fi
    codesign --force --options runtime \
        --entitlements Entitlements/Continuum-Hardened.entitlements \
        --sign - "$APP"
fi

echo
echo "Built $APP  (deployment target: macOS $DEPLOY, version $VERSION)"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/Continuum")"
if [ "$IDENTITY" = "-" ]; then
    echo "Signed: ad-hoc. Full Disk Access must be re-granted after each rebuild."
    echo "  To grant it ONCE and have it persist (single entry covering the whole"
    echo "  app, including the security engine), run this one-time setup:"
    echo "      ./scripts/make-signing-identity.sh && ./build.sh"
elif [ -n "$DEVID_HASH" ] && [ "$IDENTITY" = "$DEVID_HASH" ]; then
    echo "Signed: Developer ID Application — $DEVELOPER_NAME (timestamped, hardened)."
    echo "  Ready for notarization. For the full release pipeline run:"
    echo "      ./scripts/release.sh   # build → notarize → DMG → notarize"
else
    echo "Signed: $IDENTITY (stable — Full Disk Access granted once persists)."
fi
echo "Run with:  open $APP"
echo "Install:   cp -R $APP /Applications/"

# ---------------------------------------------------------------------------
# Package. A build is not finished until there is an image to hand someone and
# a checksum they can verify it against, so both run here rather than being a
# separate step somebody has to remember. SKIP_DMG=1 opts out for a quick
# compile-only loop.
#
# make-dmg.sh inherits CONTINUUM_VERSION, so it cannot trigger another bump
# through the `./build.sh` call it makes when an app bundle is missing.
# ---------------------------------------------------------------------------
if [ "${SKIP_DMG:-0}" != "1" ]; then
    echo
    ./scripts/make-dmg.sh "$DEPLOY"
    # When one target is built on its own, refresh only that target's line and
    # leave any other current-version entries in the manifest alone. The "all"
    # fan-out writes the complete four-target manifest once, at the end.
    if [ -z "${CONTINUUM_ALL:-}" ]; then
        ./scripts/write-checksums.sh
    fi
fi
