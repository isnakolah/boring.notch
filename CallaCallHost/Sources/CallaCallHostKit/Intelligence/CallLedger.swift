import Foundation
import IntelligenceCore

/// What the copilot remembers of a call, and in what form.
///
/// A call outruns any context window, and `agy` re-sends the whole conversation
/// on every turn (`cache_read_tokens` is always 0), so an ever-growing pile of
/// turns costs latency on exactly the request that must be fast. The ledger keeps
/// the call in three layers instead, oldest to newest:
///
///     standing   one folded paragraph for the part of the call nobody is
///                discussing any more
///     chunks     points, appended as each chunk of the call is summarised
///     tail       the last few statements, verbatim, not yet summarised
///
/// A statement enters the tail. When a chunk closes its statements are summarised
/// into points, the points are *appended* to `chunks`, and the raw statements are
/// dropped — the summary replaces the transcript it came from. When the points
/// pile up, the oldest fold into `standing` and leave. So the account grows while
/// what is sent stays bounded.
///
/// This is prompt-and-panel memory only. `transcript.jsonl` is still the complete
/// record and nothing here rewrites it.
///
/// Pure and synchronous, like `StatementSegmenter`: the caller owns the clock and
/// owns the requests, so every rule below is testable without a model.
public struct CallLedger: Sendable {
    /// One closed chunk of the call, as the points it was reduced to.
    public struct Chunk: Sendable, Hashable {
        public let points: [String]
        /// The last transcript seq this chunk accounts for, so a chunk can be
        /// placed against the transcript after the fact.
        public let throughSeq: Int

        public init(points: [String], throughSeq: Int) {
            self.points = points
            self.throughSeq = throughSeq
        }
    }

    /// Fold once the points pile up past this. Twelve lines is about what the
    /// panel can show and about what a question can afford to carry.
    public static let foldAboveLines = 12
    /// Lines kept out of a fold, so the recent part of the call stays in the words
    /// it was summarised in rather than being paraphrased twice.
    public static let keepAfterFold = 6

    /// The oldest part of the call, folded into standing fact.
    public private(set) var standing = ""
    public private(set) var chunks: [Chunk] = []
    /// Statements not yet summarised. Verbatim on purpose: a question is usually
    /// about the last thing said, and points lose the wording it refers to.
    public private(set) var tail: [Statement] = []
    /// Raised and not yet answered. Replaced rather than appended — the chunk pass
    /// is told to drop what has since been answered.
    public private(set) var openQuestions: [String] = []

    public init() {}

    // MARK: - Writing

    public mutating func append(_ statements: [Statement]) {
        tail.append(contentsOf: statements)
    }

    /// Takes the tail out for summarising. The statements leave the ledger here,
    /// not when the points come back, so a chunk cannot be summarised twice — and
    /// `restore` puts them back if the request fails.
    public mutating func takeTail() -> [Statement] {
        let taken = tail
        tail = []
        return taken
    }

    /// Puts a failed chunk's statements back at the front of the tail, so nothing
    /// said is lost to a dropped request.
    public mutating func restore(_ statements: [Statement]) {
        tail = statements + tail
    }

    /// Appends a closed chunk. The raw statements it came from are already gone.
    public mutating func applyChunk(points: [String], openQuestions: [String]?, throughSeq: Int) {
        let cleaned = Self.clean(points)
        if !cleaned.isEmpty {
            chunks.append(Chunk(points: cleaned, throughSeq: throughSeq))
        }
        if let openQuestions {
            self.openQuestions = Self.clean(openQuestions)
        }
    }

    /// Whether the points have piled up enough to be worth folding.
    public var needsFold: Bool { pointCount > Self.foldAboveLines }

    /// The chunks a fold would consume, oldest first. Empty when no fold is due.
    public func foldable() -> [Chunk] {
        guard needsFold else { return [] }
        var kept = 0
        var index = chunks.count
        while index > 0, kept + chunks[index - 1].points.count <= Self.keepAfterFold {
            kept += chunks[index - 1].points.count
            index -= 1
        }
        // Always fold at least one chunk, or a single fat chunk at the head would
        // make `needsFold` true forever and re-run the exec pass every cycle.
        return Array(chunks.prefix(max(1, index)))
    }

    /// Replaces the standing paragraph and drops the chunks it now covers.
    ///
    /// An empty paragraph changes nothing: the standing line is the only record of
    /// the earlier call, so trading it for nothing loses that part of the call
    /// outright, and leaving the chunks in place merely makes the fold due again.
    public mutating func applyFold(standing: String, over count: Int) {
        let trimmed = standing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.standing = trimmed
        chunks.removeFirst(min(count, chunks.count))
    }

    // MARK: - Reading

    public var pointCount: Int { chunks.reduce(0) { $0 + $1.points.count } }

    /// The most recently recorded points, oldest of them first. Shown to the chunk
    /// lane as what is already on the record: a warm conversation remembers the
    /// turns it summarised but still re-says the same fact in new words, and two
    /// lines making the same point is how the panel fills with noise.
    public func lastPoints(_ count: Int) -> [String] {
        Array(chunks.flatMap(\.points).suffix(count))
    }
    public var isEmpty: Bool { standing.isEmpty && chunks.isEmpty && tail.isEmpty }
    public var lastSeq: Int? { tail.last?.toSeq ?? chunks.last?.throughSeq }

    /// The account, as lines: the standing paragraph first, then every point in
    /// the order it was compiled.
    public var accountLines: [String] {
        (standing.isEmpty ? [] : [standing]) + chunks.flatMap(\.points)
    }

    /// What a question carries: the account as established fact, then the last few
    /// statements verbatim, because the question is usually about those.
    ///
    /// Sent in full on every question rather than left to the conversation to
    /// remember, so a context rollover — or a host restart — is not amnesia.
    /// - Parameter recalled: knowledge retrieved for *this* question — a note the
    ///   user wrote, or what a previous instance of this meeting concluded. Placed
    ///   above the account because it is standing fact from outside the call,
    ///   which the account's own lines may contradict and should win over.
    public func questionContext(_ question: [Statement], recalled: [String] = []) -> String {
        var sections: [String] = []
        if !recalled.isEmpty {
            sections.append("From your notes:\n" + recalled.joined(separator: "\n\n"))
        }
        let account = accountLines
        if !account.isEmpty {
            sections.append("So far:\n" + account.joined(separator: "\n"))
        }
        if !tail.isEmpty {
            sections.append("Just said:\n" + PromptComposer.render(tail))
        }
        sections.append(PromptComposer.render(question))
        return sections.joined(separator: "\n\n")
    }

    /// What the panel shows: standing fact, then every point in the order it was
    /// recorded — new lines arrive at the *bottom*.
    ///
    /// A log, not a rewritten paragraph. The panel scrolls and follows its own
    /// bottom, the way the transcript does, so the newest line is always the one
    /// under your eye and the lines above it never move. Ordering it newest-first
    /// instead made the whole list shuffle on every update, which reads as churn
    /// even though nothing above the top line had changed.
    public func panelSummary() -> String {
        let recent = chunks.flatMap(\.points).joined(separator: "\n")
        // The blank line is load-bearing: it is how the panel tells the standing
        // paragraph from the points, and it is written even with no points yet, or
        // the standing line would be rendered as the newest point.
        guard !standing.isEmpty else { return recent }
        return standing + "\n\n" + recent
    }

    /// Everything, for the end-of-call pass: the whole account plus whatever was
    /// still in the tail when the call ended.
    public func closingBrief(with leftovers: [Statement] = []) -> String {
        var sections: [String] = []
        let account = accountLines
        sections.append(account.isEmpty ? "(nothing was compiled)" : account.joined(separator: "\n"))
        let unfolded = tail + leftovers
        if !unfolded.isEmpty {
            sections.append("Said since the last summary:\n" + PromptComposer.render(unfolded))
        }
        if !openQuestions.isEmpty {
            sections.append("Left open:\n" + openQuestions.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    /// Bullets, numbering and blank lines out; a model asked for plain lines still
    /// sends "- " often enough that the panel would show it.
    static func clean(_ lines: [String]) -> [String] {
        lines.compactMap { line in
            var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            while let first = text.first, first == "-" || first == "*" || first == "•" {
                text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            return text.isEmpty ? nil : text
        }
    }
}
