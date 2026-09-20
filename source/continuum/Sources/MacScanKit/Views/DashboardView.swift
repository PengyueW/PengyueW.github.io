import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                postureGrid
                lastScanCard
                if !model.hasFullDiskAccess {
                    fdaCallout
                }
            }
            .padding(20)
        }
        .compatNavigationTitle("Dashboard")
        .compatToolbar {
            Button {
                model.startScan(tier: .standard)
            } label: {
                CompatLabel("Scan Now", systemImage: "play.fill")
            }
            .disabled(model.scanState.isRunning || model.cliURL == nil)
        }
        .onAppear { model.refreshFullDiskAccess() }
    }

    // MARK: Header — overall verdict

    private var verdict: (symbol: String, color: Color, title: LocalizedStringKey, detail: LocalizedStringKey) {
        guard let last = model.lastScan else {
            return ("shield.slash", .secondary, "No scan yet",
                    "Run a scan to establish this Mac's security posture.")
        }
        let counts = last.counts
        if counts[.critical, default: 0] > 0 {
            return ("exclamationmark.shield.fill", .red, "Critical findings",
                    "Known malware indicators were detected. Review the Scan Engine tab.")
        }
        if counts[.high, default: 0] > 0 || counts[.medium, default: 0] > 0 {
            return ("exclamationmark.shield", .orange, "Attention needed",
                    "Suspicious items were found. Review them in the Scan Engine tab.")
        }
        if counts[.review, default: 0] > 0 {
            return ("checkmark.shield", Color.compatTeal, "Mostly clean",
                    "Nothing malicious found; a few items need human judgment.")
        }
        return ("checkmark.shield.fill", .green, "No findings",
                "Nothing suspicious was detected in the last scan.")
    }

    private var header: some View {
        let v = verdict
        return HStack(spacing: 16) {
            CompatIcon(v.symbol)
                .font(.system(size: 44, weight: .medium))
                .foregroundColor(v.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(v.title)
                    .font(.largeTitle.weight(.bold))
                Text(v.detail)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .compatMaterialBackground(cornerRadius: 12)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(v.color.opacity(0.35))
        )
    }

    // MARK: Posture tiles (derived from system.py findings)

    private var postureGrid: some View {
        CompatAdaptiveVGrid(minimum: 190, spacing: 12) {
            PostureTile(
                title: "System Integrity Protection",
                symbol: "internaldrive",
                status: model.sipStatus,
                detail: "Stops malware from modifying protected system files.")
            PostureTile(
                title: "Gatekeeper",
                symbol: "checkmark.seal",
                status: model.gatekeeperStatus,
                detail: "Blocks unsigned, unnotarized apps from running silently.")
            PostureTile(
                title: "Full Disk Access",
                symbol: "lock.open.laptopcomputer",
                status: model.hasFullDiskAccess ? .enabled : .disabled,
                detail: "Needed for forensic checks (TCC database, network usage).")
            xprotectTile
        }
    }

    private var xprotectTile: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CompatIcon("cross.vial")
                    .font(Font.compatTitle2)
                    .foregroundColor(model.xprotectVersion == nil ? Color.secondary : .green)
                Spacer()
            }
            Text("XProtect Definitions")
                .font(.subheadline.weight(.semibold))
            Text(model.xprotectVersion ?? "Run a scan")
                .font(Font.compatTitle3.weight(.bold))
                .foregroundColor(model.xprotectVersion == nil ? Color.secondary : .primary)
            Text("Apple's built-in malware definitions, updated automatically.")
                .font(.caption)
                .foregroundColor(.secondary)
                .compatLineLimit(2, reservesSpace: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .compatMaterialBackground(cornerRadius: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.compat(.separatorColor).opacity(0.5))
        )
    }

    // MARK: Last scan summary

    private var lastScanCard: some View {
        Card(title: "Last Scan", systemImage: "clock.arrow.circlepath") {
            if let last = model.lastScan {
                HStack(alignment: .top, spacing: 24) {
                    severityGauge(counts: last.counts)
                    VStack(alignment: .leading, spacing: 8) {
                        CompatLabeledContent("Completed") {
                            Text(Format.scanDate.string(from: last.date))
                        }
                        CompatLabeledContent("Tier") {
                            CompatLabel(last.tier.title, systemImage: last.tier.symbol)
                        }
                        let chips = Severity.allCases.filter { last.counts[$0, default: 0] > 0 }
                        if chips.isEmpty {
                            Text("No findings — nothing suspicious detected.")
                                .foregroundColor(.secondary)
                        } else {
                            HStack(spacing: 8) {
                                ForEach(chips) { sev in
                                    SeverityCountChip(severity: sev,
                                                      count: last.counts[sev, default: 0])
                                }
                            }
                        }
                    }
                    .font(.callout)
                    Spacer()
                    Button {
                        model.selectedSection = .scan
                    } label: {
                        CompatLabel("View Results", systemImage: "list.bullet.rectangle")
                    }
                }
            } else {
                HStack {
                    Text("This Mac has not been scanned yet.")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        model.startScan(tier: .standard)
                    } label: {
                        CompatLabel("Run First Scan", systemImage: "play.fill")
                    }
                    .compatBorderedProminent()
                    .disabled(model.cliURL == nil)
                }
            }
        }
    }

    private func severityGauge(counts: [Severity: Int]) -> some View {
        let attention = counts[.critical, default: 0] + counts[.high, default: 0]
                      + counts[.medium, default: 0]
        let total = max(counts.values.reduce(0, +), 1)
        return CompatCircularGauge(
            value: Double(total - attention), in: 0...Double(total),
            tint: attention == 0 ? .green
                : (counts[.critical, default: 0] > 0 ? .red : .orange)) {
            attention == 0 ? CompatSymbol.text("checkmark") : Text("\(attention)")
        }
        .scaleEffect(1.15)
        .padding(.leading, 6)
        .compatHelp(attention == 0 ? "No actionable findings"
                             : "\(attention) finding(s) need attention")
    }

    // MARK: FDA nudge

    private var fdaCallout: some View {
        HStack(spacing: 12) {
            CompatIcon("lock.shield")
                .font(Font.compatTitle2)
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Full Disk Access not granted")
                    .font(.subheadline.weight(.semibold))
                Text("Forensic scans will report blind spots for the TCC privacy database and network-usage records until access is granted.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Show Me How") { model.showPermissionsHelp = true }
        }
        .padding(14)
        .compatColorBackground(Color.orange.opacity(0.08), cornerRadius: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.orange.opacity(0.3))
        )
    }
}
