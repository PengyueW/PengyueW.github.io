import SwiftUI

/// Live readouts for the three onboard sensors.
struct SensorsView: View {
    @EnvironmentObject private var model: SensorsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                alsCard
                lidCard
                accelCard
            }
            .padding(16)
        }
        .onAppear { model.beginObserving() }
        .onDisappear { model.endObserving() }
    }

    // MARK: ALS

    private var alsCard: some View {
        sensorCard(title: "Ambient Light Sensor",
                   symbol: "sun.max",
                   available: model.alsAvailable,
                   unavailableNote: "No ambient light sensor is exposed on this Mac (common on desktops and external displays).") {
            if let als = model.als {
                HStack(alignment: .top, spacing: 24) {
                    bigValue(String(format: "%.0f", als.lux), "lux")
                    if let kelvin = als.kelvin {
                        bigValue("\(kelvin)", "K (est.)")
                    }
                    if let rgb = als.rgb {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Light spectrum").font(.caption)
                                .foregroundColor(.secondary)
                            channelBar("R", rgb.r, .red)
                            channelBar("G", rgb.g, .green)
                            channelBar("B", rgb.b, .blue)
                        }
                    }
                }
                if als.rgb == nil {
                    Text("This sensor reports illuminance only; colour temperature and RGB spectrum need a multi-channel sensor.")
                        .font(Font.compatCaption2).foregroundColor(.secondary)
                }
                sparkline(model.luxHistory, tint: .yellow)
            }
        }
    }

    private func channelBar(_ label: LocalizedStringKey, _ value: Double,
                            _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption.compatMonospaced()).frame(width: 14)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.15))
                    Capsule().fill(color)
                        .frame(width: geo.size.width * CGFloat(min(1, value)))
                }
            }
            .frame(width: 140, height: 9)
            Text(String(format: "%.0f%%", value * 100))
                .font(Font.compatCaption2.compatMonospaced()).foregroundColor(.secondary)
        }
    }

    // MARK: Lid

    private var lidCard: some View {
        sensorCard(title: "Lid Angle",
                   symbol: "laptopcomputer",
                   available: model.lidAvailable,
                   unavailableNote: "Lid-angle sensing is only present on recent MacBook models.") {
            if let lid = model.lid {
                HStack(alignment: .top, spacing: 24) {
                    bigValue(String(format: "%.0f", lid.degrees), "degrees")
                    bigValue(String(format: "%+.0f", lid.degreesPerSecond), "°/sec")
                    lidDial(lid.degrees)
                }
                sparkline(model.lidHistory, tint: .blue)
            }
        }
    }

    private func lidDial(_ degrees: Double) -> some View {
        CompatLidDial(degrees: degrees)
        .frame(width: 90, height: 60)
    }

    // MARK: Accelerometer

    private var accelCard: some View {
        sensorCard(title: "SoC Accelerometer",
                   symbol: "gyroscope",
                   available: model.accelAvailable,
                   unavailableNote: "No motion sensor is exposed on this Mac (Apple removed the Sudden Motion Sensor once storage moved to SSD).") {
            if let accel = model.accel {
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        axisRow("X", accel.x, .red)
                        axisRow("Y", accel.y, .green)
                        axisRow("Z", accel.z, .blue)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        labelledValue("Magnitude",
                                      String(format: "%.2f g", accel.magnitude))
                        labelledValue("Pitch",
                                      String(format: "%+.0f°", accel.pitch))
                        labelledValue("Roll",
                                      String(format: "%+.0f°", accel.roll))
                    }
                }
            }
        }
    }

    private func axisRow(_ label: LocalizedStringKey, _ value: Double,
                         _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.callout.compatMonospaced()).frame(width: 16)
            GeometryReader { geo in
                let mid = geo.size.width / 2
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.15))
                    Capsule().fill(color)
                        .frame(width: abs(CGFloat(max(-1, min(1, value)))) * mid)
                        .offset(x: value >= 0 ? mid : mid - abs(CGFloat(max(-1, min(1, value)))) * mid)
                }
            }
            .frame(width: 160, height: 10)
            Text(String(format: "%+.2f", value))
                .font(.caption.compatMonospaced()).foregroundColor(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
    }

    // MARK: shared

    @ViewBuilder
    private func sensorCard<Content: View>(
        title: LocalizedStringKey, symbol: String, available: Bool,
        unavailableNote: LocalizedStringKey,
        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CompatLabel(title, systemImage: symbol).font(.headline)
            if available {
                content()
            } else {
                Text(unavailableNote)
                    .font(.callout).foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .compatFillBackground(cornerRadius: 12, opacity: 0.5)
    }

    private func bigValue(_ value: String, _ unit: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 40, weight: .semibold, design: .rounded))
            Text(unit).font(.caption).foregroundColor(.secondary)
        }
    }

    private func labelledValue(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).compatMonospacedDigit()
        }
        .font(.callout)
        .frame(width: 180)
    }

    private func sparkline(_ data: [Double], tint: Color) -> some View {
        CompatSparkline(
            values: data,
            yFor: { value, height in
                guard let lo = data.min(), let hi = data.max(), hi > lo else { return height }
                return height - CGFloat((value - lo) / (hi - lo)) * height
            },
            color: tint)
        .frame(height: 44)
    }
}
