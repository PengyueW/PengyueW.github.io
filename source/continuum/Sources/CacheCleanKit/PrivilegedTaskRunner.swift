import Foundation

/// Runs the two maintenance commands that need elevated rights or system
/// daemons: rebuilding the Spotlight index and flushing the DNS cache.
///
/// ## Why AppleScript "with administrator privileges"?
/// `mdutil -E /` requires root. The options on macOS are:
///
/// 1. **`SMAppService` daemon + XPC** — the correct production answer: a tiny
///    helper registered via `SMAppService.daemon(plistName:)`, validated by
///    code-signing requirements on both ends of the XPC connection, doing
///    exactly one whitelisted operation. Requires a signed, bundled app and
///    a noticeable amount of scaffolding.
/// 2. **`NSAppleScript` "do shell script … with administrator privileges"** —
///    macOS itself shows the standard admin password sheet; the password never
///    passes through this process. Appropriate for an unsandboxed utility that
///    performs an occasional one-shot command.
/// 3. ~~`AuthorizationExecuteWithPrivileges`~~ — deprecated and unsafe; never use.
///
/// This app ships option 2 with a hard-coded, non-interpolated command string
/// (no user input can ever reach the shell). If you move this into a signed,
/// distributable product, migrate to option 1.
struct PrivilegedTaskRunner {

    struct CommandError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Rebuild the Spotlight index for the boot volume (`mdutil -E /`).
    /// Spotlight erases and rebuilds the index in the background afterwards;
    /// searches may be incomplete for a while — surfaced to the user in the UI.
    static func rebuildSpotlightIndex() async throws -> String {
        try await runWithAdminPrivileges("/usr/bin/mdutil -E /")
    }

    /// Flush the DNS cache. `dscacheutil -flushcache` clears the Directory
    /// Service cache; HUP-ing mDNSResponder makes it drop its own cache too.
    static func flushDNSCache() async throws -> String {
        try await runWithAdminPrivileges("/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder")
    }

    /// Executes a **constant** shell command with the system admin-password
    /// prompt. The command must never contain interpolated user data.
    private static func runWithAdminPrivileges(_ command: String) async throws -> String {
        // NSAppleScript must run on a thread with a runloop; a detached task +
        // synchronous execution is fine for these short commands.
        try await Task.detached(priority: .userInitiated) { () throws -> String in
            // Escape only for embedding in the AppleScript string literal —
            // the command itself is a compile-time constant.
            let escaped = command
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let source = "do shell script \"\(escaped)\" with administrator privileges"

            var errorInfo: NSDictionary?
            guard let script = NSAppleScript(source: source) else {
                throw CommandError(message: "Could not build AppleScript.")
            }
            let output = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let number = errorInfo[NSAppleScript.errorNumber] as? Int
                if number == -128 {
                    throw CommandError(message: "Cancelled — no changes were made.")
                }
                let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                throw CommandError(message: message)
            }
            return output.stringValue ?? "Done."
        }.value
    }
}
