import Foundation
import XCTest
@testable import IntelligenceStore

/// A store in a fresh temporary directory, torn down with the test.
private func makeStore(file: StaticString = #filePath, line: UInt = #line) throws -> (CallaStore, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("calla-store-tests-\(UUID().uuidString)", isDirectory: true)
    let path = root.appendingPathComponent("calla.sqlite")
    return (try CallaStore(path: path), root)
}

final class SchemaTests: XCTestCase {
    func testMigratesFromEmptyAndIsIdempotent() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("calla-schema-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("calla.sqlite")

        _ = try CallaStore(path: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))

        // Re-opening must not re-run a migration; a second CREATE TABLE would throw.
        _ = try CallaStore(path: path)

        let database = try SQLiteDatabase(path: path.path)
        XCTAssertEqual(try database.scalarInt("PRAGMA user_version"), Schema.current)
    }

    func testFTS5IsAvailable() throws {
        // The whole retrieval design assumes the system SQLite has FTS5 compiled
        // in. If that ever stops being true, it should fail here and not on a
        // user's Mac mid-call.
        let database = try SQLiteDatabase(path: ":memory:")
        XCTAssertNoThrow(try database.execute("CREATE VIRTUAL TABLE t USING fts5(x)"))
    }

    func testTheFileIsNotWorldReadable() throws {
        let (_, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("calla.sqlite").path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(permissions & 0o077, 0, "a call transcript must not be readable by other users")
    }
}

final class KnowledgeTests: XCTestCase {
    func testUpsertReplacesChunksRatherThanAccumulating() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var note = KnowledgeNote(title: "Billing", body: "We migrated off Stripe in Q2.")
        try await store.upsert(note)
        let first = try await store.notes()
        XCTAssertEqual(first.count, 1)

        note.body = "We migrated off Stripe in Q2. Adyen is the processor now."
        try await store.upsert(note)
        let second = try await store.notes()
        XCTAssertEqual(second.count, 1, "an edit must update, not duplicate")
        XCTAssertTrue(second[0].body.contains("Adyen"))

        let hits = await store.search(query: "who processes payments", scopes: [.always], limit: 3)
        XCTAssertFalse(hits.contains { $0.text.contains("Stripe") && !$0.text.contains("Adyen") },
                       "the superseded chunk must be gone from the index")
    }

    func testScopeFiltersRetrieval() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.upsert(KnowledgeNote(
            title: "Acme", body: "Acme churned on latency in Q2.", scope: .series("series-1")))
        try await store.upsert(KnowledgeNote(
            title: "Globex", body: "Globex wants latency under 40ms.", scope: .series("series-2")))

        let mine = await store.search(query: "latency", scopes: [.always, .series("series-1")], limit: 5)
        XCTAssertTrue(mine.allSatisfy { $0.title == "Acme" },
                      "a note scoped to another series must not surface")
        XCTAssertFalse(mine.isEmpty)
    }

    func testAlwaysScopeSurfacesInEveryMeeting() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.upsert(KnowledgeNote(
            title: "About me", body: "I own the billing service at Acme.", scope: .always))

        let meeting = MeetingContext(eventID: "event-9", seriesID: "series-9")
        let hits = await store.search(
            query: "which service do I own", scopes: meeting.scopes(persona: "sales"), limit: 3)
        XCTAssertEqual(hits.first?.title, "About me")
    }

    func testSearchWorksWithoutAnEmbedder() async throws {
        // prepare() is never called here, so no vectors exist. BM25 alone must
        // still answer — this is the tier-3 degradation the design depends on.
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.upsert(KnowledgeNote(
            title: "Pricing", body: "Enterprise starts at ninety thousand a year."))
        let hits = await store.search(query: "what does enterprise cost", scopes: [.always], limit: 3)
        XCTAssertFalse(hits.isEmpty, "lexical search must work with no embedding backend")
    }

    func testTitleIsSearchableFromEveryChunk() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // A long body whose later paragraphs never repeat the subject.
        let body = (1 ... 8).map { "Paragraph \($0) about the renewal terms and the discount ladder." }
            .joined(separator: "\n\n")
        try await store.upsert(KnowledgeNote(title: "Zenith account", body: body))

        let hits = await store.search(query: "Zenith", scopes: [.always], limit: 5)
        XCTAssertFalse(hits.isEmpty, "the note title must be findable from its chunks")
    }

    func testDeleteRemovesChunksAndIndex() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let note = KnowledgeNote(title: "Temporary", body: "Ephemeral fact about quasars.")
        try await store.upsert(note)
        let before = await store.search(query: "quasars", scopes: [.always])
        XCTAssertFalse(before.isEmpty)

        try await store.deleteNote(id: note.id)
        let after = await store.search(query: "quasars", scopes: [.always])
        XCTAssertTrue(after.isEmpty, "the FTS delete trigger must fire on cascade")
        let remaining = try await store.notes()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testNotesForMeetingAreOrderedGeneralToSpecific() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.upsert(KnowledgeNote(title: "Global", body: "g", scope: .always))
        try await store.upsert(KnowledgeNote(title: "Persona", body: "p", scope: .persona("sales")))
        try await store.upsert(KnowledgeNote(title: "Series", body: "s", scope: .series("s1")))
        try await store.upsert(KnowledgeNote(title: "Event", body: "e", scope: .event("e1")))

        let meeting = MeetingContext(eventID: "e1", seriesID: "s1")
        let ordered = try await store.notes(for: meeting, persona: "sales").map(\.title)
        XCTAssertEqual(ordered, ["Global", "Persona", "Series", "Event"],
                       "the most specific note must be read last")
    }
}

final class EmbeddingTests: XCTestCase {
    /// Exercises the vector leg end to end.
    ///
    /// Asserts nothing about *which* backend loads — that depends on whether the
    /// contextual asset is present on the machine running this, which is not
    /// something a test should require. What must hold either way is that
    /// `prepare()` does not throw, that indexing after it stores vectors, and that
    /// search still returns the right note.
    func testPrepareThenSearchStillFindsTheNote() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        await store.prepare()
        try await store.upsert(KnowledgeNote(
            title: "Renewal", body: "The Zenith contract renews in March at ninety thousand."))

        let hits = await store.search(query: "when does Zenith renew", scopes: [.always], limit: 3)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertEqual(hits.first?.noteID.isEmpty, false)
    }

    /// Notes indexed before a backend existed must gain vectors once one does,
    /// or everything written on a cold first launch stays lexical forever.
    func testBackfillEmbedsWhatWasIndexedEarlier() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.upsert(KnowledgeNote(
            title: "Early", body: "Written before any embedding backend was loaded."))
        await store.prepare()

        let embedder = Embedder()
        await embedder.prepare()
        guard await embedder.backend != .none else {
            throw XCTSkip("no embedding backend on this machine; the lexical path is covered elsewhere")
        }

        let database = try SQLiteDatabase(path: root.appendingPathComponent("calla.sqlite").path)
        let pending = try database.scalarInt(
            "SELECT COUNT(*) FROM knowledge_chunk WHERE embedding IS NULL") ?? -1
        XCTAssertEqual(pending, 0, "prepare() must backfill vectors for existing chunks")
    }
}

final class FTSQueryTests: XCTestCase {
    func testPunctuationCannotReachTheMatchExpression() {
        // A transcribed question contains hyphens, colons and stray quotes. Any of
        // them unquoted is an FTS5 syntax error, which would throw mid-call.
        for query in ["what's the SLA - and NEAR: uptime?", "cost (per seat)*", "\"quoted\" ^caret"] {
            guard let match = CallaStore.ftsQuery(query) else { continue }
            let database = try? SQLiteDatabase(path: ":memory:")
            try? database?.execute("CREATE VIRTUAL TABLE t USING fts5(x)")
            XCTAssertNoThrow(
                try database?.query("SELECT rowid FROM t WHERE t MATCH ?", [.text(match)]) { $0.int(0) },
                "\(query) produced an invalid MATCH: \(match)")
        }
    }

    func testStopWordsOnlyQueryYieldsNoMatch() {
        XCTAssertNil(CallaStore.ftsQuery("and the but for"))
        XCTAssertNil(CallaStore.ftsQuery("?!  ..."))
    }
}

final class VectorBlobTests: XCTestCase {
    func testRoundTripsExactly() {
        let vector: [Float] = [0.5, -0.25, 0, 1, -1]
        XCTAssertEqual(VectorBlob.decode(VectorBlob.encode(vector)), vector)
    }

    func testMismatchedLengthsScoreZeroRatherThanCrash() {
        XCTAssertEqual(VectorBlob.similarity([1, 0], [1, 0, 0]), 0)
        XCTAssertEqual(VectorBlob.similarity([], []), 0)
    }

    func testIdenticalUnitVectorsScoreOne() {
        let vector: [Float] = [0.6, 0.8]
        XCTAssertEqual(VectorBlob.similarity(vector, vector), 1, accuracy: 0.0001)
    }
}

final class TextChunkerTests: XCTestCase {
    func testShortTextIsOneChunk() {
        XCTAssertEqual(TextChunker.chunks(of: "One short fact."), ["One short fact."])
    }

    func testEmptyTextYieldsNothing() {
        XCTAssertTrue(TextChunker.chunks(of: "   \n\n  ").isEmpty)
    }

    func testTextWithNoSentenceTerminatorsIsStillChunked() {
        // A pasted list of identifiers has no sentence boundary to split on; it
        // must be hard-sliced rather than dropped.
        let text = String(repeating: "identifier-abcdefgh ", count: 80)
        let chunks = TextChunker.chunks(of: text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertFalse(chunks.contains { $0.isEmpty })
    }

    func testLongTextSplitsAndCoversEverything() {
        let paragraphs = (1 ... 12)
            .map { "Paragraph \($0). " + String(repeating: "word ", count: 30) }
            .joined(separator: "\n\n")
        let chunks = TextChunker.chunks(of: paragraphs)
        XCTAssertGreaterThan(chunks.count, 1)
        for index in 1 ... 12 {
            XCTAssertTrue(chunks.contains { $0.contains("Paragraph \(index).") },
                          "paragraph \(index) was lost")
        }
    }
}

final class CallRecordTests: XCTestCase {
    func testCallLinksToItsCalendarEvent() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.beginCall(CallRecord(
            id: "call-abc12345", eventID: "event-1", seriesID: "series-1",
            eventTitle: "Weekly Acme sync", persona: "sales", startedAt: Date()))

        let found = try await store.calls(forEvent: nil, seriesID: "series-1")
        XCTAssertEqual(found.map(\.id), ["call-abc12345"])
        XCTAssertEqual(found.first?.eventTitle, "Weekly Acme sync")
    }

    func testTurnsAreIdempotentOnSeq() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.beginCall(CallRecord(id: "call-t", persona: "generic"))

        try await store.record(turn: StoredTurn(seq: 1, source: "them", t0: 0, t1: 1, text: "hello"),
                               callID: "call-t")
        try await store.record(turn: StoredTurn(seq: 1, source: "them", t0: 0, t1: 1, text: "hello there"),
                               callID: "call-t")

        let turns = try await store.turns(forCall: "call-t")
        XCTAssertEqual(turns.count, 1, "a re-emitted turn must correct, not duplicate")
        XCTAssertEqual(turns.first?.text, "hello there")
        let record = try await store.call(id: "call-t")
        XCTAssertEqual(record?.turnCount, 1)
    }

    func testTurnsSinceSeqReturnsOnlyTheTail() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.beginCall(CallRecord(id: "call-s", persona: "generic"))
        for seq in 1 ... 5 {
            try await store.record(
                turn: StoredTurn(seq: seq, source: "me", t0: Double(seq), t1: Double(seq) + 1, text: "turn \(seq)"),
                callID: "call-s")
        }
        let tail = try await store.turns(forCall: "call-s", since: 3)
        XCTAssertEqual(tail.map(\.seq), [4, 5])
    }

    func testSuggestionListsSurviveTheRoundTrip() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.beginCall(CallRecord(id: "call-g", persona: "generic"))

        try await store.record(
            suggestion: StoredSuggestion(
                afterSeq: 7, headline: "Name the number",
                angles: ["cite Q2", "offer the ladder"], confirm: ["90k figure"],
                summary: "They asked about price.", openQuestions: ["who signs?"], latencyMs: 2400),
            callID: "call-g")

        let stored = try await store.suggestions(forCall: "call-g")
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].angles, ["cite Q2", "offer the ladder"])
        XCTAssertEqual(stored[0].confirm, ["90k figure"])
        XCTAssertEqual(stored[0].openQuestions, ["who signs?"])
        XCTAssertEqual(stored[0].latencyMs, 2400)
    }

    /// The loop that makes a recurring meeting remember: a call ends, its account
    /// becomes a note scoped to the series, and the next occurrence retrieves it.
    func testFinishedCallBecomesRetrievableKnowledge() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let meeting = MeetingContext(eventID: "event-1", seriesID: "series-1", title: "Weekly Acme sync")
        try await store.beginCall(CallRecord(
            id: "call-done", eventID: meeting.eventID, seriesID: meeting.seriesID,
            eventTitle: meeting.title, persona: "sales", startedAt: Date()))

        let summary = CallSummary(
            callID: "call-done",
            standing: "Acme agreed to a 40ms latency target for the renewal.",
            points: ["Renewal moved to March."],
            openQuestions: ["Who signs off on the SLA?"])
        let note = try await store.finish(summary: summary, meeting: meeting)
        XCTAssertNotNil(note)
        XCTAssertEqual(note?.source, .callSummary)
        XCTAssertEqual(note?.scope, .series("series-1"))

        // The next occurrence of the same series is a different event id.
        let nextWeek = MeetingContext(eventID: "event-2", seriesID: "series-1")
        let hits = await store.search(
            query: "what latency did we agree",
            scopes: nextWeek.scopes(persona: "sales"), limit: 3)
        XCTAssertTrue(hits.contains { $0.text.contains("40ms") },
                      "the previous call's account must reach the next occurrence")
    }

    func testRerunningTheSummaryUpdatesOneNote() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = MeetingContext(eventID: "e", seriesID: "s", title: "Sync")
        try await store.beginCall(CallRecord(id: "call-r", seriesID: "s", persona: "generic"))

        try await store.finish(
            summary: CallSummary(callID: "call-r", standing: "First pass.", points: [], openQuestions: []),
            meeting: meeting)
        try await store.finish(
            summary: CallSummary(callID: "call-r", standing: "Better pass.", points: [], openQuestions: []),
            meeting: meeting)

        let notes = try await store.notes(in: .series("s"))
        XCTAssertEqual(notes.count, 1, "two accounts of one call must not both be indexed")
        XCTAssertTrue(notes[0].body.contains("Better pass."))
    }

    func testEmptySummaryIsFiledButNotIndexed() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.beginCall(CallRecord(id: "call-quiet", seriesID: "s", persona: "generic"))

        let note = try await store.finish(
            summary: CallSummary(callID: "call-quiet", standing: "", points: [], openQuestions: []),
            meeting: MeetingContext(seriesID: "s"))
        XCTAssertNil(note, "a call where nothing was established must not pollute the index")
        let filed = try await store.summary(forCall: "call-quiet")
        XCTAssertNotNil(filed)
    }

    func testSummaryWithoutAMeetingIsNotIndexed() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.beginCall(CallRecord(id: "call-adhoc", persona: "generic"))

        let note = try await store.finish(
            summary: CallSummary(callID: "call-adhoc", standing: "Something happened.",
                                 points: [], openQuestions: []),
            meeting: nil)
        XCTAssertNil(note, "an ad-hoc call has no meeting to file its account under")
        let indexed = try await store.notes()
        XCTAssertTrue(indexed.isEmpty)
    }
}

final class MeetingContextTests: XCTestCase {
    func testScopesRunGeneralToSpecific() {
        let meeting = MeetingContext(eventID: "e1", seriesID: "s1")
        XCTAssertEqual(meeting.scopes(persona: "sales"),
                       [.always, .persona("sales"), .series("s1"), .event("e1")])
    }

    func testDerivedBodyCarriesTheFieldsWorthKnowing() {
        let meeting = MeetingContext(
            eventID: "e", title: "Weekly Acme sync",
            location: "Meet", attendees: ["Dana", "Rae"], notes: "Renewal review")
        let body = meeting.derivedNoteBody() ?? ""
        XCTAssertTrue(body.contains("Weekly Acme sync"))
        XCTAssertTrue(body.contains("Dana, Rae"))
        XCTAssertTrue(body.contains("Renewal review"))
    }

    func testDerivedBodyIsNilWhenThereIsNothingToSay() {
        XCTAssertNil(MeetingContext(eventID: "e").derivedNoteBody())
    }
}
