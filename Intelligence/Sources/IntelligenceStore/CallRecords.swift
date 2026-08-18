import Foundation

/// A call, as stored. The transcript and the suggestions hang off it by id.
///
/// `eventID` and `seriesID` are the link back to the calendar. They are why a
/// finished call can become knowledge the *next* occurrence of the same meeting
/// retrieves — without them a summary is filed under nothing and found by no one.
public struct CallRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var eventID: String?
    public var seriesID: String?
    public var eventTitle: String?
    public var eventStart: Date?
    public var persona: String
    public var startedAt: Date?
    public var endedAt: Date?
    public var liveModel: String?
    public var provider: String?
    public var turnCount: Int

    enum CodingKeys: String, CodingKey {
        case id, persona, provider
        case eventID = "event_id"
        case seriesID = "series_id"
        case eventTitle = "event_title"
        case eventStart = "event_start"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case liveModel = "live_model"
        case turnCount = "turn_count"
    }

    public init(
        id: String,
        eventID: String? = nil,
        seriesID: String? = nil,
        eventTitle: String? = nil,
        eventStart: Date? = nil,
        persona: String,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        liveModel: String? = nil,
        provider: String? = nil,
        turnCount: Int = 0
    ) {
        self.id = id
        self.eventID = eventID
        self.seriesID = seriesID
        self.eventTitle = eventTitle
        self.eventStart = eventStart
        self.persona = persona
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.liveModel = liveModel
        self.provider = provider
        self.turnCount = turnCount
    }
}

public struct StoredTurn: Codable, Sendable, Equatable {
    public var seq: Int
    /// `me` or `them`, matching the host's own `CallTurn.source`.
    public var source: String
    public var t0: Double
    public var t1: Double
    public var text: String

    public init(seq: Int, source: String, t0: Double, t1: Double, text: String) {
        self.seq = seq
        self.source = source
        self.t0 = t0
        self.t1 = t1
        self.text = text
    }
}

public struct StoredSuggestion: Codable, Sendable, Equatable {
    public var afterSeq: Int
    public var headline: String
    public var angles: [String]
    public var confirm: [String]
    public var summary: String?
    public var openQuestions: [String]
    public var latencyMs: Int
    public var at: Date

    enum CodingKeys: String, CodingKey {
        case headline, angles, confirm, summary, at
        case afterSeq = "after_seq"
        case openQuestions = "open_questions"
        case latencyMs = "latency_ms"
    }

    public init(
        afterSeq: Int, headline: String, angles: [String] = [], confirm: [String] = [],
        summary: String? = nil, openQuestions: [String] = [], latencyMs: Int = 0, at: Date = Date()
    ) {
        self.afterSeq = afterSeq
        self.headline = headline
        self.angles = angles
        self.confirm = confirm
        self.summary = summary
        self.openQuestions = openQuestions
        self.latencyMs = latencyMs
        self.at = at
    }
}

/// What a call left behind: the folded paragraph, the points, and what was never
/// resolved. The `CallLedger`'s three layers, made durable.
public struct CallSummary: Codable, Sendable, Equatable {
    public var callID: String
    public var standing: String
    public var points: [String]
    public var openQuestions: [String]

    enum CodingKeys: String, CodingKey {
        case standing, points
        case callID = "call_id"
        case openQuestions = "open_questions"
    }

    public init(callID: String, standing: String, points: [String], openQuestions: [String]) {
        self.callID = callID
        self.standing = standing
        self.points = points
        self.openQuestions = openQuestions
    }

    public var isEmpty: Bool {
        standing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && points.isEmpty && openQuestions.isEmpty
    }

    /// The summary as a knowledge note body — what the next occurrence of this
    /// meeting will actually read.
    public func noteBody() -> String {
        var blocks: [String] = []
        let standing = standing.trimmingCharacters(in: .whitespacesAndNewlines)
        if !standing.isEmpty { blocks.append(standing) }
        if !points.isEmpty { blocks.append(points.joined(separator: "\n")) }
        if !openQuestions.isEmpty {
            blocks.append("Still open:\n" + openQuestions.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }
}

public extension CallaStore {
    // MARK: - Writing a call

    /// Opens a call row. Called once, at session start, before any turn arrives.
    func beginCall(_ record: CallRecord) throws {
        try run(
            """
            INSERT INTO call(id, event_id, series_id, event_title, event_start,
                             persona, started_at, ended_at, live_model, provider, turn_count)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              event_id = excluded.event_id, series_id = excluded.series_id,
              event_title = excluded.event_title, event_start = excluded.event_start,
              persona = excluded.persona, started_at = excluded.started_at,
              live_model = excluded.live_model, provider = excluded.provider
            """,
            [.text(record.id), .text(record.eventID), .text(record.seriesID),
             .text(record.eventTitle), .date(record.eventStart), .text(record.persona),
             .date(record.startedAt), .date(record.endedAt), .text(record.liveModel),
             .text(record.provider), .int(record.turnCount)])
    }

    /// One transcript turn. Idempotent on `(call_id, seq)` so a replayed turn
    /// corrects the row rather than duplicating it — the host re-emits a turn when
    /// a later pass improves its text.
    func record(turn: StoredTurn, callID: String) throws {
        try run(
            """
            INSERT INTO call_turn(call_id, seq, source, t0, t1, text) VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(call_id, seq) DO UPDATE SET
              source = excluded.source, t0 = excluded.t0, t1 = excluded.t1, text = excluded.text
            """,
            [.text(callID), .int(turn.seq), .text(turn.source),
             .double(turn.t0), .double(turn.t1), .text(turn.text)])
        try run(
            "UPDATE call SET turn_count = (SELECT COUNT(*) FROM call_turn WHERE call_id = ?) WHERE id = ?",
            [.text(callID), .text(callID)])
    }

    /// Appends a suggestion. Not deduplicated: the same `after_seq` legitimately
    /// gets several frames as the account is refreshed around a pointer, and the
    /// history pane shows that progression.
    func record(suggestion: StoredSuggestion, callID: String) throws {
        try run(
            """
            INSERT INTO call_suggestion(call_id, after_seq, headline, angles, confirm,
                                        summary, open_questions, latency_ms, at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(callID), .int(suggestion.afterSeq), .text(suggestion.headline),
             .text(Self.join(suggestion.angles)), .text(Self.join(suggestion.confirm)),
             .text(suggestion.summary), .text(Self.join(suggestion.openQuestions)),
             .int(suggestion.latencyMs), .date(suggestion.at)])
    }

    func endCall(id: String, at date: Date = Date()) throws {
        try run("UPDATE call SET ended_at = ? WHERE id = ?", [.date(date), .text(id)])
    }

    /// Stores the account a call ended with, and — this is the point — files it as
    /// knowledge scoped to the meeting so the next occurrence retrieves it.
    ///
    /// Scoped to the series when there is one, because that is the recurrence that
    /// benefits. A one-off meeting's summary is scoped to its own event id, where
    /// it is findable from the history pane but will not surface in an unrelated
    /// call — filing every summary under `always` would drown the index in a month.
    @discardableResult
    func finish(summary: CallSummary, meeting: MeetingContext?) async throws -> KnowledgeNote? {
        try run(
            """
            INSERT INTO call_summary(call_id, standing, points, open_questions)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(call_id) DO UPDATE SET
              standing = excluded.standing, points = excluded.points,
              open_questions = excluded.open_questions
            """,
            [.text(summary.callID), .text(summary.standing),
             .text(Self.join(summary.points)), .text(Self.join(summary.openQuestions))])

        guard !summary.isEmpty else { return nil }
        guard let scope = Self.summaryScope(for: meeting) else { return nil }

        let record = try call(id: summary.callID)
        let when = record?.startedAt ?? Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let label = record?.eventTitle ?? meeting?.title ?? "Call"

        let note = KnowledgeNote(
            // Derived from the call id so re-running the summary updates the note
            // instead of leaving two accounts of the same call in the index.
            id: "note-call-\(summary.callID)",
            title: "\(label) — \(formatter.string(from: when))",
            body: summary.noteBody(),
            source: .callSummary,
            scope: scope,
            createdAt: when)
        let stored = try await upsert(note)
        try run("UPDATE call_summary SET note_id = ? WHERE call_id = ?",
                [.text(stored.id), .text(summary.callID)])
        return stored
    }

    private static func summaryScope(for meeting: MeetingContext?) -> KnowledgeScope? {
        guard let meeting else { return nil }
        if let series = meeting.seriesID, !series.isEmpty { return .series(series) }
        if let event = meeting.eventID, !event.isEmpty { return .event(event) }
        return nil
    }

    // MARK: - Reading

    func call(id: String) throws -> CallRecord? {
        try query(Self.callColumns + " WHERE id = ?", [.text(id)], row: Self.call).first
    }

    func calls(limit: Int = 200) throws -> [CallRecord] {
        try query(Self.callColumns + " ORDER BY started_at DESC LIMIT ?", [.int(limit)], row: Self.call)
    }

    /// Every call for one meeting. Matches the series when the event is part of
    /// one, so "what did we say last week" works on a recurring standup.
    func calls(forEvent eventID: String?, seriesID: String?) throws -> [CallRecord] {
        if let seriesID, !seriesID.isEmpty {
            return try query(
                Self.callColumns + " WHERE series_id = ? ORDER BY started_at DESC",
                [.text(seriesID)], row: Self.call)
        }
        guard let eventID, !eventID.isEmpty else { return [] }
        return try query(
            Self.callColumns + " WHERE event_id = ? ORDER BY started_at DESC",
            [.text(eventID)], row: Self.call)
    }

    func turns(forCall callID: String, since seq: Int = -1) throws -> [StoredTurn] {
        try query(
            "SELECT seq, source, t0, t1, text FROM call_turn WHERE call_id = ? AND seq > ? ORDER BY seq",
            [.text(callID), .int(seq)]) { row in
                StoredTurn(seq: row.int(0), source: row.string(1),
                           t0: row.double(2), t1: row.double(3), text: row.string(4))
            }
    }

    func suggestions(forCall callID: String) throws -> [StoredSuggestion] {
        try query(
            """
            SELECT after_seq, headline, angles, confirm, summary, open_questions, latency_ms, at
            FROM call_suggestion WHERE call_id = ? ORDER BY id
            """,
            [.text(callID)]) { row in
                StoredSuggestion(
                    afterSeq: row.int(0), headline: row.string(1),
                    angles: Self.split(row.text(2)), confirm: Self.split(row.text(3)),
                    summary: row.text(4), openQuestions: Self.split(row.text(5)),
                    latencyMs: row.int(6), at: row.date(7) ?? Date())
            }
    }

    func summary(forCall callID: String) throws -> CallSummary? {
        try query(
            "SELECT standing, points, open_questions FROM call_summary WHERE call_id = ?",
            [.text(callID)]) { row in
                CallSummary(callID: callID, standing: row.string(0),
                            points: Self.split(row.text(1)), openQuestions: Self.split(row.text(2)))
            }.first
    }

    private static let callColumns = """
    SELECT id, event_id, series_id, event_title, event_start, persona,
           started_at, ended_at, live_model, provider, turn_count FROM call
    """

    private static func call(_ row: SQLiteRow) -> CallRecord {
        CallRecord(
            id: row.string(0), eventID: row.text(1), seriesID: row.text(2),
            eventTitle: row.text(3), eventStart: row.date(4), persona: row.string(5),
            startedAt: row.date(6), endedAt: row.date(7), liveModel: row.text(8),
            provider: row.text(9), turnCount: row.int(10))
    }

    /// String lists go in newline-separated rather than as JSON.
    ///
    /// They are all short single-line fragments by contract — an angle is capped at
    /// eight words — and a newline-joined column is greppable with the `sqlite3`
    /// CLI, which is how this database will actually be debugged.
    static func join(_ values: [String]) -> String? {
        let cleaned = values
            .map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: "\n")
    }

    static func split(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value.components(separatedBy: "\n").filter { !$0.isEmpty }
    }
}
