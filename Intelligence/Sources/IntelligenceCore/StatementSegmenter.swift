import Foundation

public enum Speaker: String, Codable, Sendable, CaseIterable {
    case local = "me"
    case remote = "them"

    public var other: Speaker { self == .local ? .remote : .local }
}

/// A transcript turn as the segmenter sees it. Deliberately not the call host's
/// `CallTurn`: core knows nothing about Whisper or the copilot.
public struct TranscriptTurn: Sendable, Hashable {
    public let seq: Int
    public let speaker: Speaker
    /// Seconds since the session started.
    public let start: Double
    public let end: Double
    public let text: String

    public init(seq: Int, speaker: Speaker, start: Double, end: Double, text: String) {
        self.seq = seq
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }

    public var duration: Double { max(0, end - start) }
}

/// A complete thought, worth spending a request on.
public struct Statement: Sendable, Hashable {
    public let fromSeq: Int
    public let toSeq: Int
    public let speaker: Speaker
    public let text: String
    public let span: Double
    /// The buffer was flushed mid-sentence by the size cap; the prompt should
    /// say the statement continues.
    public let truncated: Bool

    public init(fromSeq: Int, toSeq: Int, speaker: Speaker, text: String, span: Double, truncated: Bool) {
        self.fromSeq = fromSeq
        self.toSeq = toSeq
        self.speaker = speaker
        self.text = text
        self.span = span
        self.truncated = truncated
    }
}

/// Thresholds for `StatementSegmenter`. On the task descriptor, so a future
/// consumer tunes batching without touching the algorithm.
public struct StatementRules: Sendable, Hashable {
    /// A turn at least this long hit the VAD's own utterance cap and is
    /// certainly mid-sentence.
    public var vadCapSeconds: Double
    /// Silence after a capped turn below which we assume the continuation is
    /// still coming.
    public var cappedContinuationGap: Double
    /// Silence after a question before it goes out.
    ///
    /// Far shorter than the other boundaries, and it ignores the request floor: a
    /// question is the one input where the answer is wanted *now*, and the cost of
    /// being early is a suggestion about a question that was still being finished.
    public var questionGap: Double
    /// Silence needed after terminal punctuation.
    public var terminalGap: Double
    /// Silence that ends a statement even without punctuation.
    public var silenceGap: Double
    /// While the text ends on a conjunction or filler, require this much
    /// silence instead of `silenceGap`.
    public var hangingGap: Double
    /// Below this, a buffer is not a statement yet.
    public var minWords: Int
    /// Force a flush at this size even mid-sentence.
    public var maxWords: Int
    /// Force a flush at this span even mid-sentence.
    public var maxSpan: Double
    /// Flush a stalled buffer after this much quiet.
    public var idleWait: Double
    /// Minimum spacing between emissions; below it, statements accumulate.
    public var requestFloor: Double
    /// A flushed buffer shorter than this with no question mark is dropped.
    public var minMeaningfulWords: Int

    public init(
        vadCapSeconds: Double = 9.5,
        cappedContinuationGap: Double = 0.3,
        questionGap: Double = 0.35,
        terminalGap: Double = 0.7,
        silenceGap: Double = 1.5,
        hangingGap: Double = 2.5,
        minWords: Int = 8,
        maxWords: Int = 120,
        maxSpan: Double = 30,
        idleWait: Double = 4,
        requestFloor: Double = 2.5,
        minMeaningfulWords: Int = 3
    ) {
        self.vadCapSeconds = vadCapSeconds
        self.cappedContinuationGap = cappedContinuationGap
        self.questionGap = questionGap
        self.terminalGap = terminalGap
        self.silenceGap = silenceGap
        self.hangingGap = hangingGap
        self.minWords = minWords
        self.maxWords = maxWords
        self.maxSpan = maxSpan
        self.idleWait = idleWait
        self.requestFloor = requestFloor
        self.minMeaningfulWords = minMeaningfulWords
    }

    /// Tuned for live calls, where a turn is one VAD utterance (500ms silence,
    /// 10s hard cap) and therefore usually a phrase, not a sentence.
    public static let call = StatementRules()
}

/// Buffers turns per speaker and emits only complete statements.
///
/// Pure and synchronous: the caller owns the clock, so every rule is testable
/// with hand-set timestamps. Time is in seconds since session start, the same
/// base as `TranscriptTurn.start`.
public struct StatementSegmenter: Sendable {
    public private(set) var rules: StatementRules

    private struct Lane {
        var turns: [TranscriptTurn] = []
        var isEmpty: Bool { turns.isEmpty }
        var firstSeq: Int { turns.first?.seq ?? -1 }
        var lastSeq: Int { turns.last?.seq ?? -1 }
        var start: Double { turns.first?.start ?? 0 }
        var lastEnd: Double { turns.last?.end ?? 0 }
        var text: String {
            turns.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        var lastWasCapped = false
    }

    private var lanes: [Speaker: Lane] = [.local: Lane(), .remote: Lane()]
    private var lastEmit: Double = -.greatestFiniteMagnitude

    public init(rules: StatementRules = .call) {
        self.rules = rules
    }

    /// Feed one transcript turn. Returns whatever became complete because of it.
    public mutating func ingest(_ turn: TranscriptTurn, now: Double? = nil) -> [Statement] {
        let clock = now ?? turn.end
        var emitted: [Statement] = []

        var lane = lanes[turn.speaker] ?? Lane()
        lane.turns.append(turn)
        lane.lastWasCapped = turn.duration >= rules.vadCapSeconds
        lanes[turn.speaker] = lane

        // Rule 2: the other side started talking, so their exchange is over.
        // The most useful moment to suggest, and the cheapest signal we have.
        // Evaluated after the arriving turn is buffered, so the trivial-content
        // exemption can see what this speaker actually said.
        if let statement = flush(turn.speaker.other, at: clock, viaSpeakerChange: true) {
            emitted.append(statement)
        }

        if let statement = evaluate(turn.speaker, at: clock) {
            emitted.append(statement)
        }
        return emitted
    }

    /// Call periodically (the plan's 250ms tick) so a trailed-off sentence and a
    /// floor-delayed buffer still get out.
    public mutating func tick(now: Double) -> [Statement] {
        var emitted: [Statement] = []
        for speaker in Speaker.allCases {
            if let statement = evaluate(speaker, at: now) {
                emitted.append(statement)
            }
        }
        return emitted
    }

    /// End of session: emit whatever is buffered, ignoring the request floor.
    public mutating func drain(now: Double) -> [Statement] {
        var emitted: [Statement] = []
        for speaker in Speaker.allCases {
            if let statement = flush(speaker, at: now, viaSpeakerChange: false, force: true) {
                emitted.append(statement)
            }
        }
        return emitted
    }

    // MARK: - Rules

    private mutating func evaluate(_ speaker: Speaker, at now: Double) -> Statement? {
        guard let lane = lanes[speaker], !lane.isEmpty else { return nil }

        let gap = now - lane.lastEnd
        let words = Self.wordCount(lane.text)
        let span = max(0, lane.lastEnd - lane.start)

        // Rule 5: size cap. Forced, so it outranks the request floor — a
        // monologue must not starve the copilot.
        if words >= rules.maxWords || span >= rules.maxSpan {
            return flush(speaker, at: now, viaSpeakerChange: false, force: true, truncated: true)
        }

        // Rule 1: the VAD chopped this utterance at its cap; the rest is coming.
        if lane.lastWasCapped, gap < rules.cappedContinuationGap { return nil }

        // Rule 0: a question outranks the pacing. It flushes on a short pause and
        // ignores the request floor, because the floor exists to stop the copilot
        // narrating — not to make someone wait while they are being asked something.
        if Statement.invitesAnAnswer(lane.text), gap >= rules.questionGap {
            return flush(speaker, at: now, viaSpeakerChange: false, force: true)
        }

        // Rule 8: request floor. Keep buffering; the next emission carries it.
        guard now - lastEmit >= rules.requestFloor else { return nil }

        let text = lane.text
        if words >= rules.minWords {
            // Rule 3: punctuation, settled.
            if Self.endsTerminal(text), gap >= rules.terminalGap {
                return flush(speaker, at: now, viaSpeakerChange: false)
            }
            // Rule 4: silence is the more reliable boundary, since Whisper drops
            // final punctuation often. A hanging conjunction needs longer.
            let needed = Self.endsHanging(text) ? rules.hangingGap : rules.silenceGap
            if gap >= needed {
                return flush(speaker, at: now, viaSpeakerChange: false)
            }
        }

        // Rule 6: nothing new for a while. Never leave the copilot silent
        // because someone trailed off.
        if gap >= rules.idleWait {
            return flush(speaker, at: now, viaSpeakerChange: false)
        }
        return nil
    }

    private mutating func flush(
        _ speaker: Speaker?,
        at now: Double,
        viaSpeakerChange: Bool,
        force: Bool = false,
        truncated: Bool = false
    ) -> Statement? {
        guard let speaker, var lane = lanes[speaker], !lane.isEmpty else { return nil }
        if !force, now - lastEmit < rules.requestFloor { return nil }

        let text = lane.text
        let words = Self.wordCount(text)

        // Rule 7: don't spend a request on "yeah". A speaker-change flush is
        // exempt only when the other lane has something real to react to.
        let trivial = words < rules.minMeaningfulWords && !text.contains("?")
        let otherHasContent = Self.wordCount(lanes[speaker.other]?.text ?? "") >= rules.minMeaningfulWords
        if trivial, !(viaSpeakerChange && otherHasContent) {
            lane.turns.removeAll()
            lane.lastWasCapped = false
            lanes[speaker] = lane
            return nil
        }

        let statement = Statement(
            fromSeq: lane.firstSeq,
            toSeq: lane.lastSeq,
            speaker: speaker,
            text: text,
            span: max(0, lane.lastEnd - lane.start),
            truncated: truncated
        )
        lane.turns.removeAll()
        lane.lastWasCapped = false
        lanes[speaker] = lane
        lastEmit = now
        return statement
    }

    // MARK: - Text shape

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    private static let terminalCharacters: Set<Character> = [".", "!", "?", "…"]
    private static let hangingWords: Set<String> = [
        "and", "but", "so", "because", "or", "if", "that", "which", "with",
        "um", "uh", "like", "the", "a", "to", "of", "for", "then",
    ]

    static func endsTerminal(_ text: String) -> Bool {
        // Trailing quotes and brackets are common after a sentence end.
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\"'”’)]»"))
        guard let last = trimmed.last else { return false }
        return terminalCharacters.contains(last)
    }

    static func endsHanging(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        if last == "," || last == ";" || last == ":" || last == "-" || last == "—" { return true }
        let word = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .last?
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .lowercased() ?? ""
        return hangingWords.contains(word)
    }
}

public extension Statement {
    /// Whether this statement is something that wants answering.
    ///
    /// Used by "answers only" mode, where the copilot should speak when it has been
    /// asked something and stay quiet otherwise. Punctuation alone is not enough:
    /// Whisper drops question marks often, and an interviewer's most demanding
    /// prompts are imperatives — "walk me through the architecture", "tell me about
    /// a time you disagreed" — which are questions in everything but grammar.
    var invitesAnAnswer: Bool { Statement.invitesAnAnswer(text) }

    /// Whether this text is something that wants answering.
    static func invitesAnAnswer(_ raw: String) -> Bool {
        let text = raw.lowercased()
        if text.contains("?") { return true }

        let words = text.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        // Spoken questions rarely start on the interrogative. "So how would you
        // scale this", "okay and why did that break", "right, what happens next" —
        // the marker is filler, and matching only `words.first` misses every one of
        // them. On a call that is not an edge case; it is how most questions
        // actually arrive.
        let opening = words.drop { discourseMarkers.contains($0) }
        guard let first = opening.first else { return false }
        if interrogatives.contains(first) { return true }
        // A leading auxiliary is a yes/no question: "did you ship it", "would you
        // reach for a queue here".
        if auxiliaries.contains(first), opening.count > 1 { return true }
        return requestPhrases.contains { text.contains($0) }
    }

    /// Filler that can precede a question without changing what it is.
    ///
    /// Deliberately short, and deliberately only ever *skipped* rather than
    /// treated as evidence: a statement that merely opens with "so" is not a
    /// question, and this list only decides which word gets tested next.
    static let discourseMarkers: Set<String> = [
        "so", "and", "but", "ok", "okay", "right", "well", "now", "yeah", "yes",
        "um", "uh", "erm", "like", "just", "then", "also", "actually",
    ]

    static let interrogatives: Set<String> = [
        "what", "why", "how", "when", "where", "who", "whom", "whose", "which",
    ]

    static let auxiliaries: Set<String> = [
        "do", "does", "did", "can", "could", "would", "will", "should", "shall",
        "is", "are", "was", "were", "have", "has", "had", "am",
    ]

    /// Imperatives that function as questions in an interview.
    static let requestPhrases: [String] = [
        "tell me", "walk me through", "talk me through", "describe", "explain",
        "give me an example", "give an example", "take me through",
        "your thoughts", "elaborate", "any questions",
    ]
}
