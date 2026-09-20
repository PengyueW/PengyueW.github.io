import Foundation
import SwiftUI

/// All UI-visible state, on the main actor. Bridges the SwiftUI views to the
/// `DiskOptimizer` actor and the privileged task runner.
@MainActor
final class AppState: ObservableObject {

    enum Phase: Equatable {
        case idle
        case scanning
        case scanned
        case cleaning
        case finished
    }

    // MARK: Published state

    @Published var phase: Phase = .idle
    @Published var progress: Double = 0
    @Published var progressLabel: String = ""

    @Published private(set) var items: [ScanItem] = []
    /// IDs of items the user wants to delete. Everything starts selected;
    /// nothing is ever deleted without the explicit Clean button press.
    @Published var selectedIDs: Set<UUID> = []

    @Published var lastReport: CleaningReport?
    @Published var maintenanceLog: [String] = []
    @Published var maintenanceRunning = false

    let history = HistoryStore()
    private let optimizer = DiskOptimizer()
    private var currentTask: Task<Void, Never>?

    // MARK: Derived statistics

    var itemsByCategory: [CleanCategory: [ScanItem]] {
        Dictionary(grouping: items, by: \.category)
    }

    func totalBytes(in category: CleanCategory) -> Int64 {
        itemsByCategory[category]?.reduce(0) { $0 + $1.sizeBytes } ?? 0
    }

    var selectedItems: [ScanItem] { items.filter { selectedIDs.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.sizeBytes } }
    var totalFoundBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }

    // MARK: Scan

    func startScan() {
        guard phase != .scanning && phase != .cleaning else { return }
        phase = .scanning
        progress = 0
        progressLabel = "Preparing…"
        items = []
        selectedIDs = []
        lastReport = nil

        currentTask = Task {
            do {
                let found = try await optimizer.scan { [weak self] p in
                    guard let state = self else { return }
                    Task { @MainActor in
                        withAnimation(.easeOut(duration: 0.25)) { state.progress = p.fraction }
                        state.progressLabel = p.currentPath
                    }
                }
                self.items = found
                self.selectedIDs = Set(found.map(\.id)) // preview defaults to all selected
                self.phase = .scanned
            } catch is CancellationError {
                self.phase = .idle
            } catch {
                self.progressLabel = "Scan failed: \(error.localizedDescription)"
                self.phase = .idle
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
    }

    // MARK: Clean

    func startCleaning() {
        guard phase == .scanned, !selectedItems.isEmpty else { return }
        phase = .cleaning
        progress = 0

        let toClean = selectedItems
        currentTask = Task {
            let report = await optimizer.clean(items: toClean) { [weak self] fraction, name in
                guard let state = self else { return }
                Task { @MainActor in
                    withAnimation(.easeOut(duration: 0.2)) { state.progress = fraction }
                    state.progressLabel = name
                }
            }
            self.lastReport = report
            self.history.add(HistoryEntry(
                date: Date(),
                bytesReclaimed: report.bytesReclaimed,
                itemCount: report.trashedCount + report.removedSymlinkCount,
                skippedCount: report.skipped.count,
                note: "Moved \(report.trashedCount) item(s) to Trash, removed \(report.removedSymlinkCount) broken symlink(s)."
            ))
            // Drop the items that were processed; keep anything left unchecked.
            let cleanedIDs = Set(toClean.map(\.id))
            self.items.removeAll { cleanedIDs.contains($0.id) }
            self.selectedIDs.subtract(cleanedIDs)
            self.phase = .finished
        }
    }

    // MARK: Selection helpers

    func isCategoryFullySelected(_ category: CleanCategory) -> Bool {
        let ids = (itemsByCategory[category] ?? []).map(\.id)
        return !ids.isEmpty && ids.allSatisfy { selectedIDs.contains($0) }
    }

    func setCategory(_ category: CleanCategory, selected: Bool) {
        let ids = (itemsByCategory[category] ?? []).map(\.id)
        if selected { selectedIDs.formUnion(ids) } else { selectedIDs.subtract(ids) }
    }

    // MARK: Maintenance (Reindex tab)

    func rebuildSpotlight() {
        runMaintenance(label: "Rebuild Spotlight index") {
            try await PrivilegedTaskRunner.rebuildSpotlightIndex()
        }
    }

    func flushDNS() {
        runMaintenance(label: "Flush DNS cache") {
            try await PrivilegedTaskRunner.flushDNSCache()
        }
    }

    private func runMaintenance(label: String, _ work: @escaping () async throws -> String) {
        guard !maintenanceRunning else { return }
        maintenanceRunning = true
        maintenanceLog.append("▶ \(label)…")
        Task {
            do {
                let output = try await work()
                maintenanceLog.append("✓ \(label): \(output.isEmpty ? "OK" : output)")
            } catch {
                maintenanceLog.append("✕ \(label): \(error.localizedDescription)")
            }
            maintenanceRunning = false
        }
    }
}
