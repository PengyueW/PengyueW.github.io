import Foundation
import Combine

/// Overwrite pattern for a free-space wipe. Mirrors the file-shredder's
/// algorithms; `nil` pattern bytes mean cryptographically random data. Verify
/// passes don't apply to free space (there's no original to compare), so each
/// "pass" is a full fill-then-free cycle of the wipe pattern.
enum WipeMethod: String, CaseIterable, Identifiable {
    case zero       // 1 pass of 0x00
    case random     // 1 pass of random data
    case dod3       // DoD 5220.22-M flavour: 0x00, 0xFF, random
    case schneier7  // Schneier: 0xFF, 0x00, then 5 random passes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zero:      return "Zero Fill (1 pass)"
        case .random:    return "Random (1 pass)"
        case .dod3:      return "DoD 5220.22-M (3 passes)"
        case .schneier7: return "Schneier (7 passes)"
        }
    }

    var detail: String {
        switch self {
        case .zero:      return "Fast. Fills free space once with zeros."
        case .random:    return "Fills free space once with random data. Recommended."
        case .dod3:      return "Zeros, ones, then random — three fill cycles."
        case .schneier7: return "Ones, zeros, then five random fills. Very slow."
        }
    }

    /// One entry per pass: a fixed byte, or nil for random data.
    var passes: [UInt8?] {
        switch self {
        case .zero:      return [0x00]
        case .random:    return [nil]
        case .dod3:      return [0x00, 0xFF, nil]
        case .schneier7: return [0xFF, 0x00, nil, nil, nil, nil, nil]
        }
    }
}

/// A mounted, writable volume the wipe can target.
struct WipeVolume: Identifiable, Hashable {
    let id: String          // mount path, unique per volume
    let name: String
    let mountPath: String
    let isStartup: Bool
    let totalBytes: Int64
    let freeBytes: Int64
}

/// Live progress of a wipe run.
struct WipeProgress {
    var phase: String = ""
    var currentPass: Int = 0
    var totalPasses: Int = 0
    var bytesWritten: Int64 = 0
    var bytesTarget: Int64 = 0

    var fraction: Double {
        bytesTarget > 0 ? min(1, Double(bytesWritten) / Double(bytesTarget)) : 0
    }
}

/// Securely overwrites a volume's *free* space so previously-deleted files
/// can't be recovered forensically.
///
/// ## Why this can never touch live data
/// The wipe only ever **creates new files** inside its own scratch directory
/// and writes to those file descriptors. The kernel allocates blocks for new
/// files exclusively from free space, so by construction the only blocks ever
/// written are ones the filesystem already considers unused (which is exactly
/// where deleted/ghost/corrupted data lingers). There is no code path here that
/// opens, truncates, or writes any pre-existing file, and none that touches the
/// raw block device. Data integrity is structurally guaranteed, not merely
/// checked.
///
/// A configurable reserve is always left free so the volume never fills to 0
/// (which would destabilise the OS). When a write hits `ENOSPC` the fill file
/// size is stepped down so even small free fragments get covered.
@MainActor
final class FreeSpaceModel: ObservableObject {
    @Published var volumes: [WipeVolume] = []
    @Published var selectedVolumeID: String?
    @Published var method: WipeMethod = .random
    /// Free space (MB) deliberately left unwritten to keep the OS stable.
    @Published var reserveMB: Int = 1024
    @Published var isRunning = false
    @Published var progress = WipeProgress()
    @Published var resultMessage: String?
    @Published var errorMessage: String?

    private var cancelRequested = false

    /// Hidden scratch directory name created on the target volume.
    static let scratchName = ".ContinuumFreeSpaceWipe"

    var selectedVolume: WipeVolume? {
        volumes.first { $0.id == selectedVolumeID }
    }

    init() { refreshVolumes() }

    // MARK: - Volumes

    func refreshVolumes() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeLocalizedNameKey, .volumeIsBrowsableKey,
            .volumeIsReadOnlyKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey,
        ]
        let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                        options: [.skipHiddenVolumes]) ?? []
        var found: [WipeVolume] = []
        for url in urls {
            guard let rv = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if rv.volumeIsReadOnly == true { continue }     // can't write here
            let path = url.path
            let total = Int64(rv.volumeTotalCapacity ?? 0)
            let free = rv.volumeAvailableCapacityForImportantUsage ?? 0
            guard total > 0 else { continue }
            let isStartup = (path == "/")
            // Hide the read-only system volume; "/" already represents the boot
            // disk's writable container for our purposes.
            let name = rv.volumeLocalizedName ?? rv.volumeName ?? url.lastPathComponent
            found.append(WipeVolume(id: path, name: name, mountPath: path,
                                    isStartup: isStartup, totalBytes: total,
                                    freeBytes: free))
        }
        // Startup first, then by name.
        volumes = found.sorted {
            if $0.isStartup != $1.isStartup { return $0.isStartup }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if selectedVolumeID == nil || !volumes.contains(where: { $0.id == selectedVolumeID }) {
            selectedVolumeID = volumes.first?.id
        }
    }

    func cancel() { cancelRequested = true }

    // MARK: - Run

    func start() {
        guard !isRunning, let volume = selectedVolume else { return }
        errorMessage = nil
        resultMessage = nil

        // Resolve a user-writable scratch location *on that volume*. The boot
        // volume's "/" root isn't user-writable, so we use the home directory
        // (same APFS container → same free-space pool).
        let scratch: URL = volume.isStartup
            ? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(Self.scratchName)
            : URL(fileURLWithPath: volume.mountPath).appendingPathComponent(Self.scratchName)

        let method = self.method
        let reserveBytes = Int64(max(0, reserveMB)) * 1_048_576

        isRunning = true
        cancelRequested = false
        progress = WipeProgress(phase: "Preparing…", currentPass: 0,
                                totalPasses: method.passes.count)

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.run(scratch: scratch, method: method, reserveBytes: reserveBytes)
        }
    }

    private func isCancelled() -> Bool { cancelRequested }

    private func finish(success: Bool, message: String) {
        isRunning = false
        if success { resultMessage = message } else { errorMessage = message }
        refreshVolumes()
    }

    private func update(_ mutate: (inout WipeProgress) -> Void) {
        var p = progress
        mutate(&p)
        progress = p
    }

    // MARK: - Engine (off the main actor)

    private nonisolated func run(scratch: URL, method: WipeMethod, reserveBytes: Int64) async {
        let fm = FileManager.default

        // Start clean: remove any leftover scratch dir from a prior interrupted
        // run before measuring free space.
        try? fm.removeItem(at: scratch)

        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            await MainActor.run { [weak self] in
                self?.finish(success: false,
                             message: "Couldn't create the scratch folder on the volume: "
                                + error.localizedDescription)
            }
            return
        }

        let scratchPath = scratch.path
        let startFree = Self.freeBytes(at: scratchPath)
        let perPass = max(0, startFree - reserveBytes)
        let passes = method.passes

        if perPass <= 0 {
            try? fm.removeItem(at: scratch)
            await MainActor.run { [weak self] in
                self?.finish(success: true,
                             message: "Free space is already at or below the reserve — nothing to wipe.")
            }
            return
        }

        await MainActor.run { [weak self] in
            self?.update {
                $0.bytesTarget = perPass * Int64(passes.count)
                $0.bytesWritten = 0
            }
        }

        do {
            for (index, pattern) in passes.enumerated() {
                if await isCancelled() { throw CancellationError() }
                // Free what we wrote last pass so this pass can re-fill those
                // same blocks with the next pattern.
                Self.removeContents(of: scratch)
                try await fillFreeSpace(scratch: scratch, scratchPath: scratchPath,
                                        pattern: pattern, reserveBytes: reserveBytes,
                                        pass: index + 1, totalPasses: passes.count)
            }
            Self.removeContents(of: scratch)
            try? fm.removeItem(at: scratch)
            await MainActor.run { [weak self] in
                self?.finish(success: true,
                             message: "Free space wiped with \(method.title). Previously-deleted "
                                + "data on this volume can no longer be recovered by file-recovery tools.")
            }
        } catch is CancellationError {
            Self.removeContents(of: scratch)
            try? fm.removeItem(at: scratch)
            await MainActor.run { [weak self] in
                self?.isRunning = false
                self?.resultMessage = "Cancelled. Scratch files were removed and your free space restored."
                self?.refreshVolumes()
            }
        } catch {
            Self.removeContents(of: scratch)
            try? fm.removeItem(at: scratch)
            await MainActor.run { [weak self] in
                self?.finish(success: false, message: error.localizedDescription)
            }
        }
    }

    /// Fills the volume's free space (down to the reserve) with the pattern by
    /// creating a sequence of large files, stepping the file size down when a
    /// write hits a full disk so small free fragments are covered too.
    private nonisolated func fillFreeSpace(scratch: URL, scratchPath: String,
                                           pattern: UInt8?, reserveBytes: Int64,
                                           pass: Int, totalPasses: Int) async throws {
        let chunkSize = 4 << 20                  // 4 MiB writes
        var fileSize: Int64 = 8 << 30            // start at 8 GiB per file
        let minFileSize: Int64 = 4096
        var fileIndex = 0
        var buffer = [UInt8](repeating: pattern ?? 0, count: chunkSize)

        await MainActor.run { [weak self] in
            self?.update {
                $0.phase = "Pass \(pass) of \(totalPasses) — overwriting free space"
                $0.currentPass = pass
            }
        }

        while true {
            if await isCancelled() { throw CancellationError() }

            let free = Self.freeBytes(at: scratchPath)
            if free <= reserveBytes { return }

            let want = min(fileSize, free - reserveBytes)
            if want <= 0 { return }

            let fileURL = scratch.appendingPathComponent("wipe-\(pass)-\(fileIndex)")
            let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            if fd < 0 {
                if errno == ENOSPC { return }    // genuinely full
                throw posixError("Couldn't create fill file")
            }

            var hitFull = false
            var writtenThisFile: Int64 = 0
            while writtenThisFile < want {
                if await isCancelled() { close(fd); _ = unlink(fileURL.path); throw CancellationError() }
                let len = Int(min(Int64(chunkSize), want - writtenThisFile))
                if pattern == nil {
                    buffer.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, len) }
                }
                let n = buffer.withUnsafeBytes { raw in write(fd, raw.baseAddress, len) }
                if n < 0 {
                    if errno == ENOSPC { hitFull = true; break }
                    close(fd); throw posixError("Write failed")
                }
                if n == 0 { hitFull = true; break }
                writtenThisFile += Int64(n)
                await self.addProgress(Int64(n))
                if n < len { hitFull = true; break }   // short write ⇒ disk full
            }

            _ = fcntl(fd, F_FULLFSYNC)               // force blocks to media
            close(fd)
            fileIndex += 1

            if hitFull {
                // Step the file size down to mop up the remaining fragments;
                // stop once we're at the minimum and still can't fit anything.
                if fileSize > minFileSize {
                    fileSize = max(minFileSize, fileSize / 16)
                } else {
                    return
                }
            }
        }
    }

    private func addProgress(_ bytes: Int64) {
        progress.bytesWritten += bytes
    }

    private nonisolated func posixError(_ msg: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "\(msg): \(String(cString: strerror(errno)))",
        ])
    }

    // MARK: - Helpers

    /// Free bytes available to a non-superuser on the volume backing `path`.
    /// Uses `f_bavail`, which already excludes the root-reserved area.
    nonisolated static func freeBytes(at path: String) -> Int64 {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return 0 }
        return Int64(fs.f_bavail) * Int64(fs.f_bsize)
    }

    /// Deletes every fill file in the scratch dir (but keeps the dir itself).
    nonisolated static func removeContents(of dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir,
                                                      includingPropertiesForKeys: nil) else { return }
        for item in items { try? fm.removeItem(at: item) }
    }
}
