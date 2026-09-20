import SwiftUI

/// System maintenance actions that need elevated rights. Each one shows the
/// standard macOS admin-password prompt; the app never handles the password.
struct ReindexView: View {
    @EnvironmentObject private var state: AppState
    @State private var confirmSpotlight = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    CompatIcon("arrow.triangle.2.circlepath")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(.accentColor)
                    Text("Rebuild & Reindex")
                        .font(.largeTitle.weight(.semibold))
                    Text("These actions ask for your administrator password via the standard macOS prompt.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                maintenanceCard(
                    title: "Rebuild Spotlight Index",
                    icon: "magnifyingglass.circle",
                    description: "Erases and rebuilds the Spotlight index for the startup disk (mdutil -E /). Fixes stale or bloated indexes. Searches may be incomplete while macOS reindexes in the background — this can take a while on large disks.",
                    buttonTitle: "Rebuild Index…",
                    disabled: state.maintenanceRunning
                ) {
                    confirmSpotlight = true
                }
                .compatConfirm(Text("Rebuild the Spotlight index for the startup disk?"),
                                isPresented: $confirmSpotlight,
                                confirmTitle: Text("Rebuild"),
                                isDestructive: false,
                                confirm: { state.rebuildSpotlight() },
                                cancelTitle: Text("Cancel"),
                                cancel: {  }) {
                    Text("Spotlight search results will be incomplete until reindexing finishes.")
                }

                maintenanceCard(
                    title: "Flush DNS Cache",
                    icon: "network",
                    description: "Clears the Directory Service cache and restarts mDNSResponder's cache (dscacheutil -flushcache; killall -HUP mDNSResponder). Useful after changing DNS servers or when stale lookups cause connection problems.",
                    buttonTitle: "Flush DNS…",
                    disabled: state.maintenanceRunning
                ) {
                    state.flushDNS()
                }

                if !state.maintenanceLog.isEmpty {
                    CompatGroupBox("Activity") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(state.maintenanceLog.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption.compatMonospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(6)
                    }
                }

                if state.maintenanceRunning {
                    CompatProgress().controlSize(.small)
                }
            }
            .padding(28)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Color.compat(.windowBackgroundColor))
    }

    private func maintenanceCard(title: LocalizedStringKey,
                                 icon: String,
                                 description: LocalizedStringKey,
                                 buttonTitle: LocalizedStringKey,
                                 disabled: Bool,
                                 action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            CompatIcon(icon)
                .font(.system(size: 26))
                .foregroundColor(.accentColor)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(description)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(buttonTitle, action: action)
                .disabled(disabled)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.compat(.controlBackgroundColor)))
    }
}
