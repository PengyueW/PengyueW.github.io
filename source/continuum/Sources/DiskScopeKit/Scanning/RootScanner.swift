import Foundation

/// Privileged counterpart to `DiskScanner`. It runs the bundled `diskscope-scan`
/// helper **as root** (via `osascript … with administrator privileges`, which
/// shows the standard macOS authentication dialog) so the scan can read every
/// item on the volume — including root-owned system files the user-level scan
/// can't open — and account for the space they occupy. Items owned by root and
/// not user-writable come back flagged `restricted`, which the treemap renders
/// with a red inner outline.
///
/// Read-only: the helper only crawls and writes its own output file. The single
/// authorization prompt is the user's explicit consent.
final class RootScanner {

    struct CancelledError: Error {}
    struct AuthCancelledError: Error {}

    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    func cancel() {
        lock.lock()
        cancelled = true
        process?.terminate()
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Whether the privileged helper is present in the bundle (so the UI can
    /// hide the feature where it isn't).
    static var helperURL: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("diskscope-scan"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/diskscope-scan"),
            URL(fileURLWithPath: ".build/diskscope-scan"),   // dev / bare-executable runs
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func scan(path: String,
              progress: @escaping (_ items: Int, _ currentPath: String) -> Void,
              completion: @escaping (Result<ScanResult, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let started = Date()
            do {
                let outURL = try self.runHelper(rootPath: path, progress: progress)
                defer { try? FileManager.default.removeItem(at: outURL) }
                if self.isCancelled { throw CancelledError() }
                let (root, items, restricted) = try self.assemble(rootPath: path, from: outURL)
                root.finalize()
                let result = ScanResult(root: root, itemCount: items, deniedCount: restricted,
                                        duration: Date().timeIntervalSince(started))
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Running the privileged helper

    private func runHelper(rootPath: String,
                           progress: @escaping (Int, String) -> Void) throws -> URL {
        guard let helper = RootScanner.helperURL else {
            throw NSError(domain: "DiskScope", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "The privileged scan helper is missing from the app bundle.",
            ])
        }
        let uid = String(getuid())
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskscope-rootscan-\(UUID().uuidString).dat")

        DispatchQueue.main.async { progress(0, "Authorizing administrator scan…") }

        // Build the shell command (each path single-quoted for the shell), then
        // wrap it for AppleScript's `do shell script`, which performs the
        // privilege elevation and shows the auth dialog.
        let shellCmd = "\(shellQuote(helper.path)) \(shellQuote(rootPath)) "
            + "\(shellQuote(outURL.path)) \(uid)"
        let appleScript = "do shell script \(appleScriptQuote(shellCmd)) "
            + "with administrator privileges"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", appleScript]
        let errPipe = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = errPipe

        lock.lock(); process = proc; lock.unlock()

        try proc.run()
        DispatchQueue.main.async { progress(0, "Reading all files as administrator…\nThis may take some time.") }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        lock.lock(); process = nil; lock.unlock()

        if isCancelled { throw CancelledError() }

        if proc.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8) ?? ""
            if msg.contains("-128") || msg.localizedCaseInsensitiveContains("User canceled") {
                throw AuthCancelledError()
            }
            throw NSError(domain: "DiskScope", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: msg.isEmpty
                    ? "The privileged scan failed (exit \(proc.terminationStatus))."
                    : msg,
            ])
        }
        return outURL
    }

    // MARK: - Assembling the tree from the helper's output

    /// Parses the NUL-delimited record stream into a `FileNode` tree. Records
    /// arrive parent-before-child (fts pre-order), so a relative-path → node map
    /// assembles the tree in a single pass — mirroring `DiskScanner`.
    private func assemble(rootPath: String, from url: URL) throws -> (FileNode, Int, Int) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)

        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let rootName = rootURL.lastPathComponent.isEmpty ? rootPath : rootURL.lastPathComponent
        let root = FileNode(name: rootName, isDirectory: true, absolutePath: rootPath)
        var directories: [String: FileNode] = ["": root, ".": root]

        var itemCount = 0
        var restrictedCount = 0

        // Walk the raw bytes once, slicing each record's four NUL-separated
        // fields and decoding them individually — no giant intermediate string.
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            var fieldStart = 0
            var field = 0
            // Per-record field values.
            var isDir = false, restricted = false
            var size: Int64 = 0

            for i in 0..<n where bytes[i] == 0 {
                let slice = UnsafeBufferPointer(rebasing: bytes[fieldStart..<i])
                fieldStart = i + 1
                switch field {
                case 0:
                    isDir = (slice.count == 1 && slice[0] == 0x31)        // '1'
                case 1:
                    restricted = (slice.count == 1 && slice[0] == 0x31)
                case 2:
                    size = parseInt(slice)
                default:
                    let relPath = String(decoding: slice, as: UTF8.self)
                    if !relPath.isEmpty {
                        let name = (relPath as NSString).lastPathComponent
                        let node = FileNode(name: name, isDirectory: isDir,
                                            size: isDir ? 0 : size, restricted: restricted)
                        let parent = (relPath as NSString).deletingLastPathComponent
                        (directories[parent] ?? root).addChild(node)
                        if isDir { directories[relPath] = node }
                        if restricted { restrictedCount += 1 }
                        itemCount += 1
                    }
                }
                field = (field + 1) & 3      // 4 fields per record
            }
        }

        return (root, itemCount, restrictedCount)
    }

    private func parseInt(_ slice: UnsafeBufferPointer<UInt8>) -> Int64 {
        var v: Int64 = 0
        for b in slice where b >= 0x30 && b <= 0x39 { v = v * 10 + Int64(b - 0x30) }
        return v
    }

    // MARK: - Quoting

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
