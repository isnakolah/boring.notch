import XCTest
@testable import IntelligenceCore

/// One test per flush rule. Every rule is a judgement call about when a thought
/// is finished, so each gets pinned with hand-set timestamps rather than left to
/// a live call to disprove.
final class StatementSegmenterTests: XCTestCase {
    private let tenWords = "we would need the contract reviewed before the end of quarter"
    private let fourWords = "the contract needs review"

    private func turn(
        _ seq: Int,
        _ speaker: Speaker,
        _ start: Double,
        _ end: Double,
        _ text: String
    ) -> TranscriptTurn {
        TranscriptTurn(seq: seq, speaker: speaker, start: start, end: end, text: text)
    }

    /// Rule 1: a turn that hit the VAD's 10s cap is mid-sentence by definition.
    func testCappedTurnWaitsForItsContinuation() {
        var segmenter = StatementSegmenter()
        let capped = turn(1, .remote, 0, 10, tenWords)
        XCTAssertTrue(segmenter.ingest(capped, now: 10.1).isEmpty)
        // Still nothing while the gap stays under cappedContinuationGap.
        XCTAssertTrue(segmenter.tick(now: 10.2).isEmpty)
        // Once the silence outlasts it, the normal rules take over.
        XCTAssertFalse(segmenter.tick(now: 12).isEmpty)
    }

    /// Rule 2: the other side speaking ends the exchange, whatever the length.
    func testSpeakerChangeFlushesTheOtherLane() {
        var segmenter = StatementSegmenter()
        XCTAssertTrue(segmenter.ingest(turn(1, .remote, 0, 2, fourWords), now: 2).isEmpty)

        let emitted = segmenter.ingest(turn(2, .local, 2.2, 3.4, "yes we can do that"), now: 3.4)
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted.first?.speaker, .remote)
        XCTAssertEqual(emitted.first?.text, fourWords)
        XCTAssertEqual(emitted.first?.truncated, false)
    }

    /// Rule 3: terminal punctuation, once the silence confirms it.
    func testTerminalPunctuationNeedsSettlingSilence() {
        var segmenter = StatementSegmenter()
        XCTAssertTrue(segmenter.ingest(turn(1, .remote, 0, 3, tenWords + "."), now: 3).isEmpty)
        XCTAssertTrue(segmenter.tick(now: 3.4).isEmpty, "0.4s is inside terminalGap")
        XCTAssertEqual(segmenter.tick(now: 3.8).count, 1)
    }

    /// Rule 4: silence is the more reliable boundary, because Whisper drops final
    /// punctuation often.
    func testSilenceEndsAStatementWithoutPunctuation() {
        var segmenter = StatementSegmenter()
        XCTAssertTrue(segmenter.ingest(turn(1, .remote, 0, 3, tenWords), now: 3).isEmpty)
        XCTAssertTrue(segmenter.tick(now: 4.0).isEmpty, "1.0s is inside silenceGap")
        XCTAssertEqual(segmenter.tick(now: 4.6).count, 1)
    }

    /// Rule 4, other half: a hanging conjunction means the thought is unfinished.
    func testHangingConjunctionWaitsLonger() {
        var segmenter = StatementSegmenter()
        XCTAssertTrue(segmenter.ingest(turn(1, .remote, 0, 3, tenWords + " because"), now: 3).isEmpty)
        XCTAssertTrue(segmenter.tick(now: 4.8).isEmpty, "1.8s would flush a non-hanging buffer")
        XCTAssertEqual(segmenter.tick(now: 5.7).count, 1)
    }

    /// Rule 5: a monologue must not starve the copilot.
    func testSizeCapForcesATruncatedFlush() {
        var segmenter = StatementSegmenter()
        let long = Array(repeating: "word", count: 130).joined(separator: " ")
        let emitted = segmenter.ingest(turn(1, .remote, 0, 8, long), now: 8)
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted.first?.truncated, true)
    }

    /// Rule 6: someone trailing off must not leave the copilot silent.
    func testIdleTimerFlushesAShortBuffer() {
        var segmenter = StatementSegmenter()
        XCTAssertTrue(segmenter.ingest(turn(1, .remote, 0, 2, fourWords), now: 2).isEmpty)
        XCTAssertTrue(segmenter.tick(now: 5.0).isEmpty, "under minWords, so only idle can flush it")
        XCTAssertEqual(segmenter.tick(now: 6.2).count, 1)
    }

    /// Rule 7: don't spend a ~15k-token request on "yeah".
    func testTrivialAcknowledgementIsDiscarded() {
        var segmenter = StatementSegmenter()
        XCTAssertTrue(segmenter.ingest(turn(1, .remote, 0, 0.4, "yeah"), now: 0.4).isEmpty)
        XCTAssertTrue(segmenter.tick(now: 5).isEmpty)
        // And the lane was cleared, so it cannot resurface later.
        XCTAssertTrue(segmenter.tick(now: 30).isEmpty)
    }

    /// Rule 7 exemption: a bare "yes" still matters when it answers something.
    func testTrivialReplyIsKeptWhenTheOtherLaneHasContent() {
        var segmenter = StatementSegmenter()
        _ = segmenter.ingest(turn(1, .remote, 0, 3, tenWords + "?"), now: 3)
        let emitted = segmenter.ingest(turn(2, .local, 3.2, 3.5, "yes"), now: 3.5)
        XCTAssertEqual(emitted.count, 1, "the question flushes on speaker change")

        // Now the short answer flushes when the remote speaks again, because the
        // other lane has real content to react to.
        let next = segmenter.ingest(turn(3, .remote, 7.0, 9.0, tenWords), now: 9.0)
        XCTAssertEqual(next.first?.text, "yes")
    }

    /// Rule 8: a fast back-and-forth becomes one request, not five.
    func testRequestFloorMergesStatements() {
        var segmenter = StatementSegmenter()
        _ = segmenter.ingest(turn(1, .remote, 0, 3, tenWords + "."), now: 3)
        let first = segmenter.tick(now: 3.8)
        XCTAssertEqual(first.count, 1)

        _ = segmenter.ingest(
            turn(2, .remote, 4.0, 5.0, "and we will also need the pricing schedule attached."),
            now: 5.0
        )
        XCTAssertTrue(segmenter.tick(now: 5.9).isEmpty, "inside the request floor")

        let merged = segmenter.tick(now: 6.5)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.fromSeq, 2)
        XCTAssertTrue(merged.first?.text.contains("pricing schedule") ?? false)
    }

    /// The whole point of the component: fewer requests than turns.
    func testSegmentationRatioBeatsOnePerTurn() {
        var segmenter = StatementSegmenter()
        var statements: [Statement] = []
        var clock = 0.0

        // Twelve phrase-length turns, the way the VAD actually emits them.
        for seq in 1 ... 12 {
            let start = clock
            let end = clock + 1.2
            let text = seq % 4 == 0 ? "and that is the whole requirement." : "we need the contract reviewed"
            statements += segmenter.ingest(turn(seq, .remote, start, end, text), now: end)
            clock = end + 0.3
            statements += segmenter.tick(now: clock)
        }
        statements += segmenter.drain(now: clock + 5)

        XCTAssertFalse(statements.isEmpty)
        XCTAssertLessThan(statements.count, 12, "batching must produce fewer requests than turns")
    }

    func testDrainEmitsBufferedTextIgnoringTheFloor() {
        var segmenter = StatementSegmenter()
        _ = segmenter.ingest(turn(1, .remote, 0, 2, fourWords), now: 2)
        XCTAssertEqual(segmenter.drain(now: 2.1).count, 1)
        XCTAssertTrue(segmenter.drain(now: 2.2).isEmpty)
    }

    func testTextShapeHelpers() {
        XCTAssertTrue(StatementSegmenter.endsTerminal("done."))
        XCTAssertTrue(StatementSegmenter.endsTerminal("\"is it done?\""))
        XCTAssertFalse(StatementSegmenter.endsTerminal("not done"))
        XCTAssertTrue(StatementSegmenter.endsHanging("we should, "))
        XCTAssertTrue(StatementSegmenter.endsHanging("we should and"))
        XCTAssertFalse(StatementSegmenter.endsHanging("we should ship"))
    }
}
