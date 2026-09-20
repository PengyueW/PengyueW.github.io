import Foundation
import Combine

/// One point of a user fan curve: at `celsius`, run the fan at `fraction`
/// of its min→max RPM range.
struct FanCurvePoint: Codable, Identifiable, Equatable {
    var id = UUID()
    var celsius: Double
    var fraction: Double          // 0…1
}

/// A user-defined fan curve, applied to every fan.
struct FanCurve: Codable, Equatable {
    var points: [FanCurvePoint] = [
        FanCurvePoint(celsius: 50, fraction: 0.0),
        FanCurvePoint(celsius: 70, fraction: 0.5),
        FanCurvePoint(celsius: 85, fraction: 1.0),
    ]

    /// Linear interpolation over the sorted points.
    func fraction(at celsius: Double) -> Double {
        let sorted = points.sorted { $0.celsius < $1.celsius }
        guard let first = sorted.first, let last = sorted.last else { return 0 }
        if celsius <= first.celsius { return first.fraction }
        if celsius >= last.celsius { return last.fraction }
        for (a, b) in zip(sorted, sorted.dropFirst()) where celsius <= b.celsius {
            let span = b.celsius - a.celsius
            guard span > 0 else { return b.fraction }
            let t = (celsius - a.celsius) / span
            return a.fraction + (b.fraction - a.fraction) * t
        }
        return last.fraction
    }
}

/// Timestamped record of a USB-PD negotiation change.
struct AdapterLogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
}

/// Shared model for the three hardware pages: Thermal & Fans, Battery,
/// Power & Peripherals. Polls only while a page is visible.
@MainActor
final class HardwareModel: ObservableObject {
    // Thermal & fans
    @Published var sensors: [ThermalSensor] = []
    @Published var fans: [FanState] = []
    @Published var smcErrorDescription: String?
    @Published var fanControlError: String?
    @Published var curve = FanCurve() { didSet { persistCurve() } }
    @Published var curveEnabled = false { didSet { curveEnabledChanged() } }

    // Battery & adapter
    @Published var battery = BatterySnapshot()
    @Published var adapter = AdapterSnapshot()
    @Published var adapterLog: [AdapterLogEntry] = []
    @Published var wattHistory: [Double] = []      // last ~120 samples

    // Peripherals
    @Published var peripherals: [PeripheralDevice] = []
    @Published var isLoadingPeripherals = false

    private var client: SMCClient?
    private var smcKeys: [SMCKey] = []
    private var timer: AnyCancellable?
    private var viewers = 0
    private var lastAdapterSignature = ""
    private let curveDefaultsKey = "HardwareKit.fanCurve"

    init() {
        if let data = UserDefaults.standard.data(forKey: curveDefaultsKey),
           let saved = try? JSONDecoder().decode(FanCurve.self, from: data) {
            curve = saved
        }
    }

    // MARK: lifecycle

    /// Pages call this on appear/disappear; polling runs while any is visible.
    func beginObserving() {
        viewers += 1
        guard timer == nil else { return }
        openSMCIfNeeded()
        tick()
        timer = Timer.publish(every: 3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    func endObserving() {
        viewers = max(0, viewers - 1)
        if viewers == 0 && !curveEnabled {
            timer = nil
        }
    }

    private func openSMCIfNeeded() {
        guard client == nil else { return }
        do {
            let smc = try SMCClient()
            client = smc
            smcErrorDescription = nil
            Task.detached(priority: .utility) { [weak self] in
                let keys = smc.allKeys()
                await MainActor.run { [weak self] in self?.smcKeys = keys }
            }
        } catch {
            smcErrorDescription = error.localizedDescription
        }
    }

    private func tick() {
        if let client {
            if !smcKeys.isEmpty {
                let keys = smcKeys
                Task.detached(priority: .utility) { [weak self] in
                    let sensors = SMCThermal.sensors(client: client, keys: keys)
                    let fans = SMCThermal.fans(client: client)
                    await MainActor.run { [weak self] in
                        self?.sensors = sensors
                        self?.fans = fans
                    }
                    await self?.applyCurveIfEnabled(fans: fans, sensors: sensors)
                }
            }
        }
        refreshBattery()
    }

    // MARK: fan curve

    var hottestCPUTemp: Double? {
        let cpu = sensors.filter {
            $0.label.hasPrefix("CPU") || $0.id.hasPrefix("Tp")
                || $0.id.hasPrefix("TC")
        }
        return (cpu.isEmpty ? sensors : cpu).map(\.celsius).max()
    }

    private func curveEnabledChanged() {
        if curveEnabled {
            beginObserving()        // keep polling alive for the engine
            viewers -= 1            // …without counting as a page viewer
        } else {
            restoreAutomaticFans()
        }
    }

    private func applyCurveIfEnabled(fans: [FanState],
                                     sensors: [ThermalSensor]) {
        guard curveEnabled, let client else { return }
        let temp = hottestCPUTemp ?? sensors.first?.celsius ?? 0
        let fraction = curve.fraction(at: temp)
        for fan in fans {
            let target = fan.minRPM + (fan.maxRPM - fan.minRPM) * fraction
            do {
                try SMCThermal.setFan(client: client, fan: fan, targetRPM: target)
                fanControlError = nil
            } catch SMCError.notPrivileged {
                fanControlError = "macOS only allows root processes to change "
                    + "fan targets. The curve is shown but can’t be applied; "
                    + "run Continuum with sudo to enable writes."
                curveEnabled = false
                return
            } catch {
                fanControlError = error.localizedDescription
            }
        }
    }

    func restoreAutomaticFans() {
        guard let client else { return }
        for fan in fans {
            try? SMCThermal.setFanAutomatic(client: client, fanID: fan.id)
        }
    }

    private func persistCurve() {
        if let data = try? JSONEncoder().encode(curve) {
            UserDefaults.standard.set(data, forKey: curveDefaultsKey)
        }
    }

    // MARK: battery / adapter

    private func refreshBattery() {
        Task.detached(priority: .utility) { [weak self] in
            let (battery, adapter) = SmartBatteryReader.read()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.battery = battery
                self.adapter = adapter
                self.wattHistory.append(battery.watts)
                if self.wattHistory.count > 120 { self.wattHistory.removeFirst() }
                self.logAdapterChange(adapter)
            }
        }
    }

    private func logAdapterChange(_ adapter: AdapterSnapshot) {
        let signature = adapter.connected
            ? "\(adapter.name)|\(adapter.watts)|\(adapter.voltage)|\(adapter.current)"
            : "disconnected"
        guard signature != lastAdapterSignature else { return }
        // Skip the very first observation so opening the page logs nothing.
        let isFirst = lastAdapterSignature.isEmpty
        lastAdapterSignature = signature
        guard !isFirst else { return }

        let message: String
        if adapter.connected {
            let name = adapter.name.isEmpty ? "Charger" : adapter.name
            message = String(format:
                "%@ negotiated %.1f V × %.2f A (%.0f W contract, %.0f W max offered)",
                name, adapter.voltage, adapter.current, adapter.watts,
                adapter.maxOfferedWatts)
        } else {
            message = "Charger disconnected"
        }
        adapterLog.insert(AdapterLogEntry(date: Date(), message: message), at: 0)
        if adapterLog.count > 200 { adapterLog.removeLast() }
    }

    // MARK: peripherals

    func refreshPeripherals() {
        guard !isLoadingPeripherals else { return }
        isLoadingPeripherals = true
        Task.detached(priority: .utility) { [weak self] in
            let devices = PeripheralPowerReader.read()
            await MainActor.run { [weak self] in
                self?.peripherals = devices
                self?.isLoadingPeripherals = false
            }
        }
    }
}
