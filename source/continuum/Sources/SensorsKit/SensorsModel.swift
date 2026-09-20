import Foundation
import Combine

/// Drives sensor polling, keeps short history strips for the charts, and runs
/// the automation engine against each sample.
@MainActor
final class SensorsModel: ObservableObject {
    // Live values
    @Published var als: ALSSnapshot?
    @Published var lid: LidSnapshot?
    @Published var accel: AccelSnapshot?
    @Published var alsAvailable = true
    @Published var lidAvailable = true
    @Published var accelAvailable = true

    // History (last ~120 samples each)
    @Published var luxHistory: [Double] = []
    @Published var lidHistory: [Double] = []

    // Automations
    @Published var automations: [Automation] = []
    @Published var events: [AutomationEvent] = []

    private var timer: AnyCancellable?
    private var viewers = 0
    private var automationsActive = false
    private var lastLidDegrees: Double?
    private var lastLidTime: Date?
    private let engine = AutomationEngine()
    private let defaultsKey = "SensorsKit.automations"

    init() {
        load()
    }

    // MARK: lifecycle

    func beginObserving() {
        viewers += 1
        ensureTimer()
    }

    func endObserving() {
        viewers = max(0, viewers - 1)
        if viewers == 0 && !automationsActive { timer = nil }
    }

    /// Keeps polling alive even with no visible page so enabled automations
    /// keep evaluating in the background.
    func setAutomationsActive(_ active: Bool) {
        automationsActive = active
        if active { ensureTimer() }
        else if viewers == 0 { timer = nil }
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        tick()
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    // MARK: sampling

    private func tick() {
        let now = Date()
        Task.detached(priority: .utility) { [weak self] in
            let als = ALSReader.read()
            let lidDegrees = LidAngleReader.readDegrees()
            let accel = AccelReader.read()
            await MainActor.run { [weak self] in
                self?.ingest(als: als, lidDegrees: lidDegrees,
                             accel: accel, now: now)
            }
        }
    }

    private func ingest(als: ALSSnapshot?, lidDegrees: Double?,
                        accel: AccelSnapshot?, now: Date) {
        // ALS
        self.als = als
        alsAvailable = als != nil
        if let lux = als?.lux {
            luxHistory.append(lux)
            if luxHistory.count > 120 { luxHistory.removeFirst() }
        }

        // Lid + angular velocity
        lidAvailable = lidDegrees != nil
        if let degrees = lidDegrees {
            var velocity = 0.0
            if let prev = lastLidDegrees, let prevTime = lastLidTime {
                let dt = now.timeIntervalSince(prevTime)
                if dt > 0 { velocity = (degrees - prev) / dt }
            }
            lastLidDegrees = degrees
            lastLidTime = now
            lid = LidSnapshot(degrees: degrees, degreesPerSecond: velocity)
            lidHistory.append(degrees)
            if lidHistory.count > 120 { lidHistory.removeFirst() }
        } else {
            lid = nil
        }

        // Accelerometer
        accelAvailable = accel != nil
        self.accel = accel

        evaluateAutomations()
    }

    private func evaluateAutomations() {
        guard !automations.isEmpty else { return }
        var values: [SensorMetric: Double] = [:]
        if let als { values[.lux] = als.lux; als.kelvin.map { values[.kelvin] = Double($0) } }
        if let lid {
            values[.lidAngle] = lid.degrees
            values[.lidVelocity] = abs(lid.degreesPerSecond)
        }
        if let accel {
            values[.tilt] = abs(accel.pitch)
            values[.accelMagnitude] = accel.magnitude
        }
        let fired = engine.evaluate(automations, values: values)
        if !fired.isEmpty {
            events.insert(contentsOf: fired, at: 0)
            if events.count > 200 { events.removeLast(events.count - 200) }
        }
    }

    var hasEnabledAutomations: Bool { automations.contains { $0.enabled } }

    // MARK: automation CRUD

    func add(_ automation: Automation) {
        automations.append(automation)
        persist()
        refreshActivation()
    }

    func update(_ automation: Automation) {
        guard let index = automations.firstIndex(where: { $0.id == automation.id })
        else { return }
        automations[index] = automation
        engine.forget(automation.id)
        persist()
        refreshActivation()
    }

    func remove(_ automation: Automation) {
        automations.removeAll { $0.id == automation.id }
        engine.forget(automation.id)
        persist()
        refreshActivation()
    }

    func clearEvents() { events.removeAll() }

    private func refreshActivation() {
        setAutomationsActive(hasEnabledAutomations)
    }

    private func persist() {
        // Automation rules embed user-authored shell scripts — encrypt at rest.
        if let data = try? JSONEncoder().encode(automations),
           let blob = SecureStore.seal(data) {
            UserDefaults.standard.set(blob, forKey: defaultsKey)
        }
    }

    private func load() {
        if let blob = UserDefaults.standard.data(forKey: defaultsKey),
           let data = SecureStore.open(blob),
           let saved = try? JSONDecoder().decode([Automation].self, from: data) {
            automations = saved
        }
        refreshActivation()
    }
}
