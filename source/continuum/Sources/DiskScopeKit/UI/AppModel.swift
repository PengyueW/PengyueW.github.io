import SwiftUI
import AppKit

/// Central observable state: scan lifecycle, zoom navigation, hover tracking,
/// layout caching, and the Finder / System Settings bridges.
final class AppModel: ObservableObject {
    @Published var rootNode: FileNode?
    @Published var currentNode: FileNode?
    @Published var isScanning = false
    @Published var scanStatus = ""
    @Published var deniedCount = 0
    /// Whether the host app (Continuum) currently holds Full Disk Access.
    /// Refreshed after every scan. When this is `true` but `deniedCount > 0`,
    /// the remaining items are root-owned / mode-restricted files that FDA does
    /// not expose (FDA grants TCC-protected access, not root) — that's normal,
    /// not a missing grant.
    @Published var fdaGranted = AppModel.probeFullDiskAccess()
    @Published var hoveredBlock: LayoutBlock?
    @Published var lastError: String?
    @Published var transition: ZoomTransition?
    @Published var legendEntries: [LegendEntry] = []
    @Published var palette: TreemapPalette {
        didSet {
            guard palette != oldValue else { return }
            UserDefaults.standard.set(palette.rawValue, forKey: "treemapPalette")
            invalidateLayout()
        }
    }

    private var scanner: DiskScanner?
    private var rootScanner: RootScanner?

    /// Set after a privileged "Read All Files" scan so the UI can show that
    /// root-locked items are included (and counted) rather than skipped.
    @Published var lastScanWasPrivileged = false
    /// Number of root-locked (red-outlined) items in the last privileged scan.
    @Published var restrictedCount = 0

    /// Whether the privileged-scan helper is bundled (gates the UI affordance).
    var rootScanAvailable: Bool { RootScanner.helperURL != nil }

    init() {
        let stored = UserDefaults.standard.string(forKey: "treemapPalette")
        palette = stored.flatMap(TreemapPalette.init(rawValue:)) ?? .spectrum
    }

    /// One animated zoom: the canvas morphs between the previous layout and the
    /// new one so the clicked block visually expands to (or shrinks back from)
    /// the full canvas.
    struct ZoomTransition {
        enum Direction { case zoomIn, zoomOut }
        let direction: Direction
        /// Snapshot of the layout being left behind.
        let oldBlocks: [LayoutBlock]
        /// zoomIn: the node being entered (its rect lives in `oldBlocks`).
        /// zoomOut: the node being left (its rect lives in the new layout).
        let focusNode: FileNode
        let start: Date
        let duration: TimeInterval
    }

    /// One legend row: a top-level item's color family and its size.
    struct LegendEntry: Identifiable, Equatable {
        let label: String
        let color: Color
        let bytes: Int64
        var id: String { label }
    }

    // MARK: - Layout cache

    // Derived drawing state, rebuilt only when the zoom level or canvas size
    // changes — never per frame. Not @Published: the canvas reads it while
    // rendering.
    private var cachedBlocks: [LayoutBlock] = []
    private var cacheKey: (node: ObjectIdentifier, size: CGSize)?

    func blocks(for size: CGSize) -> [LayoutBlock] {
        guard let current = currentNode else { return [] }
        let nodeID = ObjectIdentifier(current)
        if let key = cacheKey, key.node == nodeID, key.size == size {
            return cachedBlocks
        }
        cachedBlocks = TreemapLayout.build(node: current, in: CGRect(origin: .zero, size: size),
                                           palette: palette)
        cacheKey = (nodeID, size)
        updateLegend(from: cachedBlocks)
        return cachedBlocks
    }

    /// Each top-level block owns a color family that its whole subdivision
    /// shades, so the legend maps the largest top-level items to their colors.
    /// Runs only on layout rebuild (zoom/resize) and publishes asynchronously
    /// because layout happens during canvas drawing.
    private func updateLegend(from blocks: [LayoutBlock]) {
        // Depth-0 blocks appear in size-descending order (children are sorted).
        let entries = blocks.lazy
            .filter { $0.depth == 0 }
            .prefix(8)
            .map { LegendEntry(label: $0.node.name, color: $0.color, bytes: $0.node.size) }
        let result = Array(entries)
        guard result != legendEntries else { return }
        DispatchQueue.main.async { [weak self] in
            self?.legendEntries = result
        }
    }

    /// Depth-0 blocks are the interactive layer (children of the current node).
    func hitTest(_ point: CGPoint) -> LayoutBlock? {
        for block in cachedBlocks where block.depth == 0 && block.rect.contains(point) {
            return block
        }
        return nil
    }

    private func invalidateLayout() {
        cacheKey = nil
        cachedBlocks = []
    }

    // MARK: - Scanning

    func chooseFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Scan"
        panel.message = "Choose a folder or volume to scan"
        if panel.runModal() == .OK, let url = panel.url {
            scan(path: url.path)
        }
    }

    func scan(path: String) {
        rootScanner?.cancel()
        scanner?.cancel()
        let newScanner = DiskScanner()
        scanner = newScanner

        beginScanState(path: path)

        newScanner.scan(path: path, progress: { [weak self] items, currentPath in
            self?.scanStatus = "Scanned \(items.compatFormatted()) items — \(currentPath)"
        }, completion: { [weak self] result in
            guard let self else { return }
            self.isScanning = false
            self.invalidateLayout()
            switch result {
            case .success(let scan):
                self.rootNode = scan.root
                self.currentNode = scan.root
                self.deniedCount = scan.deniedCount
                self.fdaGranted = AppModel.probeFullDiskAccess()
                self.scanStatus = "\(scan.itemCount.compatFormatted()) items — "
                    + "\(Self.format(bytes: scan.root.size)) "
                    + "in \(String(format: "%.1f", scan.duration))s"
            case .failure(let error):
                if error is DiskScanner.CancelledError {
                    self.scanStatus = "Scan cancelled"
                } else {
                    self.lastError = error.localizedDescription
                    self.scanStatus = ""
                }
            }
        })
    }

    /// Privileged scan: reads EVERY item (including root-owned files the normal
    /// scan can't open) via the bundled helper, after a one-time admin auth
    /// prompt. Root-locked items come back flagged and draw with a red outline.
    func scanAsRoot(path: String) {
        scanner?.cancel()
        rootScanner?.cancel()
        let newScanner = RootScanner()
        rootScanner = newScanner

        beginScanState(path: path)
        scanStatus = "Preparing administrator scan of \(path)…"

        newScanner.scan(path: path, progress: { [weak self] _, status in
            self?.scanStatus = status
        }, completion: { [weak self] result in
            guard let self else { return }
            self.isScanning = false
            self.invalidateLayout()
            switch result {
            case .success(let scan):
                self.rootNode = scan.root
                self.currentNode = scan.root
                self.restrictedCount = scan.deniedCount   // root-locked item count
                self.deniedCount = 0                       // nothing was unreadable
                self.lastScanWasPrivileged = true
                self.fdaGranted = AppModel.probeFullDiskAccess()
                self.scanStatus = "\(scan.itemCount.compatFormatted()) items — "
                    + "\(Self.format(bytes: scan.root.size)) "
                    + "(\(self.restrictedCount.compatFormatted()) root-locked) "
                    + "in \(String(format: "%.1f", scan.duration))s"
            case .failure(let error):
                if error is RootScanner.CancelledError {
                    self.scanStatus = "Scan cancelled"
                } else if error is RootScanner.AuthCancelledError {
                    self.scanStatus = "Administrator scan cancelled"
                } else {
                    self.lastError = error.localizedDescription
                    self.scanStatus = ""
                }
            }
        })
    }

    /// Shared reset applied at the start of either scan kind.
    private func beginScanState(path: String) {
        isScanning = true
        rootNode = nil
        currentNode = nil
        hoveredBlock = nil
        deniedCount = 0
        restrictedCount = 0
        lastScanWasPrivileged = false
        lastError = nil
        transition = nil
        legendEntries = []
        invalidateLayout()
        scanStatus = "Scanning \(path)…"
    }

    /// Re-runs the scan on the same root (the scan root stores the only
    /// absolute path in the tree).
    func rescan() {
        guard let path = rootNode?.path else { return }
        scan(path: path)
    }

    /// Re-runs the current root as a privileged "read all files" scan.
    func rescanAsRoot() {
        guard let path = rootNode?.path else { return }
        scanAsRoot(path: path)
    }

    func cancelScan() {
        scanner?.cancel()
        rootScanner?.cancel()
    }

    // MARK: - Zoom navigation

    func zoomIn(_ node: FileNode) {
        guard node.isDirectory, !node.children.isEmpty, node !== currentNode else { return }
        beginTransition(.zoomIn, focus: node)
        currentNode = node
        hoveredBlock = nil
        invalidateLayout()
    }

    func zoomOut() {
        guard let current = currentNode, let parent = current.parent else { return }
        beginTransition(.zoomOut, focus: current)
        currentNode = parent
        hoveredBlock = nil
        invalidateLayout()
    }

    func jump(to node: FileNode) {
        guard node !== currentNode else { return }
        if let current = currentNode {
            // Jumping to an ancestor animates as a zoom-out, to a descendant as
            // a zoom-in; unrelated jumps switch instantly.
            if current.chainFromRoot.contains(where: { $0 === node }) {
                beginTransition(.zoomOut, focus: current)
            } else if node.chainFromRoot.contains(where: { $0 === current }) {
                beginTransition(.zoomIn, focus: node)
            }
        }
        currentNode = node
        hoveredBlock = nil
        invalidateLayout()
    }

    private func beginTransition(_ direction: ZoomTransition.Direction, focus: FileNode) {
        guard !cachedBlocks.isEmpty else { return }
        let t = ZoomTransition(direction: direction, oldBlocks: cachedBlocks,
                               focusNode: focus, start: Date(), duration: 0.45)
        transition = t
        DispatchQueue.main.asyncAfter(deadline: .now() + t.duration + 0.08) { [weak self] in
            if self?.transition?.start == t.start {
                self?.transition = nil
            }
        }
    }

    var canZoomOut: Bool { currentNode?.parent != nil }

    // MARK: - Finder bridge

    /// Opens a Finder window rooted at the item's parent folder with the item
    /// natively selected/highlighted.
    func revealInFinder(_ node: FileNode) {
        let parentPath = node.parent?.path ?? (node.path as NSString).deletingLastPathComponent
        NSWorkspace.shared.selectFile(node.path, inFileViewerRootedAtPath: parentPath)
    }

    func copyPath(_ node: FileNode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
    }

    // MARK: - Full Disk Access

    /// Deep link straight to System Settings → Privacy & Security → Full Disk
    /// Access. There is no API to request FDA programmatically; guiding the
    /// user here is the Apple-sanctioned flow.
    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Probes whether this process can read a TCC-protected file — the exact
    /// capability Full Disk Access unlocks. This is process-wide: the grant
    /// belongs to the host app (Continuum), so every division shares the same
    /// answer. There is no per-module FDA.
    static func probeFullDiskAccess() -> Bool {
        let probe = NSHomeDirectory()
            + "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(probe, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    // MARK: - Formatting

    static func format(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func percentOfCurrentView(_ node: FileNode) -> String {
        guard let current = currentNode, current.size > 0 else { return "" }
        let pct = Double(node.size) / Double(current.size) * 100
        return String(format: "%.1f%%", pct)
    }
}
