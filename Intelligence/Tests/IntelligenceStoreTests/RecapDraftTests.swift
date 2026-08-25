import XCTest
import CallaContracts
@testable import IntelligenceStore

final class RecapDraftTests: XCTestCase {
    func testDraftIsNotKnowledgeUntilApproved() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CallaStore(path: root.appendingPathComponent("calla.sqlite"))
        let meeting = MeetingContext(eventID: "event-1", title: "Weekly")
        try await store.beginCall(CallRecord(id: "call-123456789abc", persona: "generic"))
        let draft = CallRecapDraft(
            callID: "call-123456789abc", overview: "Ship Friday.",
            items: [.init(id: "decision-1", kind: .decision, text: "Ship Friday.", fromSeq: 2, toSeq: 2)])
        try await store.save(recapDraft: draft)
        let pending = try await store.recapDraft(forCall: draft.callID)
        let notesBeforeApproval = try await store.notes(in: .event("event-1"))
        XCTAssertEqual(pending?.reviewState, .pending)
        XCTAssertTrue(notesBeforeApproval.isEmpty)
        let note = try await store.approve(recapDraftFor: draft.callID, meeting: meeting)
        let approved = try await store.recapDraft(forCall: draft.callID)
        let notesAfterApproval = try await store.notes(in: .event("event-1"))
        XCTAssertNotNil(note)
        XCTAssertEqual(approved?.reviewState, .approved)
        XCTAssertEqual(notesAfterApproval.count, 1)
    }
}
