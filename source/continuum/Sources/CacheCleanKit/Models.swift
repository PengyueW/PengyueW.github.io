import Foundation

// MARK: - Categories

/// Every kind of reclaimable space the app knows about.
/// The raw value doubles as a stable identifier for persistence.
enum CleanCategory: String, CaseIterable, Identifiable, Codable {
    case userCaches      = "user-caches"
    case logs            = "logs"
    case derivedData     = "derived-data"
    case brokenSymlinks  = "broken-symlinks"
    case orphanedSupport = "orphaned-support"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .userCaches:      return "User Caches"
        case .logs:            return "Logs"
        case .derivedData:     return "Xcode Derived Data"
        case .brokenSymlinks:  return "Broken Symlinks"
        case .orphanedSupport: return "Orphaned App Support"
        }
    }

    var systemImage: String {
        switch self {
        case .userCaches:      return "archivebox"
        case .logs:            return "doc.text"
        case .derivedData:     return "hammer"
        case .brokenSymlinks:  return "link.badge.plus"
        case .orphanedSupport: return "questionmark.folder"
        }
    }

    var detail: String {
        switch self {
        case .userCaches:
            return "App caches in ~/Library/Caches. Apps rebuild these automatically."
        case .logs:
            return "Diagnostic logs in ~/Library/Logs. Safe to remove unless you are debugging."
        case .derivedData:
            return "Xcode build intermediates. Xcode regenerates them on the next build."
        case .brokenSymlinks:
            return "Symbolic links inside the scanned folders whose targets no longer exist."
        case .orphanedSupport:
            return "Support folders left behind by known apps that are no longer installed."
        }
    }
}

// MARK: - Scan results

/// One deletable thing found by the scanner. Value type, immutable facts only;
/// the user's keep/delete choice lives in the UI layer (AppState.selection).
struct ScanItem: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let category: CleanCategory
    /// Allocated size in bytes (0 for broken symlinks — they occupy ~nothing,
    /// but removing them still de-clutters the directory tree).
    let sizeBytes: Int64
    let isDirectory: Bool

    init(url: URL, category: CleanCategory, sizeBytes: Int64, isDirectory: Bool) {
        self.id = UUID()
        self.url = url
        self.category = category
        self.sizeBytes = sizeBytes
        self.isDirectory = isDirectory
    }

    var displayName: String { url.lastPathComponent }
    var displayPath: String { url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
}

/// Streamed from the scanner so the UI can animate progress.
struct ScanProgress {
    var currentPath: String
    /// 0…1. Coarse: fraction of top-level scan roots completed.
    var fraction: Double
    var itemsFound: Int
    var bytesFound: Int64
}

// MARK: - Cleaning report

struct SkippedItem: Identifiable {
    let id = UUID()
    let path: String
    let reason: String
}

struct CleaningReport {
    var trashedCount = 0
    var removedSymlinkCount = 0
    var bytesReclaimed: Int64 = 0
    var skipped: [SkippedItem] = []
}

// MARK: - History

struct HistoryEntry: Identifiable, Codable {
    var id: UUID = UUID()
    var date: Date
    var bytesReclaimed: Int64
    var itemCount: Int
    var skippedCount: Int
    var note: String
}

// MARK: - Formatting helpers

extension Int64 {
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
