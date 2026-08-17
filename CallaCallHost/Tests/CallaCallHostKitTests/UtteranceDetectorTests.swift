import XCTest
@testable import CallaCallHostKit

/// Endpointing decides what whisper ever sees. Every failure here is silent:
/// a detector that never closes an utterance produces no turns at all, and one
/// that closes too eagerly chops sentences into fragments that read as garbled
/// transcription rather than as a VAD bug.
final class UtteranceDetectorTests: XCTestCase {
    private let rate = WhisperAudioFormat.sampleRate

    /// Speech-like signal: a tone is enough, the detector only measures energy.
    private func tone(seconds: Double, amplitude: Float = 0.3) -> [Float] {
        let count = Int(rate * seconds)
        return (0..<count).map { index in
            amplitude * sin(Float(index) * 0.05)
        }
    }

    private func silence(seconds: Double) -> [Float] {
        // Real capture never delivers exact zeros; dither keeps this honest.
        let count = Int(rate * seconds)
        return (0..<count).map { _ in Float.random(in: -0.0005...0.0005) }
    }

    private func collect(
        _ detector: UtteranceDetector,
        _ chunks: [[Float]]
    ) -> [(samples: [Float], start: Double)] {
        var emitted: [(samples: [Float], start: Double)] = []
        detector.onUtterance = { samples, start in emitted.append((samples, start)) }
        for chunk in chunks { detector.ingest(chunk[...]) }
        return emitted
    }

    func testSpeechFollowedBySilenceEmitsOneUtterance() {
        let detector = UtteranceDetector()
        let emitted = collect(detector, [silence(seconds: 0.3), tone(seconds: 1.5), silence(seconds: 1.0)])

        XCTAssertEqual(emitted.count, 1)
        let utterance = try? XCTUnwrap(emitted.first)
        XCTAssertNotNil(utterance)
        // Pre-roll means the utterance starts slightly before the tone did.
        XCTAssertGreaterThan(emitted[0].samples.count, Int(rate * 1.0))
    }

    func testTwoSeparatedPhrasesBecomeTwoUtterances() {
        let detector = UtteranceDetector()
        let emitted = collect(detector, [
            silence(seconds: 0.3),
            tone(seconds: 1.0),
            silence(seconds: 1.0),
            tone(seconds: 1.0),
            silence(seconds: 1.0),
        ])
        XCTAssertEqual(emitted.count, 2)
        XCTAssertLessThan(emitted[0].start, emitted[1].start)
    }

    func testPureSilenceEmitsNothing() {
        let detector = UtteranceDetector()
        XCTAssertTrue(collect(detector, [silence(seconds: 5)]).isEmpty)
    }

    func testAVeryShortBlipIsNotAnUtterance() {
        // Below `minUtteranceMs` — a click, not speech.
        let detector = UtteranceDetector()
        let emitted = collect(detector, [silence(seconds: 0.3), tone(seconds: 0.05), silence(seconds: 1.0)])
        XCTAssertTrue(emitted.isEmpty)
    }

    func testLongMonologueIsCutAtTheCap() {
        // Without the cap a speaker who never pauses would never produce a turn,
        // and the copilot would stay silent for the whole call.
        let detector = UtteranceDetector(maxUtteranceMs: 2_000)
        let emitted = collect(detector, [silence(seconds: 0.3), tone(seconds: 9.0), silence(seconds: 1.0)])
        XCTAssertGreaterThanOrEqual(emitted.count, 3)
        for utterance in emitted {
            XCTAssertLessThanOrEqual(
                Double(utterance.samples.count) / rate, 2.2,
                "an utterance ran past the cap")
        }
    }

    func testFlushEmitsTheTrailingUtterance() {
        // A call that ends mid-sentence must not lose that sentence.
        let detector = UtteranceDetector()
        var emitted: [[Float]] = []
        detector.onUtterance = { samples, _ in emitted.append(samples) }

        detector.ingest(silence(seconds: 0.3)[...])
        detector.ingest(tone(seconds: 1.5)[...])
        XCTAssertTrue(emitted.isEmpty, "still speaking, nothing to emit yet")

        detector.flush()
        XCTAssertEqual(emitted.count, 1)
    }

    func testResetDiscardsRatherThanEmits() {
        let detector = UtteranceDetector()
        var emitted = 0
        detector.onUtterance = { _, _ in emitted += 1 }

        detector.ingest(silence(seconds: 0.3)[...])
        detector.ingest(tone(seconds: 1.5)[...])
        detector.reset()
        XCTAssertEqual(emitted, 0)
    }

    func testResetReturnsTheDetectorToItsInitialBehaviour() {
        let detector = UtteranceDetector()
        var emitted: [Double] = []
        detector.onUtterance = { _, start in emitted.append(start) }

        detector.ingest(silence(seconds: 0.3)[...])
        detector.ingest(tone(seconds: 1.0)[...])
        detector.ingest(silence(seconds: 1.0)[...])
        let firstRun = emitted.count
        XCTAssertEqual(firstRun, 1)

        detector.reset()
        emitted.removeAll()

        detector.ingest(silence(seconds: 0.3)[...])
        detector.ingest(tone(seconds: 1.0)[...])
        detector.ingest(silence(seconds: 1.0)[...])
        XCTAssertEqual(emitted.count, 1)
        // The clock restarted, so the second run's timestamps look like the
        // first run's rather than continuing from them.
        XCTAssertLessThan(emitted[0], 1.0)
    }

    func testStartTimesTrackTheStreamClock() {
        let detector = UtteranceDetector()
        let emitted = collect(detector, [
            silence(seconds: 2.0),
            tone(seconds: 1.0),
            silence(seconds: 1.0),
        ])
        XCTAssertEqual(emitted.count, 1)
        // Roughly 2s in, minus the 200ms pre-roll.
        XCTAssertEqual(emitted[0].start, 1.8, accuracy: 0.25)
    }

    func testArbitraryChunkBoundariesDoNotChangeTheResult() {
        // Capture delivers whatever buffer size the device likes; the detector
        // must not be sensitive to where those boundaries land.
        let signal = silence(seconds: 0.3) + tone(seconds: 1.2) + silence(seconds: 1.0)

        let wholeDetector = UtteranceDetector()
        let whole = collect(wholeDetector, [signal])

        let choppedDetector = UtteranceDetector()
        var chunks: [[Float]] = []
        var index = 0
        // Deliberately not a multiple of the 30ms frame size.
        let oddChunk = 997
        while index < signal.count {
            chunks.append(Array(signal[index..<min(index + oddChunk, signal.count)]))
            index += oddChunk
        }
        let chopped = collect(choppedDetector, chunks)

        XCTAssertEqual(whole.count, chopped.count)
        XCTAssertEqual(whole[0].samples.count, chopped[0].samples.count)
        XCTAssertEqual(whole[0].start, chopped[0].start, accuracy: 0.001)
    }
}

final class AudioSignalTests: XCTestCase {
    func testExactZeroRunIsSilentButDitherIsNot() {
        XCTAssertTrue(AudioSignal.isSilent([0, 0, 0, 0]))
        XCTAssertTrue(AudioSignal.isSilent([]))
        // A live mic in a quiet room still delivers noise — that is not "capture
        // produced nothing", which is the only thing this predicate claims.
        XCTAssertFalse(AudioSignal.isSilent([0, 0, 0.00001, 0]))
    }

    func testPeakIsMagnitudeNotSignedMaximum() {
        XCTAssertEqual(AudioSignal.peak([-0.9, 0.2, 0.3]), 0.9, accuracy: 0.0001)
        XCTAssertEqual(AudioSignal.peak([]), 0)
    }
}

final class TurnModelTests: XCTestCase {
    func testTurnSourceRoundTripsThroughTheWireEncoding() throws {
        // These strings are the wire contract with the gateway, which validates
        // against exactly "me" and "them".
        XCTAssertEqual(TurnSource.me.rawValue, "me")
        XCTAssertEqual(TurnSource.them.rawValue, "them")
        XCTAssertEqual(TurnSource.allCases.count, 2)

        let turn = CallTurn(seq: 3, source: .them, t0: 1.5, t1: 2.5, text: "hello")
        let decoded = try JSONDecoder().decode(CallTurn.self, from: JSONEncoder().encode(turn))
        XCTAssertEqual(decoded, turn)
    }
}
