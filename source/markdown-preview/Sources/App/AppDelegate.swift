import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var welcomeWindow: NSWindow?
    private var openedFile = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AgentInstaller.ensureRegistered()
        // Launched to open a file (e.g. from Quick Look or "Open With") → skip the welcome window.
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if isDefaultLaunch && !openedFile { showWelcome(nil) }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome(nil) }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedFile = true
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
        welcomeWindow?.close()
    }

    @objc func showWelcome(_ sender: Any?) {
        if welcomeWindow == nil { welcomeWindow = WelcomeWindow.make() }
        welcomeWindow?.center()
        welcomeWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
