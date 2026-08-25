import XCTest
@testable import CallaContracts

final class CallaContractsTests: XCTestCase {
    func testRejectsStaleHostEvents() {
        let current = CallLifecycleSnapshot(callID: "call-a", generation: 3, state: .capturing)
        let stale = CallHostEvent(callID: "call-a", generation: 2, kind: .finished,
            snapshot: .init(callID: "call-a", generation: 2, state: .finished))
        XCTAssertFalse(current.accepts(stale))
    }

    func testQueueKeepsIndependentQuestionsAndOnlySupersedesContinuation() {
        var queue = CallQuestionQueue()
        let first = CallQuestion(fromSeq: 1, toSeq: 1, prompt: "First?", kind: .direct, confidence: 0.9)
        let second = CallQuestion(fromSeq: 2, toSeq: 2, prompt: "Second?", kind: .direct, confidence: 0.9)
        queue.enqueue(first); queue.enqueue(second)
        XCTAssertEqual(queue.beginNext()?.id, first.id)
        queue.answer(first.id, answerID: "a1")
        XCTAssertEqual(queue.beginNext()?.id, second.id)
        let third = CallQuestion(fromSeq: 3, toSeq: 3, prompt: "Third?", kind: .direct, confidence: 0.9)
        let continuation = CallQuestion(fromSeq: 4, toSeq: 4, prompt: "And timing?", kind: .direct, confidence: 0.9)
        queue.enqueue(third)
        queue.enqueue(continuation, continuing: true)
        XCTAssertEqual(queue.questions[1].state, .answering)
        XCTAssertEqual(queue.questions[2].state, .superseded)
        XCTAssertEqual(queue.questions[3].state, .queued)
    }

    func testSummaryRulesPrioritizeAnswersAndUseDeterministicTriggers() {
        let now = Date(timeIntervalSince1970: 100)
        var trigger = CallSummaryTrigger(now: now)
        trigger.recordStatement(at: now)
        XCTAssertFalse(trigger.isDue(now: now.addingTimeInterval(1), commitmentOrDecision: false, answerInFlight: false))
        trigger.recordStatement(at: now); trigger.recordStatement(at: now)
        XCTAssertTrue(trigger.isDue(now: now, commitmentOrDecision: false, answerInFlight: false))
        XCTAssertFalse(trigger.isDue(now: now, commitmentOrDecision: true, answerInFlight: true))
    }
}
