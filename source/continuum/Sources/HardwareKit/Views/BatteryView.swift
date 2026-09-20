import SwiftUI

/// Battery longevity page: health, cycles, manufacture date, temperature,
/// and a live discharge-wattage strip chart.
struct BatteryView: View {
    @EnvironmentObject private var model: HardwareModel

    var body: some View {
        Group {
            if model.battery.present {
                content
            } else {
                VStack(spacing: 12) {
                    CompatIcon("battery.0")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(.secondary)
                    Text("No Battery").font(Font.compatTitle3.weight(.semibold))
                    Text("This Mac doesn’t report an internal battery.")
                        .font(.callout).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { model.beginObserving() }
        .onDisappear { model.endObserving() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                cards
                wattChart
                detailTable
            }
            .padding(16)
        }
    }

    private var battery: BatterySnapshot { model.battery }

    private var cards: some View {
        HStack(spacing: 12) {
            card("Health",
                 String(format: "%.1f %%", battery.healthPercent),
                 "\(battery.maxCapacity) of \(battery.designCapacity) mAh design",
                 "heart", battery.healthPercent < 80 ? .orange : .green)
            card("Charge Cycles", "\(battery.cycleCount)",
                 "Apple rates most batteries for 1000",
                 "arrow.triangle.2.circlepath",
                 battery.cycleCount > 800 ? .orange : .blue)
            card("Temperature",
                 String(format: "%.1f °C", battery.temperature),
                 "Battery pack sensor", "thermometer.medium",
                 battery.temperature > 40 ? .red : Color.compatTeal)
            card("Power Draw",
                 String(format: "%+.1f W", battery.watts),
                 battery.watts < 0 ? "Discharging" :
                    battery.isCharging ? "Charging" : "Idle / on AC",
                 "bolt", battery.watts < 0 ? .orange : .green)
        }
    }

    private func card(_ title: LocalizedStringKey, _ value: String, _ detail: String,
                      _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CompatLabel(title, systemImage: symbol)
                .font(.caption).foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundColor(tint)
            Text(detail).font(Font.compatCaption2).foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .compatFillBackground(cornerRadius: 10, opacity: 0.5)
    }

    private var wattChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Real-Time Wattage (last \(model.wattHistory.count * 3) s)")
                .font(.headline)
            CompatSparkline(
                values: model.wattHistory,
                yFor: { watts, height in
                    let maxAbs = max(10, model.wattHistory.map { abs($0) }.max() ?? 10)
                    return height / 2 - CGFloat(watts / maxAbs) * height / 2
                },
                color: .accentColor,
                zeroLineFraction: 0.5)
            .frame(height: 90)
            .compatFillBackground(cornerRadius: 8, opacity: 0.4)
            Text("Above the line: charging. Below: discharging from the battery.")
                .font(Font.compatCaption2).foregroundColor(.secondary)
        }
    }

    private var detailTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Details").font(.headline).padding(.bottom, 8)
            VStack(spacing: 0) {
                row("Charge", String(format: "%.1f %% (%d mAh)",
                                     battery.chargePercent,
                                     battery.currentCapacity))
                row("Voltage", String(format: "%.2f V", battery.voltage))
                row("Amperage", String(format: "%+.2f A", battery.amperage))
                row("Manufacture date", battery.manufactureDate
                        .map { $0.compatFormatted(dateStyle: .long, timeStyle: .none) }
                    ?? "not reported on this model")
                row("Serial number",
                    battery.serial.isEmpty ? "—" : battery.serial)
                if let minutes = battery.timeRemainingMinutes {
                    row("Time remaining",
                        "\(minutes / 60) h \(minutes % 60) min")
                }
                row("External power",
                    battery.externalConnected ? "connected" : "on battery")
            }
            .compatFillBackground(cornerRadius: 10, opacity: 0.5)
        }
    }

    @ViewBuilder
    private func row(_ name: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).foregroundColor(.secondary).compatMonospacedDigit()
                .compatTextSelection()
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 7)
        Divider().padding(.leading, 12)
    }
}
