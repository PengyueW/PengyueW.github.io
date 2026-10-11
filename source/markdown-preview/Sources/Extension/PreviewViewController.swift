import Cocoa
import QuickLookUI
import WebKit

/// Quick Look preview for Markdown files, with an in-panel plain-text editor.
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController, NSTextViewDelegate, WKNavigationDelegate {
    private var fileURL: URL?
    private var encoding: String.Encoding = .utf8
    private var savedText = ""
    private var isEditing = false

    private let webView = PreviewPage.makeWebView()
    private let editorScroll = NSTextView.scrollableTextView()
    private var editor: NSTextView { editorScroll.documentView as! NSTextView }
    private let toolbar = NSVisualEffectView()
    private let modeControl = NSSegmentedControl(labels: ["Preview", "Edit"], trackingMode: .selectOne, target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let openButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let root = KeyHandlingView(frame: NSRect(x: 0, y: 0, width: 820, height: 640))
        root.keyHandler = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
        view = root
        preferredContentSize = NSSize(width: 820, height: 640)

        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(webView)

        configureEditor()
        editorScroll.translatesAutoresizingMaskIntoConstraints = false
        editorScroll.isHidden = true
        root.addSubview(editorScroll)

        configureToolbar()
        root.addSubview(toolbar)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            editorScroll.topAnchor.constraint(equalTo: root.topAnchor),
            editorScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            editorScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            editorScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
        ])
    }

    private func configureEditor() {
        let tv = editor
        tv.delegate = self
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textContainerInset = NSSize(width: 28, height: 52)
        tv.textColor = .textColor
        tv.backgroundColor = .textBackgroundColor
        editorScroll.hasVerticalScroller = true
        editorScroll.drawsBackground = true
    }

    private func configureToolbar() {
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 9
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.controlSize = .small
        modeControl.toolTip = "Switch between preview and editing (⌘E)"

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        saveButton.keyEquivalent = ""
        saveButton.isEnabled = false
        saveButton.toolTip = "Save changes (⌘S)"

        openButton.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "Open in Markdown Peek")
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        openButton.target = self
        openButton.action = #selector(openInEditor)
        openButton.toolTip = "Open in the Markdown Peek editor window"

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = true

        let stack = NSStackView(views: [statusLabel, modeControl, saveButton, openButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: toolbar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
        ])
    }

    // MARK: QLPreviewingController

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            let (text, encoding) = try TextFile.read(url)
            fileURL = url
            self.encoding = encoding
            savedText = text
            editor.string = text
            editor.undoManager?.removeAllActions()
            renderPreview()
            updateDirtyState()
            handler(nil)
        } catch {
            handler(error)
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // Edits are kept when the panel closes, like Quick Look markup on images and PDFs.
        if isDirty { writeToDisk() }
    }

    // MARK: Modes

    private var isDirty: Bool { editor.string != savedText }

    @objc private func modeChanged() {
        setEditing(modeControl.selectedSegment == 1)
    }

    private func setEditing(_ editing: Bool) {
        isEditing = editing
        modeControl.selectedSegment = editing ? 1 : 0
        if editing {
            editorScroll.isHidden = false
            webView.isHidden = true
            view.window?.makeFirstResponder(editor)
        } else {
            renderPreview()
            webView.isHidden = false
            editorScroll.isHidden = true
            view.window?.makeFirstResponder(webView)
        }
    }

    private func renderPreview() {
        webView.loadHTMLString(PreviewPage.html(for: editor.string, fileURL: fileURL, topInset: 20), baseURL: nil)
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "s":
            save()
            return true
        case "e":
            setEditing(!isEditing)
            return true
        default:
            return false
        }
    }

    // MARK: Saving

    func textDidChange(_ notification: Notification) {
        updateDirtyState()
    }

    private func updateDirtyState() {
        saveButton.isEnabled = isDirty
        if isDirty { showStatus("Edited", autoHide: false) } else if statusLabel.stringValue == "Edited" { statusLabel.isHidden = true }
    }

    @objc private func save() {
        guard isDirty else { return }
        writeToDisk()
    }

    /// Quick Look only lets the extension read the file, so the text is sent to the
    /// on-demand helper agent, which writes it.
    private func writeToDisk() {
        guard let url = fileURL else { return }
        let text = editor.string
        showStatus("Saving…", autoHide: false)
        let fail: (String) -> Void = { [weak self] message in
            DispatchQueue.main.async {
                NSLog("MarkdownPeek: could not save %@: %@", url.path, message)
                self?.showStatus("Couldn’t save — run install.sh again", autoHide: false)
            }
        }
        let agent = agentConnection().remoteObjectProxyWithErrorHandler { fail($0.localizedDescription) }
        (agent as? MarkdownPeekAgentProtocol)?.save(path: url.path, text: text, encoding: encoding.rawValue) { [weak self] error in
            if let error { fail(error); return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.savedText = text
                self.updateDirtyState()
                self.showStatus("Saved", autoHide: true)
            }
        }
    }

    private var connection: NSXPCConnection?

    private func agentConnection() -> NSXPCConnection {
        if let connection { return connection }
        let c = NSXPCConnection(machServiceName: MarkdownPeekAgent.machServiceName)
        c.remoteObjectInterface = NSXPCInterface(with: MarkdownPeekAgentProtocol.self)
        c.invalidationHandler = { [weak self] in DispatchQueue.main.async { self?.connection = nil } }
        c.resume()
        connection = c
        return c
    }

    private func showStatus(_ text: String, autoHide: Bool) {
        statusLabel.stringValue = text
        statusLabel.isHidden = false
        guard autoHide else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.statusLabel.stringValue == text else { return }
            self.statusLabel.isHidden = true
        }
    }

    @objc private func openInEditor() {
        guard let url = fileURL else { return }
        if isDirty { writeToDisk() }
        (agentConnection().remoteObjectProxy as? MarkdownPeekAgentProtocol)?.openInEditor(path: url.path)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.fragment != nil, url.scheme == "about" || url.absoluteString.hasPrefix("about:blank") {
            decisionHandler(.allow)  // in-page anchor
            return
        }
        decisionHandler(.cancel)
        (agentConnection().remoteObjectProxy as? MarkdownPeekAgentProtocol)?.openLink(url.absoluteString)
    }
}

/// Root view that forwards command-key shortcuts (⌘S, ⌘E) to the controller.
private final class KeyHandlingView: NSView {
    var keyHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
