import SwiftUI
import Combine

// Public façade for the Extensions division.

/// Owns the extensions model for the lifetime of the suite.
@MainActor
public final class ExtensionsController: ObservableObject {
    let model = ExtensionsModel()
    private var forward: AnyCancellable?

    public init() {
        forward = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// For the Home page status line.
    public var summary: String? {
        guard model.totalCount > 0 else { return nil }
        let agents = model.items[.launchAgents]?.count ?? 0
        return "\(model.totalCount) items, \(agents) launch agents/daemons"
    }
}

/// The full extensions dashboard, wired to the shared controller.
public struct ExtensionsDetailView: View {
    @ObservedObject private var controller: ExtensionsController

    public init(controller: ExtensionsController) {
        self.controller = controller
    }

    public var body: some View {
        ExtensionsView()
            .environmentObject(controller.model)
    }
}
