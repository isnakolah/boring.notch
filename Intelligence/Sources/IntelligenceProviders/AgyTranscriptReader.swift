import Foundation
import IntelligenceCore

/// Reads replies back out of `agy`.
///
/// `agy agentapi` submits and returns immediately — it never carries the answer.
/// The answer lands in a plain JSONL log the CLI keeps per conversation:
///
///     ~/.gemini/antigravity-cli/brain/<cid>/.system_generated/logs/transcript.jsonl
///     {"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"…"}
///
/// Verified over a multi-turn conversation: `step_index` is monotonic and no
/// partially-written line was ever observed. The conversation sqlite holds the
/// same text as protobuf blobs; this is the sane surface.
public struct AgyTranscriptReader: Sendable {
    public struct Step: Sendable, Hashable, Decodable {
        public let stepIndex: Int
        public let source: String
        public let type: String?
        public let status: String?
        public let content: String?

        enum CodingKeys: String, CodingKey {
            case stepIndex = "step_index"
            case source, type, status, content
        }

        /// A finished answer from the model, as opposed to a system checkpoint,
        /// the conversation-history marker, or our own input echoed back.
        public var isModelAnswer: Bool {
            source == "MODEL" && status == "DONE" && !(content ?? "").isEmpty
        }
    }

    private let root: URL
    private let pollInterval: UInt64

    public init(root: URL? = nil, pollInterval: TimeInterval = 0.05) {
        self.root = root ?? URL(
            fileURLWithPath: NSString(string: "~/.gemini/antigravity-cli/brain").expandingTildeInPath
        )
        self.pollInterval = UInt64(max(0.005, pollInterval) * 1_000_000_000)
    }

    public func transcriptURL(for conversationID: String) -> URL {
        root
            .appendingPathComponent(conversationID)
            .appendingPathComponent(".system_generated/logs/transcript.jsonl")
    }

    /// Highest model-answer step already present, so a later wait cannot return a
    /// reply that belongs to an earlier turn.
    public func lastAnswerIndex(for conversationID: String) -> Int {
        steps(for: conversationID)
            .filter(\.isModelAnswer)
            .map(\.stepIndex)
            .max() ?? -1
    }

    /// Waits for the first model answer past `after`.
    public func awaitAnswer(
        conversationID: String,
        after: Int,
        budget: TimeInterval
    ) async throws -> Step {
        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline {
            if let step = steps(for: conversationID)
                .first(where: { $0.isModelAnswer && $0.stepIndex > after })
            {
                return step
            }
            try? await Task.sleep(nanoseconds: pollInterval)
            if Task.isCancelled { throw CancellationError() }
        }
        throw IntelligenceFailure.timedOut(budget)
    }

    /// Every parseable step. A trailing partial line is skipped rather than
    /// treated as corruption — the next poll will see it whole.
    public func steps(for conversationID: String) -> [Step] {
        guard let text = try? String(contentsOf: transcriptURL(for: conversationID), encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(Step.self, from: data)
        }
    }
}
