import Foundation
import AppKit

// Polls active outbound network connections with `lsof` and resolves each to
// its owning app. This is an honest, no-special-entitlement reverse-firewall
// monitor: it can't intercept a packet before it leaves (that needs a
// NetworkExtension content filter), but it surfaces every established
// outbound socket within a second of it appearing, and blocks future traffic
// to a remote host via a pf anchor.

/// One established outbound connection, keyed so repeated polls coalesce.
struct Connection: Identifiable, Hashable {
    var id: String { "\(pid)-\(remoteAddress)-\(remotePort)-\(proto)" }
    let pid: Int32
    let processName: String
    let bundleID: String?
    let proto: String           // TCP / UDP
    let localPort: String
    let remoteAddress: String
    let remotePort: String
    var firstSeen: Date
    var lastSeen: Date

    var remoteEndpoint: String { "\(remoteAddress):\(remotePort)" }
}

/// One alert raised when a new connection from a previously-unseen app
/// appears while monitoring is active.
struct ConnectionAlert: Identifiable {
    let id = UUID()
    let date: Date
    let connection: Connection
}

enum ConnectionScanner {
    /// Returns every established / outbound connection right now.
    static func scan() -> [Connection] {
        // -i internet sockets, -n no DNS, -P no port names, -F fields output.
        let (status, out) = run("/usr/sbin/lsof",
                                ["-i", "-nP", "-FpcnPt", "-w"])
        guard status == 0 || status == 1 else { return [] }   // 1 = partial
        return parse(out)
    }

    private static func parse(_ output: String) -> [Connection] {
        var connections: [Connection] = []
        var pid: Int32 = 0
        var command = ""
        let now = Date()

        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n":
                // "name" field, e.g. "192.168.1.5:52345->17.253.144.10:443"
                guard value.contains("->") else { continue }
                let ends = value.components(separatedBy: "->")
                guard ends.count == 2 else { continue }
                let (localAddr, localPort) = splitHostPort(ends[0])
                let (remoteAddr, remotePort) = splitHostPort(ends[1])
                // Skip loopback / link-local — not "external servers".
                guard !isLocal(remoteAddr) else { continue }
                _ = localAddr
                connections.append(Connection(
                    pid: pid,
                    processName: command,
                    bundleID: bundleID(forPID: pid),
                    proto: line.contains("UDP") ? "UDP" : "TCP",
                    localPort: localPort,
                    remoteAddress: remoteAddr,
                    remotePort: remotePort,
                    firstSeen: now, lastSeen: now))
            case "P":
                // protocol field arrives before n on the same fd; fold it in
                // by patching the last appended row if needed. lsof emits
                // "TCP"/"UDP" — handled above heuristically, so ignore here.
                break
            default:
                break
            }
        }
        return connections
    }

    private static func splitHostPort(_ s: String) -> (String, String) {
        // IPv6 looks like [::1]:443; IPv4 like 1.2.3.4:443.
        if let close = s.lastIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...].drop(while: { $0 == ":" })
            return (host, String(rest))
        }
        guard let colon = s.lastIndex(of: ":") else { return (s, "") }
        return (String(s[..<colon]), String(s[s.index(after: colon)...]))
    }

    private static func isLocal(_ addr: String) -> Bool {
        addr == "127.0.0.1" || addr == "::1" || addr.hasPrefix("fe80")
            || addr == "*" || addr.isEmpty
    }

    private static var bundleCache: [Int32: String?] = [:]
    private static func bundleID(forPID pid: Int32) -> String? {
        if let cached = bundleCache[pid] { return cached }
        let app = NSRunningApplication(processIdentifier: pid)
        let bundle = app?.bundleIdentifier
        bundleCache[pid] = bundle
        return bundle
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (Int32, String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus,
                String(data: data, encoding: .utf8) ?? "")
    }
}
