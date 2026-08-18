import Foundation
import XCTest
@testable import IntelligenceStore

/// Attached files, and the one rule that makes them usable: a document is
/// searched, never packed.
///
/// The failure this guards against is quiet and expensive. Pack a forty-page
/// contract into the block that opens every call and it consumes the whole
/// budget, crowds out the two sentences that actually steer the answer, and slows
/// every context rollover for the rest of the call — while looking, from the
/// outside, like the feature working.
final class DocumentKnowledgeTests: XCTestCase {
    private func makeStore() throws -> (CallaStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("calla-doc-\(UUID().uuidString)", isDirectory: true)
        return (try CallaStore(path: root.appendingPathComponent("calla.sqlite")), root)
    }

    private func document(
        _ name: String,
        text: String,
        pages: Int = 12,
        scope: KnowledgeScope
    ) -> KnowledgeNote {
        KnowledgeNote(
            title: name, body: text, source: .document, scope: scope,
            originName: name, originKind: "pdf", byteSize: 1_200_000, pageCount: pages)
    }

    func testADocumentIsNotPackedIntoThePrompt() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let body = String(repeating: "This is a long clause about indemnity. ", count: 500)
        try await store.upsert(document("msa.pdf", text: body, scope: .series("s1")))
        try await store.upsert(KnowledgeNote(
            title: "Renewal", body: "Dana signs it in March.", scope: .series("s1")))

        let meeting = MeetingContext(eventID: "e1", seriesID: "s1")
        let block = try await store.promptBlock(for: meeting, persona: nil, limit: 8000)
        let text = try XCTUnwrap(block)

        XCTAssertTrue(text.contains("Dana signs it in March."), "a typed note goes in whole")
        XCTAssertFalse(text.contains("clause about indemnity"), "the document's text must not be packed")
        XCTAssertLessThan(text.count, 1000, "one PDF must not consume the whole block")
    }

    /// The manifest line is what makes the file askable at all.
    func testADocumentIsNamedSoItCanBeAskedAbout() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.upsert(document("msa.pdf", text: "Indemnity is capped at fees paid.", scope: .event("e1")))
        let block = try await store.promptBlock(
            for: MeetingContext(eventID: "e1"), persona: nil, limit: 8000)
        let text = try XCTUnwrap(block)

        XCTAssertTrue(text.contains("msa.pdf"), "the copilot has to know the file exists")
        XCTAssertTrue(text.contains("12 pages"))
        XCTAssertTrue(text.lowercased().contains("searchable"))
    }

    /// Not packed does not mean not reachable — this is the other half of the
    /// bargain, and the half that would make the feature pointless if it broke.
    func testADocumentIsStillRetrievable() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let body = """
        Section 4. Limitation of liability. Neither party shall be liable for
        indirect damages. Aggregate liability is capped at the fees paid in the
        twelve months preceding the claim.
        """
        try await store.upsert(document("msa.pdf", text: body, scope: .series("s1")))

        let hits = await store.search(
            query: "what is the liability cap",
            scopes: MeetingContext(eventID: "e2", seriesID: "s1").scopes(persona: nil),
            limit: 3)
        XCTAssertTrue(hits.contains { $0.text.lowercased().contains("capped at the fees") },
                      "the passage that answers the question must come back")
        XCTAssertEqual(hits.first?.source, .document)
    }

    /// A hit should cite the file, not a derived title.
    func testAHitIsLabelledWithTheFilename() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var note = document("quarterly-review.pdf", text: "Churn fell to four percent.", scope: .always)
        note.title = "Some derived label"
        try await store.upsert(note)

        let hits = await store.search(query: "what happened to churn", scopes: [.always], limit: 3)
        XCTAssertEqual(hits.first?.title, "quarterly-review.pdf")
    }

    func testATypedNoteIsPackedAndADocumentIsNotInTheSameMeeting() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.upsert(KnowledgeNote(
            title: "About them", body: "Acme churned on latency.", scope: .always))
        try await store.upsert(document("deck.pdf", text: "Slide one. Slide two.", scope: .event("e1")))

        let block = try await store.promptBlock(
            for: MeetingContext(eventID: "e1"), persona: nil, limit: 8000)
        let text = try XCTUnwrap(block)
        XCTAssertTrue(text.contains("Acme churned on latency."))
        XCTAssertTrue(text.contains("deck.pdf"))
        XCTAssertFalse(text.contains("Slide one."))
    }

    func testTheBlockIsTruncatedRatherThanRefused() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // Ten notes of 300 characters against a 1000-character ceiling. A call
        // must still start; the oldest notes are what gives way.
        for index in 1 ... 10 {
            try await store.upsert(KnowledgeNote(
                title: "Note \(index)",
                body: String(repeating: "word ", count: 60),
                scope: .always))
        }
        let block = try await store.promptBlock(
            for: MeetingContext(eventID: "e1"), persona: nil, limit: 1000)
        let text = try XCTUnwrap(block)
        XCTAssertLessThanOrEqual(text.count, 1100)
    }

    func testNothingFiledMeansNoBlockAtAll() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let block = try await store.promptBlock(
            for: MeetingContext(eventID: "e1"), persona: nil, limit: 8000)
        XCTAssertNil(block, "an empty knowledge base must not put an empty heading in the prompt")
    }

    func testDocumentFieldsSurviveTheRoundTrip() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.upsert(document("scan.pdf", text: "Read by OCR.", pages: 3, scope: .event("e1")))
        let stored = try await store.notes(in: .event("e1")).first
        XCTAssertEqual(stored?.originName, "scan.pdf")
        XCTAssertEqual(stored?.originKind, "pdf")
        XCTAssertEqual(stored?.pageCount, 3)
        XCTAssertEqual(stored?.byteSize, 1_200_000)
        XCTAssertTrue(stored?.isDocument == true)
        XCTAssertFalse(stored?.isEditable == true, "a document is not hand-editable")
    }

    /// v1 files exist on disk already; the added columns must not lose them.
    func testMigratingFromV1KeepsExistingNotes() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("calla-migrate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("calla.sqlite")

        do {
            let store = try CallaStore(path: path)
            try await store.upsert(KnowledgeNote(title: "Older", body: "Written before files existed."))
        }
        // Force the file back to v1 so the v2 migration runs over real rows.
        let database = try SQLiteDatabase(path: path.path)
        try database.execute("ALTER TABLE knowledge_note DROP COLUMN origin_name")
        try database.execute("ALTER TABLE knowledge_note DROP COLUMN origin_kind")
        try database.execute("ALTER TABLE knowledge_note DROP COLUMN byte_size")
        try database.execute("ALTER TABLE knowledge_note DROP COLUMN page_count")
        try database.execute("PRAGMA user_version = 1")

        let store = try CallaStore(path: path)
        let notes = try await store.notes()
        XCTAssertEqual(notes.map(\.title), ["Older"])
        XCTAssertEqual(notes.first?.byteSize, 0)
        let hits = await store.search(query: "written before files", scopes: [.always], limit: 3)
        XCTAssertFalse(hits.isEmpty, "the index must survive the migration")
    }
}
