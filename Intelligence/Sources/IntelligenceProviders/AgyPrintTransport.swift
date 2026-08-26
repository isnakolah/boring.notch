import Foundation
import IntelligenceCore

/// The slow, dependable path: one `agy -p` process per request.
///
/// ~8.5s each, because every process re-pays the Google handshake. Worth it in
/// exactly two places: when the resident host will not boot, and for unhurried
/// passes like an end-of-call summary — where it also buys back the thing the
/// fast path gives up, an **exact** model id rather than a coarse tier.
///
/// Flags chosen from measurements: default mode (`--mode plan` costs +790 input
/// tokens and `--sandbox` +722, for no benefit here), and no `--json-schema`
/// (it works, but spends an extra turn).
public struct AgyPrintTransport: AgyAttachmentTransport {
    private let binary: String
    private let workspace: URL
    private let catalog: ModelCatalog

    public init(binary: String, workspace: URL, catalog: ModelCatalog = .agy) {
        self.binary = binary
        self.workspace = workspace
        self.catalog = catalog
    }

    public func open(
        prompt: String,
        tier: ModelTier,
        exactModel: String?,
        title: String,
        budget: TimeInterval
    ) async throws -> AgyExchange {
        try await print(prompt: prompt, conversationID: nil, tier: tier, exactModel: exactModel, budget: budget)
    }

    public func send(
        prompt: String,
        conversationID: String,
        tier: ModelTier,
        exactModel: String?,
        budget: TimeInterval
    ) async throws -> AgyExchange {
        try await print(prompt: prompt, conversationID: conversationID, tier: tier, exactModel: exactModel, budget: budget)
    }

    /// Tutor attachments deliberately do not share ordinary print mode: this
    /// invocation is print-only, sandboxed, plan-only, and has slash commands
    /// disabled.  The CLI resolves the relative `@filename`; no model tool or
    /// file URL is offered.
    func openAttachment(
        prompt: String,
        tier: ModelTier,
        exactModel: String?,
        title: String,
        budget: TimeInterval
    ) async throws -> AgyExchange {
        try await print(
            prompt: prompt,
            conversationID: nil,
            tier: tier,
            exactModel: exactModel,
            budget: budget,
            tutorAttachment: true
        )
    }

    private struct PrintResult: Decodable {
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
        }

        let conversation_id: String
        let status: String
        let response: String?
        let usage: Usage?
    }

    private func print(
        prompt: String,
        conversationID: String?,
        tier: ModelTier,
        exactModel: String?,
        budget: TimeInterval,
        tutorAttachment: Bool = false
    ) async throws -> AgyExchange {
        let model = exactModel ?? catalog.exactID(for: tier) ?? "gemini-3.7-flash-low"
        var arguments = tutorAttachment
            ? Self.tutorAttachmentArguments(prompt: prompt, model: model)
            : ["-p", prompt, "--model", model, "--output-format", "json"]
        if let conversationID {
            arguments += ["--conversation", conversationID]
        }
        // The CLI default is 5 minutes; a live call cannot wait that long, and a
        // hung process must surface as a timeout we can fall back from.
        arguments += ["--print-timeout", "\(Int(max(5, budget.rounded())))s"]

        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let result = try await AgyProcessRunner.run(
            binary: binary,
            arguments: arguments,
            workingDirectory: workspace,
            // Leave room for process start-up on top of the model's own budget.
            timeout: budget + 10
        )
        guard let data = result.standardOutput.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(PrintResult.self, from: data)
        else {
            throw AgyProcessRunner.failure(
                from: result.standardError.isEmpty ? result.standardOutput : result.standardError,
                status: result.status
            )
        }
        guard decoded.status == "SUCCESS", let text = decoded.response else {
            throw AgyProcessRunner.failure(from: result.standardOutput, status: result.status)
        }

        return AgyExchange(
            conversationID: decoded.conversation_id,
            text: text,
            model: model,
            usage: decoded.usage.map {
                Usage(inputTokens: $0.input_tokens, outputTokens: $0.output_tokens, estimated: false)
            }
        )
    }

    static func tutorAttachmentArguments(prompt: String, model: String) -> [String] {
        ["--print", prompt, "--model", model, "--output-format", "json",
         "--mode", "plan", "--sandbox", "--disable-slash-commands"]
    }
}
