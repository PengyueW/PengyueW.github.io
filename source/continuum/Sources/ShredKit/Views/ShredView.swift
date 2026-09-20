import SwiftUI

/// Main shredder page: drop zone + queue, algorithm picker, run controls.
struct ShredView: View {
    @EnvironmentObject private var model: ShredderModel
    @State private var showImporter = false
    @State private var confirmShred = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if model.queue.isEmpty && !model.isRunning {
                emptyState
            } else {
                queueList
            }
            Divider()
            controlBar
        }
        .compatNotice(Text("Shredder"),
                       isPresented: errorBinding,
                       dismissTitle: Text("OK"),
                       dismiss: { model.errorMessage = nil }) {
            Text(model.errorMessage ?? "")
        }
        .compatConfirm(Text(confirmTitle),
                        isPresented: $confirmShred,
                        confirmTitle: Text("Shred Permanently"),
                        isDestructive: true,
                        confirm: { model.shredQueued() },
                        cancelTitle: Text("Cancel"),
                        cancel: {  }) {
            Text("The selected items will be overwritten with \(model.algorithm.title) and then deleted. This cannot be undone — not even with recovery software.")
        }
        .compatFileImporter(isPresented: $showImporter,
                            allowsMultipleSelection: true) { urls in
            model.add(urls: urls)
        }
        .compatFileDrop(isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var confirmTitle: String {
        let count = model.queue.count
        return "Permanently destroy \(count) item\(count == 1 ? "" : "s")?"
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }

    // MARK: pieces

    private var emptyState: some View {
        VStack(spacing: 14) {
            CompatIcon("scissors.badge.ellipsis")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(dropTargeted ? Color.accentColor : .secondary)
            Text("Drop files or folders to shred")
                .font(Font.compatTitle3.weight(.semibold))
            Text("Items are overwritten in place, then deleted, so their contents can’t be recovered. On SSDs the free-space copies that APFS snapshots or wear-leveling may keep are outside any app’s reach — FileVault is the real protection there.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Choose Items…") { showImporter = true }
                .compatBordered()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : .clear)
    }

    private var queueList: some View {
        List {
            if !model.results.isEmpty {
                CompatSection("Last run") {
                    ForEach(model.results) { result in
                        HStack {
                            CompatIcon(result.success
                                  ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(result.success ? .green : .red)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((result.path as NSString).lastPathComponent)
                                Text(result.message)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            if !model.queue.isEmpty {
                CompatSection("Queued — \(byteString(model.queuedBytes))") {
                    ForEach(model.queue) { item in
                        HStack {
                            CompatIcon(item.isDirectory ? "folder" : "doc")
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.url.lastPathComponent)
                                Text(item.url.deletingLastPathComponent().path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text(byteString(item.size))
                                .foregroundColor(.secondary)
                                .compatMonospacedDigit()
                            Button {
                                model.remove(item)
                            } label: {
                                CompatIcon("xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isRunning)
                        }
                    }
                }
            }
        }
        .compatInsetList()
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Picker("Algorithm", selection: $model.algorithm) {
                ForEach(ShredAlgorithm.allCases) { algo in
                    Text(algo.title).tag(algo)
                }
            }
            .frame(maxWidth: 320)
            .disabled(model.isRunning)
            .compatHelp(model.algorithm.detail)

            Button("Add…") { showImporter = true }
                .disabled(model.isRunning)

            Spacer()

            if model.isRunning {
                VStack(alignment: .trailing, spacing: 2) {
                    CompatProgress(value: model.progress.fraction)
                        .frame(width: 180)
                    Text("Pass \(model.progress.currentPass)/\(model.progress.totalPasses) — "
                         + (model.progress.currentPath as NSString).lastPathComponent)
                        .font(Font.compatCaption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Button("Stop") { model.cancel() }
            } else {
                CompatRoleButton(role: .destructive) {
                    confirmShred = true
                } label: {
                    CompatLabel("Shred \(model.queue.count) Item\(model.queue.count == 1 ? "" : "s")",
                          systemImage: "scissors")
                }
                .compatBorderedProminent()
                .compatTint(.red)
                .disabled(model.queue.isEmpty)
            }
        }
        .padding(12)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.add(urls: [url]) }
            }
        }
        return !providers.isEmpty
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
