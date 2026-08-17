import Foundation
import IntelligenceCore

/// The fast path: submit through a resident language server, read the reply from
/// the conversation's JSONL log.
///
/// Measured: 0.06s to submit, 1.6-3.2s until the answer is readable, versus 8.5s
/// for a fresh `agy -p` process. A dead host is detected in 0.07s rather than
/// hanging, which is what makes automatic fallback usable mid-call.
public struct AgyAgentAPITransport: AgyTransport {
    private let binary: String
    private let host: AgyHost
    private let reader: AgyTranscriptReader
    private let catalog: ModelCatalog
    /// Submitting is a local RPC; if it takes longer than this the server is gone.
    private let submitTimeout: TimeInterval

    public init(
        binary: String,
        host: AgyHost,
        reader: AgyTranscriptReader = .init(),
        catalog: ModelCatalog = .agy,
        submitTimeout: TimeInterval = 10
    ) {
        self.binary = binary
        self.host = host
        self.reader = reader
        self.catalog = catalog
        self.submitTimeout = submitTimeout
    }

    public func open(
        prompt: String,
        tier: ModelTier,
        exactModel: String?,
        title: String,
        budget: TimeInterval
    ) async throws -> AgyExchange {
        let endpoint = try await host.ensureRunning()
        let token = catalog.tierToken(for: tier) ?? "flash"

        let response = try await submit(
            ["agentapi", "new-conversation", "--model=\(token)", "--title=\(title)", prompt],
            endpoint: endpoint
        )
        guard let conversationID = response["response"]
            .flatMap({ $0 as? [String: Any] })?["newConversation"]
            .flatMap({ $0 as? [String: Any] })?["conversationId"] as? String
        else {
            throw AgyProcessRunner.failure(from: describe(response), status: 0)
        }

        let step = try await reader.awaitAnswer(conversationID: conversationID, after: -1, budget: budget)
        return AgyExchange(
            conversationID: conversationID,
            text: step.content ?? "",
            model: catalog.entry(for: tier)?.displayName ?? token,
            usage: nil // agentapi reports none; AgyProvider estimates instead.
        )
    }

    public func send(
        prompt: String,
        conversationID: String,
        tier: ModelTier,
        exactModel: String?,
        budget: TimeInterval
    ) async throws -> AgyExchange {
        let endpoint = try await host.ensureRunning()
        // Capture the high-water mark *before* submitting, or a fast reply could
        // be mistaken for the previous turn's.
        let after = reader.lastAnswerIndex(for: conversationID)

        let response = try await submit(
            ["agentapi", "send-message", conversationID, prompt],
            endpoint: endpoint
        )
        guard let payload = response["response"] as? [String: Any], payload["sendMessage"] != nil else {
            throw AgyProcessRunner.failure(from: describe(response), status: 0)
        }

        let step = try await reader.awaitAnswer(conversationID: conversationID, after: after, budget: budget)
        return AgyExchange(
            conversationID: conversationID,
            text: step.content ?? "",
            model: catalog.entry(for: tier)?.displayName ?? "flash",
            usage: nil
        )
    }

    // MARK: - Plumbing

    private func submit(_ arguments: [String], endpoint: AgyHost.Endpoint) async throws -> [String: Any] {
        let result = try await AgyProcessRunner.run(
            binary: binary,
            arguments: arguments,
            environment: endpoint.environment,
            timeout: submitTimeout
        )
        guard let data = result.standardOutput.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let failure = AgyProcessRunner.failure(
                from: result.standardError.isEmpty ? result.standardOutput : result.standardError,
                status: result.status
            )
            await host.invalidate()
            throw failure
        }
        // agentapi answers 200-shaped JSON even for failures, with an `error` key.
        if let error = object["error"] as? String, !error.isEmpty {
            let failure = AgyProcessRunner.failure(from: error, status: result.status)
            if case .sessionDied = failure { await host.invalidate() }
            throw failure
        }
        return object
    }

    private func describe(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "\(object)" }
        return String(decoding: data, as: UTF8.self)
    }
}
