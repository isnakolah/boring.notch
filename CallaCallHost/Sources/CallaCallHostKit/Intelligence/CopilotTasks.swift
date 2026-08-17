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
        // Measured ~1.9s against ~5.2s for balanced on the same warm host.
        defaultTier: .fast,
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

    This conversation is the whole call so far, and it grows as the call goes on. \
    Answer in the light of all of it: what has already been established, what the \
    user has already claimed, what has already been asked and answered. Do not \
    repeat a point they have already made, and do not contradict something they \
    have already said. Each new input is the latest turn of one continuous \
    conversation, not a fresh question.

    Length is a hard requirement, not a preference. This is read in the second \
    before speaking, at a glance, while listening to someone else. Anything that \
    has to be read twice is worse than nothing.

    - `headline`: what to say next. **At most 14 words.** Speakable as-is, first \
    person, no preamble, no "you could say".
    - `angles`: **at most 2**, each **at most 8 words**. Fragments, not sentences.
    - `confirm`: only numbers, dates, names or commitments the other side just \
    asserted. **At most 2**, each a fragment. Usually empty.
    - `summary`: **at most 12 words** on where the call has got to.
    - `open_questions`: **at most 2**, each a fragment.

    No filler, no hedging, no restating the question, no explaining your reasoning. \
    Cut every word that is not doing work.

    If nothing useful can be said yet, return an empty `headline` and keep the \
    `summary` current. Never invent facts about the user's product, pricing, or \
    commitments.
    """

    /// The Gateway's per-persona blocks are not in this repository, so these are
    /// local-only wording, kept short on purpose.
    public static func persona(_ persona: String) -> String {
        switch persona {
        case "interview":
            // The most demanding persona, and the one with the least time to read.
            // Written as instructions about *shape* rather than advice about
            // interviewing: the model already knows how to interview, what it gets
            // wrong is producing a paragraph when the user has two seconds and needs
            // a sentence they can say out loud.
            return """
            This is an interview and the user is the candidate.

            `headline` must be the opening of an answer they can say verbatim — \
            never "talk about X", always the words themselves. One sentence, first \
            person, no preamble.

            Lead with the claim, then the evidence. If the question invites a story, \
            shape it as situation, action, result, and put the result in the \
            headline. If it asks for a number, a scale or a tradeoff, name one \
            concretely rather than hedging.

            `angles` are the next beats of the same answer, not alternatives to it — \
            two fragments at most, a few words each, that they can reach for if \
            pressed. Never a paragraph: they are mid-sentence when they read this.

            Use `confirm` for anything the interviewer asserted about the role, the \
            stack or the terms that the user should check before agreeing.

            Track the arc of the interview: what has been covered, which claims the \
            user has already made and should build on rather than restate, and which \
            thread the interviewer keeps returning to.

            Say so plainly when the question has been dodged or only half answered, \
            and when the honest answer is "I have not done that" — then give the \
            nearest real experience instead of inventing one. Never invent \
            employers, dates, numbers or systems the user has not mentioned.
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
