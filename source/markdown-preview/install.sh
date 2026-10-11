#!/bin/bash
# Builds, installs into ~/Applications and registers the Quick Look extension.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

DEST="$HOME/Applications/Markdown Peek.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

mkdir -p "$HOME/Applications"
pkill -x MarkdownPeek 2>/dev/null || true
rm -rf "$DEST"
cp -R "build/Markdown Peek.app" "$DEST"

echo "▸ Registering"
"$LSREGISTER" -u "build/Markdown Peek.app" 2>/dev/null || true   # only the installed copy should handle .md
"$LSREGISTER" -f -R "$DEST"
"$DEST/Contents/MacOS/MarkdownPeek" --register
pluginkit -a "$DEST/Contents/PlugIns/MarkdownPeekPreview.appex"
pluginkit -e use -i com.thegreatwpy.markdownpeek.preview
qlmanage -r >/dev/null 2>&1
qlmanage -r cache >/dev/null 2>&1

echo "✓ Installed to $DEST"
pluginkit -m -v -i com.thegreatwpy.markdownpeek.preview
