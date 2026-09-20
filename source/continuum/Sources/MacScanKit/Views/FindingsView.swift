import SwiftUI

// MARK: - Results screen (after a scan completes)

struct FindingsResultsView: View {
    @EnvironmentObject private var model: AppModel
    let tier: ScanTier

    @State private var expanded: Set<Severity> = [.critical, .high, .medium]
    @State private var confirmationTargets: [Finding]?

    private var grouped: [(severity: Severity, findings: [Finding])] {
        let dict = Dictionary(grouping: model.activeFindings, by: \.severity)
        return Severity.allCases.compactMap { sev in
            guard let group = dict[sev], !group.isEmpty else { return nil }
            return (sev, group.sorted { ($0.category, $0.title) < ($1.category, $1.title) })
        }
    }

    private var eligibleFindings: [Finding] {
        model.activeFindings.filter(\.isQuarantineEligible)
    }

    var body: some View {
        Group {
            if model.activeFindings.isEmpty {
                EmptyState(
                    symbol: "checkmark.shield",
                    title: "No Findings",
                    message: model.quarantinedFindingIDs.isEmpty
                        ? "Nothing suspicious was detected by the \(tier.title.lowercased()) scan."
                        : "All actionable findings from this scan have been quarantined.",
                    actionTitle: "Run Another Scan",
                    action: { model.scanState = .idle })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        summaryHeader
                        ForEach(grouped, id: \.severity) { group in
                            severitySection(group.severity, group.findings)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(item: sheetBinding) { box in
            QuarantineConfirmationView(targets: box.findings) { confirmed in
                confirmationTargets = nil
                if confirmed {
                    Task { await model.quarantine(box.findings) }
                }
            }
        }
    }

    // Sheet plumbing: .sheet(item:) needs Identifiable.
    private struct TargetBox: Identifiable {
        let id = UUID()
        let findings: [Finding]
    }

    private var sheetBinding: Binding<TargetBox?> {
        Binding(
            get: { confirmationTargets.map(TargetBox.init(findings:)) },
            set: { if $0 == nil { confirmationTargets = nil } })
    }

    // MARK: Header

    private var summaryHeader: some View {
        Card {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(tier.title) scan complete")
                        .font(Font.compatTitle3.weight(.semibold))
                    if let last = model.lastScan {
                        Text(Format.scanDate.string(from: last.date))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 8) {
                        ForEach(grouped, id: \.severity) { group in
                            SeverityCountChip(severity: group.severity,
                                              count: group.findings.count)
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer()
                if !eligibleFindings.isEmpty && tier != .forensic {
                    Button {
                        confirmationTargets = eligibleFindings
                    } label: {
                        CompatLabel("Quarantine All Eligible (\(eligibleFindings.count))",
                              systemImage: "archivebox")
                    }
                    .compatBorderedProminent()
                    .compatTint(.red)
                }
                if tier == .forensic {
                    CompatLabel("Read-only forensic mode",
                          systemImage: "hand.raised.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .compatHelp("Suspected state-sponsored implants are never quarantined in place; preserve the machine and consult a professional.")
                }
            }
        }
    }

    // MARK: Severity accordion

    private func severitySection(_ severity: Severity, _ findings: [Finding]) -> some View {
        CompatDisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(severity) },
            set: { open in
                if open { expanded.insert(severity) } else { expanded.remove(severity) }
            })
        ) {
            VStack(spacing: 10) {
                ForEach(findings) { finding in
                    FindingRow(
                        finding: finding,
                        allowQuarantine: tier != .forensic,
                        onQuarantine: { confirmationTargets = [finding] })
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 10) {
                CompatIcon(severity.symbol)
                    .foregroundColor(severity.color)
                VStack(alignment: .leading, spacing: 1) {
                    (Text(severity.label) + Text(" — \(findings.count)"))
                        .font(.headline)
                    Text(severity.groupDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .compatMaterialBackground(cornerRadius: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(severity.color.opacity(0.25))
        )
    }
}

// MARK: - One finding

struct FindingRow: View {
    @EnvironmentObject private var model: AppModel
    let finding: Finding
    var allowQuarantine: Bool
    var onQuarantine: () -> Void

    private var isQuarantined: Bool {
        model.quarantinedFindingIDs.contains(finding.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(finding.title)
                    .font(.callout.weight(.semibold))
                    .compatTextSelection()
                Spacer()
                Text(finding.category)
                    .font(Font.compatCaption2.weight(.medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.compatQuaternary.opacity(0.6)))
            }
            if !finding.detail.isEmpty {
                Text(finding.detail)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .compatTextSelection()
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(finding.paths, id: \.self) { PathRow(path: $0) }
            if !finding.remediation.isEmpty {
                CompatLabelView {
                    Text(finding.remediation)
                        .font(.caption.compatMonospaced())
                        .compatTextSelection()
                } icon: {
                    CompatIcon("wrench.adjustable")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
            actionBar
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .compatColorBackground(Color.compat(.windowBackgroundColor).opacity(0.5), cornerRadius: 8)
    }

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 10) {
            if isQuarantined {
                CompatLabel("Quarantined", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.green)
            } else if finding.isQuarantineEligible && allowQuarantine {
                // Only critical/high removable findings get the button —
                // review/info stay a human decision (safety principle 4).
                Button(action: onQuarantine) {
                    CompatLabel("Quarantine", systemImage: "archivebox")
                }
                .compatBorderedProminent()
                .compatTint(.red)
                .controlSize(.small)
            }
            if let first = finding.paths.first(where: {
                FileManager.default.fileExists(
                    atPath: ($0 as NSString).expandingTildeInPath)
            }), !isQuarantined {
                Button {
                    let expanded = (first as NSString).expandingTildeInPath
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: expanded)])
                } label: {
                    CompatLabel("Open in Finder", systemImage: "folder")
                }
                .controlSize(.small)
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Quarantine confirmation sheet (mirrors the CLI's --remove prompt)

struct QuarantineConfirmationView: View {
    let targets: [Finding]
    let completion: (Bool) -> Void

    private var allPaths: [(finding: Finding, path: String)] {
        targets.flatMap { f in f.paths.map { (f, $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                CompatIcon("archivebox.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quarantine \(targets.count == 1 ? "this finding" : "\(targets.count) findings")?")
                        .font(Font.compatTitle3.weight(.semibold))
                    Text("Items are moved — never deleted — to ~/.macscan/quarantine and any matching launchd job is unloaded. This is fully reversible from the Quarantine tab.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(targets) { finding in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                SeverityBadge(severity: finding.severity)
                                Text(finding.title)
                                    .font(.callout.weight(.semibold))
                            }
                            ForEach(finding.paths, id: \.self) { path in
                                Text(path)
                                    .font(.caption.compatMonospaced())
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 12)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(maxHeight: 240)
            .compatColorBackground(Color.compatQuaternary.opacity(0.3), cornerRadius: 8)

            CompatLabel("Protected system paths (/System, /usr, …) are refused by the engine even if listed above.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundColor(Color.compatTertiary)

            HStack {
                Spacer()
                CompatRoleButton("Cancel", role: .cancel) { completion(false) }
                    .compatCancelAction()
                CompatRoleButton(role: .destructive) {
                    completion(true)
                } label: {
                    CompatLabel("Quarantine \(allPaths.count) item\(allPaths.count == 1 ? "" : "s")",
                          systemImage: "archivebox")
                }
                .compatBorderedProminent()
                .compatTint(.red)
                .compatDefaultAction()
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
