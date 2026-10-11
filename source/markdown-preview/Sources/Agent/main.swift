import AppKit

/// On-demand helper started by launchd when the Quick Look extension connects.
/// Writes edited Markdown back to disk and opens files in the editor app; exits when idle.
final class Agent: NSObject, NSXPCListenerDelegate, MarkdownPeekAgentProtocol {
    private var idleTimer: Timer?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: MarkdownPeekAgentProtocol.self)
        connection.exportedObject = self
        connection.resume()
        touch()
        return true
    }

    func save(path: String, text: String, encoding: UInt, reply: @escaping (String?) -> Void) {
        touch()
        guard let url = validatedURL(path) else {
            reply("Not a Markdown file: \(path)")
            return
        }
        let enc = String.Encoding(rawValue: encoding)
        guard let data = text.data(using: enc) ?? text.data(using: .utf8) else {
            reply("Could not encode text")
            return
        }
        var failure: String?
        var coordinationError: NSError?
        // Coordinated so an open editor window (NSDocument) notices and reloads.
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { failure = error.localizedDescription }
        }
        reply(failure ?? coordinationError?.localizedDescription)
    }

    func openInEditor(path: String) {
        touch()
        guard let url = validatedURL(path) else { return }
        // The agent lives at Markdown Peek.app/Contents/MacOS/MarkdownPeekAgent.
        let appURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    func openLink(_ url: String) {
        touch()
        guard let link = URL(string: url), ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(link)
    }

    private func validatedURL(_ path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard MarkdownPeekAgent.markdownExtensions.contains(url.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// launchd restarts the agent on the next connection, so there is no need to linger.
    private func touch() {
        DispatchQueue.main.async {
            self.idleTimer?.invalidate()
            self.idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in exit(0) }
        }
    }

    func start() { touch() }
}

let agent = Agent()
let listener = NSXPCListener(machServiceName: MarkdownPeekAgent.machServiceName)
listener.delegate = agent
listener.resume()
agent.start()
RunLoop.main.run()
