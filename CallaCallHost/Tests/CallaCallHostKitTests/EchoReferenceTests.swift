import XCTest
@testable import CallaCallHostKit

/// The signal-level echo test, which replaces comparing two transcripts as text.
///
/// Fixtures are synthesised rather than recorded: an echo is the reference
/// signal delayed, attenuated, spectrally mangled and buried in noise, and
/// building that explicitly is what makes it clear which of those the detector
/// is supposed to survive.
final class EchoReferenceTests: XCTestCase {
    private let rate = WhisperAudioFormat.sampleRate

    /// Speech-like: a carrier whose amplitude follows an *irregular* syllable
    /// rhythm.
    ///
    /// The irregularity is the point. A first version used a sine as the syllable
    /// envelope, and two different "speakers" then correlated at 0.99 — a
    /// periodic envelope matches itself at some lag, and the lag search dutifully
    /// found it. Real speech envelopes are aperiodic, which is exactly why this
    /// detector can tell an echo from a coincidence, so the fixture has to be
    /// aperiodic too or it tests nothing.
    private func speech(seconds: Double, seed: UInt64 = 1) -> [Float] {
        var state = seed &* 0x9E3779B97F4A7C15 &+ 0x2545F4914F6CDD1D
        func next() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state >> 11) / Double(UInt64.max >> 11)
        }

        let count = Int(rate * seconds)
        var gain = [Double](repeating: 0, count: count)
        var index = 0
        while index < count {
            let syllable = Int(rate * (0.08 + next() * 0.17))   // 80–250 ms
            let gap = Int(rate * (0.02 + next() * 0.13))        // 20–150 ms
            let peak = 0.35 + next() * 0.65
            for offset in 0..<syllable where index + offset < count {
                // Raised cosine: an onset and a decay, not a step.
                let phase = Double(offset) / Double(syllable)
                gain[index + offset] = peak * (0.5 - 0.5 * cos(2 * .pi * phase))
            }
            index += syllable + gap
        }

        return (0..<count).map { i in
            let t = Double(i) / rate
            let carrier = sin(2 * .pi * 220 * t) + 0.4 * sin(2 * .pi * 511 * t)
            return Float(gain[i] * carrier * 0.3)
        }
    }

    /// What a speaker and a room do to it: quieter, low-passed, delayed, noisy.
    private func echoed(_ source: [Float], delaySamples: Int, gain: Float) -> [Float] {
        var out = [Float](repeating: 0, count: source.count)
        var lowPassed: Float = 0
        var noiseState: UInt64 = 0x2545F4914F6CDD1D
        for index in 0..<source.count {
            let delayed = index >= delaySamples ? source[index - delaySamples] : 0
            // One-pole low pass: a laptop speaker is not flat.
            lowPassed += 0.25 * (delayed - lowPassed)
            noiseState = noiseState &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: noiseState >> 11)) / Float(Int64.max) * 0.01
            out[index] = lowPassed * gain + noise
        }
        return out
    }

    private func reference(with system: [Float], at start: Date) -> EchoReference {
        let echo = EchoReference()
        // Fed in realistic block sizes so the framing and the clock arithmetic
        // are exercised, not bypassed by one giant append.
        let block = 1024
        var index = 0
        while index < system.count {
            let end = min(index + block, system.count)
            echo.append(
                systemSamples: Array(system[index..<end]),
                at: start.addingTimeInterval(Double(index) / rate))
            index = end
        }
        return echo
    }

    func testSpeakerBleedIsCaughtDespiteDelayAttenuationAndColouring() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let system = speech(seconds: 6)
        let echo = reference(with: system, at: start)

        // The microphone hears it 120 ms later, a fifth as loud, low-passed.
        let heard = echoed(system, delaySamples: Int(rate * 0.12), gain: 0.2)
        let utterance = Array(heard[Int(rate * 1.0) ..< Int(rate * 4.0)])

        let verdict = echo.verdict(
            forMicrophone: utterance,
            endedAt: start.addingTimeInterval(4.0 + 0.12))
        XCTAssertTrue(verdict.isEcho, "correlation was \(verdict.correlation)")
        XCTAssertGreaterThan(verdict.correlation, 0.8)
    }

    func testGenuineSpeechOverTheOtherPartyIsNotEcho() {
        // Both sides talking at once is the case that must survive: suppressing
        // it would delete the user's half of every crosstalk moment.
        let start = Date(timeIntervalSince1970: 1_000_000)
        let system = speech(seconds: 6, seed: 1)
        let echo = reference(with: system, at: start)

        // A different speaker: different syllable rhythm, different phase.
        let mine = speech(seconds: 6, seed: 99)
        let utterance = Array(mine[Int(rate * 1.0) ..< Int(rate * 4.0)])

        let verdict = echo.verdict(
            forMicrophone: utterance, endedAt: start.addingTimeInterval(4.0))
        XCTAssertFalse(verdict.isEcho, "correlation was \(verdict.correlation)")
    }

    func testSilenceOnTheReferenceIsNeverEcho() {
        // Nothing came out of the speakers, so nothing can be an echo of it. A
        // detector that flags this deletes speech during every quiet stretch.
        let start = Date(timeIntervalSince1970: 1_000_000)
        let echo = reference(with: [Float](repeating: 0, count: Int(rate * 6)), at: start)
        let utterance = Array(speech(seconds: 4)[Int(rate * 0.5) ..< Int(rate * 3.5)])
        let verdict = echo.verdict(
            forMicrophone: utterance, endedAt: start.addingTimeInterval(3.5))
        XCTAssertFalse(verdict.isEcho, "correlation was \(verdict.correlation)")
    }

    func testClockSkewWithinTheSearchWindowIsTolerated() {
        // The two capture paths buffer independently, so the nominal alignment is
        // only good to a few hundred milliseconds. The lag search exists for this.
        let start = Date(timeIntervalSince1970: 1_000_000)
        let system = speech(seconds: 8)
        let echo = reference(with: system, at: start)
        let heard = echoed(system, delaySamples: Int(rate * 0.05), gain: 0.25)
        let utterance = Array(heard[Int(rate * 2.0) ..< Int(rate * 5.0)])

        for skew in [-0.6, -0.25, 0.0, 0.25, 0.6] {
            let verdict = echo.verdict(
                forMicrophone: utterance,
                endedAt: start.addingTimeInterval(5.0 + skew))
            XCTAssertTrue(verdict.isEcho, "skew \(skew) gave \(verdict.correlation)")
        }
    }

    func testShortUtterancesAreDeclinedRatherThanGuessedAt() {
        // Under ~400ms there is not enough envelope to correlate. Saying "not
        // echo" is the safe answer; the caller has a separate rule for these.
        let start = Date(timeIntervalSince1970: 1_000_000)
        let system = speech(seconds: 4)
        let echo = reference(with: system, at: start)
        let heard = echoed(system, delaySamples: Int(rate * 0.1), gain: 0.2)
        let tiny = Array(heard[0 ..< Int(rate * 0.2)])
        XCTAssertFalse(echo.verdict(forMicrophone: tiny,
                                    endedAt: start.addingTimeInterval(0.2)).isEcho)
    }

    func testResetForgetsThePreviousCall() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let system = speech(seconds: 6)
        let echo = reference(with: system, at: start)
        echo.reset()
        let heard = echoed(system, delaySamples: Int(rate * 0.12), gain: 0.2)
        let utterance = Array(heard[Int(rate * 1.0) ..< Int(rate * 4.0)])
        XCTAssertFalse(echo.verdict(forMicrophone: utterance,
                                    endedAt: start.addingTimeInterval(4.12)).isEcho)
    }

    func testStandardizeReportsFlatSignalsAsNothingToMatch() {
        XCTAssertTrue(EchoReference.standardize([Float](repeating: 0.5, count: 20)).isEmpty)
        XCTAssertTrue(EchoReference.standardize([1]).isEmpty)
        XCTAssertFalse(EchoReference.standardize([0, 1, 0, 1, 0, 1]).isEmpty)
    }
}
