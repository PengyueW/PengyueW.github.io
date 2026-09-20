import SwiftUI
import AppKit
import CacheCleanKit
import DiskScopeKit
import MacScanKit
import ShredKit
import FreeSpaceKit
import UninstallKit
import DriveHealthKit
import HardwareKit
import PermissionsKit
import ExtensionsKit
import NetGuardKit
import SensorsKit
import StatsKit

/// The process entry point.
///
/// SwiftUI's `App`/`Scene` lifecycle is macOS 11+, so the executable cannot
/// simply be an `@main struct … : App` when the deployment target is 10.15.
/// Instead this enum owns `main()` and picks a lifecycle at runtime: the
/// SwiftUI scene lifecycle wherever it exists, and a hand-built AppKit host
/// (NSWindow + NSHostingView + a programmatic menu bar) on Catalina.
///
/// Every build ships both paths, so the 10.15 binary running on a modern Mac
/// takes the *same* SwiftUI path the macOS 13 build does.
@main
enum ContinuumMain {
    @MainActor
    static func main() {
        if #available(macOS 11.0, *) {
            ContinuumApp.main()
        } else {
            LegacyAppMain.run()
        }
    }
}

// MARK: - AppKit lifecycle (macOS 10.15)

/// Owns the division controllers for the AppKit path. Under the SwiftUI
/// lifecycle these live in `@StateObject`s; here they need an explicit owner
/// with the same process lifetime.
@MainActor
final class LegacyControllers {
    private static var stored: LegacyControllers?
    /// MainActor-isolated so it may build the MainActor-bound controllers.
    static var shared: LegacyControllers {
        if let stored { return stored }
        let made = LegacyControllers()
        stored = made
        return made
    }

    let suite = SuiteModel()
    let cleaner = CacheCleanController()
    let diskMap = DiskScopeController()
    let security = MacScanController()
    let shredder = ShredController()
    let freeSpace = FreeSpaceController()
    let uninstaller = UninstallController()
    let driveHealth = DriveHealthController()
    let hardware = HardwareController()
    let permissions = PermissionsController()
    let extensions = ExtensionsController()
    let netGuard = NetGuardController()
    let sensors = SensorsController()
    let stats = StatsController()

    @ViewBuilder
    func rootView() -> some View {
        RootView(suite: suite,
                 cleaner: cleaner,
                 diskMap: diskMap,
                 security: security,
                 shredder: shredder,
                 freeSpace: freeSpace,
                 uninstaller: uninstaller,
                 driveHealth: driveHealth,
                 hardware: hardware,
                 permissions: permissions,
                 extensions: extensions,
                 netGuard: netGuard,
                 sensors: sensors,
                 stats: stats)
            .frame(minWidth: 1040, minHeight: 660)
            .applyAppLocale(UserDefaults.standard.string(forKey: languageDefaultsKey) ?? "")
    }
}

enum LegacyAppMain {
    /// Called from `ContinuumMain.main()`, which is already MainActor-isolated.
    @MainActor
    static func run() {
        let app = NSApplication.shared
        let delegate = LegacyAppDelegate()
        app.delegate = delegate
        // The delegate must outlive this call; NSApplication holds it weakly.
        legacyDelegate = delegate
        app.run()
    }
}

/// Strong reference for the delegate assigned in `LegacyAppMain.run()`.
private var legacyDelegate: AnyObject?

@MainActor
final class LegacyAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenuBar()
        showMainWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Mirrors the SwiftUI path: in Menu Bar Only mode the policy is
        // `.accessory` and the app deliberately lives on without a window.
        NSApp.activationPolicy() != .accessory
    }

    // MARK: Windows

    private func showMainWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingView(rootView: LegacyControllers.shared.rootView())
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Continuum"
        w.contentView = hosting
        w.center()
        w.setFrameAutosaveName("ContinuumMain")
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    @objc func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let view = LegacySettingsView(security: LegacyControllers.shared.security)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Continuum Settings"
        w.contentView = NSHostingView(rootView: view)
        w.center()
        w.makeKeyAndOrderFront(nil)
        settingsWindow = w
    }

    // MARK: Menu bar
    //
    // The SwiftUI path builds these from `.commands { … }`, which is macOS 11.
    // Here the same items are assembled as a plain NSMenu tree with matching
    // titles and key equivalents.

    private func buildMenuBar() {
        let mainMenu = NSMenu()

        // Application menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Continuum",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Continuum",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Continuum",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // File menu — the "Scan Folder in Disk Map…" command.
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let scan = NSMenuItem(title: "Scan Folder in Disk Map…",
                              action: #selector(scanFolder), keyEquivalent: "o")
        scan.target = self
        fileMenu.addItem(scan)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Edit menu — needed for copy/paste in text fields.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Go menu — the division shortcuts.
        let goItem = NSMenuItem()
        let goMenu = NSMenu(title: "Go")
        for (title, key, section) in Self.primaryDestinations {
            let item = NSMenuItem(title: title, action: #selector(goTo(_:)), keyEquivalent: key)
            item.target = self
            item.representedObject = SectionBox(section)
            goMenu.addItem(item)
        }
        goMenu.addItem(.separator())
        for (title, section) in Self.secondaryDestinations {
            let item = NSMenuItem(title: title, action: #selector(goTo(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = SectionBox(section)
            goMenu.addItem(item)
        }
        goMenu.addItem(.separator())
        let up = NSMenuItem(title: "Enclosing Folder",
                            action: #selector(zoomOut), keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        up.keyEquivalentModifierMask = [.command]
        up.target = self
        goMenu.addItem(up)
        goItem.submenu = goMenu
        mainMenu.addItem(goItem)

        // Window menu
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    /// NSMenuItem.representedObject needs a class type.
    private final class SectionBox: NSObject {
        let section: SuiteSection
        init(_ section: SuiteSection) { self.section = section }
    }

    private static let primaryDestinations: [(String, String, SuiteSection)] = [
        ("Home", "1", .home),
        ("Cleaner", "2", .cleaner(.scan)),
        ("Disk Map", "3", .diskMap),
        ("Security", "4", .security(.dashboard)),
        ("Menu Bar Monitors", "5", .monitors),
    ]

    private static let secondaryDestinations: [(String, SuiteSection)] = [
        ("Uninstaller", .uninstaller),
        ("Extensions", .extensions),
        ("Permissions", .permissions),
        ("Network Monitor", .netGuard),
        ("Shredder", .shredder),
        ("Free Space Wipe", .freeSpace),
        ("Thermal & Fans", .hardware(.thermal)),
        ("Battery", .hardware(.battery)),
        ("Drive Health", .driveHealth),
        ("Sensors", .sensors(.sensors)),
    ]

    // MARK: Actions

    @objc private func goTo(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? SectionBox else { return }
        showMainWindow()
        LegacyControllers.shared.suite.selection = box.section
    }

    @objc private func scanFolder() {
        showMainWindow()
        LegacyControllers.shared.suite.selection = .diskMap
        LegacyControllers.shared.diskMap.openFolderAndScan()
    }

    @objc private func zoomOut() {
        LegacyControllers.shared.diskMap.zoomOut()
    }
}

/// The Settings scene's contents, hosted in a plain window on 10.15.
private struct LegacySettingsView: View {
    let security: MacScanController

    var body: some View {
        TabView {
            SuiteSettingsView()
                .tabItem { CompatLabel("Full Disk Access", systemImage: "lock.shield") }
            LanguageSettingsView()
                .tabItem { CompatLabel("Language", systemImage: "globe") }
            SecuritySettingsView(controller: security)
                .tabItem { CompatLabel("Security Engine", systemImage: "shield.lefthalf.filled") }
            IntegrityView()
                .tabItem { CompatLabel("Integrity", systemImage: "checkmark.seal") }
        }
        .frame(width: 560)
        .applyAppLocale(UserDefaults.standard.string(forKey: languageDefaultsKey) ?? "")
    }
}
