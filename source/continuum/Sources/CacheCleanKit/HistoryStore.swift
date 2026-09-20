import Foundation

/// Persists cleaning-run history as JSON in the app's own Application Support
/// folder. Small data, so load-all/save-all is plenty.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CacheClean", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        load()
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func load() {
        guard let blob = try? Data(contentsOf: fileURL),
              let data = SecureStore.open(blob) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries),
              let blob = SecureStore.seal(data) else { return }
        try? blob.write(to: fileURL, options: .atomic)
    }
}
