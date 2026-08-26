import XCTest
@testable import CallaEngineValidation

final class TutorEngineGateTests: XCTestCase {
    private func identity(step: String = "step-1", generation: UInt64 = 2) -> TutorEngineIdentity {
        TutorEngineIdentity(runID: "run-1", generation: generation, courseKey: "course-1", revision: "rev-1", lessonID: "lesson-1", stepID: step)
    }

    func testStaleAndDuplicateEventsCannotMutateCurrentRun() {
        var gate = TutorEngineGate()
        gate.start(identity())
        XCTAssertEqual(gate.acceptEvent(requestID: "host-1", identity: identity()), .accepted)
        XCTAssertEqual(gate.acceptEvent(requestID: "host-1", identity: identity()), .duplicate)
        XCTAssertEqual(gate.acceptEvent(requestID: "host-2", identity: identity(generation: 1)), .stale)
        XCTAssertEqual(gate.acceptEvent(requestID: "host-3", identity: identity(step: "step-2")), .mismatched)
    }

    func testOnlyOneFeedbackRequestCanBePending() {
        var gate = TutorEngineGate()
        gate.start(identity())
        XCTAssertEqual(gate.beginFeedback(requestID: "feedback-1", identity: identity()), .accepted)
        XCTAssertEqual(gate.beginFeedback(requestID: "feedback-2", identity: identity()), .feedbackBusy)
        XCTAssertEqual(gate.finishFeedback(requestID: "feedback-1", identity: identity()), .accepted)
        XCTAssertEqual(gate.beginFeedback(requestID: "feedback-3", identity: identity()), .accepted)
    }

    func testAdvanceRequiresSamePinnedRunAndRevision() {
        var gate = TutorEngineGate()
        gate.start(identity())
        XCTAssertEqual(gate.advance(to: identity(step: "step-2")), .accepted)
        XCTAssertEqual(gate.active?.stepID, "step-2")
        XCTAssertEqual(gate.advance(to: TutorEngineIdentity(runID: "run-1", generation: 2, courseKey: "course-1", revision: "rev-2", lessonID: "lesson-1", stepID: "step-3")), .mismatched)
    }
}
