import Cocoa

/// Shown when the app is launched directly: explains how to use the Quick Look preview.
enum WelcomeWindow {
    static let extensionID = "com.thegreatwpy.markdownpeek.preview"

    static func make() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Markdown Peek"
        window.isReleasedWhenClosed = false

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let title = NSTextField(labelWithString: "Markdown Quick Look is ready")
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString: """
        Select any .md file in Finder and press Space to preview it. \
        Click “Edit” (or press ⌘E) in the preview to make quick changes; \
        ⌘S saves, and edits are saved automatically when the preview closes.
        """)
        body.preferredMaxLayoutWidth = 380
        body.alignment = .center

        let status = NSTextField(labelWithString: extensionStatus())
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        let open = NSButton(title: "Open Markdown File…", target: nil, action: #selector(NSDocumentController.openDocument(_:)))
        open.bezelStyle = .rounded
        open.keyEquivalent = "\r"
        let refresh = NSButton(title: "Refresh Quick Look", target: QuickLookRefresher.shared, action: #selector(QuickLookRefresher.refresh(_:)))
        refresh.bezelStyle = .rounded

        let buttons = NSStackView(views: [refresh, open])
        buttons.spacing = 10

        let stack = NSStackView(views: [icon, title, body, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 30, bottom: 22, right: 30)
        stack.setCustomSpacing(20, after: status)
        window.contentView = stack
        return window
    }

    static func extensionStatus() -> String {
        let output = run("/usr/bin/pluginkit", ["-m", "-i", extensionID])
        let preview: String
        if output.hasPrefix("+") { preview = "Preview: enabled" }
        else if output.hasPrefix("-") { preview = "Preview: disabled in System Settings → Extensions → Quick Look" }
        else { preview = "Preview: not registered yet — click Refresh" }
        return preview + (AgentInstaller.isRegistered ? "   ·   Saving: ready" : "   ·   Saving: not set up — click Refresh")
    }

    /// Runs a tool and returns its exit status.
    @discardableResult
    static func status(_ tool: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class QuickLookRefresher: NSObject {
    static let shared = QuickLookRefresher()

    @objc func refresh(_ sender: Any?) {
        let bundle = Bundle.main.bundlePath
        WelcomeWindow.run("/usr/bin/pluginkit", ["-a", bundle + "/Contents/PlugIns/MarkdownPeekPreview.appex"])
        WelcomeWindow.run("/usr/bin/pluginkit", ["-e", "use", "-i", WelcomeWindow.extensionID])
        AgentInstaller.ensureRegistered(force: true)
        WelcomeWindow.run("/usr/bin/qlmanage", ["-r"])
        WelcomeWindow.run("/usr/bin/qlmanage", ["-r", "cache"])
        (sender as? NSButton)?.title = "Refreshed ✓"
    }
}
