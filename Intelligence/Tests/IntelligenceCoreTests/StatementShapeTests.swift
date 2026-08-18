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

/// A question is the one input the pacing rules must not delay.
final class QuestionPriorityTests: XCTestCase {
    private func turn(_ seq: Int, _ speaker: Speaker, _ start: Double, _ end: Double, _ text: String) -> TranscriptTurn {
        TranscriptTurn(seq: seq, speaker: speaker, start: start, end: end, text: text)
    }

    /// Everything else waits for punctuation plus 0.7s, or 1.5s of silence. A
    /// question goes on a short pause.
    func testQuestionFlushesOnAShortPause() {
        var segmenter = StatementSegmenter()
        let asked = turn(1, .remote, 0, 3, "so how would you scale the ingestion path")
        XCTAssertTrue(segmenter.ingest(asked, now: 3).isEmpty, "not while they are still speaking")
        let emitted = segmenter.tick(now: 3.4)
        XCTAssertEqual(emitted.count, 1, "0.4s is enough for a question")
        XCTAssertTrue(emitted.first?.invitesAnAnswer ?? false)
    }

    /// The 2.5s floor exists to stop the copilot narrating, not to make someone wait
    /// while they are being asked something.
    func testQuestionIgnoresTheRequestFloor() {
        var segmenter = StatementSegmenter()
        // Eight words, because `minWords` is the gate this setup has to clear —
        // the point being established is the floor, not the length rule, and a
        // seven-word opener never emits at all.
        _ = segmenter.ingest(turn(1, .remote, 0, 3, "we run about forty separate services in production."), now: 3)
        XCTAssertEqual(segmenter.tick(now: 3.8).count, 1, "a normal statement sets the floor")

        _ = segmenter.ingest(turn(2, .remote, 4.0, 5.0, "which one would you split first?"), now: 5.0)
        let emitted = segmenter.tick(now: 5.4)
        XCTAssertEqual(emitted.count, 1, "inside the floor, but it is a question")
        XCTAssertTrue(emitted.first?.text.contains("split first") ?? false)
    }

    /// A short question would otherwise be discarded as trivial or held as thin.
    func testShortQuestionsStillGoOut() {
        var segmenter = StatementSegmenter()
        _ = segmenter.ingest(turn(1, .remote, 0, 1, "why?"), now: 1)
        let emitted = segmenter.tick(now: 1.5)
        XCTAssertEqual(emitted.count, 1)
        XCTAssertTrue(emitted.first?.invitesAnAnswer ?? false)
    }

    /// Statements keep the old pacing; only questions jump it.
    func testStatementsAreStillPaced() {
        var segmenter = StatementSegmenter()
        _ = segmenter.ingest(turn(1, .remote, 0, 3, "we moved the transcoder onto its own fleet"), now: 3)
        XCTAssertTrue(segmenter.tick(now: 3.4).isEmpty, "0.4s is not a boundary for a statement")
    }
}
