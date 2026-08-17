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
        public var taskGuidance: Int

        public init(about: Int = 1200, role: Int = 2000, base: Int = 8000, taskGuidance: Int = 4000) {
            self.about = about
            self.role = role
            self.base = base
            self.taskGuidance = taskGuidance
        }

        public static let standard = Limits()
    }

    /// First message of a conversation: guidance, the output contract, and the
    /// first piece of real input.
    public static func bootstrap(
        for request: IntelligenceRequest,
        limits: Limits = .standard
    ) -> String {
        var sections: [String] = []

        let base = clamp(request.system.base, to: limits.base)
        if !base.isEmpty { sections.append(base) }

        let role = clamp(request.system.role, to: limits.role)
        if !role.isEmpty { sections.append("## Role\n\(role)") }

        let about = clamp(request.system.about, to: limits.about)
        if !about.isEmpty { sections.append("## About the user\n\(about)") }

        let guidance = clamp(request.system.taskGuidance, to: limits.taskGuidance)
        if !guidance.isEmpty { sections.append("## Task\n\(guidance)") }

        sections.append(houseRules)

        if let contract = contractInstruction(request.task.contract) {
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
    static let houseRules = """
    ## Rules
    Answer directly from the input. Never call tools, never read or write files, \
    never search. No preamble, no closing remarks, no restating the question.
    """

    static func contractInstruction(_ contract: OutputContract) -> String? {
        switch contract {
        case .freeform:
            return nil
        case let .json(keys):
            return """
            ## Output
            Reply with a single JSON object and nothing else. Required keys: \
            \(keys.map { "`\($0)`" }.joined(separator: ", ")).
            """
        case let .sentinelJSON(keys, marker):
            return """
            ## Output
            Reply with a single JSON object and nothing else. Required keys: \
            \(keys.map { "`\($0)`" }.joined(separator: ", ")). \
            After the object, output a final line containing exactly \(marker)
            """
        }
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
