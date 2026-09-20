import SwiftUI
import Combine

// Public façade for embedding the MacScan security division inside the
// Continuum shell. The Python engine stays authoritative for everything
// state-changing; this file only re-exposes the existing GUI surface.

/// Pages of the security division, mirrored from the standalone app's sidebar.
public enum SecurityPage: String, CaseIterable, Identifiable, Hashable {
    case dashboard, scanner, quarantine, audits

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dashboard:  return "Dashboard"
        case .scanner:    return "Scan Engine"
        case .quarantine: return "Quarantine"
        case .audits:     return "Blind Spots & Audits"
        }
    }

    public var symbol: String {
        switch self {
        case .dashboard:  return "shield.lefthalf.filled"
        // waveform.badge.magnifyingglass needs macOS 14; use the older variant
        case .scanner:    return "waveform.and.magnifyingglass"
        case .quarantine: return "archivebox"
        case .audits:     return "checklist.unchecked"
        }
    }

    init(_ section: SidebarSection) {
        switch section {
        case .dashboard:  self = .dashboard
        case .scan:       self = .scanner
        case .quarantine: self = .quarantine
        case .audits:     self = .audits
        }
    }
}

/// Owns MacScan's AppModel for the lifetime of the suite and republishes its
/// changes for shell-level badges and the Home page.
@MainActor
public final class MacScanController: ObservableObject {
    let model = AppModel()
    private var forward: AnyCancellable?

    public init() {
        forward = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public var attentionCount: Int { model.attentionCount }
    public var quarantineCount: Int { model.quarantineRecords.count }
    public var engineAvailable: Bool { model.cliURL != nil }
    public var hasFullDiskAccess: Bool { model.hasFullDiskAccess }
    public var isScanning: Bool { model.scanState.isRunning }

    /// Last scan verdict, for the Home page status line.
    public var lastScanSummary: String? {
        guard let last = model.lastScan else { return nil }
        let when = last.date.compatRelativeFormatted()
        let issues = model.attentionCount
        let verdict = issues == 0 ? "no issues"
                                  : "\(issues) item\(issues == 1 ? "" : "s") need attention"
        return "Scanned \(when) — \(verdict)"
    }

    public func startStandardScan() { model.startScan(tier: .standard) }

    /// Fires when something inside the division (dashboard shortcuts, the scan
    /// engine itself) asks to show a different page; the shell moves its own
    /// sidebar selection in response. `dropFirst` skips the replayed current
    /// value so subscribing never causes a navigation by itself.
    public var pageRequests: AnyPublisher<SecurityPage, Never> {
        model.$selectedSection
            .dropFirst()
            .compactMap { $0.map(SecurityPage.init) }
            .eraseToAnyPublisher()
    }
}

/// Detail pane for one security page, carrying the division's own error alert
/// and permission/engine sheets so they work wherever the user is.
public struct SecurityDetailView: View {
    @ObservedObject private var controller: MacScanController
    private let page: SecurityPage

    public init(controller: MacScanController, page: SecurityPage) {
        self.controller = controller
        self.page = page
    }

    public var body: some View {
        Group {
            switch page {
            case .dashboard:  DashboardView()
            case .scanner:    ScanView()
            case .quarantine: QuarantineView()
            case .audits:     BlindSpotsView()
            }
        }
        .environmentObject(controller.model)
        .compatNotice(Text("Security"),
                       isPresented: errorBinding,
                       dismissTitle: Text("OK"),
                       dismiss: { controller.model.errorMessage = nil }) {
            Text(controller.model.errorMessage ?? "")
        }
        .sheet(isPresented: permissionsBinding) {
            PermissionsHelpView()
                .environmentObject(controller.model)
        }
        .sheet(isPresented: engineMissingBinding) {
            LocateEngineView()
                .environmentObject(controller.model)
                .compatInteractiveDismissDisabled()
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { controller.model.errorMessage != nil },
                set: { if !$0 { controller.model.errorMessage = nil } })
    }

    private var permissionsBinding: Binding<Bool> {
        Binding(get: { controller.model.showPermissionsHelp },
                set: { controller.model.showPermissionsHelp = $0 })
    }

    private var engineMissingBinding: Binding<Bool> {
        Binding(get: { controller.model.cliURL == nil },
                set: { _ in })
    }
}

/// Shown only if the bundled engine is missing AND discovery failed — lets the
/// user point at a `macscan` checkout manually.
struct LocateEngineView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 14) {
            CompatIcon("questionmark.folder")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.secondary)
            Text("Scan Engine Not Found")
                .font(Font.compatTitle2.weight(.semibold))
            Text("The security division is a front-end for the `macscan` command-line engine. It ships inside the app, but the copy could not be located. Select the `macscan` launcher script manually to continue.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Locate macscan…") { showImporter = true }
                .compatBorderedProminent()
                .compatControlSize(.large)
        }
        .padding(36)
        .frame(width: 520)
        .compatFileImporter(isPresented: $showImporter) { urls in
            if let url = urls.first { model.setCLI(url: url) }
        }
    }
}

/// Engine + permissions settings pane, for the suite's Settings scene.
public struct SecuritySettingsView: View {
    @ObservedObject private var controller: MacScanController
    @State private var showImporter = false
    @State private var showPermissionsHelp = false

    public init(controller: MacScanController) {
        self.controller = controller
    }

    public var body: some View {
        Form {
            CompatSection("Scan Engine") {
                CompatLabeledContent("Launcher") {
                    Text(controller.model.cliURL?.path ?? "not found")
                        .font(.callout.compatMonospaced())
                        .compatTextSelection()
                }
                Button("Change…") { showImporter = true }
            }
            CompatSection("Permissions") {
                CompatLabeledContent("Full Disk Access") {
                    CompatLabel(controller.model.hasFullDiskAccess ? "Granted" : "Not granted",
                          systemImage: controller.model.hasFullDiskAccess
                              ? "checkmark.seal.fill" : "xmark.seal")
                        .foregroundColor(controller.model.hasFullDiskAccess ? .green : .orange)
                }
                Button("How to grant Full Disk Access…") {
                    showPermissionsHelp = true
                }
            }
        }
        .compatGroupedForm()
        .frame(width: 520)
        .sheet(isPresented: $showPermissionsHelp) {
            PermissionsHelpView()
                .environmentObject(controller.model)
        }
        .compatFileImporter(isPresented: $showImporter) { urls in
            if let url = urls.first { controller.model.setCLI(url: url) }
        }
        .onAppear { controller.model.refreshFullDiskAccess() }
    }
}
