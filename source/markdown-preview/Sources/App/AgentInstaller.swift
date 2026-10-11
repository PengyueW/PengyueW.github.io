import Foundation

/// Registers the on-demand save agent (Contents/MacOS/MarkdownPeekAgent) with launchd as a
/// per-user LaunchAgent. launchd only starts it when the Quick Look extension connects.
enum AgentInstaller {
    private static let label = MarkdownPeekAgent.machServiceName

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var agentPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MarkdownPeekAgent").path
    }

    private static var domain: String { "gui/\(getuid())" }

    /// Re-registers when the agent isn't loaded or points at another copy of the app.
    static func ensureRegistered(force: Bool = false) {
        let desired: NSDictionary = [
            "Label": label,
            "ProgramArguments": [agentPath],
            "MachServices": [label: true],
            "ProcessType": "Interactive",
        ]
        let loaded = WelcomeWindow.status("/bin/launchctl", ["print", "\(domain)/\(label)"]) == 0
        if !force, loaded, NSDictionary(contentsOf: plistURL)?.isEqual(desired) == true { return }

        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try desired.write(to: plistURL)
        } catch {
            NSLog("MarkdownPeek: could not write %@: %@", plistURL.path, error.localizedDescription)
            return
        }
        WelcomeWindow.status("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        WelcomeWindow.status("/bin/launchctl", ["bootstrap", domain, plistURL.path])
    }

    static var isRegistered: Bool {
        WelcomeWindow.status("/bin/launchctl", ["print", "\(domain)/\(label)"]) == 0
    }
}
