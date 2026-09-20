import SwiftUI
import Combine

// Public façade for embedding the DiskScope treemap inside the Continuum shell.

/// Owns the treemap's AppModel for the lifetime of the suite and republishes
/// its changes; also surfaces the actions the shell's menu commands need.
public final class DiskScopeController: ObservableObject {
    let model = AppModel()
    private var forward: AnyCancellable?

    public init() {
        forward = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public var isScanning: Bool { model.isScanning }
    public var hasScan: Bool { model.rootNode != nil }
    public var canZoomOut: Bool { model.canZoomOut }

    /// Root size of the current scan, for the Home page status line.
    public var lastScanSummary: String? {
        guard let root = model.rootNode else { return nil }
        let bytes = ByteCountFormatter.string(fromByteCount: root.size, countStyle: .file)
        return "\(root.name) — \(bytes)"
    }

    public func openFolderAndScan() { model.chooseFolderAndScan() }
    public func scanHomeFolder() { model.scan(path: NSHomeDirectory()) }
    public func zoomOut() { model.zoomOut() }
}

/// The full treemap experience (toolbar, breadcrumbs, canvas, status bar).
public struct DiskMapView: View {
    @ObservedObject private var controller: DiskScopeController

    public init(controller: DiskScopeController) {
        self.controller = controller
    }

    public var body: some View {
        ContentView()
            .environmentObject(controller.model)
    }
}
