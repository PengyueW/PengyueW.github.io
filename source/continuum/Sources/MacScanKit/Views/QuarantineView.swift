import SwiftUI

struct QuarantineView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingPurge: QuarantineRecord?
    @State private var busyID: String?

    var body: some View {
        Group {
            if model.quarantineRecords.isEmpty {
                EmptyState(
                    symbol: "archivebox",
                    title: "Quarantine Is Empty",
                    message: "Items removed by MacScan are moved here — never deleted — so any removal can be undone.")
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(model.quarantineRecords) { record in
                            recordCard(record)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 800)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .compatNavigationTitle("Quarantine")
        .compatToolbar {
            Button {
                model.refreshQuarantine()
            } label: {
                CompatLabel("Refresh", systemImage: "arrow.clockwise")
            }
                }
        .onAppear { model.refreshQuarantine() }
        .compatConfirm(Text("Permanently delete “\(pendingPurge?.title ?? "")”?"),
                        isPresented: Binding(get: { pendingPurge != nil },
                                 set: { if !$0 { pendingPurge = nil } }),
                        confirmTitle: Text("Delete Permanently"),
                        isDestructive: true,
                        confirm: { if let record = pendingPurge {
                    model.purge(record)
                }
                pendingPurge = nil },
                        cancelTitle: Text("Cancel"),
                        cancel: { pendingPurge = nil }) {
            Text("The quarantined files will be erased from disk. This cannot be undone — restoring will no longer be possible.")
        }
    }

    private func recordCard(_ record: QuarantineRecord) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let sev = record.severityValue {
                        SeverityBadge(severity: sev)
                    }
                    Text(record.title)
                        .font(.headline)
                        .compatTextSelection()
                    Spacer()
                    Text(Format.prettyTimestamp(record.time))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                ForEach(record.items, id: \.self) { item in
                    HStack(spacing: 6) {
                        CompatIcon("arrow.uturn.backward.circle")
                            .font(.caption)
                            .foregroundColor(Color.compatTertiary)
                        Text(item.original)
                            .font(.caption.compatMonospaced())
                            .foregroundColor(.secondary)
                            .compatTextSelection()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if !record.launchdLabel.isEmpty {
                    CompatLabel("launchd job: \(record.launchdLabel) (\(record.launchdDomain))",
                          systemImage: "gearshape.2")
                        .font(.caption)
                        .foregroundColor(Color.compatTertiary)
                }

                HStack(spacing: 10) {
                    Button {
                        busyID = record.id
                        Task {
                            await model.restore(record)
                            busyID = nil
                        }
                    } label: {
                        CompatLabel("Restore", systemImage: "arrow.uturn.backward")
                    }
                    .controlSize(.small)
                    .disabled(busyID != nil)

                    CompatRoleButton(role: .destructive) {
                        pendingPurge = record
                    } label: {
                        CompatLabel("Delete Permanently", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .disabled(busyID != nil)

                    if busyID == record.id {
                        CompatProgress()
                            .controlSize(.small)
                    }
                    Spacer()
                    Text(record.id)
                        .font(Font.compatCaption2.compatMonospaced())
                        .foregroundColor(Color.compatTertiary)
                        .compatTextSelection()
                }
                .padding(.top, 2)
            }
        }
    }
}
