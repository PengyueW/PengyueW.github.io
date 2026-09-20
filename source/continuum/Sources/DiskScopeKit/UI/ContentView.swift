import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showFDAHelp = false
    @State private var showScanChooser = false

    var body: some View {
        VStack(spacing: 0) {
            if model.rootNode != nil {
                breadcrumbBar
                Divider()
            }
            if model.deniedCount > 0 {
                accessBanner
                Divider()
            } else if model.lastScanWasPrivileged, model.restrictedCount > 0 {
                privilegedBanner
                Divider()
            }
            ZStack {
                // Match the light-gray window background the other divisions use.
                Color.compat(.windowBackgroundColor).compatIgnoresSafeArea()
                if model.isScanning {
                    scanningView
                } else if model.rootNode == nil {
                    emptyState
                } else {
                    TreemapCanvasView(model: model)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.black.opacity(0.25), lineWidth: 1)
                        )
                        .padding(10)
                }
            }
            if model.rootNode != nil, !model.isScanning, !model.legendEntries.isEmpty {
                Divider()
                legendBar
            }
            Divider()
            statusBar
        }
        // No minWidth here: as an embedded division the suite shell owns the
        // window minimums, and a 900pt floor would shove the sidebar
        // off-screen in non-fullscreen windows.
        .frame(minHeight: 480)
        .compatToolbar { toolbarContent }
        .sheet(isPresented: $showFDAHelp) {
            FullDiskAccessHelpView(model: model)
        }
        .sheet(isPresented: $showScanChooser) {
            ScanChooserView(model: model)
        }
        .compatNotice(Text("Scan Failed"),
                       isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        ),
                       dismissTitle: Text("OK"),
                       dismiss: {  }) {
            Text(model.lastError ?? "")
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbarContent: some View {
        // No navigation-placement "Back" button here: the breadcrumb bar
        // already has one, and ⌘↑ (Go ▸ Enclosing Folder) covers the shortcut.
        Group {
            if model.isScanning {
                CompatRoleButton(role: .cancel) {
                    model.cancelScan()
                } label: {
                    CompatLabel("Stop", systemImage: "xmark.circle.fill")
                }
                .compatHelp("Stop the current scan")
            } else {
                Button {
                    showScanChooser = true
                } label: {
                    CompatLabel("New Scan…", systemImage: "plus.magnifyingglass")
                }
                .compatHelp("Rescan, or scan a different folder or volume")
            }
            CompatMenu {
                Picker("Block Colors", selection: $model.palette) {
                    ForEach(TreemapPalette.allCases) { palette in
                        Text(palette.rawValue).tag(palette)
                    }
                }
                .compatInlinePicker()
            } label: {
                CompatLabel("Colors", systemImage: "paintpalette")
            }
            .compatHelp("Change the display colors of the blocks")
            if model.rootScanAvailable, !model.isScanning, model.rootNode != nil {
                Button {
                    model.rescanAsRoot()
                } label: {
                    CompatLabel("Read All Files", systemImage: "lock.open.fill")
                }
                .compatHelp("Re-scan with administrator rights to include every file, even root-locked ones")
            }
            Button {
                showFDAHelp = true
            } label: {
                CompatLabel("Full Disk Access", systemImage: "lock.shield")
            }
            .compatHelp("How to grant Full Disk Access")
        }
    }

    // MARK: - Breadcrumbs

    private var breadcrumbBar: some View {
        HStack(spacing: 10) {
            Button {
                model.zoomOut()
            } label: {
                CompatIcon("chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 18)
            }
            .compatBordered()
            .disabled(!model.canZoomOut)
            .compatHelp("Back to enclosing folder (⌘↑)")

            CompatAutoScroll(trigger: model.currentNode?.id,
                             targetID: model.currentNode?.id) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        let chain = model.currentNode?.chainFromRoot ?? []
                        ForEach(Array(chain.enumerated()), id: \.element.id) { index, node in
                            if index > 0 {
                                CompatIcon("chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Color.secondary.opacity(0.6))
                            }
                            BreadcrumbButton(
                                name: node.name,
                                icon: index == 0 ? "internaldrive.fill" : nil,
                                isCurrent: index == chain.count - 1
                            ) {
                                model.jump(to: node)
                            }
                            .id(node.id)
                        }
                    }
                    .padding(.vertical, 1)
                }

            }

            Spacer(minLength: 8)

            if let current = model.currentNode {
                HStack(spacing: 5) {
                    Text("Total")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text(AppModel.format(bytes: current.size))
                        .font(.system(size: 14, weight: .bold))
                        .compatMonospacedDigit()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .compatBarBackground()
    }

    // MARK: - Legend

    private var legendBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                Text("Colors")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                ForEach(model.legendEntries) { entry in
                    legendItem(color: entry.color, label: entry.label, bytes: entry.bytes)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .compatBarBackground()
    }

    private func legendItem(color: Color, label: String, bytes: Int64?) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5)
                )
            Text(label)
                .font(.system(size: 12, weight: .medium))
            if let bytes {
                Text(AppModel.format(bytes: bytes))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .compatMonospacedDigit()
            }
        }
    }

    // MARK: - Banners / states

    @ViewBuilder
    private var accessBanner: some View {
        if model.fdaGranted {
            // FDA is granted to Continuum, yet a few items still couldn't be
            // read. These are root-owned / mode-restricted files that Full Disk
            // Access does not expose (FDA grants TCC-protected access, not root).
            // This is expected on a whole-disk scan — not a missing grant.
            HStack(spacing: 8) {
                CompatIcon("lock.shield.fill")
                    .foregroundColor(.secondary)
                Text("\(model.deniedCount.compatFormatted()) system-protected items were skipped (owned by root). Continuum has Full Disk Access — these aren't reachable by any app without root, so this is normal.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Spacer()
                if model.rootScanAvailable {
                    Button("Read All Files (Admin)…") { model.rescanAsRoot() }
                        .compatHelp("Re-scan with administrator rights to include every file")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
        } else {
            HStack(spacing: 8) {
                CompatIcon("exclamationmark.shield.fill")
                    .foregroundColor(.orange)
                Text("\(model.deniedCount.compatFormatted()) items could not be read. Grant Continuum Full Disk Access for a complete picture.")
                    .font(.callout)
                Spacer()
                if model.rootScanAvailable {
                    Button("Read All Files (Admin)…") { model.rescanAsRoot() }
                        .compatHelp("Re-scan with administrator rights to include every file")
                }
                Button("Grant Full Disk Access…") {
                    showFDAHelp = true
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
        }
    }

    /// Shown after a privileged scan: every file is included; root-locked items
    /// are flagged with a red outline.
    private var privilegedBanner: some View {
        HStack(spacing: 8) {
            CompatIcon("checkmark.shield.fill")
                .foregroundColor(.green)
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(Color(red: 0.95, green: 0.23, blue: 0.21), lineWidth: 1.5)
                .frame(width: 13, height: 13)
            Text("Showing all files. \(model.restrictedCount.compatFormatted()) root-locked items (red outline) can't be opened or modified without admin rights.")
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
    }

    private var scanningView: some View {
        VStack(spacing: 14) {
            CompatProgress()
                .compatControlSize(.large)
            Text(model.scanStatus)
                .font(.callout)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 600)
            Button("Cancel") { model.cancelScan() }
        }
        .padding(40)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            CompatIcon("internaldrive")
                .font(.system(size: 64, weight: .light))
                .compatGradientForeground(
                    LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.45)],
                                   startPoint: .top, endPoint: .bottom),
                    fallback: .accentColor)
            Text("DiskScope")
                .font(.system(size: 34, weight: .bold))
            Text("Visualize where your disk space went.\nEvery block's area is proportional to its size on disk.")
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                Button {
                    model.chooseFolderAndScan()
                } label: {
                    CompatLabel("Choose Folder…", systemImage: "folder")
                }
                .compatKeyboardShortcut("o")
                Button {
                    model.scan(path: NSHomeDirectory())
                } label: {
                    CompatLabel("Scan Home Folder", systemImage: "house")
                }
                Button {
                    model.scan(path: "/")
                } label: {
                    CompatLabel("Scan Startup Disk", systemImage: "internaldrive.fill")
                }
            }
            .compatControlSize(.large)
            Text("Scanning the startup disk or other users' data requires Full Disk Access.")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("How to grant Full Disk Access…") {
                showFDAHelp = true
            }
            .buttonStyle(.link)
        }
        .padding(40)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let hovered = model.hoveredBlock {
                CompatIcon(hovered.node.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundColor(.secondary)
                Text(hovered.node.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(hovered.node.path)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(AppModel.format(bytes: hovered.node.size))
                    .font(.system(size: 14, weight: .bold))
                    .compatMonospacedDigit()
                Text(model.percentOfCurrentView(hovered.node) + " of this view")
                    .foregroundColor(.secondary)
            } else {
                Text(model.scanStatus.isEmpty ? "Hover a block for details — click a folder to zoom in, double-click to reveal in Finder." : model.scanStatus)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .frame(height: 32)
        .compatBarBackground()
    }
}

// MARK: - Breadcrumb button

/// One crumb: a hover-highlighted, capsule-style button. The current location
/// is emphasized with a tinted background and bold text.
private struct BreadcrumbButton: View {
    let name: String
    let icon: String?
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    CompatIcon(icon)
                        .font(.system(size: 11))
                }
                Text(name)
                    .font(.system(size: 13, weight: isCurrent ? .bold : .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCurrent
                          ? Color.accentColor.opacity(0.18)
                          : hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundColor(isCurrent ? .primary : .accentColor)
        .onHover { hovering = $0 }
        .compatHelp(isCurrent ? "Current folder" : "Go back to \(name)")
    }
}

// MARK: - Scan chooser sheet

/// Modal version of the start page: rescan the current root or pick a new
/// scan target without losing your place until the new scan starts.
struct ScanChooserView: View {
    @ObservedObject var model: AppModel
    // `\.dismiss` is macOS 12; `presentationMode` is the universal spelling.
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        VStack(spacing: 16) {
            CompatIcon("internaldrive")
                .font(.system(size: 44, weight: .light))
                .compatGradientForeground(
                    LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.45)],
                                   startPoint: .top, endPoint: .bottom),
                    fallback: .accentColor)
            Text("Start a New Scan")
                .font(.system(size: 20, weight: .bold))

            VStack(spacing: 8) {
                if let root = model.rootNode {
                    scanButton("Rescan \u{201C}\(root.name)\u{201D}", icon: "arrow.clockwise") {
                        model.rescan()
                    }
                }
                scanButton("Choose Folder…", icon: "folder") {
                    // Let the sheet finish closing before the modal open panel runs.
                    DispatchQueue.main.async { model.chooseFolderAndScan() }
                }
                scanButton("Scan Home Folder", icon: "house") {
                    model.scan(path: NSHomeDirectory())
                }
                scanButton("Scan Startup Disk", icon: "internaldrive.fill") {
                    model.scan(path: "/")
                }
            }
            .compatControlSize(.large)

            Text("Scanning the startup disk or other users' data requires Full Disk Access.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Cancel") { presentationMode.wrappedValue.dismiss() }
                .compatCancelAction()
        }
        .padding(28)
        .frame(width: 380)
    }

    private func scanButton(_ title: LocalizedStringKey, icon: String,
                            action: @escaping () -> Void) -> some View {
        Button {
            presentationMode.wrappedValue.dismiss()
            action()
        } label: {
            CompatLabel(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Full Disk Access help sheet

struct FullDiskAccessHelpView: View {
    let model: AppModel
    // `\.dismiss` is macOS 12; `presentationMode` is the universal spelling.
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CompatLabel("Full Disk Access", systemImage: "lock.shield")
                .font(Font.compatTitle2.weight(.semibold))

            Text("""
            macOS protects system files, other users' data, Mail, Messages, Safari data, \
            and Time Machine metadata behind Full Disk Access. Disk Map runs inside \
            Continuum, so you grant this once to Continuum and every division shares it — \
            there is no separate DiskScope permission. To index protected directories \
            without access errors:
            """)

            VStack(alignment: .leading, spacing: 10) {
                stepRow(1, "Open System Settings → Privacy & Security → Full Disk Access.")
                stepRow(2, "Click the + button (authenticate if asked) and add Continuum, or enable its toggle if it is already listed. (Remove any stale duplicate entries.)")
                stepRow(3, "Quit and relaunch Continuum — access permissions are applied when the app starts.")
            }

            Text("Disk Map only reads file names and sizes. It never opens file contents, writes nothing, and has no network access. Note: a small number of items owned by root may still be skipped even with Full Disk Access — FDA grants access to protected user data, not root privileges, so this is expected.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Button {
                    model.openFullDiskAccessSettings()
                } label: {
                    CompatLabel("Open System Settings", systemImage: "gearshape")
                }
                .compatDefaultAction()
                Spacer()
                Button("Done") { presentationMode.wrappedValue.dismiss() }
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func stepRow(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text)
        }
    }
}
