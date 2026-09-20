import Foundation
import IOKit

// Minimal System Management Controller client (the classic AppleSMC user
// client used by smcFanControl/SMCKit). Reads any key, enumerates the full
// key table, and can write fan-control keys — and only fan-control keys.
//
// Writes normally require root; SMCClient surfaces kIOReturnNotPrivileged as
// a typed error so the UI can explain instead of failing silently.

/// A four-character SMC key like "TC0P" or "F0Ac".
struct SMCKey: Hashable, CustomStringConvertible {
    let code: UInt32

    init(_ name: String) {
        var value: UInt32 = 0
        for char in name.utf8.prefix(4) { value = value << 8 | UInt32(char) }
        self.code = value
    }

    init(code: UInt32) { self.code = code }

    var description: String {
        var name = ""
        for shift in stride(from: 24, through: 0, by: -8) {
            let byte = UInt8((code >> UInt32(shift)) & 0xFF)
            name.append(Character(UnicodeScalar(byte)))
        }
        return name
    }
}

/// Decoded value of one SMC key.
struct SMCValue {
    let key: SMCKey
    let typeCode: String     // "flt ", "sp78", …
    let bytes: [UInt8]

    /// Best-effort numeric decoding for the types the SMC actually uses.
    var doubleValue: Double? {
        switch typeCode {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: raw))
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 256.0
        case "ui8 ", "si8 ":
            return bytes.first.map { Double($0) }
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                          | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "ioft":
            guard bytes.count >= 8 else { return nil }
            var raw: UInt64 = 0
            for i in 0..<8 { raw = raw << 8 | UInt64(bytes[i]) }
            return Double(raw) / 65536.0
        default:
            return nil
        }
    }
}

enum SMCError: Error, LocalizedError {
    case serviceNotFound
    case notPrivileged
    case keyNotFound(String)
    case callFailed(IOReturn)

    var errorDescription: String? {
        switch self {
        case .serviceNotFound:    return "AppleSMC service not found"
        case .notPrivileged:
            return "macOS only lets root processes write SMC fan keys"
        case .keyNotFound(let k): return "SMC key \(k) not found"
        case .callFailed(let r):  return String(format: "SMC call failed (0x%08X)", r)
        }
    }
}

final class SMCClient {
    // SMCParamStruct, laid out exactly as AppleSMC expects (80 bytes).
    private struct ParamStruct {
        var key: UInt32 = 0
        var versMajor: UInt8 = 0, versMinor: UInt8 = 0, versBuild: UInt8 = 0
        var versReserved: UInt8 = 0
        var versRelease: UInt16 = 0
        var pLimitVersion: UInt16 = 0, pLimitLength: UInt16 = 0
        var pLimitCPU: UInt32 = 0, pLimitGPU: UInt32 = 0, pLimitMem: UInt32 = 0
        var keyInfoDataSize: UInt32 = 0
        var keyInfoDataType: UInt32 = 0
        var keyInfoDataAttributes: UInt8 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
               0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private enum Command: UInt8 {
        case readKey = 5
        case writeKey = 6
        case getKeyFromIndex = 8
        case getKeyInfo = 9
    }

    private static let kernelIndexSMC: UInt32 = 2   // kSMCHandleYPCEvent
    private var connection = io_connect_t(0)

    init() throws {
        let service = IOServiceGetMatchingService(
            kIOMasterPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection)
            == KERN_SUCCESS else { throw SMCError.serviceNotFound }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    private func call(_ input: inout ParamStruct) throws -> ParamStruct {
        var output = ParamStruct()
        var outputSize = MemoryLayout<ParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection, Self.kernelIndexSMC,
            &input, MemoryLayout<ParamStruct>.stride,
            &output, &outputSize)
        if result == kIOReturnNotPrivileged { throw SMCError.notPrivileged }
        guard result == kIOReturnSuccess else { throw SMCError.callFailed(result) }
        return output
    }

    private func keyInfo(_ key: SMCKey) throws -> (size: UInt32, type: UInt32) {
        var input = ParamStruct()
        input.key = key.code
        input.data8 = Command.getKeyInfo.rawValue
        let output = try call(&input)
        guard output.result == 0 else { throw SMCError.keyNotFound(key.description) }
        return (output.keyInfoDataSize, output.keyInfoDataType)
    }

    func read(_ key: SMCKey) throws -> SMCValue {
        let info = try keyInfo(key)
        var input = ParamStruct()
        input.key = key.code
        input.keyInfoDataSize = info.size
        input.data8 = Command.readKey.rawValue
        let output = try call(&input)
        guard output.result == 0 else { throw SMCError.keyNotFound(key.description) }

        var bytes: [UInt8] = []
        withUnsafeBytes(of: output.bytes) { raw in
            bytes = Array(raw.prefix(Int(min(info.size, 32))))
        }
        return SMCValue(key: key, typeCode: typeString(info.type), bytes: bytes)
    }

    func readDouble(_ name: String) -> Double? {
        (try? read(SMCKey(name)))?.doubleValue
    }

    /// All keys in the SMC's table (via #KEY count + index lookups).
    func allKeys() -> [SMCKey] {
        guard let count = readDouble("#KEY").map({ Int($0) }), count > 0,
              count < 8192 else { return [] }
        var keys: [SMCKey] = []
        for index in 0..<count {
            var input = ParamStruct()
            input.data8 = Command.getKeyFromIndex.rawValue
            input.data32 = UInt32(index)
            if let output = try? call(&input), output.result == 0 {
                keys.append(SMCKey(code: output.key))
            }
        }
        return keys
    }

    /// Writes a fan key. Restricted by name pattern so no other SMC state can
    /// ever be touched from this app: only F<d>Tg / F<d>Md (+ legacy "FS! ").
    func writeFanKey(_ name: String, bytes: [UInt8]) throws {
        let isFanKey = name == "FS! "
            || (name.count == 4 && name.hasPrefix("F")
                && (name.hasSuffix("Tg") || name.hasSuffix("Md")))
        guard isFanKey else { throw SMCError.keyNotFound(name) }

        let key = SMCKey(name)
        let info = try keyInfo(key)
        var input = ParamStruct()
        input.key = key.code
        input.keyInfoDataSize = info.size
        input.data8 = Command.writeKey.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for (i, byte) in bytes.prefix(32).enumerated() { raw[i] = byte }
        }
        let output = try call(&input)
        guard output.result == 0 else {
            throw SMCError.callFailed(IOReturn(output.result))
        }
    }

    private func typeString(_ type: UInt32) -> String {
        var name = ""
        for shift in stride(from: 24, through: 0, by: -8) {
            name.append(Character(UnicodeScalar(UInt8((type >> UInt32(shift)) & 0xFF))))
        }
        return name
    }
}

// MARK: - High-level thermal & fan snapshot

/// One named temperature reading.
struct ThermalSensor: Identifiable {
    let id: String        // SMC key
    let label: String
    let celsius: Double
}

/// One fan's full state.
struct FanState: Identifiable {
    let id: Int
    var actualRPM: Double
    var targetRPM: Double
    var minRPM: Double
    var maxRPM: Double
}

enum SMCThermal {
    /// Friendly labels for common key prefixes (Intel + Apple Silicon).
    private static let prefixLabels: [(String, String)] = [
        ("TC", "CPU"), ("Tp", "CPU core"), ("Te", "CPU efficiency"),
        ("Tf", "CPU performance"), ("TG", "GPU"), ("Tg", "GPU"),
        ("TM", "Memory"), ("Tm", "Mainboard"), ("TB", "Battery"),
        ("Tb", "Battery"), ("TH", "SSD"), ("TN", "SSD"),
        ("TA", "Airflow"), ("Ts", "Skin"), ("TW", "Wireless"),
        ("TI", "Thunderbolt"), ("TD", "Display"), ("TL", "Display"),
        ("Th", "Heatpipe"), ("TS", "Skin"),
    ]

    static func label(for key: String) -> String {
        for (prefix, label) in prefixLabels where key.hasPrefix(prefix) {
            return "\(label) (\(key))"
        }
        return key
    }

    /// Reads every plausible temperature key (prefix "T", sane 0–125 °C value).
    static func sensors(client: SMCClient, keys: [SMCKey]) -> [ThermalSensor] {
        var sensors: [ThermalSensor] = []
        for key in keys {
            let name = key.description
            guard name.hasPrefix("T") else { continue }
            guard let value = (try? client.read(key))?.doubleValue,
                  value > 1, value < 125 else { continue }
            sensors.append(ThermalSensor(id: name, label: label(for: name),
                                         celsius: value))
        }
        return sensors.sorted { $0.celsius > $1.celsius }
    }

    /// Enumerates the fans the SMC exposes.
    ///
    /// "FNum" is the documented fan count, but it is not dependable: some Macs
    /// publish it with a type this decoder does not recognise, some report 0
    /// while the per-fan keys are perfectly readable, and on others the key is
    /// absent entirely. Trusting it alone meant a machine with a working fan
    /// reported none at all — the whole Thermal & Fans page came up empty on
    /// hardware that plainly has a fan.
    ///
    /// So FNum is now a hint, not a gate: whatever it says, the per-fan speed
    /// keys F0Ac…F7Ac are probed directly and any fan that answers is
    /// included. A machine with genuinely no fan (Apple silicon MacBook Air,
    /// most iMacs' secondary index) answers nothing and still yields [].
    static func fans(client: SMCClient) -> [FanState] {
        let hinted = client.readDouble("FNum").map({ Int($0) }) ?? 0
        let probeCount = (hinted > 0 && hinted <= 8) ? hinted : 8

        var fans: [FanState] = []
        for i in 0..<probeCount {
            // A fan exists if its actual-speed key reads back at all. Zero is a
            // legitimate reading (a fan that is currently stopped), so presence
            // is decided by the key resolving, never by the value being > 0.
            guard let actual = client.readDouble("F\(i)Ac") else { continue }
            let maxRPM = client.readDouble("F\(i)Mx") ?? 0
            let minRPM = client.readDouble("F\(i)Mn") ?? 0
            // Some SMCs keep a placeholder index whose keys read as all-zero.
            // Without a plausible maximum there is nothing to display or drive,
            // so treat that as "not a fan" rather than showing a dead row.
            guard maxRPM > 0 || actual > 0 else { continue }
            fans.append(FanState(id: i,
                                 actualRPM: actual,
                                 targetRPM: client.readDouble("F\(i)Tg") ?? 0,
                                 minRPM: minRPM,
                                 maxRPM: maxRPM))
        }
        return fans
    }

    /// Sets one fan's target RPM: forced mode + target, clamped to min/max.
    /// The target key is "flt " (LE float) on Apple Silicon and "fpe2"
    /// (BE fixed-point) on Intel; encode to whatever the SMC reports.
    static func setFan(client: SMCClient, fan: FanState, targetRPM: Double) throws {
        let clamped = min(max(targetRPM, fan.minRPM), fan.maxRPM)
        let targetKey = "F\(fan.id)Tg"
        let typeCode = (try? client.read(SMCKey(targetKey)))?.typeCode ?? "flt "

        try client.writeFanKey("F\(fan.id)Md", bytes: [1])
        let bytes: [UInt8]
        if typeCode == "fpe2" {
            let raw = UInt16(clamped * 4)
            bytes = [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        } else {
            let raw = Float(clamped).bitPattern
            bytes = [UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF),
                     UInt8((raw >> 16) & 0xFF), UInt8((raw >> 24) & 0xFF)]
        }
        try client.writeFanKey(targetKey, bytes: bytes)
    }

    /// Returns fan control to the SMC's own automatic management.
    static func setFanAutomatic(client: SMCClient, fanID: Int) throws {
        try client.writeFanKey("F\(fanID)Md", bytes: [0])
    }
}
