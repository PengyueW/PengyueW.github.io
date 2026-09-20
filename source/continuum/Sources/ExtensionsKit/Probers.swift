import Foundation
import SwiftUI
import AppKit

// One prober per extension category. Each returns plain value types; all
// state changes go through the per-category supported tool (pluginkit,
// launchctl, scutil, System Events) — never by editing other apps' files.

/// Where an item came from and which controls make sense for it.
enum ExtensionCategory: String, CaseIterable, Identifiable {
    case appExtensions = "App Extensions"
    case browser       = "Browser Extensions"
    case internetPlugins = "Internet Plug-Ins"
    case prefPanes     = "Preference Panes"
    case loginItems    = "Login Items"
    case launchAgents  = "Launch Agents & Daemons"
    case vpn           = "VPN Configurations"

    var id: String { rawValue }

    /// Localized display name for UI use. `rawValue` itself must stay the
    /// stable, verbatim English identifier — it's baked into item IDs
    /// (see `Probers.swift`'s `id: "\(category.rawValue):..."`).
    var displayName: LocalizedStringKey {
        switch self {
        case .appExtensions:   return "App Extensions"
        case .browser:         return "Browser Extensions"
        case .internetPlugins: return "Internet Plug-Ins"
        case .prefPanes:       return "Preference Panes"
        case .loginItems:      return "Login Items"
        case .launchAgents:    return "Launch Agents & Daemons"
        case .vpn:             return "VPN Configurations"
        }
    }

    var symbol: String {
        switch self {
        case .appExtensions:   return "puzzlepiece.extension"
        case .browser:         return "safari"
        case .internetPlugins: return "network.badge.shield.half.filled"
        case .prefPanes:       return "gearshape.2"
        case .loginItems:      return "person.badge.clock"
        case .launchAgents:    return "bolt.badge.clock"
        case .vpn:             return "lock.shield"
        }
    }

    var explainer: LocalizedStringKey {
        switch self {
        case .appExtensions:
            return "Extensions apps registered with the system (share sheets, Safari extensions, widgets, Finder sync…). Toggling uses pluginkit elections."
        case .browser:
            return "Extensions installed inside Chrome and Firefox profiles. Browsers own this state — manage them in the browser; Continuum reveals them and shows what's installed."
        case .internetPlugins:
            return "Legacy NPAPI-era plug-ins still loaded by some apps from the Internet Plug-Ins folders."
        case .prefPanes:
            return "Third-party System Preferences panes."
        case .loginItems:
            return "Apps that open automatically at login (System Events list)."
        case .launchAgents:
            return "Background jobs from LaunchAgents/LaunchDaemons folders — the most common cause of slow boots. Unload stops a job until next login; the plist stays in place."
        case .vpn:
            return "VPN services configured in Network settings (scutil --nc)."
        }
    }
}

/// One discovered extension/plug-in/agent/etc.
struct ExtensionItem: Identifiable {
    let id: String
    let category: ExtensionCategory
    let name: String
    let detail: String
    let path: String?
    var enabled: Bool?          // nil = state unknown/not applicable
    var canToggle = false
    var needsAdmin = false
}

enum ExtensionProbers {

    static func probe(_ category: ExtensionCategory) -> [ExtensionItem] {
        switch category {
        case .appExtensions:   return appExtensions()
        case .browser:         return browserExtensions()
        case .internetPlugins: return folderItems(category: .internetPlugins,
                                                  subpath: "Internet Plug-Ins")
        case .prefPanes:       return folderItems(category: .prefPanes,
                                                  subpath: "PreferencePanes")
        case .loginItems:      return loginItems()
        case .launchAgents:    return launchItems()
        case .vpn:             return vpnServices()
        }
    }

    // MARK: helpers

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (status: Int32, out: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus,
                String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: app extensions (pluginkit)

    private static func appExtensions() -> [ExtensionItem] {
        let (status, out) = run("/usr/bin/pluginkit", ["-mAv"])
        guard status == 0 else { return [] }
        var items: [ExtensionItem] = []
        for line in out.split(separator: "\n") {
            // "<flag> <identifier>(<version>)\t<uuid>\t<path>"
            let text = String(line)
            guard let parenStart = text.firstIndex(of: "(") else { continue }
            let flag = text.first
            let identifier = text.prefix(upTo: parenStart)
                .dropFirst()
                .trimmingCharacters(in: .whitespaces)
            let parts = text.split(separator: "\t")
            let path = parts.count >= 2 ? String(parts.last!) : nil
            guard !identifier.isEmpty else { continue }
            let enabled = flag != "-"          // "-" = ignored (disabled)
            items.append(ExtensionItem(
                id: "appex:\(identifier)",
                category: .appExtensions,
                name: identifier,
                detail: path.map { ($0 as NSString).deletingLastPathComponent }
                    ?? "",
                path: path,
                enabled: enabled,
                canToggle: true))
        }
        return items.sorted { $0.name < $1.name }
    }

    static func setAppExtension(identifier: String, enabled: Bool) -> Bool {
        let id = identifier.hasPrefix("appex:")
            ? String(identifier.dropFirst(6)) : identifier
        let election = enabled ? "use" : "ignore"
        return run("/usr/bin/pluginkit", ["-e", election, "-i", id]).status == 0
    }

    // MARK: browser extensions

    private static func browserExtensions() -> [ExtensionItem] {
        var items: [ExtensionItem] = []
        let home = NSHomeDirectory()
        let fm = FileManager.default

        // Chrome (and Chromium profiles share the layout).
        let chromeRoot = "\(home)/Library/Application Support/Google/Chrome"
        if let profiles = try? fm.contentsOfDirectory(atPath: chromeRoot) {
            for profile in profiles where profile == "Default"
                || profile.hasPrefix("Profile ") {
                let extRoot = "\(chromeRoot)/\(profile)/Extensions"
                guard let ids = try? fm.contentsOfDirectory(atPath: extRoot)
                else { continue }
                for extID in ids where !extID.hasPrefix(".") {
                    let versions = (try? fm.contentsOfDirectory(
                        atPath: "\(extRoot)/\(extID)")) ?? []
                    guard let version = versions.sorted().last else { continue }
                    let manifestPath = "\(extRoot)/\(extID)/\(version)/manifest.json"
                    let name = chromeExtensionName(manifestPath: manifestPath,
                                                   fallback: extID)
                    items.append(ExtensionItem(
                        id: "chrome:\(profile):\(extID)",
                        category: .browser,
                        name: name,
                        detail: "Chrome (\(profile)) — v\(version)",
                        path: "\(extRoot)/\(extID)",
                        enabled: nil))
                }
            }
        }

        // Firefox.
        let ffRoot = "\(home)/Library/Application Support/Firefox/Profiles"
        if let profiles = try? fm.contentsOfDirectory(atPath: ffRoot) {
            for profile in profiles {
                let jsonPath = "\(ffRoot)/\(profile)/extensions.json"
                guard let data = fm.contents(atPath: jsonPath),
                      let json = try? JSONSerialization.jsonObject(with: data)
                          as? [String: Any],
                      let addons = json["addons"] as? [[String: Any]]
                else { continue }
                for addon in addons where (addon["type"] as? String) == "extension" {
                    let locale = addon["defaultLocale"] as? [String: Any]
                    let name = (locale?["name"] as? String)
                        ?? (addon["id"] as? String) ?? "extension"
                    let active = addon["active"] as? Bool
                    let id = (addon["id"] as? String) ?? name
                    items.append(ExtensionItem(
                        id: "firefox:\(profile):\(id)",
                        category: .browser,
                        name: name,
                        detail: "Firefox (\(profile))",
                        path: addon["path"] as? String,
                        enabled: active))
                }
            }
        }
        return items.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private static func chromeExtensionName(manifestPath: String,
                                            fallback: String) -> String {
        guard let data = FileManager.default.contents(atPath: manifestPath),
              let json = try? JSONSerialization.jsonObject(with: data)
                  as? [String: Any],
              let name = json["name"] as? String else { return fallback }
        // Localized placeholder like "__MSG_appName__" — fall back to the id.
        return name.hasPrefix("__MSG_") ? fallback : name
    }

    // MARK: folder-based items (internet plug-ins, pref panes)

    private static func folderItems(category: ExtensionCategory,
                                    subpath: String) -> [ExtensionItem] {
        var items: [ExtensionItem] = []
        let fm = FileManager.default
        let roots = [("/Library/\(subpath)", true),
                     (NSHomeDirectory() + "/Library/\(subpath)", false)]
        for (root, system) in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root)
            else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                items.append(ExtensionItem(
                    id: "\(category.rawValue):\(root)/\(name)",
                    category: category,
                    name: (name as NSString).deletingPathExtension,
                    detail: system ? "All users — \(root)" : "Your user — \(root)",
                    path: "\(root)/\(name)",
                    enabled: nil,
                    needsAdmin: system))
            }
        }
        return items
    }

    // MARK: login items (System Events)

    private static func loginItems() -> [ExtensionItem] {
        let script = """
        const items = Application("System Events").loginItems();
        JSON.stringify(items.map(item => ({
            name: item.name(), path: item.path(), hidden: item.hidden()
        })));
        """
        let (status, out) = run("/usr/bin/osascript",
                                ["-l", "JavaScript", "-e", script])
        guard status == 0,
              let data = out.trimmingCharacters(in: .whitespacesAndNewlines)
                  .data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data)
                  as? [[String: Any]] else { return [] }
        return list.map { entry in
            let name = (entry["name"] as? String) ?? "login item"
            return ExtensionItem(
                id: "login:\(name)",
                category: .loginItems,
                name: name,
                detail: (entry["path"] as? String) ?? "",
                path: entry["path"] as? String,
                enabled: true,
                canToggle: true)
        }
    }

    /// Removing is the only supported "disable" for classic login items.
    static func removeLoginItem(named name: String) -> Bool {
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        Application("System Events").loginItems.byName("\(escaped)").delete();
        """
        return run("/usr/bin/osascript",
                   ["-l", "JavaScript", "-e", script]).status == 0
    }

    // MARK: launch agents & daemons

    private static func launchItems() -> [ExtensionItem] {
        var items: [ExtensionItem] = []
        let loaded = loadedLaunchLabels()
        let dirs: [(String, Bool)] = [
            (NSHomeDirectory() + "/Library/LaunchAgents", false),
            ("/Library/LaunchAgents", true),
            ("/Library/LaunchDaemons", true),
        ]
        let fm = FileManager.default
        for (dir, system) in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir)
            else { continue }
            for file in names.sorted() where file.hasSuffix(".plist") {
                let path = dir + "/" + file
                let label = launchLabel(plistPath: path)
                    ?? (file as NSString).deletingPathExtension
                items.append(ExtensionItem(
                    id: "launch:\(path)",
                    category: .launchAgents,
                    name: label,
                    detail: dir,
                    path: path,
                    enabled: loaded.contains(label),
                    canToggle: !system,      // user agents only — see CLAUDE.md
                    needsAdmin: system))
            }
        }
        return items
    }

    private static func loadedLaunchLabels() -> Set<String> {
        let (status, out) = run("/bin/launchctl", ["list"])
        guard status == 0 else { return [] }
        var labels = Set<String>()
        for line in out.split(separator: "\n").dropFirst() {
            if let label = line.split(separator: "\t").last {
                labels.insert(String(label))
            }
        }
        return labels
    }

    private static func launchLabel(plistPath: String) -> String? {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist["Label"] as? String
    }

    /// Load/unload a *user* launch agent via launchctl bootstrap/bootout.
    static func setLaunchAgent(plistPath: String, enabled: Bool) -> Bool {
        let domain = "gui/\(getuid())"
        if enabled {
            return run("/bin/launchctl",
                       ["bootstrap", domain, plistPath]).status == 0
        }
        return run("/bin/launchctl",
                   ["bootout", domain, plistPath]).status == 0
    }

    // MARK: VPN (scutil --nc)

    private static func vpnServices() -> [ExtensionItem] {
        let (status, out) = run("/usr/sbin/scutil", ["--nc", "list"])
        guard status == 0 else { return [] }
        var items: [ExtensionItem] = []
        for line in out.split(separator: "\n").dropFirst() {
            let text = String(line)
            // `* (Connected) GUID PPP "Office VPN" [PPP:L2TP]`
            guard let nameStart = text.firstIndex(of: "\""),
                  let nameEnd = text.lastIndex(of: "\""),
                  nameStart < nameEnd else { continue }
            let name = String(text[text.index(after: nameStart)..<nameEnd])
            let state = text.contains("(Connected)")
            let kind = text.split(separator: "[").last
                .map { "[" + String($0) } ?? ""
            items.append(ExtensionItem(
                id: "vpn:\(name)",
                category: .vpn,
                name: name,
                detail: "\(state ? "Connected" : "Disconnected") \(kind)",
                path: nil,
                enabled: state,
                canToggle: true))
        }
        return items
    }

    static func setVPN(named name: String, connected: Bool) -> Bool {
        run("/usr/sbin/scutil",
            ["--nc", connected ? "start" : "stop", name]).status == 0
    }

    // MARK: shared actions

    static func reveal(path: String) {
        NSWorkspace.shared.selectFile(path,
                                      inFileViewerRootedAtPath:
                                          (path as NSString).deletingLastPathComponent)
    }
}
