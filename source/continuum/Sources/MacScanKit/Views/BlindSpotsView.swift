import SwiftUI

struct BlindSpotsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedID: String?
    @State private var hashFilter = ""

    private var selected: StateManifest? {
        model.manifests.first { $0.id == selectedID } ?? model.manifests.first
    }

    var body: some View {
        Group {
            if model.manifests.isEmpty {
                EmptyState(
                    symbol: "checklist.unchecked",
                    title: "No State Manifests Yet",
                    message: "A forensic scan writes a cryptographic manifest of security-relevant files plus a ledger of every location it was denied access to. A “clean” result with blind spots is inconclusive, not clean.",
                    actionTitle: "Run Forensic Scan",
                    action: {
                        model.scanState = .idle
                        model.selectedSection = .scan
                    })
            } else if let manifest = selected {
                manifestDetail(manifest)
            }
        }
        .compatNavigationTitle("Blind Spots & Audits")
        .compatToolbar {
            if model.manifests.count > 1 {
                Picker("Manifest", selection: Binding(
                    get: { selected?.id ?? "" },
                    set: { selectedID = $0 })
                ) {
                    ForEach(model.manifests) { m in
                        Text(Format.prettyTimestamp(m.generated)).tag(m.id)
                    }
                }
                .compatMenuPicker()
            }
            Button {
                model.refreshManifests()
            } label: {
                CompatLabel("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .onAppear { model.refreshManifests() }
    }

    // MARK: - One manifest

    private func manifestDetail(_ manifest: StateManifest) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                conclusivenessBanner(manifest)
                metaCard(manifest)
                blindSpotsCard(manifest)
                hashesCard(manifest)
            }
            .padding(20)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
    }

    private func conclusivenessBanner(_ manifest: StateManifest) -> some View {
        let spots = manifest.uniqueBlindSpotPaths.count
        let inconclusive = spots > 0
        return HStack(spacing: 14) {
            CompatIcon(inconclusive ? "eye.trianglebadge.exclamationmark" : "eye")
                .font(.system(size: 34))
                .foregroundColor(inconclusive ? .orange : .green)
            VStack(alignment: .leading, spacing: 3) {
                Text(inconclusive
                     ? "Inconclusive — \(spots) blind spot\(spots == 1 ? "" : "s")"
                     : "Full visibility — no blind spots")
                    .font(Font.compatTitle3.weight(.semibold))
                Text(inconclusive
                     ? "The scan could not inspect every location below. A sophisticated implant hides exactly where a scanner cannot look, so absence of findings there proves nothing."
                     : "Every targeted location was readable during this audit.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
        .compatMaterialBackground(cornerRadius: 12)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder((inconclusive ? Color.orange : .green).opacity(0.35))
        )
    }

    private func metaCard(_ manifest: StateManifest) -> some View {
        Card(title: "Audit Context", systemImage: "info.circle") {
            CompatGrid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                CompatGridRow {
                    meta("Generated", Format.prettyTimestamp(manifest.generated))
                    meta("Host", manifest.host)
                }
                CompatGridRow {
                    meta("macOS", manifest.os)
                    meta("User", manifest.user
                         + (manifest.runningAsRoot ? " (root)" : " (not root)"))
                }
                CompatGridRow {
                    meta("Files hashed", "\(manifest.filesHashed)")
                    meta("Manifest file", manifest.fileName)
                }
            }
            if !manifest.runningAsRoot {
                CompatLabel("This audit ran without root; re-run `sudo ./macscan scan --forensic` to shrink the blind-spot list.",
                      systemImage: "key")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func meta(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.callout)
                .compatTextSelection()
        }
    }

    private func blindSpotsCard(_ manifest: StateManifest) -> some View {
        // Group by reason so "needs Full Disk Access" reads as one actionable block.
        let byReason = Dictionary(grouping: manifest.blindSpots, by: \.reason)
            .map { (reason: $0.key, paths: Array(Set($0.value.map(\.path))).sorted()) }
            .sorted { $0.paths.count > $1.paths.count }

        return Card(title: "Blind Spots — where the scan could not look",
                    systemImage: "eye.slash") {
            if byReason.isEmpty {
                Text("None recorded. Every location the scan targeted was readable.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                ForEach(byReason, id: \.reason) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        CompatLabel(group.reason.isEmpty ? "unspecified" : group.reason,
                              systemImage: "lock")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.orange)
                        ForEach(group.paths, id: \.self) { path in
                            Text(path)
                                .font(.caption.compatMonospaced())
                                .foregroundColor(.secondary)
                                .compatTextSelection()
                                .padding(.leading, 14)
                        }
                    }
                    .padding(.vertical, 3)
                }
                if !model.hasFullDiskAccess {
                    Button("Grant Full Disk Access…") {
                        model.showPermissionsHelp = true
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
        }
    }

    private func hashesCard(_ manifest: StateManifest) -> some View {
        let rows = manifest.hashes
            .filter {
                hashFilter.isEmpty
                || $0.key.localizedCaseInsensitiveContains(hashFilter)
            }
            .sorted { $0.key < $1.key }

        return Card(title: "Cryptographic Manifest — \(manifest.hashes.count) files hashed",
                    systemImage: "number") {
            Text("SHA-256 fingerprints of security-relevant state. Keep the manifest file; diffing a future audit against it reveals tampering.")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("Filter paths…", text: $hashFilter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(rows.prefix(200), id: \.key) { path, digest in
                    HStack(spacing: 8) {
                        Text(path)
                            .font(.caption.compatMonospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(digest.prefix(16)) + "…")
                            .font(.caption.compatMonospaced())
                            .foregroundColor(.secondary)
                            .compatTextSelection()
                    }
                }
                if rows.count > 200 {
                    Text("…and \(rows.count - 200) more — refine the filter.")
                        .font(.caption)
                        .foregroundColor(Color.compatTertiary)
                }
            }
        }
    }
}
