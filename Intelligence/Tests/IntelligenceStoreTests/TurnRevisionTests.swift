import CallaContracts
import XCTest
@testable import IntelligenceStore

/// A call is transcribed twice — live, then again with a much better model once
/// nothing is waiting. Both have to survive.
final class TurnRevisionTests: XCTestCase {
    private var directory: URL!
    private var store: CallaStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("revisions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try CallaStore(path: directory.appendingPathComponent("calla.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func begin(_ callID: String) async throws {
        try await store.beginCall(CallRecord(id: callID, persona: "generic", startedAt: Date()))
    }

    private func turn(_ seq: Int, _ text: String, revision: Int = StoredTurn.liveRevision) -> StoredTurn {
        StoredTurn(seq: seq, source: "them", t0: Double(seq), t1: Double(seq) + 1,
                   text: text, revision: revision)
    }

    func testTheArchivePassDoesNotOverwriteWhatTheCopilotSaw() async throws {
        // Revision 0 is the record of what was on screen and what every
        // suggestion was reasoning over. Losing it would make the history pane
        // show advice next to words that were never displayed.
        try await begin("call-a")
        for seq in 0..<3 { try await store.record(turn: turn(seq, "live \(seq)"), callID: "call-a") }

        try await store.replace(
            turns: (0..<2).map { turn($0, "archive \($0)", revision: StoredTurn.archiveRevision) },
            callID: "call-a",
            revision: StoredTurn.archiveRevision)

        let live = try await store.turns(forCall: "call-a", revision: StoredTurn.liveRevision)
        let archived = try await store.turns(forCall: "call-a", revision: StoredTurn.archiveRevision)
        XCTAssertEqual(live.map(\.text), ["live 0", "live 1", "live 2"])
        XCTAssertEqual(archived.map(\.text), ["archive 0", "archive 1"])
    }

    func testTheDefaultReadIsTheBestAvailableTranscript() async throws {
        try await begin("call-b")
        try await store.record(turn: turn(0, "live text"), callID: "call-b")
        let beforeArchive = try await store.turns(forCall: "call-b")
        XCTAssertEqual(beforeArchive.map(\.text), ["live text"])

        try await store.replace(
            turns: [turn(0, "archive text", revision: StoredTurn.archiveRevision)],
            callID: "call-b", revision: StoredTurn.archiveRevision)
        let afterArchive = try await store.turns(forCall: "call-b")
        XCTAssertEqual(afterArchive.map(\.text), ["archive text"])
    }

    func testReplacingARevisionLeavesNoTailBehind() async throws {
        // The archive pass numbers its own seqs, and a re-run that finds fewer
        // turns must not leave the longer run's tail sitting underneath it.
        try await begin("call-c")
        try await store.replace(
            turns: (0..<5).map { turn($0, "first \($0)", revision: StoredTurn.archiveRevision) },
            callID: "call-c", revision: StoredTurn.archiveRevision)
        try await store.replace(
            turns: (0..<2).map { turn($0, "second \($0)", revision: StoredTurn.archiveRevision) },
            callID: "call-c", revision: StoredTurn.archiveRevision)

        let archived = try await store.turns(forCall: "call-c", revision: StoredTurn.archiveRevision)
        XCTAssertEqual(archived.map(\.text), ["second 0", "second 1"])
    }

    func testTurnCountCountsTheLivePassOnly() async throws {
        // `turn_count` is what History shows and what recap spans are expressed
        // against; an archive import must not appear to double the call.
        try await begin("call-d")
        for seq in 0..<4 { try await store.record(turn: turn(seq, "live \(seq)"), callID: "call-d") }
        try await store.replace(
            turns: (0..<9).map { turn($0, "archive \($0)", revision: StoredTurn.archiveRevision) },
            callID: "call-d", revision: StoredTurn.archiveRevision)

        let record = try await store.call(id: "call-d")
        XCTAssertEqual(record?.turnCount, 4)
    }

    func testConfidenceRoundTripsAndDistinguishesUnmeasuredFromZero() async throws {
        // NULL means "this pass did not measure"; 0.0 means "the model was sure
        // this was nothing". Collapsing them would make every legacy turn look
        // maximally untrustworthy.
        try await begin("call-e")
        try await store.record(
            turn: StoredTurn(seq: 0, source: "me", t0: 0, t1: 1, text: "measured",
                             confidence: 0.42, noSpeech: 0.03),
            callID: "call-e")
        try await store.record(
            turn: StoredTurn(seq: 1, source: "me", t0: 1, t1: 2, text: "unmeasured"),
            callID: "call-e")

        let turns = try await store.turns(forCall: "call-e")
        XCTAssertEqual(turns[0].confidence ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertEqual(turns[0].noSpeech ?? -1, 0.03, accuracy: 0.0001)
        XCTAssertNil(turns[1].confidence)
        XCTAssertNil(turns[1].noSpeech)
    }

    func testSinceCursorStillWorksWithinARevision() async throws {
        // The live panel polls with a cursor; revisions must not disturb it.
        try await begin("call-f")
        for seq in 0..<5 { try await store.record(turn: turn(seq, "t\(seq)"), callID: "call-f") }
        let tail = try await store.turns(forCall: "call-f", since: 2,
                                         revision: StoredTurn.liveRevision)
        XCTAssertEqual(tail.map(\.seq), [3, 4])
    }
}
