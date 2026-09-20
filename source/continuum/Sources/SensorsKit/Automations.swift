import Foundation

// User-scriptable automations (feature #12): run a shell script when a sensor
// metric crosses a threshold. Rules are edge-triggered — the action fires once
// when the condition flips from false to true, not on every poll while true.

/// A metric an automation can watch.
enum SensorMetric: String, Codable, CaseIterable, Identifiable {
    case lux
    case kelvin
    case lidAngle
    case lidVelocity
    case tilt              // |pitch| in degrees
    case accelMagnitude    // total g

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lux:            return "Ambient light (lux)"
        case .kelvin:         return "Colour temperature (K)"
        case .lidAngle:       return "Lid angle (°)"
        case .lidVelocity:    return "Lid speed (°/s)"
        case .tilt:           return "Tilt (°)"
        case .accelMagnitude: return "Acceleration (g)"
        }
    }

    var unit: String {
        switch self {
        case .lux: return "lux"
        case .kelvin: return "K"
        case .lidAngle, .tilt: return "°"
        case .lidVelocity: return "°/s"
        case .accelMagnitude: return "g"
        }
    }
}

enum Comparison: String, Codable, CaseIterable, Identifiable {
    case greaterThan, lessThan
    var id: String { rawValue }
    var symbol: String { self == .greaterThan ? "≥" : "≤" }
    func matches(_ value: Double, _ threshold: Double) -> Bool {
        self == .greaterThan ? value >= threshold : value <= threshold
    }
}

/// One automation rule. The script is run with `/bin/sh -c` and gets the
/// triggering value in the `CONTINUUM_VALUE` environment variable.
struct Automation: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var metric: SensorMetric
    var comparison: Comparison
    var threshold: Double
    var script: String
    var enabled: Bool = true

    static func == (lhs: Automation, rhs: Automation) -> Bool { lhs.id == rhs.id }
}

/// A line in the automation run log.
struct AutomationEvent: Identifiable {
    let id = UUID()
    let date: Date
    let automationName: String
    let value: Double
    let success: Bool
    let output: String
}

/// Evaluates automations against the latest metric values and runs scripts on
/// rising edges. Pure logic + Process; persistence is the model's job.
final class AutomationEngine {
    private var lastMatched: [UUID: Bool] = [:]

    /// Returns events for any automations that fired on this sample.
    func evaluate(_ automations: [Automation],
                  values: [SensorMetric: Double]) -> [AutomationEvent] {
        var events: [AutomationEvent] = []
        for rule in automations where rule.enabled {
            guard let value = values[rule.metric] else { continue }
            let matched = rule.comparison.matches(value, rule.threshold)
            let previously = lastMatched[rule.id] ?? false
            lastMatched[rule.id] = matched
            if matched && !previously {
                events.append(run(rule, value: value))
            }
        }
        return events
    }

    func forget(_ id: UUID) { lastMatched[id] = nil }

    private func run(_ rule: Automation, value: Double) -> AutomationEvent {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", rule.script]
        var env = ProcessInfo.processInfo.environment
        env["CONTINUUM_VALUE"] = String(value)
        env["CONTINUUM_METRIC"] = rule.metric.rawValue
        env["CONTINUUM_AUTOMATION"] = rule.name
        task.environment = env
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        var success = false
        var output = ""
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            success = task.terminationStatus == 0
            output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if output.isEmpty {
                output = success ? "ran (no output)"
                                 : "exited \(task.terminationStatus)"
            }
        } catch {
            output = error.localizedDescription
        }
        return AutomationEvent(date: Date(), automationName: rule.name,
                               value: value, success: success, output: output)
    }
}
