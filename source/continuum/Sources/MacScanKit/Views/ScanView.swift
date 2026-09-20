import SwiftUI

struct ScanView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTier: ScanTier = .standard

    var body: some View {
        Group {
            switch model.scanState {
            case .idle:
                tierPicker
            case .running(let tier):
                RunningScanView(tier: tier)
            case .finished(let tier):
                FindingsResultsView(tier: tier)
            }
        }
        .compatNavigationTitle("Scan Engine")
        .compatToolbar {
            if case .finished = model.scanState {
                Button {
                    model.scanState = .idle
                } label: {
                    CompatLabel("New Scan", systemImage: "arrow.counterclockwise")
                }
            }
            if case .running = model.scanState {
                CompatRoleButton(role: .cancel) {
                    model.cancelScan()
                } label: {
                    CompatLabel("Cancel", systemImage: "stop.fill")
                }
            }
                }
    }

    // MARK: - Tier selection

    private var tierPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose a scan tier")
                    .font(Font.compatTitle2.weight(.bold))
                Text("Every tier is read-only. Nothing is changed unless you explicitly quarantine a finding afterwards — and even then, removal is reversible.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                ForEach(ScanTier.allCases) { tier in
                    TierCard(tier: tier, isSelected: tier == selectedTier) {
                        selectedTier = tier
                    }
                }

                if selectedTier == .forensic {
                    forensicAdvisory
                }

                HStack {
                    Spacer()
                    Button {
                        model.startScan(tier: selectedTier)
                    } label: {
                        CompatLabel("Start \(selectedTier.title) Scan",
                              systemImage: "play.fill")
                            .frame(minWidth: 180)
                    }
                    .compatBorderedProminent()
                    .compatControlSize(.large)
                    .disabled(model.cliURL == nil)
                    Spacer()
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    private var forensicAdvisory: some View {
        VStack(alignment: .leading, spacing: 8) {
            CompatLabelView {
                Text("Forensic coverage notes")
                    .font(.subheadline.weight(.semibold))
            } icon: {
                CompatIcon(model.hasFullDiskAccess
                      ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(model.hasFullDiskAccess ? .green : .orange)
            }
            if !model.hasFullDiskAccess {
                Text("Full Disk Access is not granted, so the TCC privacy database and network-usage records will be blind spots — the scan still runs and reports exactly what it could not inspect.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Grant Full Disk Access…") {
                    model.showPermissionsHelp = true
                }
                .controlSize(.small)
            }
            Text("For maximum coverage (EFI check, system-domain databases), run `sudo ./macscan scan --forensic` in Terminal. Findings of this class are never auto-removed: suspected state-sponsored implants are a preserve-and-handoff decision.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .compatColorBackground(Color.compatQuaternary.opacity(0.4), cornerRadius: 8)
    }
}

// MARK: - Tier card

private struct TierCard: View {
    let tier: ScanTier
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 14) {
                CompatIcon(tier.symbol)
                    .font(.title)
                    .frame(width: 40)
                    .foregroundColor(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(tier.title)
                            .font(.headline)
                        Text(tier.duration)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.compatQuaternary.opacity(0.6)))
                    }
                    Text(tier.scope)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    CompatLabel(tier.privileges, systemImage: "key")
                        .font(.caption)
                        .foregroundColor(Color.compatTertiary)
                }
                Spacer()
                CompatIcon(isSelected ? "checkmark.circle.fill" : "circle")
                    .font(Font.compatTitle3)
                    .foregroundColor(isSelected ? Color.accentColor : Color.compat(.quaternaryLabelColor))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .compatMaterialBackground(cornerRadius: 10)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.compat(.separatorColor),
                                  lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Live scan stream

private struct RunningScanView: View {
    @EnvironmentObject private var model: AppModel
    let tier: ScanTier

    var body: some View {
        VStack(spacing: 18) {
            header
                .padding(.top, 30)
            logStream
                .frame(maxWidth: 700)
            CompatRoleButton(role: .cancel) {
                model.cancelScan()
            } label: {
                CompatLabel("Cancel Scan", systemImage: "stop.fill")
            }
            .compatControlSize(.large)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: 8) {
            CompatProgress()
                .compatControlSize(.large)
            Text("\(tier.title) scan in progress…")
                .font(Font.compatTitle3.weight(.semibold))
            if let current = model.progressLines.last(where: { $0.isModule }) {
                Text(current.text)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .animation(.default, value: current.id)
            }
        }
    }

    private var logStream: some View {
        CompatAutoScroll(trigger: model.progressLines,
                         targetID: model.progressLines.last?.id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.progressLines) { line in
                        StreamLine(line: line,
                                   isLatest: line.id == model.progressLines.last?.id)
                            .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .compatColorBackground(Color.black.opacity(0.04), cornerRadius: 10)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.compat(.separatorColor).opacity(0.5))
            )

        }
    }
}

private struct StreamLine: View {
    let line: ProgressLine
    let isLatest: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            CompatIcon(line.isModule ? "circle.dashed" : "info.circle")
                .font(.caption)
                .foregroundColor(line.isModule ? Color.accentColor : Color.secondary)
            Text(line.text)
                .font(.callout.compatMonospaced())
                .foregroundColor(isLatest ? Color.primary : Color.secondary)
        }
    }
}
