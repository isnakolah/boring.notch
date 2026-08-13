import Foundation

// The single chokepoint for running an external binary. Nothing else in Sweep
// may construct a Process, and nothing anywhere composes a shell command string:
// the executable and its arguments are always passed separately, so a path
// containing a space or a quote cannot become an injection.
//
// Phase 02 needs this for the launchctl fallback; Phase 08 uses it for vendor
// teardown commands, which is why it lives under Reclaim/.

struct ProcessResult: Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var succeeded: Bool { exitCode == 0 }
}

enum ProcessRunnerError: Error, Equatable {
    case executableNotFound(String)
    case launchFailed(String)
    case timedOut(after: TimeInterval)
}

protocol ProcessRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> ProcessResult
    /// The full path to a binary on the *login* shell's PATH, or nil. Teardown
    /// commands (`brew`, `docker`) live on the login PATH, which a GUI app does
    /// not inherit, so it must be resolved explicitly.
    func resolveOnLoginPath(_ binary: String) -> String?
}

extension ProcessRunning {
    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        try run(executable, arguments, timeout: 30)
    }
}

struct ProcessRunner: ProcessRunning {

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessRunnerError.executableNotFound(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        // Drain both pipes concurrently. A process that fills the 64 KB pipe
        // buffer blocks forever if we wait for exit before reading.
        let collector = OutputCollector()
        let draining = DispatchGroup()
        for (handle, isStdout) in [(outPipe.fileHandleForReading, true), (errPipe.fileHandleForReading, false)] {
            DispatchQueue.global(qos: .userInitiated).async(group: draining) {
                let data = handle.readDataToEndOfFile()
                collector.append(data, isStdout: isStdout)
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                // Give it a moment to die on SIGTERM before escalating.
                if !waitForExit(process, within: 2) {
                    kill(process.processIdentifier, SIGKILL)
                }
                break
            }
            usleep(20_000)
        }

        process.waitUntilExit()
        draining.wait()

        if timedOut {
            throw ProcessRunnerError.timedOut(after: timeout)
        }

        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: collector.text(stdout: true),
            standardError: collector.text(stdout: false))
    }

    // Resolves a binary against the login shell's PATH. The only shell string used
    // is the fixed literal `echo $PATH` — the tool command itself never touches a
    // shell, so there is nothing to inject into (AGENTS: never compose shell
    // strings by hand).
    func resolveOnLoginPath(_ binary: String) -> String? {
        guard let path = Self.loginPath.value else { return nil }
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(binary)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    // Resolved once per process. `/bin/zsh -lc 'echo $PATH'` loads the user's login
    // environment (their Homebrew, asdf, etc.).
    private static let loginPath = LoginPath()

    private final class LoginPath: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: String??
        var value: String? {
            lock.lock(); defer { lock.unlock() }
            if let cached { return cached }
            let resolved = Self.query()
            cached = resolved
            return resolved
        }
        private static func query() -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "echo $PATH"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        }
    }

    private func waitForExit(_ process: Process, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning {
            if Date() >= deadline { return false }
            usleep(20_000)
        }
        return true
    }
}

// Both pipe readers write here from their own queues.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func append(_ data: Data, isStdout: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isStdout { out.append(data) } else { err.append(data) }
    }

    func text(stdout: Bool) -> String {
        lock.lock()
        defer { lock.unlock() }
        let data = stdout ? out : err
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
