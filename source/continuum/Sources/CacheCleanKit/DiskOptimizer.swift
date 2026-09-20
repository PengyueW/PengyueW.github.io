import Foundation
import AppKit

/// Core backend service: scans the whitelisted locations and performs
/// trash-based cleaning. An `actor`, so all file-system work happens off the
/// main thread while remaining data-race free.
actor DiskOptimizer {

    private let fm = FileManager.default

    // MARK: - Scanning (read-only, never mutates anything)

    /// Walks every whitelisted location and returns the deletable items found.
    /// Progress is delivered through `onProgress` (called on the actor; hop to
    /// the main actor in the caller). Honors task cancellation between steps.
    func scan(onProgress: @Sendable @escaping (ScanProgress) -> Void) async throws -> [ScanItem] {
        var items: [ScanItem] = []
        var bytesFound: Int64 = 0

        // Each step is (label, weight-equal unit of work).
        let steps: [(String, () throws -> [ScanItem])] = [
            ("User Caches",   { try self.scanTopLevelChildren(of: SafetyPolicy.userCachesRoot, category: .userCaches, skipNames: SafetyPolicy.cacheDenylist) }),
            ("Logs",          { try self.scanTopLevelChildren(of: SafetyPolicy.logsRoot, category: .logs) }),
            ("Derived Data",  { try self.scanTopLevelChildren(of: SafetyPolicy.derivedDataRoot, category: .derivedData) }),
            ("Broken Symlinks", { try self.scanBrokenSymlinks() }),
            ("Orphaned App Support", { try self.scanOrphanedSupportDirs() }),
        ]

        for (index, (label, work)) in steps.enumerated() {
            try Task.checkCancellation()
            onProgress(ScanProgress(currentPath: label,
                                    fraction: Double(index) / Double(steps.count),
                                    itemsFound: items.count,
                                    bytesFound: bytesFound))
            do {
                let found = try work()
                items.append(contentsOf: found)
                bytesFound += found.reduce(0) { $0 + $1.sizeBytes }
            } catch {
                // A whole category failing (e.g. folder missing) is not fatal;
                // log and continue with the next category.
                NSLog("CacheClean: scan step '\(label)' skipped: \(error.localizedDescription)")
            }
        }

        onProgress(ScanProgress(currentPath: "Done",
                                fraction: 1.0,
                                itemsFound: items.count,
                                bytesFound: bytesFound))
        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Lists the direct children of `root` as candidate items, sizing each one
    /// recursively. We deliberately offer *top-level* entries (one row per app
    /// cache folder) rather than tens of thousands of individual files — easier
    /// to review, and trashing a folder is one undoable Finder operation.
    private func scanTopLevelChildren(of root: URL,
                                      category: CleanCategory,
                                      skipNames: Set<String> = []) throws -> [ScanItem] {
        guard fm.fileExists(atPath: root.path) else { return [] }

        let children = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        )

        var result: [ScanItem] = []
        for child in children {
            if skipNames.contains(child.lastPathComponent) { continue }
            do {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { continue } // handled by symlink pass
                let isDir = values.isDirectory == true
                let size = isDir ? allocatedSize(ofDirectory: child)
                                 : Int64(values.allValues[.totalFileAllocatedSizeKey] as? Int ?? 0)
                result.append(ScanItem(url: child, category: category, sizeBytes: size, isDirectory: isDir))
            } catch {
                NSLog("CacheClean: could not inspect \(child.path): \(error.localizedDescription)")
            }
        }
        return result
    }

    /// Recursive allocated size; unreadable entries count as 0 instead of failing.
    private func allocatedSize(ofDirectory url: URL) -> Int64 {
        var total: Int64 = 0
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = fm.enumerator(at: url,
                                             includingPropertiesForKeys: Array(keys),
                                             options: [],
                                             errorHandler: { _, _ in true }) else { return 0 }
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Finds dangling symlinks — only inside the whitelisted roots, never
    /// system-wide.
    private func scanBrokenSymlinks() throws -> [ScanItem] {
        var result: [ScanItem] = []
        for root in SafetyPolicy.deletableRoots where fm.fileExists(atPath: root.path) {
            guard let enumerator = fm.enumerator(at: root,
                                                 includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                 options: [],
                                                 errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
                // fileExists(atPath:) follows the link: false ⇒ target is gone.
                if !fm.fileExists(atPath: url.path) {
                    result.append(ScanItem(url: url, category: .brokenSymlinks, sizeBytes: 0, isDirectory: false))
                }
            }
        }
        return result
    }

    /// Offers a curated Application Support folder only when its owning app is
    /// verifiably gone. Unknown folders are never considered.
    private func scanOrphanedSupportDirs() throws -> [ScanItem] {
        var result: [ScanItem] = []
        for (folderName, bundleID) in SafetyPolicy.knownOrphanCandidates {
            let dir = SafetyPolicy.appSupportRoot.appendingPathComponent(folderName, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            // App still installed anywhere Launch Services knows about? Keep the folder.
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil { continue }
            result.append(ScanItem(url: dir,
                                   category: .orphanedSupport,
                                   sizeBytes: allocatedSize(ofDirectory: dir),
                                   isDirectory: true))
        }
        return result
    }

    // MARK: - Cleaning (only ever called with user-approved items)

    /// Moves the given items to the Trash. Re-validates every path against
    /// `SafetyPolicy` immediately before acting. Failures are collected, never
    /// thrown — one locked file must not abort the run.
    func clean(items: [ScanItem],
               onProgress: @Sendable @escaping (Double, String) -> Void) async -> CleaningReport {
        var report = CleaningReport()

        for (index, item) in items.enumerated() {
            if Task.isCancelled { break }
            onProgress(Double(index) / Double(max(items.count, 1)), item.displayName)

            // Item may have vanished since the scan (apps clean their own caches).
            // For broken symlinks fileExists() follows the link and returns
            // false, so check the link itself instead.
            let stillExists = item.category == .brokenSymlinks
                ? ((try? item.url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true)
                : fm.fileExists(atPath: item.url.path)
            guard stillExists else {
                report.skipped.append(SkippedItem(path: item.displayPath, reason: "No longer exists"))
                continue
            }

            do {
                try SafetyPolicy.validateDeletable(item.url, allowOrphan: item.category == .orphanedSupport)
            } catch {
                report.skipped.append(SkippedItem(path: item.displayPath, reason: error.localizedDescription))
                continue
            }

            do {
                if item.category == .brokenSymlinks {
                    try removeBrokenSymlink(item.url, report: &report)
                } else {
                    try await recycle(item.url)
                    report.trashedCount += 1
                    report.bytesReclaimed += item.sizeBytes
                }
            } catch {
                // Locked, permission denied, etc. — skip gracefully.
                report.skipped.append(SkippedItem(path: item.displayPath, reason: error.localizedDescription))
            }
        }

        onProgress(1.0, "Done")
        return report
    }

    /// Trash via NSWorkspace so the user gets the standard Finder safety net
    /// (Put Back, empties on their schedule).
    private func recycle(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle([url]) { _, error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    /// Finder often refuses to trash dangling symlinks, so try the Trash first
    /// and fall back to unlinking — after re-confirming the link is still
    /// dangling so we can never unlink a live file.
    private func removeBrokenSymlink(_ url: URL, report: inout CleaningReport) throws {
        guard !fm.fileExists(atPath: url.path) else {
            // Target reappeared; the link is no longer broken. Leave it alone.
            report.skipped.append(SkippedItem(path: url.path, reason: "Symlink target exists again"))
            return
        }
        do {
            var trashed: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &trashed)
        } catch {
            try fm.removeItem(at: url) // unlinks the link itself, never its target
        }
        report.removedSymlinkCount += 1
    }
}
