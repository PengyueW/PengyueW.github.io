import Foundation
import SQLite3
import AppKit

// Read-only access to macOS's TCC (Transparency, Consent & Control)
// databases — the source of truth behind System Settings → Privacy &
// Security. The user database covers per-user services; the system database
// (readable only with Full Disk Access) covers Camera, Microphone, Full Disk
// Access itself, Accessibility and the other machine-wide services.
//
// This kit never writes the databases. Revocation goes through `tccutil
// reset`, granting through System Settings deep links — the supported paths.

/// One TCC service we surface, with its System Settings anchor.
struct TCCService: Identifiable, Hashable {
    let id: String           // kTCCService… name
    let title: String
    let symbol: String
    let settingsAnchor: String

    static let known: [TCCService] = [
        .init(id: "kTCCServiceCamera", title: "Camera",
              symbol: "camera", settingsAnchor: "Privacy_Camera"),
        .init(id: "kTCCServiceMicrophone", title: "Microphone",
              symbol: "mic", settingsAnchor: "Privacy_Microphone"),
        .init(id: "kTCCServiceListenEvent", title: "Input Monitoring",
              symbol: "keyboard", settingsAnchor: "Privacy_ListenEvent"),
        .init(id: "kTCCServiceScreenCapture", title: "Screen Recording",
              symbol: "rectangle.dashed.badge.record",
              settingsAnchor: "Privacy_ScreenCapture"),
        .init(id: "kTCCServiceAccessibility", title: "Accessibility",
              symbol: "figure.walk.circle", settingsAnchor: "Privacy_Accessibility"),
        .init(id: "kTCCServiceSystemPolicyAllFiles", title: "Full Disk Access",
              symbol: "internaldrive", settingsAnchor: "Privacy_AllFiles"),
        .init(id: "kTCCServiceSystemPolicyDesktopFolder", title: "Desktop Folder",
              symbol: "menubar.dock.rectangle", settingsAnchor: "Privacy_DesktopFolder"),
        .init(id: "kTCCServiceSystemPolicyDocumentsFolder", title: "Documents Folder",
              symbol: "doc", settingsAnchor: "Privacy_DocumentsFolder"),
        .init(id: "kTCCServiceSystemPolicyDownloadsFolder", title: "Downloads Folder",
              symbol: "arrow.down.circle", settingsAnchor: "Privacy_DownloadsFolder"),
        .init(id: "kTCCServiceSystemPolicyNetworkVolumes", title: "Network Volumes",
              symbol: "externaldrive.connected.to.line.below",
              settingsAnchor: "Privacy_NetworkVolume"),
        .init(id: "kTCCServiceSystemPolicyRemovableVolumes", title: "Removable Volumes",
              symbol: "externaldrive", settingsAnchor: "Privacy_RemovableVolume"),
        .init(id: "kTCCServiceAppleEvents", title: "Automation (Apple Events)",
              symbol: "applescript", settingsAnchor: "Privacy_Automation"),
        .init(id: "kTCCServiceDeveloperTool", title: "Developer Tools",
              symbol: "hammer", settingsAnchor: "Privacy_DevTools"),
        .init(id: "kTCCServiceAddressBook", title: "Contacts",
              symbol: "person.crop.circle", settingsAnchor: "Privacy_Contacts"),
        .init(id: "kTCCServiceCalendar", title: "Calendars",
              symbol: "calendar", settingsAnchor: "Privacy_Calendars"),
        .init(id: "kTCCServiceReminders", title: "Reminders",
              symbol: "checklist", settingsAnchor: "Privacy_Reminders"),
        .init(id: "kTCCServicePhotos", title: "Photos",
              symbol: "photo.on.rectangle", settingsAnchor: "Privacy_Photos"),
        .init(id: "kTCCServiceLocation", title: "Location (apps with entries)",
              symbol: "location", settingsAnchor: "Privacy_LocationServices"),
    ]

    static func lookup(_ id: String) -> TCCService {
        known.first { $0.id == id }
            ?? TCCService(id: id,
                          title: id.replacingOccurrences(of: "kTCCService", with: ""),
                          symbol: "questionmark.circle",
                          settingsAnchor: "Privacy")
    }
}

/// One row of a TCC database: an app's standing for one service.
struct TCCGrant: Identifiable {
    let id = UUID()
    let serviceID: String
    let client: String        // bundle id or absolute binary path
    let allowed: Bool
    let limited: Bool          // auth_value 3 = limited (e.g. selected photos)
    let lastModified: Date?
    let fromSystemDB: Bool

    var clientDisplayName: String {
        if client.hasPrefix("/") {
            return (client as NSString).lastPathComponent
        }
        if let url = NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: client) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return client
    }

    var appIcon: NSImage? {
        guard !client.hasPrefix("/"),
              let url = NSWorkspace.shared.urlForApplication(
                  withBundleIdentifier: client) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

enum TCCReader {
    static var userDBPath: String {
        NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
    }
    static let systemDBPath = "/Library/Application Support/com.apple.TCC/TCC.db"

    /// Both databases merged; `systemReadable` is false without Full Disk
    /// Access, in which case only user-domain services appear.
    static func readAll() -> (grants: [TCCGrant], systemReadable: Bool) {
        var grants = read(path: userDBPath, system: false) ?? []
        let systemGrants = read(path: systemDBPath, system: true)
        if let systemGrants { grants += systemGrants }
        return (grants, systemGrants != nil)
    }

    private static func read(path: String, system: Bool) -> [TCCGrant]? {
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        var db: OpaquePointer?
        let uri = "file:\(path)?mode=ro"
        guard sqlite3_open_v2(uri, &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
                              nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT service, client, auth_value, last_modified FROM access"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }

        var grants: [TCCGrant] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let serviceC = sqlite3_column_text(statement, 0),
                  let clientC = sqlite3_column_text(statement, 1) else { continue }
            let authValue = sqlite3_column_int(statement, 2)
            let modified = sqlite3_column_int64(statement, 3)
            grants.append(TCCGrant(
                serviceID: String(cString: serviceC),
                client: String(cString: clientC),
                allowed: authValue == 2 || authValue == 3,
                limited: authValue == 3,
                lastModified: modified > 0
                    ? Date(timeIntervalSince1970: TimeInterval(modified)) : nil,
                fromSystemDB: system))
        }
        return grants
    }

    /// Revokes one app's grant via the supported `tccutil reset` path.
    /// Returns an error string on failure.
    static func reset(serviceID: String, client: String?) -> String? {
        let serviceName = serviceID.replacingOccurrences(of: "kTCCService",
                                                         with: "")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", serviceName] + (client.map { [$0] } ?? [])
        let errPipe = Pipe()
        task.standardOutput = Pipe()
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            return error.localizedDescription
        }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "tccutil exited with status \(task.terminationStatus)"
        }
        return nil
    }

    static func openSystemSettings(anchor: String) {
        let urlString =
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
