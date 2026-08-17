import Foundation
import IntelligenceCore

/// One round trip to `agy`, however it gets there.
///
/// Two implementations with very different costs: `AgyAgentAPITransport` reuses a
/// resident language server (~1.6s end to end) and `AgyPrintTransport` starts a
/// process per request (~8.5s). Same seam, so a host that will not boot degrades
/// instead of failing.
public protocol AgyTransport: Sendable {
    /// Starts a conversation and returns its id along with the first reply.
    func open(prompt: String, tier: ModelTier, exactModel: String?, title: String, budget: TimeInterval) async throws -> AgyExchange
    /// Appends to an existing conversation.
    func send(prompt: String, conversationID: String, tier: ModelTier, exactModel: String?, budget: TimeInterval) async throws -> AgyExchange
}

public struct AgyExchange: Sendable {
    public let conversationID: String
    public let text: String
    public let model: String
    public let usage: Usage?

    public init(conversationID: String, text: String, model: String, usage: Usage? = nil) {
        self.conversationID = conversationID
        self.text = text
        self.model = model
        self.usage = usage
    }
}

/// Shared process plumbing. Prompts go in `argv` because `agy` does not read a
/// prompt from stdin (verified); macOS `ARG_MAX` is ~1MB, far above any
/// transcript statement.
enum AgyProcessRunner {
    struct Result: Sendable {
        let standardOutput: String
        let standardError: String
        let status: Int32
    }

    static func run(
        binary: String,
        arguments: [String],
        environment extra: [String: String] = [:],
        workingDirectory: URL? = nil,
        timeout: TimeInterval
    ) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        // Host-agent variables are stripped so a nested agent cannot be confused
        // about which harness it is running under. HOME comes from the passwd
        // database rather than `NSHomeDirectory()`: see `AgyEnvironment`.
        var environment = AgyEnvironment.processEnvironment(adding: extra)
        for key in environment.keys where key.hasPrefix("CLAUDE") || key.hasPrefix("WARP") || key.hasPrefix("AI_AGENT") {
            environment.removeValue(forKey: key)
        }
        process.environment = environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw IntelligenceFailure.providerMissing("could not run \(binary): \(error)")
        }

        // Drain on background queues: a full pipe buffer would deadlock a child
        // that is still writing while we wait for it to exit.
        let outData = UnsafeDataBox()
        let errData = UnsafeDataBox()
        let group = DispatchGroup()
        for (handle, box) in [(out.fileHandleForReading, outData), (err.fileHandleForReading, errData)] {
            group.enter()
            DispatchQueue.global().async {
                box.data = handle.readDataToEndOfFile()
                group.leave()
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
        }
        if process.isRunning {
            process.terminate()
            throw IntelligenceFailure.timedOut(timeout)
        }
        await withCheckedContinuation { continuation in
            group.notify(queue: .global()) { continuation.resume() }
        }

        return Result(
            standardOutput: String(decoding: outData.data, as: UTF8.self),
            standardError: String(decoding: errData.data, as: UTF8.self),
            status: process.terminationStatus
        )
    }

    /// Classifies whatever the CLI complained about, so the router knows whether
    /// to retry, fall back, or give up on the provider entirely.
    static func failure(from text: String, status: Int32) -> IntelligenceFailure {
        let lowered = text.lowercased()
        if lowered.contains("not logged in") || lowered.contains("token source") {
            return .unauthenticated(text.trimmed(240))
        }
        if lowered.contains("429") || lowered.contains("rate limit") || lowered.contains("quota") {
            return .quotaExceeded(text.trimmed(240))
        }
        if lowered.contains("ls_address") || lowered.contains("connection refused")
            || lowered.contains("connection reset") || lowered.contains("unavailable")
        {
            return .sessionDied(text.trimmed(240))
        }
        return .transport("exit \(status): \(text.trimmed(240))")
    }
}

/// `readDataToEndOfFile` off-actor needs somewhere to put its bytes.
final class UnsafeDataBox: @unchecked Sendable {
    var data = Data()
}

extension String {
    func trimmed(_ limit: Int) -> String {
        let clean = trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count <= limit ? clean : String(clean.prefix(limit)) + "…"
    }
}
