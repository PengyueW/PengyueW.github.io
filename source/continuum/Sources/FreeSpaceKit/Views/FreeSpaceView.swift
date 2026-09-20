import SwiftUI

/// Free-space wipe page: pick a volume + algorithm, set the safety reserve, and
/// run. While running it shows a live progress bar with a Cancel button.
struct FreeSpaceView: View {
    @EnvironmentObject private var model: FreeSpaceModel
    @State private var confirmWipe = false

    var body: some View {
        CompatFormPage {
            volumeSection
            methodSection
            safetySection
            if model.isRunning { progressSection } else { runSection }
            explanationSection
        }
        .compatNotice(Text("Free Space Wipe"),
                       isPresented: errorBinding,
                       dismissTitle: Text("OK"),
                       dismiss: { model.errorMessage = nil }) {
            Text(model.errorMessage ?? "")
        }
        .compatConfirm(Text(confirmTitle),
                        isPresented: $confirmWipe,
                        confirmTitle: Text("Wipe Free Space"),
                        isDestructive: true,
                        confirm: { model.start() },
                        cancelTitle: Text("Cancel"),
                        cancel: {  }) {
            Text("This fills the free space on “\(model.selectedVolume?.name ?? "")” with \(model.method.title), then removes the fill files. Your existing files are never touched — only unused space is overwritten. It can take a long time and will make the disk appear full while it runs.")
        }
        .onAppear { model.refreshVolumes() }
    }

    private var confirmTitle: String {
        "Wipe free space on “\(model.selectedVolume?.name ?? "this volume")”?"
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }

    // MARK: - Sections

    private var volumeSection: some View {
        CompatSection("Volume") {
            Picker("Target", selection: Binding(
                get: { model.selectedVolumeID ?? "" },
                set: { model.selectedVolumeID = $0 })) {
                ForEach(model.volumes) { vol in
                    Text(vol.isStartup ? "\(vol.name) (Startup)" : vol.name)
                        .tag(vol.id)
                }
            }
            .disabled(model.isRunning)

            if let vol = model.selectedVolume {
                CompatLabeledContent("Free now") {
                    Text("\(format(vol.freeBytes)) free of \(format(vol.totalBytes))")
                        .compatMonospacedDigit()
                        .foregroundColor(.secondary)
                }
            }
            Button("Rescan Volumes") { model.refreshVolumes() }
                .disabled(model.isRunning)
        }
    }

    private var methodSection: some View {
        CompatSection("Algorithm") {
            Picker("Method", selection: $model.method) {
                ForEach(WipeMethod.allCases) { m in
                    Text(m.title).tag(m)
                }
            }
            .compatMenuPicker()
            .disabled(model.isRunning)
            Text(model.method.detail)
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }

    private var safetySection: some View {
        CompatSection("Safety reserve") {
            Stepper(value: $model.reserveMB, in: 0...20480, step: 256) {
                CompatLabeledContent("Leave free") {
                    Text("\(format(Int64(model.reserveMB) * 1_048_576))")
                        .compatMonospacedDigit()
                }
            }
            .disabled(model.isRunning)
            Text("Free space kept unwritten so the volume never fills completely (which can crash apps or the OS). A small amount of free space is therefore left un-wiped by design.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var runSection: some View {
        Section {
            Button {
                confirmWipe = true
            } label: {
                CompatLabel("Wipe Free Space", systemImage: "eraser.line.dashed")
                    .frame(maxWidth: .infinity)
            }
            .compatBorderedProminent()
            .compatControlSize(.large)
            .disabled(model.selectedVolume == nil)
            if let msg = model.resultMessage {
                CompatLabel(msg, systemImage: "checkmark.seal.fill")
                    .font(.callout)
                    .foregroundColor(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var progressSection: some View {
        CompatSection("In progress") {
            Text(model.progress.phase)
                .font(.callout)
            CompatProgress(value: model.progress.fraction)
            HStack {
                Text("\(format(model.progress.bytesWritten)) written")
                    .font(.caption).compatMonospacedDigit().foregroundColor(.secondary)
                Spacer()
                Text("\(Int(model.progress.fraction * 100))%")
                    .font(.caption).compatMonospacedDigit().foregroundColor(.secondary)
            }
            CompatRoleButton(role: .cancel) {
                model.cancel()
            } label: {
                CompatLabel("Cancel", systemImage: "xmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .compatControlSize(.large)
        }
    }

    private var explanationSection: some View {
        CompatSection("How this works & its limits") {
            Group {
                bullet("Only free space is overwritten. The wipe creates new files in a hidden scratch folder and fills them — the system only ever allocates unused blocks to new files, so your existing data is never read or written.")
                bullet("Corrupted, orphaned or “ghost” data sitting in unallocated blocks is treated as free and overwritten.")
                bullet("On SSDs (TRIM) and APFS, the platform may already have electronically erased free blocks, and wear-levelling means a logical overwrite isn't guaranteed to hit the same physical cells. This is most effective on HDDs and external/USB drives.")
                bullet("APFS snapshots and local Time Machine backups keep old blocks “in use,” so data they reference isn't free space and won't be wiped until those snapshots are removed.")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
