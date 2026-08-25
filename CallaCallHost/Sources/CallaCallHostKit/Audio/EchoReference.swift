import Accelerate
import Foundation

/// Decides whether a microphone utterance is the speakers being heard again.
///
/// Without headphones the microphone picks up the other party, whisper
/// transcribes it a second time as if it were the user, and the transcript
/// doubles. Measured across 54 recorded calls: **36% of every `me` turn** landed
/// on top of a `them` turn, and on speaker-mode calls it reached 97%. The `me`
/// leg's word error rate against a large-model reference is 68.8% against the
/// remote leg's 19.7% — almost all of that gap is this.
///
/// The existing defence compares the two transcripts as text, which cannot work
/// well and did not: the legs hear the same words through different paths and
/// whisper renders them differently ("full stop" against "all stop"), and the mic
/// leg usually endpoints first, so a `me` turn is published before the `them`
/// turn it would have been compared against even exists.
///
/// This compares the *audio*, before any inference is spent.
///
/// **Envelopes, not samples.** A loudspeaker and a room change the spectrum and
/// the phase of what they replay, so sample-level correlation is unreliable — but
/// they leave the amplitude envelope almost intact, because that is what makes it
/// recognisably the same speech. Correlating 100 Hz envelopes instead of 16 kHz
/// waveforms is both more robust and about three orders of magnitude cheaper: a
/// three-second utterance against a two-second lag search is sixty thousand
/// multiply-adds, not a billion.
public final class EchoReference: @unchecked Sendable {
    /// Envelope resolution. 10 ms is short enough to resolve syllables, which is
    /// what carries the correlation, and long enough that a couple of frames of
    /// clock error do not matter.
    static let frameSamples = 160
    /// How much reference history to keep. Far more than the lag search needs;
    /// it is 100 floats per second, so the whole buffer is a few kilobytes.
    static let historySeconds: Double = 30
    /// How far the two legs' clocks may disagree. The microphone tap and the
    /// ScreenCaptureKit queue buffer independently, so the nominal alignment is
    /// good to a few hundred milliseconds and no better.
    static let maximumLagSeconds: Double = 1.0
    /// Below this many frames (~400 ms) a correlation is not evidence of
    /// anything; short utterances are handled by the caller's own rule.
    static let minimumFrames = 40

    /// Normalised correlation above which the microphone is judged to be hearing
    /// the speakers. Echo through a laptop speaker and mic correlates in the high
    /// 0.8s; genuine simultaneous speech from two people does not come close.
    public var threshold: Float = 0.72

    private let lock = NSLock()
    /// Envelope frames, oldest first.
    private var envelope: [Float] = []
    /// Wall-clock time of the first frame still in `envelope`.
    private var envelopeStart: Date?
    /// Samples not yet long enough to close a frame.
    private var partial: [Float] = []

    public init() {}

    // MARK: - Reference side

    /// Feeds the `them` leg. Call with the same samples the detector sees.
    ///
    /// `at` is when this block was captured; the default is now, which is correct
    /// for a live tap and lets tests supply a clock.
    public func append(systemSamples samples: [Float], at time: Date = Date()) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        if envelopeStart == nil {
            // The first frame of this block starts here, minus whatever partial
            // samples are already carried over.
            envelopeStart = time.addingTimeInterval(
                -Double(partial.count) / WhisperAudioFormat.sampleRate)
        }
        partial.append(contentsOf: samples)
        while partial.count >= Self.frameSamples {
            envelope.append(Self.rms(Array(partial.prefix(Self.frameSamples))))
            partial.removeFirst(Self.frameSamples)
        }

        let capacity = Int(Self.historySeconds * WhisperAudioFormat.sampleRate)
            / Self.frameSamples
        if envelope.count > capacity {
            let excess = envelope.count - capacity
            envelope.removeFirst(excess)
            envelopeStart = envelopeStart?.addingTimeInterval(
                Double(excess * Self.frameSamples) / WhisperAudioFormat.sampleRate)
        }
    }

    // MARK: - Query

    public struct Verdict: Sendable, Equatable {
        public var isEcho: Bool
        public var correlation: Float
        /// Where the best match sat, in seconds. Useful in the log: a stable lag
        /// across a call is the machine's own output latency.
        public var lagSeconds: Double
    }

    /// Whether a microphone utterance is an echo of what the speakers were
    /// playing.
    ///
    /// `endedAt` is when the detector closed the utterance, so the audio it
    /// covers is the window ending there.
    public func verdict(forMicrophone samples: [Float], endedAt: Date = Date()) -> Verdict {
        let none = Verdict(isEcho: false, correlation: 0, lagSeconds: 0)
        guard samples.count >= Self.frameSamples * Self.minimumFrames else { return none }

        let probe = Self.envelope(of: samples)
        guard probe.count >= Self.minimumFrames else { return none }

        lock.lock()
        let reference = envelope
        let referenceStart = envelopeStart
        lock.unlock()

        guard let referenceStart, reference.count >= probe.count else { return none }

        // Where the utterance nominally sits inside the reference timeline.
        let duration = Double(samples.count) / WhisperAudioFormat.sampleRate
        let startedAt = endedAt.addingTimeInterval(-duration)
        let nominalFrame = Int(startedAt.timeIntervalSince(referenceStart)
            * WhisperAudioFormat.sampleRate / Double(Self.frameSamples))

        let lagFrames = Int(Self.maximumLagSeconds * WhisperAudioFormat.sampleRate)
            / Self.frameSamples
        let lowest = max(0, nominalFrame - lagFrames)
        let highest = min(reference.count - probe.count, nominalFrame + lagFrames)
        guard lowest <= highest else { return none }

        let normalizedProbe = Self.standardize(probe)
        guard !normalizedProbe.isEmpty else { return none }

        var best: Float = 0
        var bestOffset = lowest
        for offset in lowest...highest {
            let slice = Array(reference[offset ..< offset + probe.count])
            let normalizedSlice = Self.standardize(slice)
            // A silent stretch of reference has no envelope to match; treating
            // its zero variance as a match would flag every quiet moment.
            guard !normalizedSlice.isEmpty else { continue }
            var correlation: Float = 0
            vDSP_dotpr(normalizedProbe, 1, normalizedSlice, 1, &correlation,
                       vDSP_Length(probe.count))
            correlation /= Float(probe.count)
            if correlation > best {
                best = correlation
                bestOffset = offset
            }
        }

        let lagSeconds = Double((bestOffset - nominalFrame) * Self.frameSamples)
            / WhisperAudioFormat.sampleRate
        return Verdict(isEcho: best >= threshold, correlation: best, lagSeconds: lagSeconds)
    }

    /// Drops all history. Call between calls so one session cannot be judged
    /// against the previous one's audio.
    public func reset() {
        lock.lock()
        envelope.removeAll(keepingCapacity: true)
        partial.removeAll(keepingCapacity: true)
        envelopeStart = nil
        lock.unlock()
    }

    // MARK: - Signal

    static func envelope(of samples: [Float]) -> [Float] {
        var result: [Float] = []
        result.reserveCapacity(samples.count / frameSamples)
        var index = 0
        while index + frameSamples <= samples.count {
            result.append(rms(Array(samples[index ..< index + frameSamples])))
            index += frameSamples
        }
        return result
    }

    static func rms(_ frame: [Float]) -> Float {
        var value: Float = 0
        vDSP_rmsqv(frame, 1, &value, vDSP_Length(frame.count))
        return value
    }

    /// Zero mean, unit standard deviation. Returns empty when the signal is flat,
    /// which is how "there is nothing here to correlate against" is expressed.
    static func standardize(_ values: [Float]) -> [Float] {
        guard values.count > 1 else { return [] }
        var mean: Float = 0
        vDSP_meanv(values, 1, &mean, vDSP_Length(values.count))
        var centred = [Float](repeating: 0, count: values.count)
        var negativeMean = -mean
        vDSP_vsadd(values, 1, &negativeMean, &centred, 1, vDSP_Length(values.count))

        var sumOfSquares: Float = 0
        vDSP_svesq(centred, 1, &sumOfSquares, vDSP_Length(centred.count))
        let deviation = (sumOfSquares / Float(centred.count)).squareRoot()
        guard deviation > 1e-6 else { return [] }

        var scale = 1 / deviation
        var scaled = [Float](repeating: 0, count: centred.count)
        vDSP_vsmul(centred, 1, &scale, &scaled, 1, vDSP_Length(centred.count))
        return scaled
    }
}

/// A counter touched from capture callbacks on several queues.
///
/// `os_unfair_lock` would be lighter, but this is incremented a few times a
/// minute and correctness under strict concurrency is worth more than the
/// nanoseconds.
public final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    public init() {}

    public func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    public var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
