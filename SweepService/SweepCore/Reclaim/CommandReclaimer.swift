import Foundation

// Reclaims by running a toolchain's own teardown command instead of deleting its
// files (C5). The command frees space globally (e.g. `docker system prune`), so
// the bytes returned here are only for accounting; the figure the user sees is the
// measured volume delta.
//
// No shell string is composed: the binary is resolved against the login PATH and
// executed directly with its argument array (both from `KnownTools`, never user
// input). The 10-minute timeout bounds a slow prune.
struct CommandReclaimer: Reclaimer {
    let teardown: KnownTools.Teardown
    let runner: any ProcessRunning

    static let timeout: TimeInterval = 10 * 60

    func reclaim(_ target: Target, progress: @escaping @Sendable (Double) -> Void) async throws -> Int64 {
        try assertReclaimable(target)
        progress(0)

        guard let binaryPath = runner.resolveOnLoginPath(teardown.binary) else {
            // The planner should have downgraded already; refuse rather than fail
            // silently if a command reclaimer is built without its binary.
            throw ReclaimError.teardownFailed("\(teardown.binary) is not on the PATH")
        }

        let result: ProcessResult
        do {
            result = try runner.run(binaryPath, teardown.arguments, timeout: Self.timeout)
        } catch {
            throw ReclaimError.teardownFailed(describe(error))
        }

        progress(1)
        guard result.succeeded else {
            throw ReclaimError.teardownFailed(
                "\(teardown.binary) exited \(result.exitCode): \(result.standardError)")
        }
        // The command acted on the owner's data; the target's bytes are the best
        // per-item estimate, but the engine reports the measured delta.
        return target.bytes
    }

    private func describe(_ error: Error) -> String {
        if let processError = error as? ProcessRunnerError {
            switch processError {
            case .executableNotFound(let path): return "\(path) not found"
            case .launchFailed(let message): return message
            case .timedOut(let after): return "timed out after \(Int(after))s"
            }
        }
        return error.localizedDescription
    }
}
