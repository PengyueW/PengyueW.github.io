import SwiftUI
import Combine

// Public façade for the Sensors division (live sensors + automations).

/// Pages of the sensors division.
public enum SensorsPage: String, CaseIterable, Identifiable, Hashable {
    case sensors, automations

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sensors:     return "Sensors"
        case .automations: return "Automations"
        }
    }

    public var symbol: String {
        switch self {
        case .sensors:     return "sensor"
        case .automations: return "wand.and.stars"
        }
    }
}

/// Owns the sensors model for the lifetime of the suite. Automations keep
/// running even when no sensors page is on screen.
@MainActor
public final class SensorsController: ObservableObject {
    let model = SensorsModel()
    private var forward: AnyCancellable?

    public init() {
        forward = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public var enabledAutomationCount: Int {
        model.automations.filter { $0.enabled }.count
    }

    /// For the Home page status line.
    public var summary: String? {
        guard !model.automations.isEmpty else { return nil }
        return "\(model.automations.count) automations, "
            + "\(model.events.count) runs logged"
    }
}

/// Detail pane for one sensors page, wired to the shared controller.
public struct SensorsDetailView: View {
    @ObservedObject private var controller: SensorsController
    private let page: SensorsPage

    public init(controller: SensorsController, page: SensorsPage) {
        self.controller = controller
        self.page = page
    }

    public var body: some View {
        Group {
            switch page {
            case .sensors:     SensorsView()
            case .automations: AutomationsView()
            }
        }
        .environmentObject(controller.model)
    }
}
