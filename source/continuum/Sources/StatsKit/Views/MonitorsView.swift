import SwiftUI

/// Menu-bar monitors page: large live gauges, the menu-bar item config, and
/// the app presentation switch.
struct MonitorsView: View {
    @EnvironmentObject private var model: StatsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                gauges
                cpuChart
                menuBarSection
                presentationSection
            }
            .padding(16)
        }
    }

    private var s: SystemSample { model.sample }

    private var gauges: some View {
        HStack(spacing: 12) {
            gauge("CPU", value: s.cpuBusyPercent / 100,
                  label: String(format: "%.0f%%", s.cpuBusyPercent),
                  detail: "\(s.activeThreads) active threads · \(s.logicalCores) cores",
                  tint: s.cpuBusyPercent > 80 ? .red : .blue)
            gauge("RAM Pressure", value: s.memoryPressure,
                  label: String(format: "%.0f%%", s.memoryPressure * 100),
                  detail: "\(bytes(s.memUsedBytes)) of \(bytes(s.memTotalBytes))",
                  tint: s.memoryPressure > 0.8 ? .red
                        : s.memoryPressure > 0.6 ? .orange : .green)
            gauge("Network", value: min(1, s.netInBytesPerSec / 5_000_000),
                  label: "↓\(StatsModel.rate(s.netInBytesPerSec))",
                  detail: "↑\(StatsModel.rate(s.netOutBytesPerSec))",
                  tint: Color.compatTeal)
        }
    }

    private func gauge(_ title: LocalizedStringKey, value: Double, label: String,
                       detail: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.caption).foregroundColor(.secondary)
            ZStack {
                Circle().stroke(tint.opacity(0.15), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(0, min(1, value)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(label)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .compatMonospacedDigit()
            }
            .frame(width: 96, height: 96)
            Text(detail).font(Font.compatCaption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .compatFillBackground(cornerRadius: 12, opacity: 0.5)
    }

    private var cpuChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CPU — last \(model.cpuHistory.count * 2) s").font(.headline)
            CompatSparkline(
                values: model.cpuHistory,
                yFor: { value, height in height - CGFloat(value / 100) * height },
                color: .blue)
            .frame(height: 70)
            .compatFillBackground(cornerRadius: 8, opacity: 0.4)
        }
    }

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Menu-Bar Item").font(.headline)
            Text("Choose which metrics appear in the menu bar. They’re shown whenever the app runs in “Menu Bar Only” mode.")
                .font(.caption).foregroundColor(.secondary)
            Toggle("CPU utilization", isOn: $model.menuBar.showCPU)
            Toggle("RAM pressure", isOn: $model.menuBar.showRAM)
            Toggle("Network bandwidth", isOn: $model.menuBar.showNetwork)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .compatFillBackground(cornerRadius: 10, opacity: 0.4)
    }

    private var presentationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("App Mode").font(.headline)
            Picker("", selection: $model.presentation) {
                ForEach(AppPresentation.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.presentation.detail)
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .compatFillBackground(cornerRadius: 10, opacity: 0.4)
    }

    private func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
    }
}
