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

/// One sidebar entry of the suite: the Home page or a page inside one of the
/// divisions.
enum SuiteSection: Hashable {
    case home
    case cleaner(CleanerPage)
    case diskMap
    case security(SecurityPage)
    case uninstaller
    case extensions
    case permissions
    case shredder
    case netGuard
    case freeSpace
    case driveHealth
    case hardware(HardwarePage)
    case sensors(SensorsPage)
    case monitors
    case donate
}

/// Shell-level state shared between the window and the menu commands.
@MainActor
final class SuiteModel: ObservableObject {
    @Published var selection: SuiteSection? = .home
}

/// The SwiftUI scene-based lifecycle. `App`, `WindowGroup`, `Settings`,
/// `@StateObject` and `@AppStorage` are all macOS 11, so this whole type is
/// gated — macOS 10.15 launches through `LegacyAppMain` instead (see
/// ContinuumMain below).
@available(macOS 11.0, *)
struct ContinuumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // The chosen interface language ("" = follow the system). Driving the
    // environment locale from this re-localizes the whole UI live.
    @AppStorage(languageDefaultsKey) private var languageCode = ""
    @StateObject private var suite = SuiteModel()
    @StateObject private var cleaner = CacheCleanController()
    @StateObject private var diskMap = DiskScopeController()
    @StateObject private var security = MacScanController()
    @StateObject private var shredder = ShredController()
    @StateObject private var freeSpace = FreeSpaceController()
    @StateObject private var uninstaller = UninstallController()
    @StateObject private var driveHealth = DriveHealthController()
    @StateObject private var hardware = HardwareController()
    @StateObject private var permissions = PermissionsController()
    @StateObject private var extensions = ExtensionsController()
    @StateObject private var netGuard = NetGuardController()
    @StateObject private var sensors = SensorsController()
    @StateObject private var stats = StatsController()

    var body: some Scene {
        WindowGroup("Continuum") {
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
                .applyAppLocale(languageCode)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Folder in Disk Map…") {
                    suite.selection = .diskMap
                    diskMap.openFolderAndScan()
                }
                .keyboardShortcut("o")
            }
            CommandMenu("Go") {
                Group {
                    Button("Home") { suite.selection = .home }
                        .keyboardShortcut("1")
                    Button("Cleaner") { suite.selection = .cleaner(.scan) }
                        .keyboardShortcut("2")
                    Button("Disk Map") { suite.selection = .diskMap }
                        .keyboardShortcut("3")
                    Button("Security") { suite.selection = .security(.dashboard) }
                        .keyboardShortcut("4")
                    Button("Menu Bar Monitors") { suite.selection = .monitors }
                        .keyboardShortcut("5")
                }
                Divider()
                Group {
                    Button("Uninstaller") { suite.selection = .uninstaller }
                    Button("Extensions") { suite.selection = .extensions }
                    Button("Permissions") { suite.selection = .permissions }
                    Button("Network Monitor") { suite.selection = .netGuard }
                    Button("Shredder") { suite.selection = .shredder }
                    Button("Free Space Wipe") { suite.selection = .freeSpace }
                    Button("Thermal & Fans") { suite.selection = .hardware(.thermal) }
                    Button("Battery") { suite.selection = .hardware(.battery) }
                    Button("Drive Health") { suite.selection = .driveHealth }
                    Button("Sensors") { suite.selection = .sensors(.sensors) }
                }
                Divider()
                Button("Enclosing Folder") { diskMap.zoomOut() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!diskMap.canZoomOut)
            }
        }

        Settings {
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
            .applyAppLocale(languageCode)
        }
    }
}

extension View {
    /// Applies the user's chosen interface language as the environment locale,
    /// or leaves the system locale in place when "System Default" is selected.
    @ViewBuilder
    func applyAppLocale(_ code: String) -> some View {
        if let locale = AppLanguage.environmentLocale(for: code) {
            environment(\.locale, locale)
        } else {
            self
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed only when launched as a bare executable (no bundle): promote
        // to a regular foreground app so the window appears and gets focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // In Menu Bar Only mode the activation policy is `.accessory` and the
        // window is deliberately ordered out — keep the app alive so it lives
        // on in the menu bar (the status item and "Open Continuum" bring it
        // back). In normal (.regular) mode, closing the last window quits as
        // users expect.
        NSApp.activationPolicy() != .accessory
    }
}
