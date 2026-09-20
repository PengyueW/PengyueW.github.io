import SwiftUI
import AppKit
import Combine

// Public façade for the Hardware division (thermal & fans, battery,
// power delivery & peripherals).

/// Pages of the hardware division.
public enum HardwarePage: String, CaseIterable, Identifiable, Hashable {
    case thermal, battery, power

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .thermal: return "Thermal & Fans"
        case .battery: return "Battery"
        case .power:   return "Power & Peripherals"
        }
    }

    public var symbol: String {
        switch self {
        case .thermal: return "fanblades"
        case .battery: return "battery.75"
        case .power:   return "powerplug"
        }
    }
}

/// Owns the hardware model for the lifetime of the suite.
@MainActor
public final class HardwareController: ObservableObject {
    let model = HardwareModel()
    private var forward: AnyCancellable?

    private var terminationObserver: NSObjectProtocol?

    public init() {
        forward = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // A custom fan curve must never outlive the app: hand the fans back
        // to the SMC on quit, no matter how the app exits normally.
        // A custom fan curve must never outlive the app: hand the fans back
        // to the SMC on quit. The observer is registered with queue: .main so
        // the block runs on the main thread where the model lives. (Swift 5.8
        // can't statically prove the main-actor hop here, hence the isolation
        // warning; it's behaviourally correct on this toolchain.)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.model.restoreAutomaticFans()
        }
    }

    /// For the Home page status line.
    public var summary: String? {
        guard model.battery.present else { return nil }
        return String(format: "Battery %.0f %% health, %d cycles",
                      model.battery.healthPercent, model.battery.cycleCount)
    }

    /// Returns fans to SMC control; the shell calls this at app termination
    /// so a custom curve never outlives the app.
    public func releaseFanControl() {
        model.restoreAutomaticFans()
    }
}

/// Detail pane for one hardware page, wired to the shared controller.
public struct HardwareDetailView: View {
    @ObservedObject private var controller: HardwareController
    private let page: HardwarePage

    public init(controller: HardwareController, page: HardwarePage) {
        self.controller = controller
        self.page = page
    }

    public var body: some View {
        Group {
            switch page {
            case .thermal: ThermalView()
            case .battery: BatteryView()
            case .power:   PowerView()
            }
        }
        .environmentObject(controller.model)
    }
}
