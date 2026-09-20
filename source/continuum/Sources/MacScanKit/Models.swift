import SwiftUI

// MARK: - Severity

/// Mirrors SEVERITY_ORDER in src/macscan/finding.py.
enum Severity: String, Codable, CaseIterable, Identifiable, Comparable {
    case critical, high, medium, review, info

    var id: String { rawValue }

    var sortRank: Int {
        switch self {
        case .critical: return 0
        case .high:     return 1
        case .medium:   return 2
        case .review:   return 3
        case .info:     return 4
        }
    }

    static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.sortRank < rhs.sortRank
    }

    var label: LocalizedStringKey { LocalizedStringKey(rawValue.capitalized) }

    var symbol: String {
        switch self {
        case .critical: return "exclamationmark.octagon.fill"
        case .high:     return "exclamationmark.triangle.fill"
        case .medium:   return "exclamationmark.circle.fill"
        case .review:   return "person.fill.questionmark"
        case .info:     return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .critical: return .red
        case .high:     return .orange
        case .medium:   return .yellow
        case .review:   return Color.compatTeal
        case .info:     return .gray
        }
    }

    /// Group blurb shown under each disclosure-group header.
    var groupDescription: LocalizedStringKey {
        switch self {
        case .critical: return "Matches a known malware family. Eligible for quarantine."
        case .high:     return "Strong heuristic match. Eligible for quarantine."
        case .medium:   return "Suspicious but plausibly benign. Review manually."
        case .review:   return "Needs human judgment — never auto-removed."
        case .info:     return "Posture and status notes."
        }
    }
}

// MARK: - Finding

/// Mirrors the Finding dataclass in src/macscan/finding.py; decoded from
/// `macscan scan --json` and re-encoded (same keys) for `macscan quarantine-json`.
struct Finding: Codable, Identifiable, Hashable {
    let id: UUID
    var severity: Severity
    var category: String
    var title: String
    var detail: String
    var paths: [String]
    var launchdLabel: String
    var launchdDomain: String
    var removable: Bool
    var remediation: String

    private enum CodingKeys: String, CodingKey {
        case severity, category, title, detail, paths, removable, remediation
        case launchdLabel = "launchd_label"
        case launchdDomain = "launchd_domain"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        let rawSeverity = (try? c.decode(String.self, forKey: .severity)) ?? "info"
        severity = Severity(rawValue: rawSeverity) ?? .info
        category = (try? c.decode(String.self, forKey: .category)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? "(untitled finding)"
        detail = (try? c.decode(String.self, forKey: .detail)) ?? ""
        paths = (try? c.decode([String].self, forKey: .paths)) ?? []
        launchdLabel = (try? c.decode(String.self, forKey: .launchdLabel)) ?? ""
        launchdDomain = (try? c.decode(String.self, forKey: .launchdDomain)) ?? ""
        removable = (try? c.decode(Bool.self, forKey: .removable)) ?? false
        remediation = (try? c.decode(String.self, forKey: .remediation)) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(severity.rawValue, forKey: .severity)
        try c.encode(category, forKey: .category)
        try c.encode(title, forKey: .title)
        try c.encode(detail, forKey: .detail)
        try c.encode(paths, forKey: .paths)
        try c.encode(launchdLabel, forKey: .launchdLabel)
        try c.encode(launchdDomain, forKey: .launchdDomain)
        try c.encode(removable, forKey: .removable)
        try c.encode(remediation, forKey: .remediation)
    }

    /// Mirrors the eligibility filter in quarantine.run_removal — the Python
    /// side re-checks this, but the UI must not even offer the button otherwise.
    var isQuarantineEligible: Bool {
        removable && !paths.isEmpty && (severity == .critical || severity == .high)
    }
}

// MARK: - Scan tiers

enum ScanTier: String, CaseIterable, Identifiable, Codable {
    case standard, deep, forensic

    var id: String { rawValue }

    var arguments: [String] {
        switch self {
        case .standard: return []
        case .deep:     return ["--deep"]
        case .forensic: return ["--forensic"]
        }
    }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .deep:     return "Deep"
        case .forensic: return "Forensic"
        }
    }

    var symbol: String {
        switch self {
        case .standard: return "bolt.shield"
        case .deep:     return "magnifyingglass.circle"
        case .forensic: return "stethoscope"
        }
    }

    var duration: LocalizedStringKey {
        switch self {
        case .standard: return "≈ 30 seconds"
        case .deep:     return "1–3 minutes"
        case .forensic: return "5–15 minutes"
        }
    }

    var privileges: LocalizedStringKey {
        switch self {
        case .standard: return "No special privileges"
        case .deep:     return "Root improves coverage (Background Task Management)"
        case .forensic: return "Best with Full Disk Access; gaps become blind spots"
        }
    }

    var scope: LocalizedStringKey {
        switch self {
        case .standard:
            return "System posture, launchd & cron persistence, running processes, known malware artifacts, privacy permissions, browser hijacks."
        case .deep:
            return "Everything in Standard, plus login items, listening ports, /Applications signature sweep, browser extensions, live sockets."
        case .forensic:
            return "Anti-spyware engine (Pegasus/Reign-class): IoC triage, system-binary integrity, Unified Log analysis, injection & boot/kernel checks, cryptographic state manifest. Read-only by design."
        }
    }
}

// MARK: - Quarantine records (read from ~/.macscan/quarantine/<id>/manifest.json)

struct QuarantineRecord: Codable, Identifiable, Hashable {
    struct Item: Codable, Hashable {
        var original: String
        var stored: String
    }

    var id: String
    var time: String
    var title: String
    var severity: String
    var launchdLabel: String
    var launchdDomain: String
    var items: [Item]

    private enum CodingKeys: String, CodingKey {
        case id, time, title, severity, items
        case launchdLabel = "launchd_label"
        case launchdDomain = "launchd_domain"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? "?"
        time = (try? c.decode(String.self, forKey: .time)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? "(unknown item)"
        severity = (try? c.decode(String.self, forKey: .severity)) ?? "?"
        launchdLabel = (try? c.decode(String.self, forKey: .launchdLabel)) ?? ""
        launchdDomain = (try? c.decode(String.self, forKey: .launchdDomain)) ?? ""
        items = (try? c.decode([Item].self, forKey: .items)) ?? []
    }

    var severityValue: Severity? { Severity(rawValue: severity) }
}

// MARK: - State manifests (read from ~/.macscan/manifests/manifest-*.json)

struct StateManifest: Codable, Identifiable, Hashable {
    struct BlindSpot: Codable, Hashable {
        var path: String
        var reason: String
    }

    var generated: String
    var host: String
    var os: String
    var user: String
    var runningAsRoot: Bool
    var filesHashed: Int
    var hashes: [String: String]
    var blindSpots: [BlindSpot]

    /// Set after decoding; identifies the manifest on disk.
    var fileName: String = ""

    var id: String { fileName.isEmpty ? generated : fileName }

    private enum CodingKeys: String, CodingKey {
        case generated, host, os, user, hashes
        case runningAsRoot = "running_as_root"
        case filesHashed = "files_hashed"
        case blindSpots = "blind_spots"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generated = (try? c.decode(String.self, forKey: .generated)) ?? "?"
        host = (try? c.decode(String.self, forKey: .host)) ?? "?"
        os = (try? c.decode(String.self, forKey: .os)) ?? "?"
        user = (try? c.decode(String.self, forKey: .user)) ?? "?"
        runningAsRoot = (try? c.decode(Bool.self, forKey: .runningAsRoot)) ?? false
        filesHashed = (try? c.decode(Int.self, forKey: .filesHashed)) ?? 0
        hashes = (try? c.decode([String: String].self, forKey: .hashes)) ?? [:]
        blindSpots = (try? c.decode([BlindSpot].self, forKey: .blindSpots)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(generated, forKey: .generated)
        try c.encode(host, forKey: .host)
        try c.encode(os, forKey: .os)
        try c.encode(user, forKey: .user)
        try c.encode(runningAsRoot, forKey: .runningAsRoot)
        try c.encode(filesHashed, forKey: .filesHashed)
        try c.encode(hashes, forKey: .hashes)
        try c.encode(blindSpots, forKey: .blindSpots)
    }

    var uniqueBlindSpotPaths: [String] {
        Array(Set(blindSpots.map(\.path))).sorted()
    }
}

// MARK: - Persisted last scan

struct ScanRecord: Codable {
    var date: Date
    var tier: ScanTier
    var exitCode: Int32
    var findings: [Finding]

    var counts: [Severity: Int] {
        findings.reduce(into: [:]) { $0[$1.severity, default: 0] += 1 }
    }
}

// MARK: - Quarantine bridge result (from `macscan quarantine-json`)

struct QuarantineBridgeResult: Codable {
    struct Entry: Codable {
        var id: String
        var title: String
    }
    struct Skipped: Codable {
        var title: String
        var reason: String
    }
    var quarantined: [Entry]
    var skipped: [Skipped]
    var errors: [String]
}
