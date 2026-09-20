import SwiftUI

/// Past cleaning runs and total space reclaimed over time.
struct HistoryView: View {
    @EnvironmentObject private var state: AppState

    private var totalReclaimed: Int64 {
        state.history.entries.reduce(0) { $0 + $1.bytesReclaimed }
    }

    var body: some View {
        Group {
            if state.history.entries.isEmpty {
                VStack(spacing: 10) {
                    CompatIcon("clock")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(.secondary)
                    Text("No cleaning runs yet")
                        .font(Font.compatTitle3.weight(.medium))
                    Text("Your past cleanups and the space they reclaimed will appear here.")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(state.history.entries) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.date.compatFormatted(dateStyle: .medium, timeStyle: .short))
                                        .font(.body)
                                    Text(entry.note)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    if entry.skippedCount > 0 {
                                        Text("\(entry.skippedCount) item(s) skipped")
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    }
                                }
                                Spacer()
                                Text(entry.bytesReclaimed.formattedBytes)
                                    .font(.callout.weight(.semibold).compatMonospacedDigit())
                                    .foregroundColor(.green)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        HStack {
                            Text("Total reclaimed: \(totalReclaimed.formattedBytes)")
                                .font(.headline)
                            Spacer()
                            CompatRoleButton("Clear History", role: .destructive) {
                                state.history.clear()
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .compatInsetList()
            }
        }
        .background(Color.compat(.windowBackgroundColor))
    }
}
