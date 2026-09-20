import SwiftUI
import Combine

// Public façade for the Network Monitor division.

/// Owns the NetGuard model for the lifetime of the suite.
@MainActor
public final class NetGuardController: ObservableObject {
    let model = NetGuardModel()
    private var forward: AnyCancellable?

    public init() {
        forward = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public var isMonitoring: Bool { model.isMonitoring }
    public var alertCount: Int { model.alerts.count }
    public var blockedCount: Int { model.firewall.rules.count }

    /// For the Home page status line.
    public var summary: String? {
        guard model.isMonitoring else { return nil }
        return "\(model.connections.count) outbound connections, "
            + "\(model.firewall.rules.count) blocked"
    }
}

/// The full network-monitor page, wired to the shared controller.
public struct NetGuardDetailView: View {
    @ObservedObject private var controller: NetGuardController

    public init(controller: NetGuardController) {
        self.controller = controller
    }

    public var body: some View {
        NetGuardView()
            .environmentObject(controller.model)
    }
}
