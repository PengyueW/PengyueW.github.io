import SwiftUI
import Combine

// Public façade for the Monitors division (menu-bar resource monitors +
// app-presentation switch).

/// Owns the stats model for the lifetime of the suite.
@MainActor
public final class StatsController: ObservableObject {
    let model = StatsModel()
    private var forward: AnyCancellable?

    public init() {
        forward = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Called by the shell once the app has launched: starts sampling and
    /// applies the saved presentation mode. `showWindow` lets the model bring
    /// the main window back when the user returns to Dock & Window mode.
    public func start(showWindow: @escaping () -> Void) {
        model.showMainWindow = showWindow
        model.start()
    }

    /// For the Home page status line.
    public var summary: String? {
        String(format: "CPU %.0f%% · RAM %.0f%%",
               model.sample.cpuBusyPercent, model.sample.memUsedPercent)
    }
}

/// The full monitors page, wired to the shared controller.
public struct MonitorsDetailView: View {
    @ObservedObject private var controller: StatsController

    public init(controller: StatsController) {
        self.controller = controller
    }

    public var body: some View {
        MonitorsView()
            .environmentObject(controller.model)
    }
}
