import Foundation
import IntelligenceCore

/// What the copilot asks the intelligence layer for.
///
/// Two tasks with deliberately different shapes: a live one that must answer
/// while the moment is still live, and an end-of-call one where quality matters
/// and latency does not.
public enum CopilotTasks {
    /// The sentinel is what makes a reply unambiguously finished, without paying
    /// for `--json-schema` (which costs a whole extra turn).
    public static let sentinel = "<<<CALLA_END>>>"

    /// Keys match the Gateway's own contract, so a local suggestion decodes into
    /// exactly the same `CopilotFrame.Suggestion` the rest of the app already
    /// handles.
    public static let suggest = IntelligenceTask(
        id: "copilot.suggest",
        defaultTier: .balanced,
        contract: .sentinelJSON(
            keys: ["headline", "angles", "confirm"],
            marker: sentinel
        ),
        // Measured round trips are ~2.5-3.5s. Past this the suggestion is about a
        // moment that has already passed, so it is worth less than nothing.
        latencyBudget: 12,
        conversation: .perSession,
        batching: .statement(.call),
        allowedProviders: [.localAgy]
    )

    /// One pass when the call ends. Runs on the deep tier through the print
    /// transport, which is slow (~8.5s) but can name an exact model.
    public static let summary = IntelligenceTask(
        id: "copilot.summary",
        defaultTier: .deep,
        contract: .json(keys: ["summary", "open_questions"]),
        latencyBudget: 90,
        conversation: .perSession,
        batching: .manual,
        allowedProviders: [.localAgy]
    )
}

/// The local provider's own prompt.
///
/// Deliberately *not* the Gateway's ~8k system prompt: every request re-pays the
/// provider's ~15k-token tool preamble, so a compact block is the difference
/// between a fast copilot and a slow one. The Gateway keeps its own wording when
/// it is answering.
public enum CopilotLocalPrompt {
    public static let base = """
    You sit beside someone during a live call and tell them what to say next.

    You see a running transcript labelled `Me:` (the user) and `Them:` (everyone \
    else). Advise the user only. Be concrete, short, and specific to what was just \
    said — never generic coaching, never a summary of what you heard.

    - `headline`: the single most useful thing to say or ask next, in one short \
    sentence, phrased so it can be read aloud.
    - `angles`: up to three brief alternative directions, each a fragment.
    - `confirm`: facts or numbers just stated that the user should verify before \
    agreeing to them. Empty when there are none.
    - `summary`: one sentence on where the conversation has got to.
    - `open_questions`: things raised and not yet answered.

    If nothing useful can be said yet, return an empty `headline` and keep the \
    `summary` current. Never invent facts about the user's product, pricing, or \
    commitments.
    """

    /// The Gateway's per-persona blocks are not in this repository, so these are
    /// local-only wording, kept short on purpose.
    public static func persona(_ persona: String) -> String {
        switch persona {
        case "interview":
            return """
            This is an interview. Help the user answer with evidence and structure, \
            and flag when a question has been dodged or only half answered.
            """
        case "sales":
            return """
            This is a sales call. Surface the next qualifying question, watch for \
            buying signals and unstated objections, and never promise terms.
            """
        case "support":
            return """
            This is a support call. Drive towards reproduction, scope, and the next \
            concrete step. Ask for specifics rather than reassurance.
            """
        default:
            return """
            General conversation. Keep the user precise and moving, and surface \
            anything left ambiguous.
            """
        }
    }

    /// Builds the blocks for a request from the user's own profile, falling back to
    /// the local defaults. A profile the engine accepted is already within the
    /// 1200/2000/8000 limits, and `PromptComposer` clamps anyway.
    public static func blocks(persona: String, profile: CallProfile?) -> PromptBlocks {
        PromptBlocks(
            base: profile?.baseGuidance?.isEmpty == false ? profile!.baseGuidance! : base,
            role: profile?.personaGuidance?.isEmpty == false
                ? profile!.personaGuidance!
                : Self.persona(persona),
            about: profile?.about ?? "",
            taskGuidance: ""
        )
    }
}

/// Turns a contract payload into the frame the whole app already speaks.
public enum CopilotSuggestionDecoder {
    private struct Payload: Decodable {
        let headline: String?
        let angles: [String]?
        let confirm: [String]?
        let summary: String?
        let open_questions: [String]?
    }

    /// `afterSeq` is the last transcript turn the suggestion accounts for, which
    /// keeps `suggestionAfterSeq` meaning what it has always meant on the app side.
    public static func decode(
        _ payload: Data,
        callID: String,
        afterSeq: Int,
        latency: TimeInterval
    ) throws -> CopilotFrame.Suggestion {
        let decoded = try JSONDecoder().decode(Payload.self, from: payload)
        return CopilotFrame.Suggestion(
            callID: callID,
            afterSeq: afterSeq,
            headline: decoded.headline ?? "",
            angles: decoded.angles ?? [],
            confirm: decoded.confirm ?? [],
            summary: decoded.summary ?? "",
            openQuestions: decoded.open_questions ?? [],
            latencyMs: Int((latency * 1000).rounded())
        )
    }
}
