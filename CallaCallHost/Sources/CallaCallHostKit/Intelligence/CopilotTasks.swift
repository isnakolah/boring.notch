import Foundation
import IntelligenceCore
import IntelligenceStore

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
        // Headline, steps, and anything worth checking. The rolling summary is a
        // separate task now: asking a fast model to re-summarise the call on every
        // pointer paid for the same paragraph over and over, and made the one thing
        // that has to be quick slower.
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

    /// The rolling account of the call, one chunk at a time.
    ///
    /// Deliberately a different task from `suggest`, on a stronger tier: a summary
    /// is worth thinking about and nobody is waiting on it mid-sentence, whereas a
    /// pointer is the opposite on both counts.
    ///
    /// `.perSession` under its own key, so this lane is a second warm conversation
    /// alongside the pointer's and is never charged a bootstrap mid-call. Because
    /// the conversation remembers the account, each request carries only the turns
    /// since the last one and asks for points about *those* — the account grows by
    /// appending rather than by being rewritten, which is what stops a long call
    /// quietly losing the numbers agreed in its first ten minutes.
    public static let brief = IntelligenceTask(
        id: "copilot.brief",
        defaultTier: .balanced,
        // Points, not prose. A paragraph in a notch panel is read by nobody
        // mid-call; a short stack of lines can be scanned in the gap between
        // sentences.
        contract: .json(keys: ["points", "open_questions"]),
        latencyBudget: 45,
        conversation: .perSession,
        batching: .manual,
        allowedProviders: [.localAgy]
    )

    /// Folds the oldest points into one standing paragraph, so the account can go
    /// on growing without what a question carries growing with it.
    ///
    /// A fresh conversation every time, on purpose: it is given the points it is to
    /// fold and needs no memory beyond them, and a one-shot thread cannot drag the
    /// rest of the call into a job nobody is waiting for.
    public static let exec = IntelligenceTask(
        id: "copilot.exec",
        defaultTier: .balanced,
        contract: .json(keys: ["standing", "open_questions"]),
        latencyBudget: 60,
        conversation: .oneShot,
        batching: .manual,
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
    /// The pack these prompts are read from.
    ///
    /// Set once at startup so the host honours the user's own edits under
    /// `<runtime>/copilot/prompts`; unset it and everything falls back to the
    /// bundled wording.
    public nonisolated(unsafe) static var pack = PromptPack()

    public static var base: String { pack.text(.liveBase) }

    /// The wording that shipped, kept only so the Settings pane can offer
    /// "start from the default" without reaching into the pack.
    public static let bundledBase = """
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
    - `angles`: **at most 2**, each **at most 8 words**. Fragments, not sentences. \
    Where an answer has an order to it, these are its next steps rather than \
    alternatives to it.
    - `confirm`: only numbers, dates, names or commitments the other side just \
    asserted. **At most 2**, each a fragment. Usually empty.

    No filler, no hedging, no restating the question, no explaining your reasoning. \
    Cut every word that is not doing work.

    If nothing useful can be said yet, return an empty `headline` rather than \
    filling the space. Never invent facts about the user's product, pricing, or \
    commitments.

    Input arrives in up to three parts, and they are not equal.

    - `So far:` is the compiled account of the call up to now. Established fact. \
    Never repeat it back, never advise them to say something already covered there.
    - `Just said:` is the last few turns, verbatim. This is the live context: a \
    question almost always refers to it, so read the question in its light and reuse \
    its wording where that is what the question is about.
    - The last line is what to answer. Answer that, not the parts above it.
    """

    /// The persona block, from the pack. Adding a persona is dropping a file
    /// into `live/personas/`; an unknown one falls back to `generic`.
    public static func persona(_ persona: String) -> String {
        pack.persona(persona)
    }

    /// The wording that shipped. Unused at runtime — `persona(_:)` reads the
    /// pack — and kept as the reference the pack files were extracted from.
    static func bundledPersona(_ persona: String) -> String {
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

            `angles` are the **steps of the answer, in the order they should be \
            said** — not alternatives, not commentary. Each one a few words: the \
            next thing out of their mouth after the headline. Think of the headline \
            plus the steps as a spine they can talk down while thinking.

            For a system-design question the steps are the moves: clarify scale, \
            name the bottleneck, pick the store, then the failure mode. For a \
            behavioural question they are the beats: situation, what they did, the \
            result, what they would change. For a coding question: the approach, the \
            complexity, the edge case. Two steps at most on screen, and they should \
            advance as the answer progresses rather than repeating what has already \
            been said.

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
            base: profile?.baseGuidance?.isEmpty == false ? profile!.baseGuidance! : Self.base,
            role: profile?.personaGuidance?.isEmpty == false
                ? profile!.personaGuidance!
                : Self.persona(persona),
            about: profile?.about ?? "",
            knowledge: Self.background(profile: profile),
            taskGuidance: ""
        )
    }

    /// What the call is about, for every lane that needs it.
    ///
    /// The meeting header is rebuilt here rather than trusted to be inside
    /// `knowledge`: the engine composes that blob from the knowledge base, and a
    /// call can have a meeting with nothing written about it yet — which is the
    /// common case on the first occurrence, and exactly when knowing the title and
    /// who is on the call is worth the most.
    public static func background(profile: CallProfile?) -> String {
        var blocks: [String] = []
        if let header = profile?.meeting?.derivedNoteBody() { blocks.append(header) }
        let knowledge = profile?.knowledge?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !knowledge.isEmpty { blocks.append(knowledge) }
        return blocks.joined(separator: "\n\n")
    }
}

/// The prompt for the chunk lane — the growing account.
public enum CopilotBriefPrompt {
    /// From `lanes/brief.md`.
    public static var text: String { CopilotLocalPrompt.pack.text(.laneBrief) }

    /// The wording that shipped, kept as the reference `lanes/brief.md` was
    /// extracted from. `text` is what is actually sent.
    ///
    /// Summarises the newest chunk of a call and nothing else.
    ///
    /// This lane is one warm conversation for the whole call, so it has already
    /// seen everything that came before. That is what lets it be asked for points
    /// about the *new* turns only: the account grows by appending, and the earlier
    /// points are never re-emitted, so they cannot be silently lost in a rewrite.
    public static let base = [
        "You keep the running account of a conversation while it happens.",
        "",
        "Each message is the turns since the last one. Write points about those turns",
        "alone. Everything earlier is already recorded and will be shown alongside",
        "yours, so restating it wastes the space and the reader's time.",
        "",
        "`points`: usually 1 line, never more than 2, each at most 12 words, in the",
        "order the turns happened. Most messages are a single statement and deserve a",
        "single line. No bullet characters, no numbering, no leading dashes — one",
        "thought per line, a fragment rather than a sentence where that is shorter. No",
        "preamble and no 'they discussed'.",
        "",
        "Where the message opens with lines already on the record, they are exactly",
        "that: written down and visible. A line that repeats one of them in different",
        "words is worse than no line at all, because both then sit on a small screen",
        "saying the same thing. Add only what they do not already say.",
        "",
        "Keep what will still matter in an hour: names, numbers, systems, constraints,",
        "decisions, commitments, and who owes what. Drop pleasantries, hedging and",
        "anything already covered. If the turns established nothing durable, return an",
        "empty `points` rather than filling it — an empty answer is a normal answer",
        "here, and most small talk deserves one.",
        "",
        "Where these turns correct something earlier — a figure revised, a plan",
        "abandoned — say so in the point, so the correction outranks the original.",
        "",
        "`open_questions`: at most 3 fragments, raised and not yet answered, carried",
        "forward from earlier ones plus anything new. Drop those since answered.",
        "",
        "Never invent numbers, names or commitments that were not said.",
    ].joined(separator: "\n")
}

/// The prompt for the exec lane — the fold.
public enum CopilotExecPrompt {
    /// From `lanes/exec.md`.
    public static var text: String { CopilotLocalPrompt.pack.text(.laneExec) }

    /// The wording that shipped, kept as the reference `lanes/exec.md` was
    /// extracted from. `text` is what is actually sent.
    ///
    /// Compresses the oldest points into one standing paragraph.
    ///
    /// Read by the same person mid-call, but about the part of the conversation
    /// nobody is discussing any more: it exists so the earlier hour is still
    /// *present* in every question without costing what an hour of points would.
    public static let base = [
        "You compress the earlier part of a conversation into a standing summary.",
        "",
        "The input is the summary so far, if there is one, and the points that have",
        "since accumulated. Merge them into one account of the whole of it.",
        "",
        "`standing`: at most 2 lines, at most 20 words each. Durable fact only — who",
        "the parties are, the numbers and names established, what was decided, what was",
        "promised and by whom. No narrative, no 'they discussed', no preamble.",
        "",
        "Nothing here is recorded anywhere else, so anything you leave out is gone for",
        "the rest of the call. When two facts compete for the space, keep the one a",
        "later answer would be wrong without: a figure, a commitment, a constraint.",
        "",
        "`open_questions`: at most 3 fragments, still unanswered.",
        "",
        "Never invent numbers, names or commitments that were not said.",
    ].joined(separator: "\n")
}

/// The end-of-call pass's own shape.
///
/// `CopilotTasks.summary` declares the keys `summary` and `open_questions`, and
/// was being decoded by `CopilotSuggestionDecoder`, which looks for `headline`,
/// `angles` and `confirm`. Those are always absent, so the deep model's work
/// arrived as a frame that was empty in every field anyone reads — and the
/// durable recap was then built from the ledger instead. The most expensive pass
/// in the system was decoration.
public struct CopilotClosingSummary: Sendable, Equatable {
    public var overview: String
    public var openQuestions: [String]

    public init(overview: String, openQuestions: [String]) {
        self.overview = overview
        self.openQuestions = openQuestions
    }

    private struct Payload: Decodable {
        let summary: String?
        let open_questions: [String]?
        /// Tolerated because the fast lane's shape is what a mis-prompted model
        /// tends to fall back to, and an overview is worth having either way.
        let headline: String?
    }

    public static func decode(_ payload: Data) throws -> CopilotClosingSummary {
        let decoded = try JSONDecoder().decode(Payload.self, from: payload)
        let overview = (decoded.summary ?? decoded.headline ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CopilotClosingSummary(
            overview: overview,
            openQuestions: decoded.open_questions ?? [])
    }
}

/// The prompt for the end-of-call pass.
public enum CopilotSummaryPrompt {
    /// From `lanes/summary.md`.
    public static var text: String { CopilotLocalPrompt.pack.text(.laneSummary) }
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
