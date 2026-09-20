import AppKit
import Combine

/// An application discovered in /Applications or ~/Applications.
struct InstalledApp: Identifiable, Hashable {
    let id: String              // bundle path
    let name: String
    let bundleID: String
    let version: String
    let url: URL
    let isAppleApp: Bool

    static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// What kind of leftover a found path is, for grouping in the UI.
enum LeftoverKind: String, CaseIterable {
    case bundle        = "Application"
    case launchItem    = "Launch Agents & Daemons"
    case support       = "Application Support"
    case preferences   = "Preferences"
    case caches        = "Caches"
    case containers    = "Containers"
    case other         = "Logs, State & Other"

    var symbol: String {
        switch self {
        case .bundle:      return "app.dashed"
        case .launchItem:  return "bolt.badge.clock"
        case .support:     return "internaldrive"
        case .preferences: return "gearshape"
        case .caches:      return "archivebox"
        case .containers:  return "shippingbox"
        case .other:       return "doc.text"
        }
    }
}

/// One file/folder associated with the selected app.
struct LeftoverItem: Identifiable {
    let id = UUID()
    let url: URL
    let kind: LeftoverKind
    let size: Int64
    let needsAdmin: Bool        // lives in a system domain (/Library, …)
    var selected = true
}

/// Finds every on-disk trace of an app (deep-seated launch agents, app
/// support, plists, containers) and moves the selected ones to the Trash.
@MainActor
final class UninstallerModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var selectedApp: InstalledApp?
    @Published var leftovers: [LeftoverItem] = []
    @Published var isLoadingApps = false
    @Published var isScanningLeftovers = false
    @Published var isRemoving = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    var selectedBytes: Int64 {
        leftovers.filter(\.selected).reduce(0) { $0 + $1.size }
    }

    // MARK: app discovery

    func loadApps() {
        guard !isLoadingApps else { return }
        isLoadingApps = true
        Task.detached(priority: .userInitiated) {
            var found: [InstalledApp] = []
            let fm = FileManager.default
            let roots = ["/Applications",
                         NSHomeDirectory() + "/Applications"]
            for root in roots {
                guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
                for name in names.sorted() {
                    let path = root + "/" + name
                    guard name.hasSuffix(".app"),
                          let bundle = Bundle(path: path),
                          let bundleID = bundle.bundleIdentifier else { continue }
                    let info = bundle.infoDictionary ?? [:]
                    let display = (info["CFBundleDisplayName"] as? String)
                        ?? (info["CFBundleName"] as? String)
                        ?? (name as NSString).deletingPathExtension
                    let version = (info["CFBundleShortVersionString"] as? String)
                        ?? (info["CFBundleVersion"] as? String) ?? "—"
                    found.append(InstalledApp(
                        id: path, name: display, bundleID: bundleID,
                        version: version, url: URL(fileURLWithPath: path),
                        isAppleApp: bundleID.hasPrefix("com.apple.")))
                }
            }
            let apps = found
            await MainActor.run { [weak self] in
                self?.apps = apps
                self?.isLoadingApps = false
            }
        }
    }

    // MARK: leftover discovery

    func select(app: InstalledApp) {
        selectedApp = app
        leftovers = []
        statusMessage = nil
        isScanningLeftovers = true
        let bundleID = app.bundleID
        let name = app.name
        let appURL = app.url
        Task.detached(priority: .userInitiated) { [weak self] in
            let items = Self.findLeftovers(bundleID: bundleID, appName: name,
                                           appURL: appURL)
            await MainActor.run { [weak self] in
                guard let self, self.selectedApp?.id == app.id else { return }
                self.leftovers = items
                self.isScanningLeftovers = false
            }
        }
    }

    private nonisolated static func findLeftovers(bundleID: String, appName: String,
                                                  appURL: URL) -> [LeftoverItem] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var items: [LeftoverItem] = []
        var seen = Set<String>()

        func add(_ path: String, _ kind: LeftoverKind, admin: Bool = false) {
            guard fm.fileExists(atPath: path), seen.insert(path).inserted else { return }
            items.append(LeftoverItem(url: URL(fileURLWithPath: path), kind: kind,
                                      size: payloadSize(path), needsAdmin: admin))
        }

        // The bundle itself first.
        items.append(LeftoverItem(url: appURL, kind: .bundle,
                                  size: payloadSize(appURL.path),
                                  needsAdmin: !fm.isWritableFile(atPath:
                                      appURL.deletingLastPathComponent().path)))
        seen.insert(appURL.path)

        // Direct, exactly-named per-domain locations.
        let userPairs: [(String, LeftoverKind)] = [
            ("\(home)/Library/Application Support/\(bundleID)", .support),
            ("\(home)/Library/Application Support/\(appName)", .support),
            ("\(home)/Library/Caches/\(bundleID)", .caches),
            ("\(home)/Library/Caches/\(appName)", .caches),
            ("\(home)/Library/Preferences/\(bundleID).plist", .preferences),
            ("\(home)/Library/Preferences/\(bundleID).plist.lockfile", .preferences),
            ("\(home)/Library/Containers/\(bundleID)", .containers),
            ("\(home)/Library/Saved Application State/\(bundleID).savedState", .other),
            ("\(home)/Library/HTTPStorages/\(bundleID)", .other),
            ("\(home)/Library/WebKit/\(bundleID)", .other),
            ("\(home)/Library/Logs/\(bundleID)", .other),
            ("\(home)/Library/Logs/\(appName)", .other),
            ("\(home)/Library/Application Scripts/\(bundleID)", .other),
            ("\(home)/Library/Cookies/\(bundleID).binarycookies", .other),
        ]
        for (path, kind) in userPairs { add(path, kind) }

        let systemPairs: [(String, LeftoverKind)] = [
            ("/Library/Application Support/\(appName)", .support),
            ("/Library/Application Support/\(bundleID)", .support),
            ("/Library/Caches/\(bundleID)", .caches),
            ("/Library/Preferences/\(bundleID).plist", .preferences),
        ]
        for (path, kind) in systemPairs { add(path, kind, admin: true) }

        // Group containers: directory names embed the team-prefixed bundle id.
        let groupRoot = "\(home)/Library/Group Containers"
        if let groups = try? fm.contentsOfDirectory(atPath: groupRoot) {
            for group in groups where group.lowercased()
                .contains(bundleID.lowercased()) {
                add("\(groupRoot)/\(group)", .containers)
            }
        }

        // Launch agents / daemons: match by filename prefix OR by a reference
        // to the bundle id / bundle path inside the plist.
        let launchDirs: [(String, Bool)] = [
            ("\(home)/Library/LaunchAgents", false),
            ("/Library/LaunchAgents", true),
            ("/Library/LaunchDaemons", true),
        ]
        for (dir, admin) in launchDirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in names where file.hasSuffix(".plist") {
                let path = dir + "/" + file
                let byName = file.lowercased().hasPrefix(bundleID.lowercased())
                let byContent = !byName && plist(path, references: bundleID,
                                                 orPath: appURL.path)
                if byName || byContent { add(path, .launchItem, admin: admin) }
            }
        }

        return items.sorted {
            ($0.kind.rawValue, $0.url.path) < ($1.kind.rawValue, $1.url.path)
        }
    }

    private nonisolated static func plist(_ path: String, references bundleID: String,
                                          orPath appPath: String) -> Bool {
        guard let data = fm_contents(path),
              let text = String(data: data, encoding: .utf8)
                ?? propertyListString(data) else { return false }
        return text.contains(bundleID) || text.contains(appPath)
    }

    private nonisolated static func fm_contents(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    /// Binary plists aren't UTF-8; decode and re-serialize as XML to search.
    private nonisolated static func propertyListString(_ data: Data) -> String? {
        guard let obj = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil),
              let xml = try? PropertyListSerialization.data(
                  fromPropertyList: obj, format: .xml, options: 0) else { return nil }
        return String(data: xml, encoding: .utf8)
    }

    private nonisolated static func payloadSize(_ path: String) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? fm.attributesOfItem(atPath: path)[.size] as? Int64)
                .flatMap { $0 } ?? 0
        }
        var total: Int64 = 0
        if let walker = fm.enumerator(at: URL(fileURLWithPath: path),
                                      includingPropertiesForKeys: [.fileSizeKey]) {
            for case let child as URL in walker {
                let fileSize = (try? child.resourceValues(forKeys: [.fileSizeKey]))?
                    .fileSize ?? 0
                total += Int64(fileSize)
            }
        }
        return total
    }

    // MARK: removal

    func toggle(_ item: LeftoverItem) {
        guard let index = leftovers.firstIndex(where: { $0.id == item.id }) else { return }
        leftovers[index].selected.toggle()
    }

    func uninstallSelected() {
        guard let app = selectedApp, !isRemoving else { return }
        let chosen = leftovers.filter(\.selected)
        guard !chosen.isEmpty else { return }
        isRemoving = true
        statusMessage = nil

        Task { @MainActor in
            // Quit the app if it's running so the bundle can be trashed.
            for running in NSWorkspace.shared.runningApplications
            where running.bundleIdentifier == app.bundleID {
                running.terminate()
            }

            // Unload launch agents in the user domain before deleting them.
            for item in chosen where item.kind == .launchItem && !item.needsAdmin {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                task.arguments = ["unload", item.url.path]
                try? task.run()
                task.waitUntilExit()
            }

            var trashed = 0, failed: [String] = []
            let adminPaths = chosen.filter(\.needsAdmin).map(\.url.path)

            for item in chosen where !item.needsAdmin {
                do {
                    try FileManager.default.trashItem(at: item.url,
                                                      resultingItemURL: nil)
                    trashed += 1
                } catch {
                    failed.append(item.url.lastPathComponent)
                }
            }

            if !adminPaths.isEmpty {
                if Self.adminRemove(paths: adminPaths) {
                    trashed += adminPaths.count
                } else {
                    failed.append(contentsOf:
                        adminPaths.map { ($0 as NSString).lastPathComponent })
                }
            }

            var summary = "Moved \(trashed) item\(trashed == 1 ? "" : "s") to the Trash"
            if !failed.isEmpty {
                summary += " — failed: \(failed.joined(separator: ", "))"
            }
            statusMessage = summary
            isRemoving = false
            select(app: app)        // re-scan to show what's left
            loadAppsAfterRemoval(app: app)
        }
    }

    private func loadAppsAfterRemoval(app: InstalledApp) {
        if !FileManager.default.fileExists(atPath: app.url.path) {
            apps.removeAll { $0.id == app.id }
            selectedApp = nil
            leftovers = []
        }
    }

    /// System-domain leftovers are root-owned; remove them with one admin
    /// prompt. They are deleted (not trashed) because the Trash is per-user.
    private nonisolated static func adminRemove(paths: [String]) -> Bool {
        let quoted = paths
            .map { $0.replacingOccurrences(of: "'", with: "'\\''") }
            .map { "'\($0)'" }
            .joined(separator: " ")
        let script = "do shell script \"rm -rf \(quoted)\" "
            + "with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        return error == nil
    }
}
