import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case dashboard, scan, quarantine, audits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:  return "Dashboard"
        case .scan:       return "Scan Engine"
        case .quarantine: return "Quarantine"
        case .audits:     return "Blind Spots & Audits"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard:  return "shield.lefthalf.filled"
        case .scan:       return "waveform.and.magnifyingglass"
        case .quarantine: return "archivebox"
        case .audits:     return "checklist.unchecked"
        }
    }
}

enum ScanState: Equatable {
    case idle
    case running(ScanTier)
    case finished(ScanTier)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

struct ProgressLine: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isModule: Bool      // a "  • module" line vs. free-form engine chatter
    var date = Date()
}

@MainActor
final class AppModel: ObservableObject {

    // MARK: Navigation & engine wiring
    @Published var selectedSection: SidebarSection? = .dashboard
    @Published var cliURL: URL?

    // MARK: Scanning
    @Published var scanState: ScanState = .idle
    @Published var progressLines: [ProgressLine] = []
    @Published var findings: [Finding] = []
    @Published var lastScan: ScanRecord?
    @Published var quarantinedFindingIDs: Set<UUID> = []

    // MARK: Quarantine & audits
    @Published var quarantineRecords: [QuarantineRecord] = []
    @Published var manifests: [StateManifest] = []

    // MARK: Permissions / errors
    @Published var hasFullDiskAccess = false
    @Published var showPermissionsHelp = false
    @Published var errorMessage: String?

    private var currentProcess: Process?

    private var engine: MacScanEngine? {
        cliURL.map(MacScanEngine.init)
    }

    init() {
        cliURL = MacScanEngine.discoverCLI()
        hasFullDiskAccess = MacScanEngine.hasFullDiskAccess()
        lastScan = Self.loadLastScan()
        findings = lastScan?.findings ?? []
        if lastScan != nil { scanState = .finished(lastScan!.tier) }
        refreshQuarantine()
        refreshManifests()
    }

    func setCLI(url: URL) {
        guard MacScanEngine.isLauncher(url) else {
            errorMessage = "'\(url.path)' is not the macscan launcher "
                         + "(expected the script with src/macscan beside it)."
            return
        }
        UserDefaults.standard.set(url.path, forKey: MacScanEngine.cliDefaultsKey)
        cliURL = url
    }

    // MARK: - Scan lifecycle

    func startScan(tier: ScanTier) {
        guard !scanState.isRunning else { return }
        guard let engine else {
            errorMessage = EngineError.cliNotFound.errorDescription
            return
        }
        refreshFullDiskAccess()
        scanState = .running(tier)
        progressLines = []
        quarantinedFindingIDs = []
        selectedSection = .scan

        Task {
            do {
                let outcome = try await engine.scan(
                    tier: tier,
                    onLaunch: { [weak self] process in
                        Task { @MainActor in self?.currentProcess = process }
                    },
                    onProgress: { [weak self] line in
                        Task { @MainActor in self?.appendProgress(line) }
                    })
                self.findings = outcome.findings
                let record = ScanRecord(date: Date(), tier: tier,
                                        exitCode: outcome.exitCode,
                                        findings: outcome.findings)
                self.lastScan = record
                Self.saveLastScan(record)
                self.scanState = .finished(tier)
                if tier == .forensic {
                    self.refreshManifests()
                }
            } catch is CancellationError {
                self.scanState = .idle
            } catch {
                // A cancelled Process surfaces as a bad exit code, not a
                // CancellationError — treat user-initiated cancellation quietly.
                if self.currentProcess == nil {
                    self.scanState = .idle
                } else {
                    self.errorMessage = error.localizedDescription
                    self.scanState = .idle
                }
            }
            self.currentProcess = nil
        }
    }

    func cancelScan() {
        currentProcess?.terminate()
        currentProcess = nil
        appendProgress("Scan cancelled.")
        scanState = .idle
    }

    private func appendProgress(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if trimmed.hasPrefix("•") {
            let module = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            progressLines.append(ProgressLine(
                text: "Checking \(module)…", isModule: true))
        } else {
            progressLines.append(ProgressLine(text: trimmed, isModule: false))
        }
    }

    // MARK: - Quarantine actions

    /// Quarantine one or more findings. The caller must already have shown the
    /// confirmation step (mirrors `--remove`'s prompt); the Python bridge
    /// re-validates eligibility regardless.
    func quarantine(_ targets: [Finding]) async {
        guard let engine else {
            errorMessage = EngineError.cliNotFound.errorDescription
            return
        }
        let eligible = targets.filter(\.isQuarantineEligible)
        guard !eligible.isEmpty else { return }
        do {
            let result = try await engine.quarantine(eligible)
            let doneTitles = Set(result.quarantined.map(\.title))
            for f in eligible where doneTitles.contains(f.title) {
                quarantinedFindingIDs.insert(f.id)
            }
            refreshQuarantine()
            if !result.errors.isEmpty {
                errorMessage = "Some items could not be moved (system-level items "
                             + "need sudo via the CLI):\n"
                             + result.errors.joined(separator: "\n")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restore(_ record: QuarantineRecord) async {
        guard let engine else {
            errorMessage = EngineError.cliNotFound.errorDescription
            return
        }
        do {
            let (success, message) = try await engine.restore(id: record.id)
            if !success {
                errorMessage = message.isEmpty
                    ? "Restore of '\(record.id)' failed." : message
            }
            refreshQuarantine()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func purge(_ record: QuarantineRecord) {
        do {
            try MacScanEngine.purgeQuarantined(id: record.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshQuarantine()
    }

    // MARK: - Refresh helpers

    func refreshQuarantine() {
        quarantineRecords = MacScanEngine.loadQuarantine()
    }

    func refreshManifests() {
        manifests = MacScanEngine.loadManifests()
    }

    func refreshFullDiskAccess() {
        hasFullDiskAccess = MacScanEngine.hasFullDiskAccess()
    }

    // MARK: - Posture (derived from system.py findings of the last scan)

    /// system.py only emits a finding when a protection is *off*, so posture is
    /// "enabled" when the last scan ran and the corresponding finding is absent.
    enum PostureStatus {
        case enabled, disabled, unknown
    }

    private func posture(findingTitle: String) -> PostureStatus {
        guard let last = lastScan else { return .unknown }
        return last.findings.contains { $0.title == findingTitle }
            ? .disabled : .enabled
    }

    var sipStatus: PostureStatus {
        posture(findingTitle: "System Integrity Protection is disabled")
    }

    var gatekeeperStatus: PostureStatus {
        posture(findingTitle: "Gatekeeper is disabled")
    }

    var xprotectVersion: String? {
        lastScan?.findings
            .first { $0.title.hasPrefix("Apple XProtect definitions: version ") }?
            .title.replacingOccurrences(
                of: "Apple XProtect definitions: version ", with: "")
    }

    var activeFindings: [Finding] {
        findings.filter { !quarantinedFindingIDs.contains($0.id) }
    }

    var attentionCount: Int {
        activeFindings.filter { $0.severity <= .medium }.count
    }

    // MARK: - Last-scan persistence (~/.macscan/gui/last-scan.json)

    private static var lastScanURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".macscan/gui/last-scan.json")
    }

    private static func loadLastScan() -> ScanRecord? {
        guard let blob = try? Data(contentsOf: lastScanURL),
              let data = SecureStore.open(blob) else { return nil }
        return try? JSONDecoder().decode(ScanRecord.self, from: data)
    }

    private static func saveLastScan(_ record: ScanRecord) {
        let url = lastScanURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Scan records carry the paths of detected threats — encrypt at rest.
        if let data = try? JSONEncoder().encode(record),
           let blob = SecureStore.seal(data) {
            try? blob.write(to: url, options: .atomic)
        }
    }
}
