import Cocoa

/// Programmatic main menu (the app ships without nibs).
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        let appMenu = submenu(in: main, title: appName)
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Quick Look Setup…", action: #selector(AppDelegate.showWelcome(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let services = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(in: main, title: "File")
        file.addItem(withTitle: "New", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        let recent = file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        recent.submenu = NSMenu(title: "Open Recent")
        recent.submenu?.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        file.addItem(withTitle: "Duplicate", action: #selector(NSDocument.duplicate(_:)), keyEquivalent: "S")
        file.addItem(withTitle: "Rename…", action: #selector(NSDocument.rename(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Revert To Saved", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")

        let edit = submenu(in: main, title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        find.submenu = findMenu
        findMenu.addItem(findItem("Find…", .showFindInterface, "f"))
        findMenu.addItem(findItem("Find and Replace…", .showReplaceInterface, "f", [.command, .option]))
        findMenu.addItem(findItem("Find Next", .nextMatch, "g"))
        findMenu.addItem(findItem("Find Previous", .previousMatch, "G"))
        findMenu.addItem(findItem("Use Selection for Find", .setSearchString, "e"))

        let view = submenu(in: main, title: "View")
        view.addItem(withTitle: "Editor Only", action: #selector(EditorWindowController.showEditOnly(_:)), keyEquivalent: "1")
        view.addItem(withTitle: "Editor and Preview", action: #selector(EditorWindowController.showSplit(_:)), keyEquivalent: "2")
        view.addItem(withTitle: "Preview Only", action: #selector(EditorWindowController.showPreviewOnly(_:)), keyEquivalent: "3")
        view.addItem(.separator())
        view.addItem(withTitle: "Show Toolbar", action: #selector(NSWindow.toggleToolbarShown(_:)), keyEquivalent: "")
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        let window = submenu(in: main, title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(in main: NSMenu, title: String) -> NSMenu {
        let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return menu
    }

    private static func findItem(_ title: String, _ action: NSTextFinder.Action, _ key: String,
                                 _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
        item.tag = action.rawValue
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
