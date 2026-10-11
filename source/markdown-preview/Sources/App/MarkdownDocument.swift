import Cocoa

@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument {
    var text = ""
    private var encoding: String.Encoding = .utf8

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        addWindowController(EditorWindowController(document: self))
    }

    override func read(from data: Data, ofType typeName: String) throws {
        (text, encoding) = TextFile.decode(data)
        for case let controller as EditorWindowController in windowControllers {
            controller.documentTextDidReload()
        }
    }

    /// Applies text edited elsewhere (the Quick Look panel) to the open document.
    func replaceText(_ newText: String) {
        text = newText
        for case let controller as EditorWindowController in windowControllers {
            controller.documentTextDidReload()
        }
        updateChangeCount(.changeDone)
    }

    override func data(ofType typeName: String) throws -> Data {
        if let controller = windowControllers.first as? EditorWindowController {
            text = controller.currentText
        }
        return text.data(using: encoding) ?? Data(text.utf8)
    }
}
