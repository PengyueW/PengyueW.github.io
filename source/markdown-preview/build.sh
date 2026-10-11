#!/bin/bash
# Builds "Markdown Peek.app" (host app + Quick Look preview extension) with the
# Command Line Tools only — no Xcode project needed.
#   ./build.sh                 → build/Markdown Peek.app (ad-hoc signed)
#   SIGN_ID="My Identity" ./build.sh   → sign with a specific codesigning identity
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Markdown Peek"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
EXT="$APP/Contents/PlugIns/MarkdownPeekPreview.appex"
SDK="$(xcrun --show-sdk-path)"
MIN_OS="12.0"
SIGN_ID="${SIGN_ID:--}"
ARCHS="${ARCHS:-arm64 x86_64}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS" "$BUILD_DIR/obj"

compile() {  # compile <output> <module> <swiftc flags and sources...> → universal binary
    local output="$1" module="$2"; shift 2
    local slices=()
    for arch in $ARCHS; do
        local slice="$BUILD_DIR/obj/$module-$arch"
        xcrun swiftc -O -whole-module-optimization -sdk "$SDK" -target "$arch-apple-macos$MIN_OS" \
            -module-name "$module" "$@" -o "$slice"
        slices+=("$slice")
    done
    lipo -create "${slices[@]}" -output "$output"
}

echo "▸ Compiling app"
compile "$APP/Contents/MacOS/MarkdownPeek" MarkdownPeek \
    Sources/Shared/*.swift Sources/App/*.swift

echo "▸ Compiling save agent"
compile "$APP/Contents/MacOS/MarkdownPeekAgent" MarkdownPeekAgent \
    Sources/Shared/AgentProtocol.swift Sources/Agent/*.swift

echo "▸ Compiling Quick Look extension"
compile "$EXT/Contents/MacOS/MarkdownPeekPreview" MarkdownPeekPreview \
    -application-extension -parse-as-library -Xlinker -e -Xlinker _NSExtensionMain \
    Sources/Shared/*.swift Sources/Extension/*.swift

echo "▸ Assembling bundle"
cp Resources/App-Info.plist "$APP/Contents/Info.plist"
cp Resources/Extension-Info.plist "$EXT/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

ICONSET="$BUILD_DIR/AppIcon.iconset"
if [ ! -f "$BUILD_DIR/AppIcon.icns" ] || [ Scripts/make-icon.swift -nt "$BUILD_DIR/AppIcon.icns" ]; then
    rm -rf "$ICONSET"
    xcrun swift Scripts/make-icon.swift "$ICONSET" 2>/dev/null
    iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"
fi
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing ($SIGN_ID)"
codesign --force --sign "$SIGN_ID" --entitlements Resources/Extension.entitlements --timestamp=none "$EXT"
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP/Contents/MacOS/MarkdownPeekAgent"
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "✓ Built $APP"
