import SwiftUI

/// Automations page: rule list + editor sheet + run log. Lets the user inject
/// scripts that fire when a sensor metric crosses a threshold.
struct AutomationsView: View {
    @EnvironmentObject private var model: SensorsModel
    @State private var editing: Automation?
    @State private var showEditor = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.automations.isEmpty {
                empty
            } else {
                rulesList
            }
            Divider()
            logSection
        }
        .sheet(isPresented: $showEditor) {
            AutomationEditor(automation: editing) { result in
                if let existing = model.automations.first(where: { $0.id == result.id }) {
                    _ = existing
                    model.update(result)
                } else {
                    model.add(result)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sensor Automations").font(Font.compatTitle3.weight(.semibold))
                Text("Run a script when a sensor reading crosses a threshold. Rules fire once on each rising edge; the script gets the value in $CONTINUUM_VALUE.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button {
                editing = nil
                showEditor = true
            } label: {
                CompatLabel("New Automation", systemImage: "plus")
            }
        }
        .padding(12)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            CompatIcon("wand.and.stars")
                .font(.system(size: 38, weight: .light))
                .foregroundColor(.secondary)
            Text("No automations yet")
                .font(Font.compatTitle3.weight(.semibold))
            Text("Example: when the lid angle drops below 5°, run a script that pauses your music; or when lux falls below 50, switch to dark mode.")
                .font(.callout).foregroundColor(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rulesList: some View {
        List {
            ForEach(model.automations) { rule in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { rule.enabled },
                        set: { var r = rule; r.enabled = $0; model.update(r) }))
                        .labelsHidden()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rule.name).font(.callout.weight(.medium))
                        Text("when \(rule.metric.title) \(rule.comparison.symbol) "
                             + "\(Int(rule.threshold)) \(rule.metric.unit)")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Edit") { editing = rule; showEditor = true }
                        .controlSize(.small)
                    CompatRoleButton(role: .destructive) {
                        model.remove(rule)
                    } label: {
                        CompatIcon("trash")
                    }
                    .controlSize(.small).buttonStyle(.plain)
                    .foregroundColor(.red)
                }
                .padding(.vertical, 2)
            }
        }
        .compatInsetList()
        .frame(maxHeight: 280)
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Run Log").font(.headline)
                Spacer()
                if !model.events.isEmpty {
                    Button("Clear") { model.clearEvents() }.controlSize(.small)
                }
            }
            .padding(.horizontal, 12).padding(.top, 8)
            if model.events.isEmpty {
                Text("No automations have fired yet.")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            } else {
                List(model.events) { event in
                    HStack(alignment: .top, spacing: 8) {
                        CompatIcon(event.success
                              ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(event.success ? .green : .red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(event.automationName) — value \(String(format: "%.1f", event.value))")
                                .font(.caption.weight(.medium))
                            Text(event.output)
                                .font(Font.compatCaption2.compatMonospaced())
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                            Text(event.date.compatFormatted(dateStyle: .none, timeStyle: .medium))
                                .font(Font.compatCaption2).foregroundColor(Color.compatTertiary)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .compatInsetList()
                .frame(maxHeight: 200)
            }
        }
    }
}

/// Create / edit one automation.
private struct AutomationEditor: View {
    // `\.dismiss` is macOS 12; `presentationMode` is the universal spelling.
    @Environment(\.presentationMode) private var presentationMode
    @State private var name: String
    @State private var metric: SensorMetric
    @State private var comparison: Comparison
    @State private var threshold: Double
    @State private var script: String
    private let id: UUID
    private let enabled: Bool
    private let onSave: (Automation) -> Void

    init(automation: Automation?, onSave: @escaping (Automation) -> Void) {
        _name = State(initialValue: automation?.name ?? "")
        _metric = State(initialValue: automation?.metric ?? .lidAngle)
        _comparison = State(initialValue: automation?.comparison ?? .lessThan)
        _threshold = State(initialValue: automation?.threshold ?? 5)
        _script = State(initialValue: automation?.script
                        ?? "osascript -e 'display notification \"Triggered\" with title \"Continuum\"'")
        id = automation?.id ?? UUID()
        enabled = automation?.enabled ?? true
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(name.isEmpty ? "New Automation" : "Edit Automation")
                .font(Font.compatTitle2.weight(.semibold))

            Form {
                TextField("Name", text: $name)
                Picker("When", selection: $metric) {
                    ForEach(SensorMetric.allCases) { Text($0.title).tag($0) }
                }
                Picker("Is", selection: $comparison) {
                    Text("at or above (≥)").tag(Comparison.greaterThan)
                    Text("at or below (≤)").tag(Comparison.lessThan)
                }
                HStack {
                    Text("Threshold")
                    Slider(value: $threshold, in: thresholdRange)
                    Text("\(Int(threshold)) \(metric.unit)")
                        .compatMonospacedDigit().frame(width: 70, alignment: .trailing)
                }
            }
            .compatGroupedForm()

            Text("Shell script (run with /bin/sh; $CONTINUUM_VALUE holds the reading)")
                .font(.caption).foregroundColor(.secondary)
            CompatTextEditor(text: $script)
                .font(.callout.compatMonospaced())
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.compatQuaternary))

            CompatLabel("Scripts run with your full user privileges. Only add code you trust.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundColor(.orange)

            HStack {
                Spacer()
                Button("Cancel") { presentationMode.wrappedValue.dismiss() }
                Button("Save") {
                    onSave(Automation(id: id,
                                      name: name.isEmpty ? "Automation" : name,
                                      metric: metric, comparison: comparison,
                                      threshold: threshold, script: script,
                                      enabled: enabled))
                    presentationMode.wrappedValue.dismiss()
                }
                .compatBorderedProminent()
                .disabled(script.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var thresholdRange: ClosedRange<Double> {
        switch metric {
        case .lux:            return 0...2000
        case .kelvin:         return 2000...10000
        case .lidAngle, .tilt: return 0...180
        case .lidVelocity:    return 0...180
        case .accelMagnitude: return 0...4
        }
    }
}
