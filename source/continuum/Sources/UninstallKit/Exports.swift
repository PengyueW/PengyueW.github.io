import SwiftUI
import Combine

// Public façade for the Uninstaller division.

/// Owns the uninstaller model for the lifetime of the suite.
@MainActor
public final class UninstallController: ObservableObject {
    let model = UninstallerModel()
    private var forward: AnyCancellable?

    public init() {
        forward = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public var isBusy: Bool { model.isRemoving || model.isScanningLeftovers }
    public var appCount: Int { model.apps.filter { !$0.isAppleApp }.count }

    /// For the Home page status line.
    public var summary: String? {
        guard !model.apps.isEmpty else { return nil }
        return "\(appCount) third-party apps installed"
    }
}

/// The full uninstaller page, wired to the shared controller.
public struct UninstallerDetailView: View {
    @ObservedObject private var controller: UninstallController

    public init(controller: UninstallController) {
        self.controller = controller
    }

    public var body: some View {
        UninstallerView()
            .environmentObject(controller.model)
    }
}
