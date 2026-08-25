import Foundation

/// Builds the two kinds of message a conversation ever needs: the bootstrap
/// (contract + guidance, sent exactly once) and the delta (only what is new).
///
/// Every request re-pays the provider's own system-prompt overhead — ~15k tokens
/// for `agy`, which no flag removes — so restating guidance is the one waste we
/// can actually avoid.
public enum PromptComposer {
    /// Ceilings inherited from `CallaCopilotCommandValidation`, so a profile that
    /// the engine accepted cannot overflow a prompt here.
    public struct Limits: Sendable, Hashable {
        public var about: Int
        public var role: Int
        public var base: Int
        /// Larger than the rest because it is assembled from several notes plus a
        /// previous call's account. Still bounded: this is sent once per
        /// conversation, but a rollover re-sends it, and an unbounded block would
        /// make every rollover progressively slower.
        public var knowledge: Int
        public var taskGuidance: Int

        public init(
            about: Int = 1200,
            role: Int = 2000,
            base: Int = 8000,
            knowledge: Int = 8000,
            taskGuidance: Int = 4000
        ) {
            self.about = about
            self.role = role
            self.base = base
            self.knowledge = knowledge
            self.taskGuidance = taskGuidance
        }

        public static let standard = Limits()
    }

    /// First message of a conversation: guidance, the output contract, and the
    /// first piece of real input.
    public static func bootstrap(
        for request: IntelligenceRequest,
        limits: Limits = .standard,
        pack: PromptPack = PromptPack()
    ) -> String {
        var sections: [String] = []

        let base = clamp(request.system.base, to: limits.base)
        if !base.isEmpty { sections.append(base) }

        let role = clamp(request.system.role, to: limits.role)
        if !role.isEmpty { sections.append("## Role\n\(role)") }

        let about = clamp(request.system.about, to: limits.about)
        if !about.isEmpty { sections.append("## About the user\n\(about)") }

        // After `about` and before the contract: it is context to reason from,
        // not an instruction, and putting it last would have it read as the most
        // recent thing asked for.
        let knowledge = clamp(request.system.knowledge, to: limits.knowledge)
        if !knowledge.isEmpty { sections.append("## Background\n\(knowledge)") }

        let guidance = clamp(request.system.taskGuidance, to: limits.taskGuidance)
        if !guidance.isEmpty { sections.append("## Task\n\(guidance)") }

        sections.append(pack.text(.houseRules))

        if let contract = pack.contractInstruction(request.task.contract) {
            sections.append(contract)
        }

        sections.append("## Input\n\(request.input)")
        return sections.joined(separator: "\n\n")
    }

    /// Every later message: only what is new. The conversation holds the rest,
    /// and restating guidance would cost tokens for no gain.
    public static func delta(for request: IntelligenceRequest) -> String {
        request.input
    }

    /// Sent once, in the bootstrap. Keeps the model from reaching for tools it
    /// has no business using — the workspace it runs in is deliberately empty.
    ///
    /// The wording lives in `composer/house-rules.md`; this reads whatever is
    /// effective, so an override is visible to callers that ask here.
    static var houseRules: String { PromptPack().text(.houseRules) }

    static func contractInstruction(
        _ contract: OutputContract,
        pack: PromptPack = PromptPack()
    ) -> String? {
        pack.contractInstruction(contract)
    }

    /// Truncates on a word boundary and says so, rather than cutting mid-word and
    /// leaving the model to guess.
    static func clamp(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let cut = trimmed.index(trimmed.startIndex, offsetBy: limit)
        let head = trimmed[trimmed.startIndex ..< cut]
        let boundary = head.lastIndex(where: { $0.isWhitespace }) ?? cut
        return String(trimmed[trimmed.startIndex ..< boundary]) + "\n[truncated]"
    }
}

public extension PromptComposer {
    /// A statement rendered for the model, with speaker attribution and a note
    /// when the size cap cut it mid-sentence.
    static func render(_ statement: Statement) -> String {
        let who = statement.speaker == .local ? "Me" : "Them"
        let suffix = statement.truncated ? " […statement continues]" : ""
        return "\(who): \(statement.text)\(suffix)"
    }

    /// Several statements that accumulated while a request was in flight. One
    /// request carrying three statements beats three requests.
    static func render(_ statements: [Statement]) -> String {
        statements.map(render).joined(separator: "\n")
    }
}
