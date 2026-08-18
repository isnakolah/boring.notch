import Foundation
import XCTest
@testable import IntelligenceStore

/// Bringing calls recorded before the store existed into it.
///
/// The property that matters most is idempotency: this runs at engine startup,
/// and a second pass that duplicated every turn would silently double the size of
/// every transcript the user has.
final class ArchiveImportTests: XCTestCase {
    private var root: URL!
    private var callsDirectory: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("calla-import-\(UUID().uuidString)", isDirectory: true)
        callsDirectory = root.appendingPathComponent("calls", isDirectory: true)
        try FileManager.default.createDirectory(at: callsDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() throws -> CallaStore {
        try CallaStore(path: root.appendingPathComponent("calla.sqlite"))
    }

    /// Writes one call directory in exactly the shape `CallArchive` produces.
    @discardableResult
    private func writeCall(
        id: String,
        turns: Int = 3,
        suggestions: Int = 1,
        ended: Bool = true,
        extraLine: String? = nil
    ) throws -> URL {
        let directory = callsDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let started = Date(timeIntervalSince1970: 1_700_000_000)
        var meta = """
        {"call_id":"\(id)","persona":"sales","started_at":"\(iso(started))",\
        "live_model":"whisper-small-en","turn_count":\(turns),"dropped_self_turns":0
        """
        meta += ended ? ",\"ended_at\":\"\(iso(started.addingTimeInterval(600)))\"}" : "}"
        try meta.write(to: directory.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)

        var transcript = (1 ... max(turns, 1)).map { seq in
            """
            {"id":"\(UUID().uuidString)","seq":\(seq),"source":"\(seq.isMultiple(of: 2) ? "me" : "them")",\
            "t0":\(seq),"t1":\(seq + 1),"text":"turn \(seq) about the renewal"}
            """
        }.joined(separator: "\n")
        if let extraLine { transcript += "\n" + extraLine }
        try transcript.write(
            to: directory.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        if suggestions > 0 {
            let lines = (1 ... suggestions).map { index in
                """
                {"call_id":"\(id)","after_seq":\(index),"headline":"Name the number",\
                "angles":["cite Q2"],"confirm":[],"latency_ms":2400}
                """
            }.joined(separator: "\n")
            try lines.write(
                to: directory.appendingPathComponent("suggestions.jsonl"), atomically: true, encoding: .utf8)
        }
        return directory
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }

    // MARK: - Tests

    func testImportsCallsTurnsAndSuggestions() async throws {
        try writeCall(id: "call-one", turns: 3, suggestions: 2)
        let store = try makeStore()

        let count = await store.importArchives(from: callsDirectory)
        XCTAssertEqual(count, 1)

        let calls = try await store.calls()
        XCTAssertEqual(calls.map(\.id), ["call-one"])
        XCTAssertEqual(calls.first?.persona, "sales")
        XCTAssertNotNil(calls.first?.endedAt)

        let turns = try await store.turns(forCall: "call-one")
        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns.first?.source, "them")

        let advice = try await store.suggestions(forCall: "call-one")
        XCTAssertEqual(advice.count, 2)
        XCTAssertEqual(advice.first?.angles, ["cite Q2"])
    }

    func testSecondRunImportsNothing() async throws {
        try writeCall(id: "call-one", turns: 4)
        let store = try makeStore()

        let first = await store.importArchives(from: callsDirectory)
        XCTAssertEqual(first, 1)
        let second = await store.importArchives(from: callsDirectory)
        XCTAssertEqual(second, 0, "the marker must stop a second walk")

        let turns = try await store.turns(forCall: "call-one")
        XCTAssertEqual(turns.count, 4, "turns must not be duplicated by a re-run")
    }

    func testACallAlreadyInTheStoreIsLeftAlone() async throws {
        try writeCall(id: "call-live", turns: 3)
        let store = try makeStore()
        // As if the call had been recorded live, with a meeting attached — which
        // the archive files know nothing about and must not overwrite.
        try await store.beginCall(CallRecord(
            id: "call-live", eventID: "event-1", seriesID: "series-1",
            eventTitle: "Weekly Acme sync", persona: "sales"))

        _ = await store.importArchives(from: callsDirectory)

        let record = try await store.call(id: "call-live")
        XCTAssertEqual(record?.seriesID, "series-1", "the import must not clear the calendar link")
        let turns = try await store.turns(forCall: "call-live")
        XCTAssertEqual(turns.count, 0, "a call already in the store is skipped whole")
    }

    /// The shape the archive actually has on disk.
    ///
    /// Not hypothetical: on the first machine this ran against, none of forty-four
    /// archived calls had a `meta.json` and thirty-seven had a `call.json`. The
    /// host only writes `meta.json` on a clean stop, and calls end by signal —
    /// so requiring it imported exactly nothing.
    func testImportsACallThatOnlyHasCallJSON() async throws {
        let directory = callsDirectory.appendingPathComponent("call-killed", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let startRecord = "{\"call_id\":\"call-killed\",\"gateway_connected\":false,"
            + "\"mic_active\":false,\"persona\":\"interview\","
            + "\"started_at\":\"\(iso(started))\",\"system_audio_active\":false,\"turn_count\":0}"
        try startRecord.write(
            to: directory.appendingPathComponent("call.json"), atomically: true, encoding: .utf8)

        let transcript = (1 ... 3).map { seq in
            "{\"id\":\"\(UUID().uuidString)\",\"seq\":\(seq),\"source\":\"them\","
                + "\"t0\":\(seq),\"t1\":\(seq + 1),\"text\":\"turn \(seq)\"}"
        }.joined(separator: "\n")
        try transcript.write(
            to: directory.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        let store = try makeStore()
        let imported = await store.importArchives(from: callsDirectory)
        XCTAssertEqual(imported, 1, "a call killed before it could write meta.json is still a call")

        let record = try await store.call(id: "call-killed")
        XCTAssertEqual(record?.persona, "interview")
        XCTAssertEqual(record?.startedAt, started)
        // call.json is written at start, so its own count is always zero. The
        // store must count the rows it actually inserted.
        XCTAssertEqual(record?.turnCount, 3)
        XCTAssertNotNil(record?.endedAt, "the transcript's mtime is the best end time there is")
    }

    /// A directory with nothing but a transcript is still a call that happened.
    func testImportsACallWithNoMetadataAtAll() async throws {
        let directory = callsDirectory.appendingPathComponent("call-bare", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "{\"seq\":1,\"source\":\"me\",\"t0\":0,\"t1\":1,\"text\":\"hello\"}".write(
            to: directory.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        let store = try makeStore()
        let imported = await store.importArchives(from: callsDirectory)
        XCTAssertEqual(imported, 1)
        let record = try await store.call(id: "call-bare")
        XCTAssertEqual(record?.id, "call-bare", "the directory name is the call id")
        XCTAssertEqual(record?.turnCount, 1)
    }

    func testACallWithNothingTranscribedIsSkipped() async throws {
        // Armed and abandoned: metadata, no speech. Nothing to import, and
        // nothing lost by skipping it.
        let directory = callsDirectory.appendingPathComponent("call-silent", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let startRecord = "{\"call_id\":\"call-silent\",\"persona\":\"generic\","
            + "\"started_at\":\"\(iso(Date()))\"}"
        try startRecord.write(
            to: directory.appendingPathComponent("call.json"), atomically: true, encoding: .utf8)

        let store = try makeStore()
        let imported = await store.importArchives(from: callsDirectory)
        XCTAssertEqual(imported, 0)
    }

    func testATruncatedLastLineDoesNotLoseTheFile() async throws {
        // These are append-only logs written by a process that gets SIGINTed, so a
        // half-written final line is an expected state rather than corruption.
        try writeCall(id: "call-cut", turns: 3, extraLine: "{\"seq\":4,\"source\":\"me\",\"t0\":4,")
        let store = try makeStore()

        let imported = await store.importArchives(from: callsDirectory)
        XCTAssertEqual(imported, 1)
        let turns = try await store.turns(forCall: "call-cut")
        XCTAssertEqual(turns.count, 3, "the three good turns must survive the bad fourth")
    }

    func testImportsSeveralCalls() async throws {
        for index in 1 ... 5 { try writeCall(id: "call-\(index)", turns: 2) }
        let store = try makeStore()
        let imported = await store.importArchives(from: callsDirectory)
        XCTAssertEqual(imported, 5)
        let calls = try await store.calls()
        XCTAssertEqual(calls.count, 5)
    }

    func testAMissingDirectoryIsNotAnError() async throws {
        let store = try makeStore()
        let missing = root.appendingPathComponent("nope", isDirectory: true)
        let imported = await store.importArchives(from: missing)
        XCTAssertEqual(imported, 0)
    }
}
