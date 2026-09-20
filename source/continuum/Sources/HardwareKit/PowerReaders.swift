import Foundation
import IOKit

// Readers for the AppleSmartBattery IORegistry entry (battery health, live
// discharge wattage, USB-PD adapter negotiation) and for peripheral power
// draw via system_profiler's USB/Thunderbolt trees.

/// Snapshot of the battery beyond what the macOS menu shows.
struct BatterySnapshot {
    var present = false
    var cycleCount = 0
    var designCapacity = 0          // mAh
    var maxCapacity = 0             // mAh (current full-charge capacity)
    var currentCapacity = 0         // mAh
    var voltage = 0.0               // V
    var amperage = 0.0              // A, negative while discharging
    var temperature = 0.0           // °C
    var isCharging = false
    var externalConnected = false
    var serial = ""
    var manufactureDate: Date?
    var timeRemainingMinutes: Int?

    var healthPercent: Double {
        designCapacity > 0 ? Double(maxCapacity) / Double(designCapacity) * 100 : 0
    }
    var chargePercent: Double {
        maxCapacity > 0 ? Double(currentCapacity) / Double(maxCapacity) * 100 : 0
    }
    /// Signed instantaneous power: negative = discharging.
    var watts: Double { voltage * amperage }
}

/// One USB-PD profile the charger offered during negotiation.
struct PDProfile: Identifiable {
    let id: Int
    let maxVoltage: Double   // V
    let maxCurrent: Double   // A
    var maxWatts: Double { maxVoltage * maxCurrent }
}

/// The negotiated state of the connected charger.
struct AdapterSnapshot {
    var connected = false
    var name = ""
    var manufacturer = ""
    var watts = 0.0          // negotiated contract wattage
    var voltage = 0.0        // negotiated V
    var current = 0.0        // negotiated A
    var profiles: [PDProfile] = []
    var maxOfferedWatts: Double {
        max(watts, profiles.map(\.maxWatts).max() ?? 0)
    }
}

enum SmartBatteryReader {
    static func read() -> (battery: BatterySnapshot, adapter: AdapterSnapshot) {
        var battery = BatterySnapshot()
        var adapter = AdapterSnapshot()

        let service = IOServiceGetMatchingService(
            kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (battery, adapter) }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
                  service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any]
        else { return (battery, adapter) }

        func int(_ key: String) -> Int? { props[key] as? Int }

        battery.present = (props["BatteryInstalled"] as? Bool) ?? true
        battery.cycleCount = int("CycleCount") ?? 0
        battery.designCapacity = int("DesignCapacity") ?? 0
        battery.maxCapacity = int("AppleRawMaxCapacity")
            ?? int("NominalChargeCapacity") ?? int("MaxCapacity") ?? 0
        battery.currentCapacity = int("AppleRawCurrentCapacity")
            ?? int("CurrentCapacity") ?? 0
        battery.voltage = Double(int("Voltage") ?? 0) / 1000.0
        let amps = int("InstantAmperage") ?? int("Amperage") ?? 0
        battery.amperage = Double(amps) / 1000.0
        battery.temperature = Double(int("Temperature") ?? 0) / 100.0
        battery.isCharging = (props["IsCharging"] as? Bool) ?? false
        battery.externalConnected = (props["ExternalConnected"] as? Bool) ?? false
        battery.serial = (props["Serial"] as? String)
            ?? (props["BatterySerialNumber"] as? String) ?? ""
        if let minutes = int("TimeRemaining"), minutes > 0, minutes < 0xFFFF {
            battery.timeRemainingMinutes = minutes
        }
        // Intel-style packed date: bits 9-15 year-1980, 5-8 month, 0-4 day.
        if let packed = int("ManufactureDate"), packed > 0 {
            var parts = DateComponents()
            parts.year = 1980 + (packed >> 9 & 0x7F)
            parts.month = packed >> 5 & 0x0F
            parts.day = packed & 0x1F
            battery.manufactureDate = Calendar.current.date(from: parts)
        }

        if let details = props["AdapterDetails"] as? [String: Any] {
            adapter.connected = battery.externalConnected
            adapter.name = (details["Name"] as? String)
                ?? (details["Description"] as? String) ?? ""
            adapter.manufacturer = (details["Manufacturer"] as? String) ?? ""
            adapter.watts = Double(details["Watts"] as? Int ?? 0)
            adapter.voltage = Double(details["AdapterVoltage"] as? Int
                                     ?? details["Voltage"] as? Int ?? 0) / 1000.0
            adapter.current = Double(details["Current"] as? Int ?? 0) / 1000.0
            if let hvc = details["UsbHvcMenu"] as? [[String: Any]] {
                adapter.profiles = hvc.enumerated().map { index, entry in
                    PDProfile(id: (entry["Index"] as? Int) ?? index,
                              maxVoltage: Double(entry["MaxVoltage"] as? Int ?? 0) / 1000.0,
                              maxCurrent: Double(entry["MaxCurrent"] as? Int ?? 0) / 1000.0)
                }
            }
        }
        return (battery, adapter)
    }
}

// MARK: - Peripheral power draw

/// One external device hanging off USB / Thunderbolt and its bus-power draw.
struct PeripheralDevice: Identifiable {
    let id = UUID()
    let name: String
    let vendor: String
    let bus: String              // "USB" / "Thunderbolt"
    let currentRequiredMilliAmps: Int
    let currentAvailableMilliAmps: Int
    let extraOperatingCurrent: Int
}

enum PeripheralPowerReader {
    /// Parses `system_profiler SPUSBDataType -json` (and the Thunderbolt
    /// tree for device names — TB doesn't report current draw).
    static func read() -> [PeripheralDevice] {
        var devices: [PeripheralDevice] = []

        if let usb = profilerItems(dataType: "SPUSBDataType") {
            collectUSB(items: usb, into: &devices)
        }
        if let tb = profilerItems(dataType: "SPThunderboltDataType") {
            for item in tb {
                let name = (item["_name"] as? String) ?? "Thunderbolt device"
                // Skip the Mac's own root ports; keep attached devices.
                guard let children = item["_items"] as? [[String: Any]] else { continue }
                for child in children {
                    devices.append(PeripheralDevice(
                        name: (child["_name"] as? String) ?? name,
                        vendor: (child["vendor_name_key"] as? String) ?? "",
                        bus: "Thunderbolt",
                        currentRequiredMilliAmps: 0,
                        currentAvailableMilliAmps: 0,
                        extraOperatingCurrent: 0))
                }
            }
        }
        return devices
    }

    private static func profilerItems(dataType: String) -> [[String: Any]]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = [dataType, "-json", "-detailLevel", "mini"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let items = json[dataType] as? [[String: Any]] else { return nil }
        return items
    }

    private static func collectUSB(items: [[String: Any]],
                                   into devices: inout [PeripheralDevice]) {
        for item in items {
            let name = (item["_name"] as? String) ?? ""
            let required = milliAmps(item["bus_power_used"] ?? item["current_required"])
            let available = milliAmps(item["bus_power"] ?? item["current_available"])
            let extra = milliAmps(item["extra_current_used"])
            let isHubOrBus = name.localizedCaseInsensitiveContains("bus")
                || name.localizedCaseInsensitiveContains("hub")
            if required > 0 || extra > 0, !isHubOrBus {
                devices.append(PeripheralDevice(
                    name: name,
                    vendor: (item["manufacturer"] as? String) ?? "",
                    bus: "USB",
                    currentRequiredMilliAmps: required,
                    currentAvailableMilliAmps: available,
                    extraOperatingCurrent: extra))
            }
            if let children = item["_items"] as? [[String: Any]] {
                collectUSB(items: children, into: &devices)
            }
        }
    }

    private static func milliAmps(_ value: Any?) -> Int {
        if let n = value as? Int { return n }
        if let s = value as? String { return Int(s) ?? 0 }
        return 0
    }
}
