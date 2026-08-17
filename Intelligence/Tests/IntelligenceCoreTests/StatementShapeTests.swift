import XCTest
@testable import IntelligenceCore

/// "Answers only" mode speaks when asked and stays quiet otherwise, so this rule
/// decides whether a request is spent at all.
final class StatementShapeTests: XCTestCase {
    private func statement(_ text: String, _ speaker: Speaker = .remote) -> Statement {
        Statement(fromSeq: 0, toSeq: 0, speaker: speaker, text: text, span: 3, truncated: false)
    }

    func testPunctuatedQuestions() {
        XCTAssertTrue(statement("So what would you do differently?").invitesAnAnswer)
        XCTAssertTrue(statement("does that scale to ten times the traffic?").invitesAnAnswer)
    }

    /// Whisper drops final punctuation regularly, so the mark cannot be required.
    func testUnpunctuatedQuestionsStillCount() {
        XCTAssertTrue(statement("how would you approach scaling this").invitesAnAnswer)
        XCTAssertTrue(statement("why did you leave that role").invitesAnAnswer)
        XCTAssertTrue(statement("did you own the migration end to end").invitesAnAnswer)
    }

    /// An interviewer's hardest prompts are imperatives, not questions.
    func testImperativeRequestsCount() {
        XCTAssertTrue(statement("walk me through the architecture").invitesAnAnswer)
        XCTAssertTrue(statement("tell me about a time you disagreed with a lead").invitesAnAnswer)
        XCTAssertTrue(statement("describe the hardest bug you have shipped").invitesAnAnswer)
        XCTAssertTrue(statement("give me an example of that").invitesAnAnswer)
    }

    func testStatementsAndSmallTalkDoNot() {
        XCTAssertFalse(statement("we are a team of about forty engineers").invitesAnAnswer)
        XCTAssertFalse(statement("thanks for making the time today").invitesAnAnswer)
        XCTAssertFalse(statement("i used a virtual machine for that work").invitesAnAnswer)
        XCTAssertFalse(statement("").invitesAnAnswer)
    }

    /// "is" as a leading auxiliary is a question; the same word mid-sentence is not.
    func testLeadingAuxiliaryIsNotMatchedMidSentence() {
        XCTAssertTrue(statement("is the on-call rota shared").invitesAnAnswer)
        XCTAssertFalse(statement("the rota is shared across two teams").invitesAnAnswer)
    }
}
