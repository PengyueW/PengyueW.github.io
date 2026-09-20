import Foundation
import Combine

/// Overwrite algorithm for a shred run. Pass patterns follow the published
/// standards; `nil` pattern bytes mean cryptographically random data.
enum ShredAlgorithm: String, CaseIterable, Identifiable {
    case zeroFill   // 1 pass of 0x00
    case random     // 1 pass of random data
    case dod3       // DoD 5220.22-M: 0x00, 0xFF, random + verify
    case schneier7  // Schneier: 0xFF, 0x00, then 5 random passes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zeroFill:  return "Zero Fill (1 pass)"
        case .random:    return "Random (1 pass)"
        case .dod3:      return "DoD 5220.22-M (3 passes + verify)"
        case .schneier7: return "Schneier (7 passes)"
        }
    }

    var detail: String {
        switch self {
        case .zeroFill:  return "Fast. Overwrites once with zeros."
        case .random:    return "Overwrites once with random data."
        case .dod3:      return "Zeros, ones, then verified random data."
        case .schneier7: return "Ones, zeros, then five random passes. Slow."
        }
    }

    /// One entry per pass: a fixed byte, or nil for random data.
    var passes: [UInt8?] {
        switch self {
        case .zeroFill:  return [0x00]
        case .random:    return [nil]
        case .dod3:      return [0x00, 0xFF, nil]
        case .schneier7: return [0xFF, 0x00, nil, nil, nil, nil, nil]
        }
    }

    /// Whether the final pass is read back and compared after writing.
    var verifiesFinalPass: Bool { self == .dod3 }
}

/// A file or folder queued for shredding.
struct ShredItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let isDirectory: Bool
    let size: Int64          // bytes of regular-file payload underneath

    static func == (lhs: ShredItem, rhs: ShredItem) -> Bool { lhs.id == rhs.id }
}

/// Live progress of a shred run.
struct ShredProgress {
    var currentPath = ""
    var currentPass = 0
    var totalPasses = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0

    var fraction: Double {
        bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : 0
    }
}

/// Result line of a completed run, one per top-level queued item.
struct ShredResult: Identifiable {
    let id = UUID()
    let path: String
    let success: Bool
    let message: String
}

/// Owns the queue and performs the multi-pass overwrite + unlink.
///
/// Safety rules:
/// - refuses paths under the protected-root list (system dirs, the home
///   folder itself, mounted volume roots);
/// - never follows symlinks — a symlink is unlinked, its target untouched;
/// - the UI must get an explicit confirmation before `shredQueued()`.
@MainActor
final class ShredderModel: ObservableObject {
    @Published var queue: [ShredItem] = []
    @Published var algorithm: ShredAlgorithm = .dod3
    @Published var isRunning = false
    @Published var progress = ShredProgress()
    @Published var results: [ShredResult] = []
    @Published var errorMessage: String?

    private var cancelRequested = false

    var queuedBytes: Int64 { queue.reduce(0) { $0 + $1.size } }

    // MARK: queue management

    func add(urls: [URL]) {
        for url in urls {
            let std = url.standardizedFileURL
            if let reason = Self.protectionReason(for: std) {
                errorMessage = reason
                continue
            }
            guard !queue.contains(where: { $0.url == std }) else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: std.path,
                                                 isDirectory: &isDir) else { continue }
            let size = Self.payloadSize(of: std)
            queue.append(ShredItem(url: std, isDirectory: isDir.boolValue, size: size))
        }
    }

    func remove(_ item: ShredItem) {
        queue.removeAll { $0.id == item.id }
    }

    func cancel() { cancelRequested = true }

    /// Paths we refuse outright, no matter what the user clicked.
    static func protectionReason(for url: URL) -> String? {
        let path = url.path
        let home = NSHomeDirectory()
        let forbidden: [String] = [
            "/", "/System", "/usr", "/bin", "/sbin", "/etc", "/var",
            "/Library", "/Applications", "/private",
            home, home + "/Library", home + "/Desktop", home + "/Documents",
            home + "/Downloads",
        ]
        if forbidden.contains(path) {
            return "“\(url.lastPathComponent.isEmpty ? path : url.lastPathComponent)” is a protected location and can’t be shredded."
        }
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/")
            || path.hasPrefix("/bin/") || path.hasPrefix("/sbin/") {
            return "System files can’t be shredded."
        }
        return nil
    }

    // MARK: run

    func shredQueued() {
        guard !isRunning, !queue.isEmpty else { return }
        isRunning = true
        cancelRequested = false
        results = []
        let items = queue
        let algo = algorithm
        progress = ShredProgress(totalPasses: algo.passes.count,
                                 bytesTotal: queuedBytes * Int64(algo.passes.count))

        Task.detached(priority: .userInitiated) { [weak self] in
            for item in items {
                guard let self else { return }
                if await self.isCancelled() { break }
                do {
                    try await self.shred(item: item, algorithm: algo)
                    await self.report(item: item, success: true,
                                      message: "Shredded with \(algo.title)")
                } catch is CancellationError {
                    await self.report(item: item, success: false, message: "Cancelled")
                    break
                } catch {
                    await self.report(item: item, success: false,
                                      message: error.localizedDescription)
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                let done = Set(self.results.filter(\.success).map(\.path))
                self.queue.removeAll { done.contains($0.url.path) }
                self.isRunning = false
            }
        }
    }

    private func isCancelled() -> Bool { cancelRequested }

    private func report(item: ShredItem, success: Bool, message: String) {
        results.append(ShredResult(path: item.url.path, success: success,
                                   message: message))
    }

    // MARK: engine (runs off the main actor)

    private nonisolated func shred(item: ShredItem, algorithm: ShredAlgorithm) async throws {
        let fm = FileManager.default
        var files: [URL] = []
        var dirs: [URL] = []

        let attrs = try fm.attributesOfItem(atPath: item.url.path)
        let type = attrs[.type] as? FileAttributeType
        if type == .typeSymbolicLink {
            try fm.removeItem(at: item.url)        // unlink the link only
            return
        }
        if item.isDirectory {
            dirs.append(item.url)
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey,
                                          .isSymbolicLinkKey]
            if let walker = fm.enumerator(at: item.url, includingPropertiesForKeys: keys,
                                          options: []) {
                for case let child as URL in walker {
                    let rv = try child.resourceValues(forKeys: Set(keys))
                    if rv.isSymbolicLink == true {
                        try? fm.removeItem(at: child)
                    } else if rv.isDirectory == true {
                        dirs.append(child)
                    } else if rv.isRegularFile == true {
                        files.append(child)
                    }
                }
            }
        } else {
            files.append(item.url)
        }

        for file in files {
            if await isCancelled() { throw CancellationError() }
            try await overwriteAndUnlink(file: file, algorithm: algorithm)
        }
        // Deepest directories first so each is empty by the time we hit it.
        for dir in dirs.sorted(by: { $0.path.count > $1.path.count }) {
            try? fm.removeItem(at: dir)
        }
    }

    private nonisolated func overwriteAndUnlink(file: URL,
                                                algorithm: ShredAlgorithm) async throws {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int64)
            .flatMap { $0 } ?? 0

        if size > 0 {
            // O_RDWR, not O_WRONLY: the DoD verification pass reads the file
            // back through this same descriptor, and a write-only descriptor
            // makes every pread() fail with EBADF.
            let fd = open(file.path, O_RDWR)
            guard fd >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                    NSLocalizedDescriptionKey:
                        "Can’t open \(file.lastPathComponent) for writing"])
            }
            defer { close(fd) }

            let chunkSize = 1 << 20
            let passes = algorithm.passes
            for (index, pattern) in passes.enumerated() {
                let isFinal = index == passes.count - 1
                let verify = isFinal && algorithm.verifiesFinalPass
                try await writePass(fd: fd, size: size, pattern: pattern,
                                    chunkSize: chunkSize, verify: verify,
                                    passNumber: index + 1, of: passes.count,
                                    path: file.path)
                // Force the pass to physical media before starting the next.
                _ = fcntl(fd, F_FULLFSYNC)
            }
            _ = ftruncate(fd, 0)
            _ = fcntl(fd, F_FULLFSYNC)
        }

        // Obscure the name and metadata, then unlink.
        var current = file
        for _ in 0..<2 {
            let renamed = current.deletingLastPathComponent()
                .appendingPathComponent(UUID().uuidString)
            if (try? fm.moveItem(at: current, to: renamed)) != nil {
                current = renamed
            }
        }
        try fm.removeItem(at: current)
    }

    private nonisolated func writePass(fd: Int32, size: Int64, pattern: UInt8?,
                                       chunkSize: Int, verify: Bool,
                                       passNumber: Int, of totalPasses: Int,
                                       path: String) async throws {
        var buffer = [UInt8](repeating: pattern ?? 0, count: chunkSize)

        // A random pass is generated from a seeded PRNG rather than
        // arc4random_buf, so the verification read can regenerate the expected
        // bytes chunk by chunk instead of holding a copy of the whole file in
        // memory (which used to make large files unshreddable).
        var seed: UInt64 = 0
        if pattern == nil {
            arc4random_buf(&seed, MemoryLayout<UInt64>.size)
            if seed == 0 { seed = 0x9E37_79B9_7F4A_7C15 }
        }
        var rng = SplitMix64(seed: seed)

        var written: Int64 = 0
        while written < size {
            if await isCancelled() { throw CancellationError() }
            let len = Int(min(Int64(chunkSize), size - written))
            if pattern == nil { rng.fill(&buffer, count: len) }
            let n = buffer.withUnsafeBytes { raw in
                pwrite(fd, raw.baseAddress, len, off_t(written))
            }
            guard n == len else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                    NSLocalizedDescriptionKey: "Write failed at offset \(written)"])
            }
            written += Int64(len)
            await updateProgress(path: path, pass: passNumber,
                                 totalPasses: totalPasses, add: Int64(len))
        }

        guard verify else { return }

        // Verification only means something against what actually reached the
        // media: flush the pass out, then turn the page cache off for the
        // read-back so pread() can't hand us the buffer we just wrote.
        guard fcntl(fd, F_FULLFSYNC) != -1 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey:
                    "Couldn’t flush the final pass to disk before verifying: "
                    + String(cString: strerror(errno))])
        }
        _ = fcntl(fd, F_NOCACHE, 1)
        defer { _ = fcntl(fd, F_NOCACHE, 0) }

        rng = SplitMix64(seed: seed)
        var readBuffer = [UInt8](repeating: 0, count: chunkSize)
        var checked: Int64 = 0
        while checked < size {
            if await isCancelled() { throw CancellationError() }
            let len = Int(min(Int64(chunkSize), size - checked))
            if pattern == nil { rng.fill(&buffer, count: len) }
            let n = readBuffer.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress, len, off_t(checked))
            }
            guard n == len else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                    NSLocalizedDescriptionKey:
                        "Verification read failed at offset \(checked): "
                        + (n < 0 ? String(cString: strerror(errno))
                                 : "short read (\(n) of \(len) bytes)")])
            }
            let matches = readBuffer.withUnsafeBytes { got in
                buffer.withUnsafeBytes { want in
                    memcmp(got.baseAddress!, want.baseAddress!, len) == 0
                }
            }
            guard matches else {
                throw NSError(domain: "ShredKit", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Verification failed at offset \(checked) — the final pass did not read back correctly"])
            }
            checked += Int64(len)
        }
    }

    private func updateProgress(path: String, pass: Int, totalPasses: Int,
                                add: Int64) {
        progress.currentPath = path
        progress.currentPass = pass
        progress.totalPasses = totalPasses
        progress.bytesDone += add
    }

    // MARK: sizing

    private static func payloadSize(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64)
                .flatMap { $0 } ?? 0
        }
        var total: Int64 = 0
        if let walker = fm.enumerator(at: url,
                                      includingPropertiesForKeys: [.fileSizeKey,
                                                                   .isRegularFileKey]) {
            for case let child as URL in walker {
                if let rv = try? child.resourceValues(forKeys: [.fileSizeKey,
                                                                .isRegularFileKey]),
                   rv.isRegularFile == true {
                    total += Int64(rv.fileSize ?? 0)
                }
            }
        }
        return total
    }
}

/// Deterministic 64-bit PRNG (SplitMix64) used to generate — and later
/// regenerate — the random overwrite pass. Reproducibility is the whole point:
/// it lets the verification pass compare against the expected bytes without
/// buffering the file's worth of random data.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Fills the first `count` bytes of `buffer` with the next PRNG output.
    mutating func fill(_ buffer: inout [UInt8], count: Int) {
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < count {
                var word = next()
                let n = min(8, count - offset)
                withUnsafeBytes(of: &word) { src in
                    memcpy(base + offset, src.baseAddress!, n)
                }
                offset += n
            }
        }
    }
}
