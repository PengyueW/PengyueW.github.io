import SwiftUI
import Combine

// Public façade for embedding the CacheClean cleaner inside the Continuum
// shell. Everything else in this module stays internal; the shell owns one
// CacheCleanController and renders CleanerDetailView for the selected page.

/// Pages of the cleaner division, mirrored from the standalone app's sidebar.
public enum CleanerPage: String, CaseIterable, Identifiable, Hashable {
    case scan, clean, maintenance, history

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .scan:        return "Scan"
        case .clean:       return "Clean"
        case .maintenance: return "Maintenance"
        case .history:     return "History"
        }
    }

    public var symbol: String {
        switch self {
        case .scan:        return "magnifyingglass"
        case .clean:       return "trash"
        case .maintenance: return "arrow.triangle.2.circlepath"
        case .history:     return "clock"
        }
    }
}

/// Owns the cleaner's AppState for the lifetime of the suite and republishes
/// its changes so shell-level UI (sidebar badges, Home page) stays live.
@MainActor
public final class CacheCleanController: ObservableObject {
    let state = AppState()
    private var forward: AnyCancellable?

    public init() {
        forward = state.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public var pendingItemCount: Int { state.items.count }
    public var historyCount: Int { state.history.entries.count }
    public var reclaimableBytes: Int64 { state.totalFoundBytes }
    public var isBusy: Bool { state.phase == .scanning || state.phase == .cleaning }

    /// Most recent cleaning run, for the Home page status line.
    public var lastRunSummary: String? {
        guard let entry = state.history.entries.first else { return nil }
        let bytes = ByteCountFormatter.string(fromByteCount: entry.bytesReclaimed,
                                              countStyle: .file)
        let when = entry.date.compatRelativeFormatted()
        return "Reclaimed \(bytes) \(when)"
    }

    public func startScan() { state.startScan() }
}

/// Detail pane for one cleaner page, wired to the shared controller.
public struct CleanerDetailView: View {
    @ObservedObject private var controller: CacheCleanController
    private let page: CleanerPage
    private let goToClean: () -> Void

    public init(controller: CacheCleanController,
                page: CleanerPage,
                goToClean: @escaping () -> Void) {
        self.controller = controller
        self.page = page
        self.goToClean = goToClean
    }

    public var body: some View {
        Group {
            switch page {
            case .scan:        ScanView(goToClean: goToClean)
            case .clean:       CleanView()
            case .maintenance: ReindexView()
            case .history:     HistoryView()
            }
        }
        .environmentObject(controller.state)
    }
}
