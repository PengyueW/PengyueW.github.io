import Cocoa
import WebKit

/// Compact editor window: Markdown source on the left, live preview on the right.
final class EditorWindowController: NSWindowController, NSTextViewDelegate, NSToolbarDelegate, WKNavigationDelegate {
    enum Mode: Int { case edit, split, preview }

    private static let frameName = "MarkdownPeekEditor"

    private let splitView = NSSplitView()
    private let editorScroll = NSTextView.scrollableTextView()
    private var editor: NSTextView { editorScroll.documentView as! NSTextView }
    private let webView = PreviewPage.makeWebView()
    private let modeControl = NSSegmentedControl()
    private var pageLoaded = false
    private var pendingRender: DispatchWorkItem?

    private var markdownDocument: MarkdownDocument? { document as? MarkdownDocument }
    var currentText: String { editor.string }

    init(document: MarkdownDocument) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 480, height: 320)
        window.toolbarStyle = .unifiedCompact
        window.tabbingMode = .preferred
        super.init(window: window)
        buildContent()
        buildToolbar()
        shouldCascadeWindows = false
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        window.setFrameAutosaveName(Self.frameName)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var document: AnyObject? {
        didSet { documentTextDidReload() }
    }

    private func buildContent() {
        let tv = editor
        tv.delegate = self
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textContainerInset = NSSize(width: 18, height: 16)

        webView.navigationDelegate = self

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = "MarkdownPeekSplit"
        splitView.addArrangedSubview(editorScroll)
        splitView.addArrangedSubview(webView)
        window?.contentView = splitView
    }

    private func buildToolbar() {
        modeControl.segmentCount = 3
        let symbols = ["doc.plaintext", "rectangle.split.2x1", "eye"]
        let labels = ["Edit", "Split", "Preview"]
        for (i, name) in symbols.enumerated() {
            modeControl.setImage(NSImage(systemSymbolName: name, accessibilityDescription: labels[i]), forSegment: i)
            modeControl.setToolTip("\(labels[i]) (⌘\(i + 1))", forSegment: i)
            modeControl.setWidth(34, forSegment: i)
        }
        modeControl.trackingMode = .selectOne
        modeControl.selectedSegment = Mode.split.rawValue
        modeControl.target = self
        modeControl.action = #selector(modeControlChanged)

        let toolbar = NSToolbar(identifier: "MarkdownPeekToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
    }

    // MARK: Document sync

    func documentTextDidReload() {
        guard let doc = markdownDocument, isWindowLoaded || window != nil else { return }
        if editor.string != doc.text {
            editor.string = doc.text
        }
        renderNow(fullReload: true)
    }

    func textDidChange(_ notification: Notification) {
        markdownDocument?.text = editor.string
        scheduleRender()
    }

    // MARK: Rendering

    private func scheduleRender() {
        pendingRender?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.renderNow(fullReload: false) }
        pendingRender = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func renderNow(fullReload: Bool) {
        guard currentMode != .edit || fullReload else { return }
        let url = markdownDocument?.fileURL
        if fullReload || !pageLoaded {
            pageLoaded = false
            webView.loadHTMLString(PreviewPage.html(for: editor.string, fileURL: url), baseURL: nil)
        } else {
            webView.evaluateJavaScript(PreviewPage.replaceBodyScript(PreviewPage.bodyHTML(for: editor.string, fileURL: url)))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
              !url.absoluteString.hasPrefix("about:") else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        NSWorkspace.shared.open(url)
    }

    // MARK: Modes

    private var currentMode: Mode { Mode(rawValue: modeControl.selectedSegment) ?? .split }

    @objc private func modeControlChanged() {
        apply(mode: currentMode)
    }

    @objc func showEditOnly(_ sender: Any?) { set(mode: .edit) }
    @objc func showSplit(_ sender: Any?) { set(mode: .split) }
    @objc func showPreviewOnly(_ sender: Any?) { set(mode: .preview) }

    private func set(mode: Mode) {
        modeControl.selectedSegment = mode.rawValue
        apply(mode: mode)
    }

    private func apply(mode: Mode) {
        editorScroll.isHidden = mode == .preview
        webView.isHidden = mode == .edit
        splitView.adjustSubviews()
        if mode != .edit { renderNow(fullReload: !pageLoaded) }
        window?.makeFirstResponder(mode == .preview ? webView : editor)
    }

    // MARK: NSToolbarDelegate

    private static let modeItem = NSToolbarItem.Identifier("mode")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.modeItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .space, Self.modeItem]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.modeItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "View"
        item.view = modeControl
        return item
    }
}
