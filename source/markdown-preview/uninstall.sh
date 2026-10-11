#!/bin/bash
# Removes Markdown Peek, its Quick Look extension and the save agent.
set -uo pipefail
APP="$HOME/Applications/Markdown Peek.app"
LABEL=com.thegreatwpy.markdownpeek.agent
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
pkill -x MarkdownPeek 2>/dev/null
pluginkit -r "$APP/Contents/PlugIns/MarkdownPeekPreview.appex" 2>/dev/null
"$LSREGISTER" -u "$APP" 2>/dev/null
rm -rf "$APP"
qlmanage -r >/dev/null 2>&1
echo "✓ Markdown Peek removed"
