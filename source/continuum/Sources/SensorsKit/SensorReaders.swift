import Foundation
import IOKit
import IOKit.hid

// Readers for the three onboard sensors this division exposes. Each is
// best-effort: the hardware differs wildly across Mac models, so every reader
// returns an optional snapshot and the model surfaces an availability state
// the UI can explain rather than pretending a value exists.

/// Ambient light: illuminance plus a derived colour estimate.
struct ALSSnapshot {
    var lux: Double
    var kelvin: Int?            // correlated colour temperature, if channels exist
    var rgb: (r: Double, g: Double, b: Double)?   // normalised 0…1 per channel
    var rawChannels: [Double]   // whatever the sensor reported
}

/// Lid angle in degrees plus the angular velocity from the previous sample.
struct LidSnapshot {
    var degrees: Double
    var degreesPerSecond: Double
}

/// Accelerometer: gravity vector (g), derived tilt, magnitude.
struct AccelSnapshot {
    var x: Double
    var y: Double
    var z: Double

    var magnitude: Double { (x * x + y * y + z * z).squareRoot() }
    /// Pitch / roll in degrees from the gravity vector.
    var pitch: Double { atan2(-y, (x * x + z * z).squareRoot()) * 180 / .pi }
    var roll: Double { atan2(x, z) * 180 / .pi }
}

// MARK: - Ambient Light Sensor

enum ALSReader {
    /// Apple's light sensor exposes a kIOHIDEventTypeAmbientLightSensor event;
    /// the legacy AppleLMUController service returns a 2-element lux array.
    /// We try the service-property route first (works without an event tap).
    static func read() -> ALSSnapshot? {
        guard let channels = lmuChannels(), let first = channels.first else {
            return nil
        }
        // The LMU reports raw counts; Apple's own scaling is undocumented.
        // Convert to an approximate lux with a commonly-used linear factor and
        // keep the raw channels for the spectrum view.
        let lux = first * 0.0625
        var snapshot = ALSSnapshot(lux: lux, kelvin: nil, rgb: nil,
                                   rawChannels: channels)

        // Some sensors expose 3+ colour channels; if so, derive an RGB ratio
        // and a rough correlated colour temperature.
        if channels.count >= 3 {
            let total = max(channels[0] + channels[1] + channels[2], 1)
            let r = channels[0] / total
            let g = channels[1] / total
            let b = channels[2] / total
            snapshot.rgb = (r, g, b)
            snapshot.kelvin = correlatedColorTemperature(r: r, g: g, b: b)
        }
        return snapshot
    }

    private static func lmuChannels() -> [Double]? {
        let service = IOServiceGetMatchingService(
            kIOMasterPortDefault, IOServiceMatching("AppleLMUController"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connect)
            == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connect) }

        var outputs: [UInt64] = [0, 0]
        var outputCount: UInt32 = 2
        // Selector 0 of the LMU user client = read lux pair.
        guard IOConnectCallMethod(connect, 0, nil, 0, nil, 0,
                                  &outputs, &outputCount, nil, nil)
            == KERN_SUCCESS else { return nil }
        return Array(outputs.prefix(Int(outputCount))).map(Double.init)
    }

    /// McCamy's approximation, fed a normalised RGB estimate. Rough — the
    /// label in the UI calls it an estimate.
    private static func correlatedColorTemperature(r: Double, g: Double,
                                                    b: Double) -> Int {
        let X = 0.4124 * r + 0.3576 * g + 0.1805 * b
        let Y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let Z = 0.0193 * r + 0.1192 * g + 0.9505 * b
        let denom = X + Y + Z
        guard denom > 0 else { return 0 }
        let x = X / denom, y = Y / denom
        let n = (x - 0.3320) / (0.1858 - y)
        let cct = 449 * pow(n, 3) + 3525 * pow(n, 2) + 6823.3 * n + 5520.33
        return max(1000, min(40000, Int(cct)))
    }
}

// MARK: - HID sensor base (lid angle + accelerometer)

/// Shared helper to pull the latest report from an Apple sensor HID device by
/// usage page / usage, returning the raw report bytes.
enum HIDSensorReader {
    static func firstReport(usagePage: UInt32, usage: UInt32) -> [UInt8]? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault,
                                         IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: usagePage,
            kIOHIDDeviceUsageKey as String: usage,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            == kIOReturnSuccess else { return nil }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first else { return nil }

        let reportSize = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64
        var report = [UInt8](repeating: 0, count: max(reportSize, 8))
        var length = report.count
        let result = report.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1,
                                 buf.baseAddress!, &length)
        }
        guard result == kIOReturnSuccess else { return nil }
        return Array(report.prefix(length))
    }
}

// MARK: - Lid angle

enum LidAngleReader {
    // Apple's lid-angle sensor lives behind a sensor-usage HID device
    // (usage page 0x20 "Sensors", lid-angle usage). Report layout: a
    // little-endian UInt16 angle in degrees after a 1-byte report id.
    private static let usagePage: UInt32 = 0x20
    private static let usage: UInt32 = 0x8A      // lid-angle sensor usage

    static func readDegrees() -> Double? {
        guard let report = HIDSensorReader.firstReport(usagePage: usagePage,
                                                       usage: usage),
              report.count >= 3 else { return nil }
        let raw = UInt16(report[1]) | UInt16(report[2]) << 8
        let degrees = Double(raw)
        guard degrees >= 0, degrees <= 360 else { return nil }
        return min(180, degrees)
    }
}

// MARK: - Accelerometer (SMS / device-management)

enum AccelReader {
    /// Apple's Sudden Motion Sensor user client (Intel) and equivalents
    /// return a signed 3-axis vector; we normalise to g (≈256 counts/g on the
    /// classic SMS).
    static func read() -> AccelSnapshot? {
        let service = IOServiceGetMatchingService(
            kIOMasterPortDefault, IOServiceMatching("SMCMotionSensor"))
            .nonZeroOr(IOServiceGetMatchingService(
                kIOMasterPortDefault, IOServiceMatching("AppleSMCMotionSensor")))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connect)
            == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connect) }

        // Selector 5 = read motion data on the classic SMS user client.
        var input: UInt64 = 0
        var output = [UInt8](repeating: 0, count: 40)
        var outSize = output.count
        let result = output.withUnsafeMutableBufferPointer { buf in
            IOConnectCallStructMethod(connect, 5, &input,
                                      MemoryLayout<UInt64>.size,
                                      buf.baseAddress, &outSize)
        }
        guard result == kIOReturnSuccess, outSize >= 6 else { return nil }

        func axis(_ offset: Int) -> Double {
            let raw = Int16(bitPattern: UInt16(output[offset])
                            | UInt16(output[offset + 1]) << 8)
            return Double(raw) / 256.0
        }
        return AccelSnapshot(x: axis(0), y: axis(2), z: axis(4))
    }
}

private extension io_service_t {
    /// Falls back to `alternative` when this service handle is null.
    func nonZeroOr(_ alternative: @autoclosure () -> io_service_t) -> io_service_t {
        self != 0 ? self : alternative()
    }
}
