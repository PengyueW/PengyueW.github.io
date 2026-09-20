import Foundation

struct ProcessResult {
    var exitCode: Int32
    var stdout: Data
    var stderr: String
}

enum EngineError: LocalizedError {
    case cliNotFound
    case pythonMissing
    case launchFailed(String)
    case badOutput(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "The macscan command-line tool could not be located. "
                 + "Use Settings to point MacScan at the launcher script."
        case .pythonMissing:
            return "The security engine needs Python 3, and this Mac does not "
                 + "have one installed. (macOS ships only a placeholder at "
                 + "/usr/bin/python3, which reports an \u{201C}xcrun: invalid "
                 + "active developer path\u{201D} error when run.)\n\n"
                 + "Install it with \u{201C}xcode-select --install\u{201D} in "
                 + "Terminal, or with Homebrew (\u{201C}brew install "
                 + "python3\u{201D}), then run the scan again."
        case .launchFailed(let why):
            return "Could not launch the scan engine: \(why)"
        case .badOutput(let why):
            return "The scan engine returned unreadable output: \(why)"
        }
    }
}

/// Async wrapper around Process (NSTask). stdout is accumulated as Data (the
/// JSON report); stderr is streamed line-by-line so the UI can show live
/// progress. Nothing here ever blocks the main thread.
enum CommandRunner {

    static func run(executable: URL,
                    arguments: [String],
                    stdin: Data? = nil,
                    onLaunch: ((Process) -> Void)? = nil,
                    onStderrLine: ((String) -> Void)? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = executable.deletingLastPathComponent()

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var inPipe: Pipe?
        if stdin != nil {
            inPipe = Pipe()
            process.standardInput = inPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        // Register the termination signal before launch so a fast exit can
        // never race past us.
        var exitContinuation: AsyncStream<Int32>.Continuation!
        let exitStream = AsyncStream<Int32> { exitContinuation = $0 }
        let exitCont = exitContinuation!
        process.terminationHandler = { p in
            exitCont.yield(p.terminationStatus)
            exitCont.finish()
        }

        do {
            try process.run()
        } catch {
            throw EngineError.launchFailed(error.localizedDescription)
        }
        onLaunch?(process)

        if let stdin, let inPipe {
            let writer = inPipe.fileHandleForWriting
            // Detached: a full pipe buffer must not deadlock against our reads.
            Task.detached {
                writer.compatWrite(stdin)
                try? writer.close()
            }
        }

        let outHandle = outPipe.fileHandleForReading
        let stdoutTask = Task.detached { () -> Data in
            outHandle.compatReadToEnd() ?? Data()
        }

        var stderrText = ""
        do {
            for await line in errPipe.fileHandleForReading.compatLines() {
                stderrText += line + "\n"
                onStderrLine?(line)
            }
        } catch {
            // Stream torn down (process killed); fall through to collect exit.
        }

        let stdout = await stdoutTask.value
        var exitCode: Int32 = -1
        for await code in exitStream {
            exitCode = code
        }
        return ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderrText)
    }
}
