import Foundation

/// Quick Look gives the (mandatorily sandboxed) preview extension read-only access to the file
/// and forbids it from launching apps, so saving and "open in editor" go over XPC to a small
/// launchd agent that ships inside the app bundle and runs only on demand.
@objc protocol MarkdownPeekAgentProtocol {
    /// Replies with nil on success, or an error message.
    func save(path: String, text: String, encoding: UInt, reply: @escaping (String?) -> Void)
    func openInEditor(path: String)
    /// Opens a web or mail link from the preview in the default app.
    func openLink(_ url: String)
}

enum MarkdownPeekAgent {
    static let machServiceName = "com.thegreatwpy.markdownpeek.agent"
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "qmd"]
}
