import SwiftUI

/// Itemized preview: check/uncheck whole categories or individual items, then
/// move the selection to the Trash with one explicit button press.
struct CleanView: View {
    @EnvironmentObject private var state: AppState
    @State private var confirmClean = false

    var body: some View {
        Group {
            switch state.phase {
            case .cleaning:
                cleaningProgress
            case .finished:
                if let report = state.lastReport { reportView(report) }
            default:
                if state.items.isEmpty {
                    emptyView
                } else {
                    itemList
                }
            }
        }
        .background(Color.compat(.windowBackgroundColor))
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            CompatIcon("checkmark.seal")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.green)
            Text("Nothing to clean")
                .font(Font.compatTitle3.weight(.medium))
            Text("Run a scan first, or everything found has already been cleaned.")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var itemList: some View {
        VStack(spacing: 0) {
            List {
                ForEach(CleanCategory.allCases) { category in
                    if let categoryItems = state.itemsByCategory[category], !categoryItems.isEmpty {
                        Section {
                            ForEach(categoryItems) { item in
                                ItemRow(item: item, isSelected: selectionBinding(for: item))
                            }
                        } header: {
                            CategoryHeader(category: category,
                                           count: categoryItems.count,
                                           bytes: state.totalBytes(in: category),
                                           isOn: categoryBinding(for: category))
                        }
                    }
                }
            }
            .compatInsetList()

            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(state.selectedItems.count) of \(state.items.count) items selected")
                    .font(.callout)
                Text("Recoverable from the Trash after cleaning")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(state.selectedBytes.formattedBytes)
                .font(Font.compatTitle3.weight(.semibold).compatMonospacedDigit())
            Button {
                confirmClean = true
            } label: {
                CompatLabel("Move to Trash", systemImage: "trash")
                    .frame(minWidth: 130)
            }
            .compatControlSize(.large)
            .compatBorderedProminent()
            .disabled(state.selectedItems.isEmpty)
            .compatConfirm(Text("Move \(state.selectedItems.count) item(s) (\(state.selectedBytes.formattedBytes)) to the Trash?"),
                            isPresented: $confirmClean,
                            confirmTitle: Text("Move to Trash"),
                            isDestructive: true,
                            confirm: { state.startCleaning() },
                            cancelTitle: Text("Cancel"),
                            cancel: {  }) {
                Text("Items stay in the Trash until you empty it. Broken symlinks are removed directly.")
            }
        }
        .padding(16)
    }

    private var cleaningProgress: some View {
        VStack(spacing: 18) {
            ProgressGauge(progress: state.progress)
                .frame(width: 140, height: 140)
            Text(state.progressLabel)
                .font(.callout.compatMonospaced())
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reportView(_ report: CleaningReport) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                CompatIcon("checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.green)
                Text("Cleaned \(report.bytesReclaimed.formattedBytes)")
                    .font(.title.weight(.semibold))
                Text("\(report.trashedCount) item(s) moved to Trash · \(report.removedSymlinkCount) broken symlink(s) removed")
                    .foregroundColor(.secondary)

                if !report.skipped.isEmpty {
                    CompatGroupBox("Skipped \(report.skipped.count) item(s)") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(report.skipped) { skip in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(skip.path).font(.caption.compatMonospaced())
                                    Text(skip.reason).font(.caption).foregroundColor(.orange)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                    .frame(maxWidth: 560)
                }

                Button("Scan Again") { state.startScan() }
                    .compatBorderedProminent()
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Bindings

    private func selectionBinding(for item: ScanItem) -> Binding<Bool> {
        Binding(
            get: { state.selectedIDs.contains(item.id) },
            set: { on in
                if on { state.selectedIDs.insert(item.id) } else { state.selectedIDs.remove(item.id) }
            }
        )
    }

    private func categoryBinding(for category: CleanCategory) -> Binding<Bool> {
        Binding(
            get: { state.isCategoryFullySelected(category) },
            set: { state.setCategory(category, selected: $0) }
        )
    }
}

private struct CategoryHeader: View {
    let category: CleanCategory
    let count: Int
    let bytes: Int64
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Toggle(isOn: $isOn) {
                CompatLabel(LocalizedStringKey(category.displayName), systemImage: category.systemImage)
                    .font(.headline)
            }
            .toggleStyle(.checkbox)
            .compatHelp(LocalizedStringKey(category.detail))
            Spacer()
            Text("\(count) · \(bytes.formattedBytes)")
                .font(.subheadline.compatMonospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct ItemRow: View {
    let item: ScanItem
    @Binding var isSelected: Bool

    var body: some View {
        HStack {
            Toggle(isOn: $isSelected) {
                HStack(spacing: 8) {
                    CompatIcon(item.isDirectory ? "folder" : "doc")
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.displayName)
                        Text(item.displayPath)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            Text(item.category == .brokenSymlinks ? "—" : item.sizeBytes.formattedBytes)
                .font(.callout.compatMonospacedDigit())
                .foregroundColor(.secondary)
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
    }
}
