import XCTest
@testable import CallaCallHostKit

/// whisper splits one utterance at its own internal boundaries, which are not
/// sentence boundaries. Publishing each piece as a turn is how a single clause
/// ended up spread across five rows of the panel.
final class SegmentMergeTests: XCTestCase {
    private func segment(
        _ start: Double, _ end: Double, _ text: String, confidence: Double? = nil,
        noSpeech: Double? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text,
                          confidence: confidence, noSpeech: noSpeech)
    }

    func testContiguousFragmentsOfOneClauseAreJoined() {
        let merged = CallTranscriber.merge([
            segment(0, 1.2, "So, actually, if solving"),
            segment(1.2, 2.4, "problems that I have a better understanding"),
            segment(2.4, 3.0, "of"),
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(
            merged[0].text,
            "So, actually, if solving problems that I have a better understanding of")
        XCTAssertEqual(merged[0].start, 0)
        XCTAssertEqual(merged[0].end, 3.0)
    }

    func testAFinishedSentenceKeepsItsBoundary() {
        let merged = CallTranscriber.merge([
            segment(0, 1, "That is settled."),
            segment(1, 2, "Now about the timeline"),
        ])
        XCTAssertEqual(merged.count, 2)
    }

    func testARealPauseKeepsItsBoundary() {
        let merged = CallTranscriber.merge([
            segment(0, 1, "one thought"),
            segment(3, 4, "a separate thought"),
        ])
        XCTAssertEqual(merged.count, 2)
    }

    func testConfidenceIsWeightedByDuration() {
        // A long confident span must not be dragged down by a short shaky one.
        let merged = CallTranscriber.merge([
            segment(0, 3, "the confident part", confidence: 0.9),
            segment(3, 3.5, "and this bit", confidence: 0.3),
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].confidence ?? -1,
                       (0.9 * 3 + 0.3 * 0.5) / 3.5, accuracy: 0.0001)
    }

    func testTheStricterNoSpeechEstimateWins() {
        // If any part of a merged turn looked like silence, the whole is suspect.
        let merged = CallTranscriber.merge([
            segment(0, 1, "words", noSpeech: 0.1),
            segment(1, 2, "more words", noSpeech: 0.8),
        ])
        XCTAssertEqual(merged[0].noSpeech ?? -1, 0.8, accuracy: 0.0001)
    }

    func testMissingConfidenceOnOneSideIsNotTreatedAsZero() {
        let merged = CallTranscriber.merge([
            segment(0, 1, "measured", confidence: 0.8),
            segment(1, 2, "unmeasured"),
        ])
        XCTAssertEqual(merged[0].confidence ?? -1, 0.8, accuracy: 0.0001)
    }

    func testDegenerateInputIsReturnedUnchanged() {
        XCTAssertTrue(CallTranscriber.merge([]).isEmpty)
        let single = [segment(0, 1, "alone")]
        XCTAssertEqual(CallTranscriber.merge(single).map(\.text), ["alone"])
    }
}
