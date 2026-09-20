import Foundation

/// The single source of truth for *where the app is allowed to look and what it
/// is allowed to delete*. Every deletion is validated here a second time at
/// delete-time, even though items were discovered inside the same roots —
/// defense in depth against bugs elsewhere in the app.
enum SafetyPolicy {

    // MARK: Whitelisted scan roots

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var userCachesRoot: URL { home.appendingPathComponent("Library/Caches", isDirectory: true) }
    static var logsRoot: URL { home.appendingPathComponent("Library/Logs", isDirectory: true) }
    static var derivedDataRoot: URL { home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true) }
    static var appSupportRoot: URL { home.appendingPathComponent("Library/Application Support", isDirectory: true) }

    /// Roots inside which deletion is permitted. Note: Application Support is
    /// deliberately NOT a blanket root — only curated orphan folders qualify
    /// (see `knownOrphanCandidates`), and those are validated individually.
    static var deletableRoots: [URL] {
        [userCachesRoot, logsRoot, derivedDataRoot]
    }

    /// Cache folders we never offer for deletion even though they live under
    /// ~/Library/Caches, because removing them logs the user out of things or
    /// confuses the OS more than it helps.
    static let cacheDenylist: Set<String> = [
        "com.apple.HomeKit",
        "com.apple.Safari",            // contains favicons tied to keychain state
        "CloudKit",
        "FamilyCircle",
        "com.apple.ap.adprivacyd",
    ]

    /// Curated map of Application Support folder names → bundle identifier of
    /// the app that owns them. A folder is offered as "orphaned" only if its
    /// name appears here AND the owning app cannot be found on disk.
    /// This list is intentionally short and conservative: unknown folders are
    /// never touched, because many apps share frameworks or store user data
    /// (e.g. mail databases) in Application Support.
    static let knownOrphanCandidates: [String: String] = [
        "Spotify":            "com.spotify.client",
        "Slack":              "com.tinyspeck.slackmacgap",
        "zoom.us":            "us.zoom.xos",
        "discord":            "com.hnc.Discord",
        "Google Chrome Canary": "com.google.Chrome.canary",
        "Firefox Developer Edition": "org.mozilla.firefoxdeveloperedition",
        "obs-studio":         "com.obsproject.obs-studio",
        "VLC":                "org.videolan.vlc",
        "Postman":            "com.postmanlabs.mac",
        "Caffeine":           "com.lightheadsw.Caffeine",
    ]

    // MARK: Validation

    enum ValidationError: LocalizedError {
        case outsideWhitelist(String)
        case isWhitelistRootItself(String)
        case denylisted(String)
        case symlinkEscape(String)

        var errorDescription: String? {
            switch self {
            case .outsideWhitelist(let p):     return "Refusing to touch path outside whitelist: \(p)"
            case .isWhitelistRootItself(let p): return "Refusing to delete a whitelist root itself: \(p)"
            case .denylisted(let p):           return "Path is on the protection denylist: \(p)"
            case .symlinkEscape(let p):        return "Path resolves outside the whitelist (symlink escape): \(p)"
            }
        }
    }

    /// Throws unless `url` is something we are allowed to delete.
    /// `allowOrphan` additionally permits the curated Application Support dirs.
    static func validateDeletable(_ url: URL, allowOrphan: Bool = false) throws {
        let standardized = url.standardizedFileURL

        // 1. Must be lexically inside a deletable root (or be a curated orphan dir).
        let lexicallyAllowed = deletableRoots.contains { isDescendant(standardized, of: $0) }
        let orphanAllowed = allowOrphan && isCuratedOrphanDir(standardized)
        guard lexicallyAllowed || orphanAllowed else {
            throw ValidationError.outsideWhitelist(standardized.path)
        }

        // 2. Never delete a root itself (e.g. all of ~/Library/Caches).
        for root in deletableRoots + [appSupportRoot] where standardized.path == root.standardizedFileURL.path {
            throw ValidationError.isWhitelistRootItself(standardized.path)
        }

        // 3. Denylist check for protected cache folders.
        if isDescendant(standardized, of: userCachesRoot) {
            let relativeFirst = standardized.path
                .dropFirst(userCachesRoot.standardizedFileURL.path.count)
                .split(separator: "/").first.map(String.init) ?? ""
            if cacheDenylist.contains(relativeFirst) {
                throw ValidationError.denylisted(standardized.path)
            }
        }

        // 4. Symlink-escape check: the *resolved* path must also be inside the
        //    whitelist, otherwise a symlinked folder could trick us into
        //    trashing content elsewhere. Broken symlinks resolve to themselves,
        //    which is fine — they are inside the roots by check 1.
        let resolved = standardized.resolvingSymlinksInPath()
        if resolved.path != standardized.path {
            let resolvedAllowed = deletableRoots.contains { isDescendant(resolved, of: $0) }
                || (allowOrphan && isDescendant(resolved, of: appSupportRoot))
            if !resolvedAllowed {
                // The link itself is in-bounds; deleting *the link* is safe,
                // but only if it does not point at live out-of-bounds data.
                let targetExists = FileManager.default.fileExists(atPath: standardized.path) // follows links
                if targetExists {
                    throw ValidationError.symlinkEscape(standardized.path)
                }
            }
        }
    }

    /// True if `url` is one of the curated orphan candidates (direct child of
    /// Application Support with a name in our table).
    static func isCuratedOrphanDir(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        return parent == appSupportRoot.standardizedFileURL.path
            && knownOrphanCandidates.keys.contains(url.lastPathComponent)
    }

    /// Strict descendant check on path components — no string-prefix tricks
    /// (avoids "/a/bc" matching root "/a/b").
    static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let child = url.standardizedFileURL.pathComponents
        let parent = root.standardizedFileURL.pathComponents
        return child.count > parent.count && Array(child.prefix(parent.count)) == parent
    }
}
