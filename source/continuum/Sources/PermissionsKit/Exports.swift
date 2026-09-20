import SwiftUI
import Combine

// Public façade for the Permissions division.

/// Owns the permissions model for the lifetime of the suite.
@MainActor
public final class PermissionsController: ObservableObject {
    let model = PermissionsModel()
    private var forward: AnyCancellable?

    public init() {
        forward = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// For the Home page status line.
    public var summary: String? {
        guard model.lastRefresh != nil else { return nil }
        return "\(model.allowedCount) active permission grants"
    }
}

/// The full permission-manager page, wired to the shared controller.
public struct PermissionsDetailView: View {
    @ObservedObject private var controller: PermissionsController

    public init(controller: PermissionsController) {
        self.controller = controller
    }

    public var body: some View {
        PermissionsView()
            .environmentObject(controller.model)
    }
}
