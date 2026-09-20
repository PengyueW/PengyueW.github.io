import SwiftUI
import AppKit
import Combine

/// How the whole app presents itself (feature #12).
public enum AppPresentation: String, CaseIterable, Identifiable, Codable {
    case regular      // Dock icon + main window
    case menuBarOnly  // no Dock icon, menu-bar item only

    public var id: String { rawValue }

    public var title: LocalizedStringKey {
        switch self {
        case .regular:     return "Dock & Window"
        case .menuBarOnly: return "Menu Bar Only"
        }
    }

    public var detail: LocalizedStringKey {
        switch self {
        case .regular:     return "Normal app: Dock icon and main window."
        case .menuBarOnly: return "No Dock icon; live monitors in the menu bar."
        }
    }
}

/// Which metrics appear in the menu-bar item.
struct MenuBarConfig: Codable, Equatable {
    var showCPU = true
    var showRAM = true
    var showNetwork = true
}

/// Owns the metrics sampler, the menu-bar status item, and the app
/// presentation mode.
@MainActor
final class StatsModel: ObservableObject {
    @Published var sample = SystemSample()
    @Published var cpuHistory: [Double] = []
    @Published var presentation: AppPresentation = .regular {
        // Only run the AppKit side effects once the app is actually up.
        // Doing so from `init` (when the saved value is loaded) re-enters
        // AppKit while SwiftUI is still constructing this @StateObject inside
        // its scene/AttributeGraph evaluation, which traps (EXC_BREAKPOINT).
        didSet { guard hasStarted else { return }; applyPresentation(); persist() }
    }
    @Published var menuBar = MenuBarConfig() {
        didSet { guard hasStarted else { return }; rebuildMenuBarTitle(); persist() }
    }

    private let sampler = SystemMetricsSampler()
    private var timer: AnyCancellable?
    private var statusItem: NSStatusItem?
    private var hasStarted = false
    private let presentationKey = "StatsKit.presentation"
    private let menuBarKey = "StatsKit.menuBar"

    init() {
        if let raw = UserDefaults.standard.string(forKey: presentationKey),
           let saved = AppPresentation(rawValue: raw) {
            presentation = saved
        }
        if let data = UserDefaults.standard.data(forKey: menuBarKey),
           let saved = try? JSONDecoder().decode(MenuBarConfig.self, from: data) {
            menuBar = saved
        }
    }

    /// Called once at launch from the shell, after the app is up.
    func start() {
        hasStarted = true
        sample = sampler.sample()
        timer = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
        applyPresentation()
    }

    private func tick() {
        let fresh = sampler.sample()
        sample = fresh
        cpuHistory.append(fresh.cpuBusyPercent)
        if cpuHistory.count > 90 { cpuHistory.removeFirst() }
        rebuildMenuBarTitle()
    }

    // MARK: presentation

    /// The shell sets this so "Menu Bar Only"/"Background" can still bring the
    /// window back when the user picks Dock & Window again.
    var showMainWindow: (() -> Void)?

    private func applyPresentation() {
        switch presentation {
        case .regular:
            NSApp.setActivationPolicy(.regular)
            teardownStatusItem()
            NSApp.activate(ignoringOtherApps: true)
            showMainWindow?()
        case .menuBarOnly:
            NSApp.setActivationPolicy(.accessory)
            ensureStatusItem()
            hideMainWindows()
        }
    }

    /// `.accessory` only drops the Dock icon — any open window stays on screen
    /// (just shuffled behind other apps). Order the real windows out so
    /// "Menu Bar Only" actually hides the UI. This is *not* `.prohibited`: the
    /// menu-bar item remains and "Open Continuum" / picking Dock & Window again
    /// reopens the window, so the app is never stranded with no way back.
    private func hideMainWindows() {
        for window in NSApp.windows where window.canBecomeMain {
            window.orderOut(nil)
        }
    }

    // MARK: menu-bar item

    private func ensureStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Continuum", action: #selector(openApp),
                     keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Continuum",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        rebuildMenuBarTitle()
    }

    private func teardownStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func openApp() {
        presentation = .regular
    }

    private func rebuildMenuBarTitle() {
        guard let button = statusItem?.button else { return }
        var parts: [String] = []
        if menuBar.showCPU {
            parts.append(String(format: "C %.0f%%", sample.cpuBusyPercent))
        }
        if menuBar.showRAM {
            parts.append(String(format: "M %.0f%%", sample.memUsedPercent))
        }
        if menuBar.showNetwork {
            parts.append("↓\(Self.rate(sample.netInBytesPerSec)) "
                         + "↑\(Self.rate(sample.netOutBytesPerSec))")
        }
        button.title = parts.isEmpty ? "Continuum" : parts.joined(separator: "  ")
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    }

    static func rate(_ bytesPerSec: Double) -> String {
        let units = ["B", "K", "M", "G"]
        var value = bytesPerSec
        var unit = 0
        while value >= 1024 && unit < units.count - 1 { value /= 1024; unit += 1 }
        return String(format: value >= 100 ? "%.0f%@" : "%.1f%@",
                      value, units[unit]) + "/s"
    }

    private func persist() {
        UserDefaults.standard.set(presentation.rawValue, forKey: presentationKey)
        if let data = try? JSONEncoder().encode(menuBar) {
            UserDefaults.standard.set(data, forKey: menuBarKey)
        }
    }
}
