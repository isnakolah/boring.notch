import Foundation

/// Result of executing a CLI command.
struct CLIResult: Sendable, Equatable {
    let output: String
    let exitCode: Int32

    init(output: String, exitCode: Int32 = 0) {
        self.output = output
        self.exitCode = exitCode
    }
}

/// Protocol for executing CLI commands.
protocol CLIExecutor: Sendable {
    /// Finds a tool on the system. Returns the path if found, nil otherwise.
    func locate(_ binary: String) -> String?

    /// Runs a CLI command and returns the result.
    ///
    /// - Parameter completionMarkers: substrings that signal the command has
    ///   produced its final output. While none have appeared the runner suppresses
    ///   its idle-exit and keeps reading up to the hard timeout — needed for TUIs
    ///   like `claude /usage` that render a "loading…" screen then fall silent
    ///   during a network fetch before drawing the real data.
    func execute(
        binary: String,
        args: [String],
        input: String?,
        timeout: TimeInterval,
        workingDirectory: URL?,
        autoResponses: [String: String],
        completionMarkers: [String]
    ) throws -> CLIResult
}

extension CLIExecutor {
    /// Convenience overload for callers that don't need completion gating.
    func execute(
        binary: String,
        args: [String],
        input: String?,
        timeout: TimeInterval,
        workingDirectory: URL?,
        autoResponses: [String: String]
    ) throws -> CLIResult {
        try execute(
            binary: binary,
            args: args,
            input: input,
            timeout: timeout,
            workingDirectory: workingDirectory,
            autoResponses: autoResponses,
            completionMarkers: []
        )
    }
}
