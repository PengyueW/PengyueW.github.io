import SwiftUI
import Combine

// Public façade for the Free Space wipe division. Everything else stays
// internal; the shell owns one FreeSpaceController and renders FreeSpaceDetailView.

/// Owns the free-space wipe model for the lifetime of the suite and republishes
/// its changes for shell-level UI (Home page status line, sidebar busy state).
@MainActor
public final class FreeSpaceController: ObservableObject {
    let model = FreeSpaceModel()
    private var forward: AnyCancellable?

    public init() {
        forward = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public var isBusy: Bool { model.isRunning }

    /// Outcome of the most recent run, for the Home page status line.
    public var lastRunSummary: String? {
        if model.isRunning {
            let pct = Int(model.progress.fraction * 100)
            return "Wiping free space… \(pct)%"
        }
        if let err = model.errorMessage { return err }
        if model.resultMessage != nil { return "Free space wiped" }
        return nil
    }
}

/// The full free-space wipe page, wired to the shared controller.
public struct FreeSpaceDetailView: View {
    @ObservedObject private var controller: FreeSpaceController

    public init(controller: FreeSpaceController) {
        self.controller = controller
    }

    public var body: some View {
        FreeSpaceView()
            .environmentObject(controller.model)
    }
}
