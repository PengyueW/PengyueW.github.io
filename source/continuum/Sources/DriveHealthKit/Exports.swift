import SwiftUI
import Combine

// Public façade for the Drive Health division.

/// Owns the drive-health model for the lifetime of the suite.
@MainActor
public final class DriveHealthController: ObservableObject {
    let model = DriveHealthModel()
    private var forward: AnyCancellable?

    public init() {
        forward = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public var hasCriticalWarning: Bool {
        (model.log?.warnings.isEmpty == false)
    }

    /// For the Home page status line.
    public var summary: String? {
        guard let log = model.log else { return nil }
        let tb = Double(log.bytesWritten) / 1_000_000_000_000
        return String(format: "%.1f TB written — %d %% life left",
                      tb, max(0, 100 - log.percentageUsed))
    }

    /// Lets the Home page trigger an early read so the summary fills in.
    public func refresh() { model.refresh() }
}

/// The full drive-health page, wired to the shared controller.
public struct DriveHealthDetailView: View {
    @ObservedObject private var controller: DriveHealthController

    public init(controller: DriveHealthController) {
        self.controller = controller
    }

    public var body: some View {
        DriveHealthView()
            .environmentObject(controller.model)
    }
}
