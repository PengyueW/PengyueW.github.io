import SwiftUI

/// Thermal & Fans page: live sensor table, fan dials, and the custom fan
/// curve editor.
struct ThermalView: View {
    @EnvironmentObject private var model: HardwareModel

    var body: some View {
        Group {
            if let errorDescription = model.smcErrorDescription {
                unavailable(errorDescription)
            } else {
                content
            }
        }
        .onAppear { model.beginObserving() }
        .onDisappear { model.endObserving() }
    }

    private func unavailable(_ errorDescription: String) -> some View {
        VStack(spacing: 12) {
            CompatIcon("thermometer.snowflake")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.secondary)
            Text("Thermal Sensors Unavailable").font(Font.compatTitle3.weight(.semibold))
            Text("The SMC isn’t reachable: \(errorDescription)")
                .font(.callout).foregroundColor(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                fansSection
                curveSection
                sensorsSection
            }
            .padding(16)
        }
    }

    // MARK: fans

    private var fansSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fans").font(.headline)
            if model.fans.isEmpty {
                Text("No fans reported by the SMC (fanless Mac, or sensors still loading).")
                    .font(.callout).foregroundColor(.secondary)
            } else {
                HStack(spacing: 12) {
                    ForEach(model.fans) { fan in
                        fanCard(fan)
                    }
                }
            }
            if let error = model.fanControlError {
                CompatLabel(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.orange)
            }
        }
    }

    private func fanCard(_ fan: FanState) -> some View {
        VStack(spacing: 6) {
            Text("Fan \(fan.id + 1)").font(.caption).foregroundColor(.secondary)
            Text("\(Int(fan.actualRPM))")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
            Text("RPM").font(Font.compatCaption2).foregroundColor(.secondary)
            CompatProgress(value: progressFraction(fan))
                .frame(width: 110)
            Text("target \(Int(fan.targetRPM)) · range \(Int(fan.minRPM))–\(Int(fan.maxRPM))")
                .font(Font.compatCaption2).foregroundColor(.secondary)
        }
        .padding(12)
        .compatFillBackground(cornerRadius: 10, opacity: 0.5)
    }

    private func progressFraction(_ fan: FanState) -> Double {
        let span = fan.maxRPM - fan.minRPM
        guard span > 0 else { return 0 }
        return min(1, max(0, (fan.actualRPM - fan.minRPM) / span))
    }

    // MARK: curve

    private var curveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Custom Fan Curve").font(.headline)
                Spacer()
                Toggle("Apply curve", isOn: $model.curveEnabled)
                    .toggleStyle(.switch)
                    .disabled(model.fans.isEmpty)
            }
            Text("Maps the hottest CPU sensor to a fan speed between each fan’s minimum and maximum. macOS restricts SMC writes to root, so applying the curve may require running Continuum with sudo; the SMC always regains control when disabled.")
                .font(.caption).foregroundColor(.secondary)

            curveChart
                .frame(height: 160)

            ForEach($model.curve.points) { $point in
                HStack(spacing: 12) {
                    Text("\(Int(point.celsius)) °C")
                        .frame(width: 56, alignment: .trailing)
                        .compatMonospacedDigit()
                    Slider(value: $point.celsius, in: 30...105, step: 1)
                        .frame(maxWidth: 220)
                    Text("\(Int(point.fraction * 100)) %")
                        .frame(width: 52, alignment: .trailing)
                        .compatMonospacedDigit()
                    Slider(value: $point.fraction, in: 0...1, step: 0.05)
                        .frame(maxWidth: 220)
                    Button {
                        model.curve.points.removeAll { $0.id == point.id }
                    } label: {
                        CompatIcon("minus.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(model.curve.points.count <= 2)
                }
                .font(.callout)
            }
            Button {
                let last = model.curve.points.map(\.celsius).max() ?? 50
                model.curve.points.append(
                    FanCurvePoint(celsius: min(last + 10, 105), fraction: 1.0))
            } label: {
                CompatLabel("Add Point", systemImage: "plus")
            }
            .disabled(model.curve.points.count >= 8)
        }
        .padding(12)
        .compatFillBackground(cornerRadius: 10, opacity: 0.4)
    }

    private var curveChart: some View {
        // Drawn with SwiftUI Paths rather than a Canvas — Canvas is macOS 12.
        GeometryReader { geo in
            let size = geo.size
            let tMin = 30.0, tMax = 105.0
            let x = { (t: Double) -> CGFloat in
                CGFloat((t - tMin) / (tMax - tMin)) * size.width
            }
            let y = { (f: Double) -> CGFloat in
                size.height - CGFloat(f) * size.height
            }
            ZStack {
                // Grid lines every 10 °C.
                Path { p in
                    for t in stride(from: 40.0, through: 100.0, by: 10) {
                        p.move(to: CGPoint(x: x(t), y: 0))
                        p.addLine(to: CGPoint(x: x(t), y: size.height))
                    }
                }
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)

                // The interpolated curve.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: y(model.curve.fraction(at: tMin))))
                    for t in stride(from: tMin, through: tMax, by: 1) {
                        p.addLine(to: CGPoint(x: x(t), y: y(model.curve.fraction(at: t))))
                    }
                }
                .stroke(Color.accentColor, lineWidth: 2)

                // Control points.
                Path { p in
                    for point in model.curve.points {
                        p.addEllipse(in: CGRect(x: x(point.celsius) - 4,
                                                y: y(point.fraction) - 4,
                                                width: 8, height: 8))
                    }
                }
                .fill(Color.accentColor)

                // Live temperature marker.
                if let temp = model.hottestCPUTemp {
                    Path { p in
                        p.move(to: CGPoint(x: x(temp), y: 0))
                        p.addLine(to: CGPoint(x: x(temp), y: size.height))
                    }
                    .stroke(Color.red.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.compat(.windowBackgroundColor).opacity(0.5)))
    }

    // MARK: sensors

    private var sensorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Temperature Sensors (\(model.sensors.count))")
                .font(.headline)
            if model.sensors.isEmpty {
                Text("Enumerating SMC sensor keys…")
                    .font(.callout).foregroundColor(.secondary)
            } else {
                CompatAdaptiveGrid(items: model.sensors, minimum: 210, spacing: 8) { sensor in
                        HStack {
                            Text(sensor.label)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer()
                            Text(String(format: "%.1f °C", sensor.celsius))
                                .font(.callout.weight(.semibold))
                                .compatMonospacedDigit()
                                .foregroundColor(tint(sensor.celsius))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .compatFillBackground(cornerRadius: 7, opacity: 0.5)
                }
            }
        }
    }

    private func tint(_ celsius: Double) -> Color {
        celsius >= 90 ? .red : celsius >= 70 ? .orange : .primary
    }
}
