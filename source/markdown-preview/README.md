# Markdown Peek

Press **Space** on any `.md` file in Finder to see it rendered, the same way Quick Look shows
`.txt` or `.json` files. Click **Edit** (or press **⌘E**) in the preview to make quick changes
without leaving Quick Look.

Everything uses Apple frameworks only (AppKit, WebKit, QuickLookUI, Foundation XPC). There are
no third-party dependencies, and the Markdown renderer is written from scratch in Swift.

## Install

```sh
./install.sh      # builds, installs to ~/Applications, registers everything
```

Requirements: macOS 12 or later and the Xcode Command Line Tools. The full Xcode app isn't needed.
To remove everything, run `./uninstall.sh`.

If Space still shows plain text, open **Markdown Peek** and click **Refresh Quick Look**, or check
*System Settings → Privacy & Security → Extensions → Quick Look*.

## Using it

| In the Quick Look panel | |
|---|---|
| **Preview / Edit** toggle, or **⌘E** | Switch between the rendered view and a plain-text editor |
| **Save**, or **⌘S** | Write changes to the file |
| Close the panel | Unsaved edits are saved automatically |
| ⧉ button | Open the file in the Markdown Peek editor window (side-by-side live preview) |

The editor window (also available through *Open With → Markdown Peek*) is a standard macOS document
window. It has autosave, Versions, undo, Find & Replace, and Edit / Split / Preview modes (⌘1 / ⌘2 / ⌘3).
It is registered as an *alternate* handler, so it doesn't replace your default Markdown app.

Supported Markdown: headings, emphasis, strikethrough, links (inline, reference, and auto-linked),
images (relative images are embedded inline), block quotes, nested and task lists, GitHub tables,
fenced and indented code, horizontal rules, inline and block HTML, and YAML front matter. The output
follows the light/dark system appearance.

## How it works

```
Markdown Peek.app
├─ Contents/MacOS/MarkdownPeek           editor app (NSDocument)
├─ Contents/MacOS/MarkdownPeekAgent      on-demand save helper (launchd + XPC)
└─ Contents/PlugIns/MarkdownPeekPreview.appex   Quick Look preview extension
```

macOS requires Quick Look extensions to be sandboxed. It gives them **read-only** access to the
previewed file and blocks them from launching apps. To work within those limits, the extension
sends edits over XPC to `MarkdownPeekAgent`, which is a per-user LaunchAgent
(`~/Library/LaunchAgents/com.thegreatwpy.markdownpeek.agent.plist`). launchd starts the agent
only when it's needed, and it exits after 30 seconds of inactivity. The agent writes only to
existing files with a Markdown extension. Its file writes are coordinated, so an open editor
window picks up the changes.

## Layout

```
Sources/Shared     Markdown → HTML renderer, preview page/CSS, XPC protocol
Sources/Extension  Quick Look view controller (preview + in-panel editor)
Sources/Agent      XPC save agent
Sources/App        editor app, menus, welcome window, agent registration
Resources          Info.plists and entitlements
Scripts            app icon generator
```

`build.sh` produces a universal (arm64 + x86_64) app signed ad-hoc. To sign with a specific
identity, run `SIGN_ID="Your Identity" ./build.sh`.
