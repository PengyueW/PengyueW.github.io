import Foundation

/// High-level interface to the Python engine. Every state-changing operation
/// goes through the CLI (so its safety guardrails — protected-path refusal,
/// severity eligibility, reversible quarantine — stay authoritative); reads of
/// quarantine/manifest state decode the JSON files the engine itself writes.
struct MacScanEngine {

    let cliURL: URL

    static let cliDefaultsKey = "macscanCLIPath"

    // MARK: - CLI discovery

    /// Find the `macscan` launcher: explicit env var, then the user's saved
    /// choice, then walking up from the app binary and the working directory
    /// (covers both `swift run` in the repo and the bundled .app living in
    /// gui/ or anywhere inside the checkout).
    static func discoverCLI() -> URL? {
        if let env = ProcessInfo.processInfo.environment["MACSCAN_CLI"] {
            let url = URL(fileURLWithPath: env)
            if isLauncher(url) { return url }
        }
        // The engine ships inside the app bundle (Contents/Resources/
        // macscan-engine) so the suite is fully self-contained.
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("macscan-engine/macscan")
            if isLauncher(bundled) { return bundled }
        }
        if let saved = UserDefaults.standard.string(forKey: cliDefaultsKey) {
            let url = URL(fileURLWithPath: saved)
            if isLauncher(url) { return url }
        }
        var roots: [URL] = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        if let exe = Bundle.main.executableURL {
            roots.append(exe.deletingLastPathComponent())
        }
        for root in roots {
            var dir = root.standardizedFileURL
            for _ in 0..<10 {
                let candidate = dir.appendingPathComponent("macscan")
                if isLauncher(candidate) { return candidate }
                let parent = dir.deletingLastPathComponent()
                if parent == dir { break }
                dir = parent
            }
        }
        return nil
    }

    /// A genuine launcher is an executable `macscan` file with the package
    /// source tree (src/macscan) beside it.
    static func isLauncher(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.isExecutableFile(atPath: url.path),
              fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue
        else { return false }
        let pkg = url.deletingLastPathComponent()
            .appendingPathComponent("src/macscan/cli.py")
        return fm.fileExists(atPath: pkg.path)
    }

    // MARK: - Scanning

    struct ScanOutcome {
        var findings: [Finding]
        var exitCode: Int32
    }

    func scan(tier: ScanTier,
              onLaunch: @escaping (Process) -> Void,
              onProgress: @escaping (String) -> Void) async throws -> ScanOutcome {
        let result = try await CommandRunner.run(
            executable: cliURL,
            arguments: ["scan", "--json"] + tier.arguments,
            onLaunch: onLaunch,
            onStderrLine: onProgress)

        // 127 is the launcher's "no usable Python 3 interpreter" exit. It is a
        // missing prerequisite on the machine, not malformed engine output, so
        // it gets an error the user can actually act on rather than a stderr
        // tail about xcrun.
        guard result.exitCode != 127 else { throw EngineError.pythonMissing }

        // 0/1/2 are scan verdicts, not failures (clean / findings / critical).
        guard (0...2).contains(result.exitCode), !result.stdout.isEmpty else {
            let tail = result.stderr.split(separator: "\n").suffix(4).joined(separator: " ")
            throw EngineError.badOutput(
                "exit code \(result.exitCode)\(tail.isEmpty ? "" : " — \(tail)")")
        }
        do {
            let findings = try JSONDecoder().decode([Finding].self, from: result.stdout)
            return ScanOutcome(findings: findings, exitCode: result.exitCode)
        } catch {
            throw EngineError.badOutput(error.localizedDescription)
        }
    }

    // MARK: - Quarantine (state-changing; CLI is authoritative)

    /// Quarantine findings via `macscan quarantine-json`. The CLI re-applies
    /// the eligibility rules (removable + critical/high + concrete paths) and
    /// refuses protected system paths, no matter what we send it.
    func quarantine(_ findings: [Finding]) async throws -> QuarantineBridgeResult {
        let payload = try JSONEncoder().encode(findings)
        let result = try await CommandRunner.run(
            executable: cliURL,
            arguments: ["quarantine-json"],
            stdin: payload)
        guard !result.stdout.isEmpty else {
            throw EngineError.badOutput("quarantine bridge produced no output")
        }
        do {
            return try JSONDecoder().decode(QuarantineBridgeResult.self, from: result.stdout)
        } catch {
            throw EngineError.badOutput(error.localizedDescription)
        }
    }

    /// Restore a quarantined item via `macscan restore <id>`.
    func restore(id: String) async throws -> (success: Bool, message: String) {
        let result = try await CommandRunner.run(
            executable: cliURL,
            arguments: ["restore", id])
        let text = String(data: result.stdout, encoding: .utf8) ?? ""
        return (result.exitCode == 0, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Quarantine / manifest state (read-only file decoding)

    static var quarantineRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".macscan/quarantine")
    }

    static var manifestsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".macscan/manifests")
    }

    static func loadQuarantine() -> [QuarantineRecord] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: quarantineRoot, includingPropertiesForKeys: nil) else { return [] }
        var records: [QuarantineRecord] = []
        for dir in entries {
            let manifest = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifest),
                  let record = try? JSONDecoder().decode(QuarantineRecord.self, from: data)
            else { continue }
            records.append(record)
        }
        return records.sorted { $0.id > $1.id }   // ids start with a timestamp
    }

    /// Permanently delete one quarantined item. The id is validated the same
    /// way quarantine.restore() validates it, and the deletion is constrained
    /// to a direct child of ~/.macscan/quarantine — nothing else is reachable.
    static func purgeQuarantined(id: String) throws {
        guard !id.isEmpty, !id.hasPrefix("."),
              !id.contains("/"), !id.contains("..")
        else { throw EngineError.badOutput("invalid quarantine id '\(id)'") }
        let target = quarantineRoot.appendingPathComponent(id).standardizedFileURL
        guard target.deletingLastPathComponent() == quarantineRoot.standardizedFileURL,
              FileManager.default.fileExists(
                  atPath: target.appendingPathComponent("manifest.json").path)
        else { throw EngineError.badOutput("'\(id)' is not a quarantined item") }
        try FileManager.default.removeItem(at: target)
    }

    static func loadManifests() -> [StateManifest] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: manifestsRoot, includingPropertiesForKeys: nil) else { return [] }
        var manifests: [StateManifest] = []
        for file in entries where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var manifest = try? JSONDecoder().decode(StateManifest.self, from: data)
            else { continue }
            manifest.fileName = file.lastPathComponent
            manifests.append(manifest)
        }
        return manifests.sorted { $0.fileName > $1.fileName }
    }

    // MARK: - Full Disk Access probe

    /// The child Python process inherits this process's TCC grants, so probing
    /// our own read access to the user TCC database answers "will the forensic
    /// tier see TCC.db?" exactly.
    static func hasFullDiskAccess() -> Bool {
        let probe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        let fd = open(probe.path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        return false
    }
}
