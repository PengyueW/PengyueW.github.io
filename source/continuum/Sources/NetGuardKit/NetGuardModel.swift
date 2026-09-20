import Foundation
import Combine
import AppKit

/// Reverse-firewall model: polls outbound connections, coalesces them by
/// endpoint, raises alerts for newly-seen apps, and drives the pf block list.
@MainActor
final class NetGuardModel: ObservableObject {
    @Published var connections: [Connection] = []
    @Published var alerts: [ConnectionAlert] = []
    @Published var isMonitoring = false
    @Published var alertOnNewApps = true
    let firewall = Firewall()

    private var timer: AnyCancellable?
    private var seenApps = Set<String>()
    private var firstScan = true
    private var firewallForward: AnyCancellable?

    init() {
        firewallForward = firewall.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var connectionsByApp: [(app: String, bundleID: String?, conns: [Connection])] {
        var groups: [String: [Connection]] = [:]
        for conn in connections {
            groups[conn.processName, default: []].append(conn)
        }
        return groups
            .map { (app: $0.key, bundleID: $0.value.first?.bundleID,
                    conns: $0.value.sorted { $0.lastSeen > $1.lastSeen }) }
            .sorted { $0.conns.count > $1.conns.count }
    }

    func toggleMonitoring() {
        isMonitoring ? stop() : start()
    }

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        firstScan = true
        tick()
        timer = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    func stop() {
        isMonitoring = false
        timer = nil
    }

    private func tick() {
        Task.detached(priority: .utility) {
            let fresh = ConnectionScanner.scan()
            await MainActor.run { [weak self] in
                self?.merge(fresh)
            }
        }
    }

    private func merge(_ fresh: [Connection]) {
        var byID: [String: Connection] = [:]
        for old in connections { byID[old.id] = old }

        var merged: [Connection] = []
        var newlySeenApps: [Connection] = []
        for var conn in fresh {
            if let existing = byID[conn.id] {
                conn.firstSeen = existing.firstSeen
                merged.append(conn)
            } else {
                merged.append(conn)
                if !seenApps.contains(conn.processName) {
                    newlySeenApps.append(conn)
                }
            }
            seenApps.insert(conn.processName)
        }
        connections = merged.sorted { $0.lastSeen > $1.lastSeen }

        // Don't fire alerts for everything already running on first scan.
        if !firstScan && alertOnNewApps {
            for conn in newlySeenApps {
                alerts.insert(ConnectionAlert(date: Date(), connection: conn),
                              at: 0)
            }
            if alerts.count > 200 { alerts.removeLast(alerts.count - 200) }
        }
        firstScan = false
    }

    // MARK: blocking

    func block(_ conn: Connection) {
        firewall.block(host: conn.remoteAddress, note: conn.processName)
    }

    func unblock(host: String) {
        firewall.unblock(host: host)
    }

    func clearAlerts() { alerts.removeAll() }
}
