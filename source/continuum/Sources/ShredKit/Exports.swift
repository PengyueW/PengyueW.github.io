import SwiftUI
import Combine

// Public façade for the Shredder division. Everything else stays internal;
// the shell owns one ShredController and renders ShredderDetailView.

/// Owns the shredder model for the lifetime of the suite and republishes its
/// changes for shell-level UI (Home page status line).
@MainActor
public final class ShredController: ObservableObject {
    let model = ShredderModel()
    private var forward: AnyCancellable?

    public init() {
        forward = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public var isBusy: Bool { model.isRunning }
    public var queuedCount: Int { model.queue.count }

    /// Outcome of the most recent run, for the Home page status line.
    public var lastRunSummary: String? {
        guard !model.results.isEmpty else { return nil }
        let ok = model.results.filter(\.success).count
        let failed = model.results.count - ok
        var text = "Shredded \(ok) item\(ok == 1 ? "" : "s")"
        if failed > 0 { text += ", \(failed) failed" }
        return text
    }
}

/// The full shredder page, wired to the shared controller.
public struct ShredderDetailView: View {
    @ObservedObject private var controller: ShredController

    public init(controller: ShredController) {
        self.controller = controller
    }

    public var body: some View {
        ShredView()
            .environmentObject(controller.model)
    }
}
