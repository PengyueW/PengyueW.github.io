import Foundation
import IOKit

// Low-level reader for the NVMe S.M.A.R.T. log (log page 0x02) and the
// controller identify page, through IOKit's NVMeSMARTLib plug-in — the same
// route smartmontools uses on macOS. Works for Apple internal SSDs and most
// third-party NVMe enclosures that expose IONVMeBlockStorageDevice; needs no
// special privileges. Everything degrades to `nil` when the user client is
// unavailable (e.g. some USB bridges).

/// Parsed NVMe SMART / health information log.
struct NVMeSMARTLog {
    var criticalWarning: UInt8 = 0
    var temperatureKelvin: Int = 0
    var availableSparePercent: Int = 0
    var spareThresholdPercent: Int = 0
    var percentageUsed: Int = 0          // endurance estimate, can exceed 100
    var dataUnitsRead: UInt64 = 0        // 1 unit = 1000 × 512 B
    var dataUnitsWritten: UInt64 = 0
    var hostReadCommands: UInt64 = 0
    var hostWriteCommands: UInt64 = 0
    var controllerBusyMinutes: UInt64 = 0
    var powerCycles: UInt64 = 0
    var powerOnHours: UInt64 = 0
    var unsafeShutdowns: UInt64 = 0
    var mediaErrors: UInt64 = 0
    var errorLogEntries: UInt64 = 0

    var temperatureCelsius: Double { Double(temperatureKelvin) - 273.15 }
    var bytesRead: UInt64 { dataUnitsRead &* 512_000 }
    var bytesWritten: UInt64 { dataUnitsWritten &* 512_000 }

    /// Critical-warning bit meanings per the NVMe spec.
    var warnings: [String] {
        var list: [String] = []
        if criticalWarning & 0x01 != 0 { list.append("Available spare below threshold") }
        if criticalWarning & 0x02 != 0 { list.append("Temperature above threshold") }
        if criticalWarning & 0x04 != 0 { list.append("NVM subsystem reliability degraded") }
        if criticalWarning & 0x08 != 0 { list.append("Media placed in read-only mode") }
        if criticalWarning & 0x10 != 0 { list.append("Volatile memory backup failed") }
        return list
    }
}

/// Identity strings from the NVMe controller identify page.
struct NVMeIdentity {
    var model = ""
    var serial = ""
    var firmware = ""
}

enum NVMeSMARTReader {

    // NVMeSMARTLib plug-in UUIDs (from <IOKit/storage/nvme/NVMeSMARTLibExternal.h>).
    private static var userClientTypeID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil,
            0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F,
            0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
    }
    private static var smartInterfaceID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil,
            0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF,
            0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)
    }
    /// kIOCFPlugInInterfaceID — the C macro isn't imported into Swift.
    private static var plugInInterfaceID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil,
            0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
            0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    }

    /// Mirror of the head of IONVMeSMARTInterface: IUnknown guts, version
    /// fields, then the two functions we call. Field order and types must
    /// stay exactly in sync with the SDK header.
    private struct InterfaceVTable {
        var _reserved: UnsafeMutableRawPointer?
        var QueryInterface: (@convention(c) (
            UnsafeMutableRawPointer?, CFUUIDBytes,
            UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32)?
        var AddRef: (@convention(c) (UnsafeMutableRawPointer?) -> UInt32)?
        var Release: (@convention(c) (UnsafeMutableRawPointer?) -> UInt32)?
        var version: UInt16
        var revision: UInt16
        var SMARTReadData: (@convention(c) (
            UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> IOReturn)?
        var GetIdentifyData: (@convention(c) (
            UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32) -> IOReturn)?
    }

    /// Reads the SMART log and identify page from the first NVMe device.
    /// Returns nil when no device exposes the NVMe SMART user client.
    static func read() -> (log: NVMeSMARTLog, identity: NVMeIdentity)? {
        var iterator = io_iterator_t(0)
        guard IOServiceGetMatchingServices(
                  kIOMasterPortDefault,
                  IOServiceMatching("IONVMeBlockStorageDevice"),
                  &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            if let result = read(service: service) { return result }
        }
        return nil
    }

    private static func read(service: io_service_t)
        -> (log: NVMeSMARTLog, identity: NVMeIdentity)? {
        var pluginPtr: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(
                  service, userClientTypeID, plugInInterfaceID,
                  &pluginPtr, &score) == KERN_SUCCESS,
              let plugin = pluginPtr else { return nil }
        defer { IODestroyPlugInInterface(plugin) }

        var rawInterface: UnsafeMutableRawPointer?
        guard plugin.pointee?.pointee.QueryInterface(
                  UnsafeMutableRawPointer(plugin),
                  CFUUIDGetUUIDBytes(smartInterfaceID),
                  &rawInterface) == 0,
              let raw = rawInterface else { return nil }

        let iface = raw.assumingMemoryBound(
            to: UnsafeMutablePointer<InterfaceVTable>.self)
        let vtable = iface.pointee.pointee
        defer { _ = vtable.Release?(raw) }

        // SMART / health log is a fixed 512-byte structure.
        var logBuffer = [UInt8](repeating: 0, count: 512)
        let logOK = logBuffer.withUnsafeMutableBytes { buf -> Bool in
            vtable.SMARTReadData?(raw, buf.baseAddress) == KERN_SUCCESS
        }
        guard logOK else { return nil }

        // Identify-controller page is 4096 bytes; namespace 0 = controller.
        var idBuffer = [UInt8](repeating: 0, count: 4096)
        let idOK = idBuffer.withUnsafeMutableBytes { buf -> Bool in
            vtable.GetIdentifyData?(raw, buf.baseAddress, 0) == KERN_SUCCESS
        }

        return (parseLog(logBuffer),
                idOK ? parseIdentity(idBuffer) : NVMeIdentity())
    }

    // MARK: parsing

    private static func parseLog(_ b: [UInt8]) -> NVMeSMARTLog {
        func le16(_ offset: Int) -> Int {
            Int(b[offset]) | Int(b[offset + 1]) << 8
        }
        // 128-bit little-endian counters; the low 8 bytes cover any real value.
        func le64(_ offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for i in (0..<8).reversed() { value = value << 8 | UInt64(b[offset + i]) }
            return value
        }
        var log = NVMeSMARTLog()
        log.criticalWarning = b[0]
        log.temperatureKelvin = le16(1)
        log.availableSparePercent = Int(b[3])
        log.spareThresholdPercent = Int(b[4])
        log.percentageUsed = Int(b[5])
        log.dataUnitsRead = le64(32)
        log.dataUnitsWritten = le64(48)
        log.hostReadCommands = le64(64)
        log.hostWriteCommands = le64(80)
        log.controllerBusyMinutes = le64(96)
        log.powerCycles = le64(112)
        log.powerOnHours = le64(128)
        log.unsafeShutdowns = le64(144)
        log.mediaErrors = le64(160)
        log.errorLogEntries = le64(176)
        return log
    }

    private static func parseIdentity(_ b: [UInt8]) -> NVMeIdentity {
        func ascii(_ range: Range<Int>) -> String {
            String(bytes: b[range], encoding: .ascii)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        var identity = NVMeIdentity()
        identity.serial = ascii(4..<24)
        identity.model = ascii(24..<64)
        identity.firmware = ascii(64..<72)
        return identity
    }
}

/// Size of the physical whole disk backing the boot volume, via IORegistry.
enum BootDiskInfo {
    static func wholeDiskSize() -> Int64? {
        guard let matching = IOBSDNameMatching(kIOMasterPortDefault, 0, "disk0")
        else { return nil }
        let service = IOServiceGetMatchingService(kIOMasterPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let size = IORegistryEntryCreateCFProperty(
                  service, "Size" as CFString, kCFAllocatorDefault, 0)?
                  .takeRetainedValue() as? Int64 else { return nil }
        return size
    }
}
