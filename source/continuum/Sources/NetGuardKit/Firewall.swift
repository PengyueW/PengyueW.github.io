import Foundation

// Blocks outbound traffic to specific remote hosts by writing a pf anchor and
// loading it with one administrator prompt. This is the supported, reversible
// way to enforce a block without a NetworkExtension entitlement: rules live in
// a dedicated anchor file the app owns, so nothing in the system pf config is
// disturbed and "unblock all" is a single clean operation.

/// One persisted block rule.
struct BlockRule: Identifiable, Codable, Hashable {
    var id: String { host }
    let host: String            // remote IP
    let note: String            // app name it was blocking when added
    let date: Date
}

@MainActor
final class Firewall: ObservableObject {
    @Published private(set) var rules: [BlockRule] = []
    @Published var lastError: String?

    private let anchorPath = NSTemporaryDirectory() + "continuum.netguard.pf"
    private let defaultsKey = "NetGuardKit.blockRules"
    private let anchorName = "com.continuum.netguard"

    init() {
        if let blob = UserDefaults.standard.data(forKey: defaultsKey),
           let data = SecureStore.open(blob),
           let saved = try? JSONDecoder().decode([BlockRule].self, from: data) {
            rules = saved
        }
    }

    func isBlocked(_ host: String) -> Bool {
        rules.contains { $0.host == host }
    }

    func block(host: String, note: String) {
        guard !isBlocked(host) else { return }
        rules.append(BlockRule(host: host, note: note, date: Date()))
        persistAndApply()
    }

    func unblock(host: String) {
        rules.removeAll { $0.host == host }
        persistAndApply()
    }

    func unblockAll() {
        rules.removeAll()
        persistAndApply()
    }

    private func persistAndApply() {
        if let data = try? JSONEncoder().encode(rules),
           let blob = SecureStore.seal(data) {
            UserDefaults.standard.set(blob, forKey: defaultsKey)
        }
        apply()
    }

    /// Writes the anchor rules and (re)loads them via pfctl behind one admin
    /// prompt. With no rules, the anchor is flushed instead.
    private func apply() {
        let ruleText = rules
            .map { "block drop out quick to \($0.host)" }
            .joined(separator: "\n")
        do {
            try ruleText.write(toFile: anchorPath, atomically: true,
                               encoding: .utf8)
        } catch {
            lastError = "Couldn’t write the firewall anchor: \(error.localizedDescription)"
            return
        }

        // Ensure pf is enabled, register our anchor, and load it. Each step is
        // idempotent; `-e` is allowed to fail (already enabled).
        let shell = """
        /sbin/pfctl -E 2>/dev/null; \
        /sbin/pfctl -a \(anchorName) -f \(shellQuote(anchorPath))
        """
        let script = "do shell script \"\(escapeForAppleScript(shell))\" "
            + "with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            lastError = "The firewall change needs administrator approval. "
                + "(\(error["NSAppleScriptErrorMessage"] as? String ?? "cancelled"))"
        } else {
            lastError = nil
        }
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
