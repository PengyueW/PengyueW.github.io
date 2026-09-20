import Foundation

struct ScanResult {
    let root: FileNode
    let itemCount: Int
    let deniedCount: Int
    let duration: TimeInterval
}

/// High-performance background directory crawler built on
/// FileManager (NSFileManager) and its deep DirectoryEnumerator
/// (NSDirectoryEnumerator).
///
/// - Hidden files ARE included: `.skipsHiddenFiles` is deliberately not passed,
///   so dotfiles, `~/Library/Caches`, `/Library/Caches`, and protected OS
///   structures are all enumerated (subject to TCC / Full Disk Access).
/// - Symlinks are never followed (no cycles, no double counting).
/// - Permission errors don't abort the scan; they are counted so the UI can
///   prompt the user to grant Full Disk Access.
final class DiskScanner {

    struct CancelledError: Error {}

    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Crawls `path` off the main thread. `progress` and `completion` are
    /// always delivered on the main queue.
    func scan(path: String,
              progress: @escaping (_ items: Int, _ currentPath: String) -> Void,
              completion: @escaping (Result<ScanResult, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let started = Date()
            do {
                let (root, items, denied) = try self.crawl(path: path, progress: progress)
                root.finalize()
                let result = ScanResult(root: root, itemCount: items, deniedCount: denied,
                                        duration: Date().timeIntervalSince(started))
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func crawl(path: String,
                       progress: @escaping (Int, String) -> Void) throws -> (FileNode, Int, Int) {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
        ]
        let keySet = Set(keys)

        var deniedCount = 0
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.producesRelativePathURLs],   // note: NOT .skipsHiddenFiles
            errorHandler: { _, _ in
                deniedCount += 1
                return true                         // keep crawling past protected items
            }
        ) else {
            throw NSError(domain: "DiskScope", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Cannot open \(path) for enumeration.",
            ])
        }

        let rootName = rootURL.lastPathComponent.isEmpty ? path : rootURL.lastPathComponent
        let root = FileNode(name: rootName, isDirectory: true, absolutePath: path)

        // The deep enumerator yields parents before their children, so a map of
        // relative path -> directory node lets the tree assemble in one pass.
        var directories: [String: FileNode] = ["": root, ".": root]
        var itemCount = 0

        for case let url as URL in enumerator {
            if itemCount & 1023 == 0, isCancelled { throw CancelledError() }

            let values = try? url.resourceValues(forKeys: keySet)
            let isSymlink = values?.isSymbolicLink ?? false
            let isDirectory = (values?.isDirectory ?? false) && !isSymlink
            let size: Int64
            if isDirectory {
                size = 0    // directory size = sum of children, computed in finalize()
            } else {
                size = Int64(values?.totalFileAllocatedSize
                             ?? values?.fileAllocatedSize
                             ?? values?.fileSize
                             ?? 0)
            }

            let relativePath = url.relativePath
            let parentPath = (relativePath as NSString).deletingLastPathComponent
            let node = FileNode(name: url.lastPathComponent, isDirectory: isDirectory, size: size)
            (directories[parentPath] ?? root).addChild(node)
            if isDirectory {
                directories[relativePath] = node
            }
            if isSymlink {
                enumerator.skipDescendants()
            }

            itemCount += 1
            if itemCount % 4096 == 0 {
                let current = url.path
                let count = itemCount
                DispatchQueue.main.async { progress(count, current) }
            }
        }
        return (root, itemCount, deniedCount)
    }
}
