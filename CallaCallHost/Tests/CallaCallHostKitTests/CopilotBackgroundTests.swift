import IntelligenceCore
import IntelligenceStore
import XCTest
@testable import CallaCallHostKit

/// What every lane is told about the call it is sitting in.
///
/// The bug these cover is not hypothetical: the account and fold lanes are
/// separate `agy` conversations and were built with the output contract as their
/// entire system prompt, so they wrote about "a service" where the question lane
/// knew the name. Two of four lanes had the context.
final class CopilotBackgroundTests: XCTestCase {
    private func profile(
        knowledge: String? = nil,
        meeting: MeetingContext? = nil,
        about: String? = nil
    ) -> CallProfile {
        var value = CallProfile()
        value.about = about
        value.knowledge = knowledge
        value.meeting = meeting
        return value
    }

    func testBackgroundCarriesTheMeetingEvenWithNoKnowledgeWritten() {
        // The first occurrence of a meeting has nothing written about it yet, and
        // that is exactly when the title and the attendee list are worth the most.
        let meeting = MeetingContext(
            eventID: "e1", title: "Weekly Acme sync", attendees: ["Dana", "Rae"])
        let background = CopilotLocalPrompt.background(profile: profile(meeting: meeting))
        XCTAssertTrue(background.contains("Weekly Acme sync"))
        XCTAssertTrue(background.contains("Dana, Rae"))
    }

    func testBackgroundJoinsTheMeetingHeaderAndTheKnowledge() {
        let background = CopilotLocalPrompt.background(profile: profile(
            knowledge: "They churned on latency in Q2.",
            meeting: MeetingContext(eventID: "e1", title: "Acme")))
        XCTAssertTrue(background.contains("Acme"))
        XCTAssertTrue(background.contains("churned on latency"))
    }

    func testBackgroundIsEmptyWhenThereIsNothingToSay() {
        XCTAssertTrue(CopilotLocalPrompt.background(profile: nil).isEmpty)
        XCTAssertTrue(CopilotLocalPrompt.background(profile: profile()).isEmpty)
    }

    func testQuestionLaneBlocksCarryKnowledge() {
        let blocks = CopilotLocalPrompt.blocks(
            persona: "sales",
            profile: profile(knowledge: "Enterprise starts at ninety thousand.",
                             meeting: MeetingContext(eventID: "e", title: "Renewal"),
                             about: "I own billing."))
        XCTAssertEqual(blocks.about, "I own billing.")
        XCTAssertTrue(blocks.knowledge.contains("ninety thousand"))
        XCTAssertTrue(blocks.knowledge.contains("Renewal"))
    }

    /// The composed bootstrap is what actually reaches the model, so the block
    /// has to survive composition and not merely exist on the struct.
    func testBackgroundReachesTheComposedPrompt() {
        let blocks = CopilotLocalPrompt.blocks(
            persona: "generic",
            profile: profile(knowledge: "Adyen is the processor.",
                             meeting: MeetingContext(eventID: "e", title: "Payments review")))
        let prompt = PromptComposer.bootstrap(for: IntelligenceRequest(
            task: CopilotTasks.suggest, sessionKey: "k", system: blocks, input: "Them: who processes?"))
        XCTAssertTrue(prompt.contains("## Background"))
        XCTAssertTrue(prompt.contains("Adyen is the processor."))
        XCTAssertTrue(prompt.contains("Payments review"))
    }

    func testKnowledgeIsClampedRatherThanSentWhole() {
        // The block is re-sent on every context rollover, so an unbounded one
        // makes each rollover slower than the last.
        var blocks = PromptBlocks(base: "b")
        blocks.knowledge = String(repeating: "x", count: 20_000)
        let prompt = PromptComposer.bootstrap(for: IntelligenceRequest(
            task: CopilotTasks.brief, sessionKey: "k", system: blocks, input: "in"))
        XCTAssertTrue(prompt.contains("[truncated]"))
        XCTAssertLessThan(prompt.count, 20_000)
    }
}

final class QuestionContextTests: XCTestCase {
    private func statement(_ text: String, speaker: Speaker = .remote) -> Statement {
        Statement(fromSeq: 1, toSeq: 1, speaker: speaker, text: text, span: 1, truncated: false)
    }

    func testRecalledKnowledgeLeadsTheContext() {
        // Above the account on purpose: it is standing fact from outside the call,
        // and the account's own lines are a model's paraphrase of what was said.
        var ledger = CallLedger()
        ledger.applyChunk(points: ["They asked about pricing."], openQuestions: nil, throughSeq: 1)
        let context = ledger.questionContext(
            [statement("what does enterprise cost?")],
            recalled: ["Pricing: Enterprise starts at ninety thousand."])

        let notes = try? XCTUnwrap(context.range(of: "From your notes:"))
        let account = try? XCTUnwrap(context.range(of: "So far:"))
        XCTAssertNotNil(notes)
        XCTAssertNotNil(account)
        if let notes, let account {
            XCTAssertTrue(notes.lowerBound < account.lowerBound)
        }
    }

    func testNoRecalledKnowledgeLeavesTheContextUnchanged() {
        var ledger = CallLedger()
        ledger.applyChunk(points: ["A point."], openQuestions: nil, throughSeq: 1)
        let question = [statement("and then?")]
        XCTAssertEqual(ledger.questionContext(question), ledger.questionContext(question, recalled: []))
        XCTAssertFalse(ledger.questionContext(question).contains("From your notes:"))
    }
}
