import Foundation
import Darwin

// Samples CPU, memory pressure and network throughput from the Mach/BSD APIs.
// Pure value types out; the model owns the timer and deltas.

/// One sample of the live system metrics.
struct SystemSample {
    var cpuUserPercent = 0.0
    var cpuSystemPercent = 0.0
    var cpuIdlePercent = 100.0
    var activeThreads = 0
    var logicalCores = 1

    var memUsedBytes: UInt64 = 0
    var memTotalBytes: UInt64 = 0
    /// 0…1 memory pressure (1 = fully used + compressed/wired heavy).
    var memoryPressure = 0.0

    var netInBytesPerSec: Double = 0
    var netOutBytesPerSec: Double = 0

    var cpuBusyPercent: Double { cpuUserPercent + cpuSystemPercent }
    var memUsedPercent: Double {
        memTotalBytes > 0 ? Double(memUsedBytes) / Double(memTotalBytes) * 100 : 0
    }
}

/// Stateful sampler — keeps the previous CPU ticks and network counters so
/// each `sample()` returns rates, not cumulative totals.
final class SystemMetricsSampler {
    private var prevCPUTicks: host_cpu_load_info?
    private var prevNetIn: UInt64 = 0
    private var prevNetOut: UInt64 = 0
    private var prevNetTime = Date()
    private let cores = ProcessInfo.processInfo.activeProcessorCount

    func sample() -> SystemSample {
        var s = SystemSample()
        s.logicalCores = cores
        sampleCPU(into: &s)
        sampleMemory(into: &s)
        sampleNetwork(into: &s)
        sampleThreads(into: &s)
        return s
    }

    // MARK: CPU

    private func sampleCPU(into s: inout SystemSample) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        defer { prevCPUTicks = info }
        guard let prev = prevCPUTicks else { return }

        func delta(_ idx: Int) -> Double {
            Double(ticks(info, idx)) - Double(ticks(prev, idx))
        }
        let user = delta(Int(CPU_STATE_USER))
        let system = delta(Int(CPU_STATE_SYSTEM))
        let nice = delta(Int(CPU_STATE_NICE))
        let idle = delta(Int(CPU_STATE_IDLE))
        let total = user + system + nice + idle
        guard total > 0 else { return }
        s.cpuUserPercent = (user + nice) / total * 100
        s.cpuSystemPercent = system / total * 100
        s.cpuIdlePercent = idle / total * 100
    }

    private func ticks(_ info: host_cpu_load_info, _ index: Int) -> UInt32 {
        withUnsafePointer(to: info.cpu_ticks) {
            $0.withMemoryRebound(to: UInt32.self, capacity: 4) { $0[index] }
        }
    }

    // MARK: memory

    private func sampleMemory(into s: inout SystemSample) {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        s.memTotalBytes = total

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        // "Used" in the Activity-Monitor sense: app + wired + compressed.
        s.memUsedBytes = active + wired + compressed
        // Pressure proxy: wired+compressed weigh heaviest.
        if total > 0 {
            let pressure = Double(wired + compressed + active) / Double(total)
            s.memoryPressure = min(1, pressure)
        }
    }

    // MARK: network

    private func sampleNetwork(into s: inout SystemSample) {
        var totalIn: UInt64 = 0, totalOut: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let addr = ptr {
            defer { ptr = addr.pointee.ifa_next }
            guard let ifa = addr.pointee.ifa_addr,
                  ifa.pointee.sa_family == UInt8(AF_LINK),
                  let name = addr.pointee.ifa_name else { continue }
            let ifname = String(cString: name)
            // Skip loopback; count physical + en/utun interfaces.
            guard !ifname.hasPrefix("lo") else { continue }
            if let data = addr.pointee.ifa_data?
                .assumingMemoryBound(to: if_data.self) {
                totalIn += UInt64(data.pointee.ifi_ibytes)
                totalOut += UInt64(data.pointee.ifi_obytes)
            }
        }

        let now = Date()
        let dt = now.timeIntervalSince(prevNetTime)
        defer {
            prevNetIn = totalIn
            prevNetOut = totalOut
            prevNetTime = now
        }
        guard prevNetIn > 0 || prevNetOut > 0, dt > 0 else { return }
        // Guard against counter resets (interface down/up).
        if totalIn >= prevNetIn {
            s.netInBytesPerSec = Double(totalIn - prevNetIn) / dt
        }
        if totalOut >= prevNetOut {
            s.netOutBytesPerSec = Double(totalOut - prevNetOut) / dt
        }
    }

    // MARK: threads

    private func sampleThreads(into s: inout SystemSample) {
        var count: mach_msg_type_number_t = 0
        var info = processor_info_array_t(bitPattern: 0)
        var procCount: natural_t = 0
        // We use the process count of our own task threads as a cheap proxy
        // is misleading; instead report total host threads via task list is
        // restricted. Use the run-queue length from load average instead.
        _ = info; _ = count; _ = procCount
        var loadavg = [Double](repeating: 0, count: 3)
        getloadavg(&loadavg, 3)
        // Active "threads" approximated by the 1-minute run-queue figure,
        // which is what users read as thread pressure.
        s.activeThreads = Int(loadavg[0].rounded())
    }
}
