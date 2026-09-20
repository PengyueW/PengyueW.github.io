import SwiftUI

/// Drive health dashboard: lifespan / TBW headline cards on top, the full
/// S.M.A.R.T. attribute table below.
struct DriveHealthView: View {
    @EnvironmentObject private var model: DriveHealthModel

    var body: some View {
        Group {
            if let log = model.log {
                content(log)
            } else if model.isUnavailable {
                unavailable()
            } else {
                CompatProgress("Reading S.M.A.R.T. data…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { model.startAutoRefresh() }
        .onDisappear { model.stopAutoRefresh() }
        .compatToolbar {
            Group {
                Button {
                    model.refresh()
                } label: {
                    CompatIcon("arrow.clockwise")
                }
                .compatHelp("Refresh S.M.A.R.T. data")
                .disabled(model.isRefreshing)
            }
                }
    }

    private func unavailable() -> some View {
        VStack(spacing: 12) {
            CompatIcon("internaldrive.badge.questionmark")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.secondary)
            Text("S.M.A.R.T. Data Unavailable")
                .font(Font.compatTitle3.weight(.semibold))
            Text("The NVMe S.M.A.R.T. user client isn’t available for this drive. Internal Apple SSDs and most NVMe enclosures support it; many USB bridges don’t.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Try Again") { model.refresh() }
                .compatBordered()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ log: NVMeSMARTLog) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(log)
                if !log.warnings.isEmpty {
                    warningBox(log.warnings)
                }
                cards(log)
                attributeTable(log)
                footnote
            }
            .padding(16)
        }
    }

    private func header(_ log: NVMeSMARTLog) -> some View {
        HStack(spacing: 12) {
            CompatIcon("internaldrive")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.identity.model.isEmpty ? "NVMe SSD"
                                                  : model.identity.model)
                    .font(Font.compatTitle3.weight(.semibold))
                HStack(spacing: 8) {
                    if let size = model.diskSize {
                        Text(ByteCountFormatter.string(fromByteCount: size,
                                                       countStyle: .file))
                    }
                    if !model.identity.serial.isEmpty {
                        Text("S/N \(model.identity.serial)")
                    }
                    if !model.identity.firmware.isEmpty {
                        Text("FW \(model.identity.firmware)")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
            if let date = model.lastRefresh {
                Text("Updated \(date.compatFormatted(dateStyle: .none, timeStyle: .medium))")
                    .font(Font.compatCaption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func warningBox(_ warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CompatLabel("Critical warnings", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundColor(.red)
            ForEach(warnings, id: \.self) { Text("• \($0)") }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .compatColorBackground(Color.red.opacity(0.1), cornerRadius: 8)
    }

    private func cards(_ log: NVMeSMARTLog) -> some View {
        HStack(spacing: 12) {
            statCard(title: "Estimated Life Left",
                     value: "\(model.estimatedLifePercentLeft ?? 0) %",
                     detail: "\(log.percentageUsed) % of rated endurance used",
                     symbol: "heart.text.square",
                     tint: lifeTint(log.percentageUsed))
            statCard(title: "Total Written (TBW)",
                     value: terabytes(log.bytesWritten),
                     detail: "\(log.dataUnitsWritten.compatFormatted()) data units",
                     symbol: "arrow.down.doc",
                     tint: .blue)
            statCard(title: "Total Read",
                     value: terabytes(log.bytesRead),
                     detail: "\(log.dataUnitsRead.compatFormatted()) data units",
                     symbol: "arrow.up.doc",
                     tint: Color.compatTeal)
            statCard(title: "Temperature",
                     value: String(format: "%.0f °C", log.temperatureCelsius),
                     detail: "Composite sensor",
                     symbol: "thermometer.medium",
                     tint: log.temperatureCelsius > 70 ? .red : .orange)
        }
    }

    private func lifeTint(_ used: Int) -> Color {
        used >= 90 ? .red : used >= 70 ? .orange : .green
    }

    private func statCard(title: LocalizedStringKey, value: String, detail: String,
                          symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CompatLabel(title, systemImage: symbol)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundColor(tint)
            Text(detail)
                .font(Font.compatCaption2)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .compatFillBackground(cornerRadius: 10, opacity: 0.5)
    }

    private func attributeTable(_ log: NVMeSMARTLog) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("S.M.A.R.T. Attributes")
                .font(.headline)
                .padding(.bottom, 8)
            VStack(spacing: 0) {
                Group {
                    attributeRow("Critical warning flags",
                                 log.criticalWarning == 0 ? "none"
                                     : String(format: "0x%02X", log.criticalWarning))
                    attributeRow("Available spare",
                                 "\(log.availableSparePercent) % (threshold \(log.spareThresholdPercent) %)")
                    attributeRow("Percentage used (endurance)", "\(log.percentageUsed) %")
                    attributeRow("Data units read",
                                 "\(log.dataUnitsRead.compatFormatted()) — \(terabytes(log.bytesRead))")
                    attributeRow("Data units written",
                                 "\(log.dataUnitsWritten.compatFormatted()) — \(terabytes(log.bytesWritten))")
                    attributeRow("Host read commands", log.hostReadCommands.compatFormatted())
                    attributeRow("Host write commands", log.hostWriteCommands.compatFormatted())
                }
                Group {
                    attributeRow("Controller busy time",
                                 "\(log.controllerBusyMinutes.compatFormatted()) min")
                    attributeRow("Power cycles", log.powerCycles.compatFormatted())
                    attributeRow("Power-on hours",
                                 "\(log.powerOnHours.compatFormatted()) h "
                                 + "(≈ \(log.powerOnHours / 24) days)")
                    attributeRow("Unsafe shutdowns", log.unsafeShutdowns.compatFormatted())
                    attributeRow("Media & data integrity errors",
                                 log.mediaErrors.compatFormatted())
                    attributeRow("Error log entries", log.errorLogEntries.compatFormatted())
                }
            }
            .compatFillBackground(cornerRadius: 10, opacity: 0.5)
        }
    }

    @ViewBuilder
    private func attributeRow(_ name: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .compatMonospacedDigit()
                .compatTextSelection()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        Divider().padding(.leading, 12)
    }

    private var footnote: some View {
        Text("Data units are 1000 × 512-byte blocks as defined by the NVMe specification. “Estimated life left” inverts the drive’s own percentage-used endurance estimate; drives routinely outlive it.")
            .font(Font.compatCaption2)
            .foregroundColor(.secondary)
    }

    private func terabytes(_ bytes: UInt64) -> String {
        let tb = Double(bytes) / 1_000_000_000_000
        if tb >= 1 { return String(format: "%.2f TB", tb) }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes),
                                         countStyle: .file)
    }
}
