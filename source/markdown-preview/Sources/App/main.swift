import Cocoa

// `MarkdownPeek --register` (used by install.sh) registers the save agent and exits.
if CommandLine.arguments.contains("--register") {
    AgentInstaller.ensureRegistered(force: true)
    exit(AgentInstaller.isRegistered ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
