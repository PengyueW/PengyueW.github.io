import SwiftUI

/// Two-pane uninstaller: app picker on the left, discovered leftovers with
/// per-item checkboxes on the right.
struct UninstallerView: View {
    @EnvironmentObject private var model: UninstallerModel
    @State private var search = ""
    @State private var confirmUninstall = false

    var body: some View {
        HSplitView {
            appList
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            detail
                .frame(minWidth: 420, maxWidth: .infinity)
        }
        .onAppear { if model.apps.isEmpty { model.loadApps() } }
        .compatNotice(Text("Uninstaller"),
                       isPresented: errorBinding,
                       dismissTitle: Text("OK"),
                       dismiss: { model.errorMessage = nil }) {
            Text(model.errorMessage ?? "")
        }
    }

    private var filteredApps: [InstalledApp] {
        let visible = model.apps.filter { !$0.isAppleApp }
        guard !search.isEmpty else { return visible }
        return visible.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.bundleID.localizedCaseInsensitiveContains(search)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }

    // MARK: left pane

    private var appList: some View {
        VStack(spacing: 0) {
            TextField("Search apps", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            if model.isLoadingApps {
                Spacer()
                CompatProgress("Reading /Applications…")
                Spacer()
            } else {
                List(filteredApps, selection: appSelection) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                            .resizable()
                            .frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name)
                            Text(app.bundleID)
                                .font(Font.compatCaption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .tag(app)
                }
                .compatInsetList()
            }
        }
    }

    private var appSelection: Binding<InstalledApp?> {
        Binding(get: { model.selectedApp },
                set: { if let app = $0 { model.select(app: app) } })
    }

    // MARK: right pane

    @ViewBuilder
    private var detail: some View {
        if let app = model.selectedApp {
            VStack(spacing: 0) {
                header(app)
                Divider()
                if model.isScanningLeftovers {
                    Spacer()
                    CompatProgress("Locating files for \(app.name)…")
                    Spacer()
                } else {
                    leftoverList
                }
                Divider()
                actionBar(app)
            }
        } else {
            VStack(spacing: 12) {
                CompatIcon("trash.slash")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(.secondary)
                Text("Select an app to see everything it left on disk")
                    .font(Font.compatTitle3.weight(.semibold))
                Text("Continuum locates the bundle plus hidden launch agents, application support folders, preference plists, caches and container data, so nothing stays behind.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ app: InstalledApp) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(Font.compatTitle3.weight(.semibold))
                Text("\(app.bundleID) — v\(app.version)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
        }
        .padding(12)
    }

    private var leftoverList: some View {
        List {
            ForEach(LeftoverKind.allCases, id: \.self) { kind in
                let items = model.leftovers.filter { $0.kind == kind }
                if !items.isEmpty {
                    CompatSection(kind.rawValue) {
                        ForEach(items) { item in
                            row(item)
                        }
                    }
                }
            }
        }
        .compatInsetList()
    }

    private func row(_ item: LeftoverItem) -> some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { item.selected },
                set: { _ in model.toggle(item) }))
                .labelsHidden()
            CompatIcon(item.kind.symbol)
                .foregroundColor(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent)
                Text(item.url.deletingLastPathComponent().path)
                    .font(Font.compatCaption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if item.needsAdmin {
                CompatIcon("lock")
                    .foregroundColor(.orange)
                    .compatHelp("In a system location — removing it asks for an administrator password.")
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                .foregroundColor(.secondary)
                .compatMonospacedDigit()
        }
    }

    private func actionBar(_ app: InstalledApp) -> some View {
        HStack {
            let selected = model.leftovers.filter(\.selected).count
            Text("\(selected) of \(model.leftovers.count) items — "
                 + ByteCountFormatter.string(fromByteCount: model.selectedBytes,
                                             countStyle: .file))
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer()
            Button("Rescan") { model.select(app: app) }
                .disabled(model.isRemoving)
            CompatRoleButton(role: .destructive) {
                confirmUninstall = true
            } label: {
                if model.isRemoving {
                    CompatProgress().controlSize(.small)
                } else {
                    CompatLabel("Uninstall…", systemImage: "trash")
                }
            }
            .compatBorderedProminent()
            .compatTint(.red)
            .disabled(selected == 0 || model.isRemoving)
            .compatConfirm(Text("Uninstall \(app.name)?"),
                            isPresented: $confirmUninstall,
                            confirmTitle: Text("Move to Trash"),
                            isDestructive: true,
                            confirm: { model.uninstallSelected() },
                            cancelTitle: Text("Cancel"),
                            cancel: {  }) {
                Text("The checked items are moved to the Trash (system-domain items are deleted after an administrator prompt). The app is quit first if it’s running.")
            }
        }
        .padding(12)
    }
}
