import Foundation

/// Energy-based endpointing: turns a continuous stream into utterances.
///
/// One instance per capture leg. Not thread-safe — feed each instance from a
/// single serial context (its leg's tap or sample queue).
///
/// The design point that matters: a single RMS cutoff does not survive
/// automatic gain control. Once AGC lifts a quiet talker, between-syllable dips
/// clear any fixed threshold and the detector never sees silence again. So
/// there are two cutoffs — an adaptive absolute one and an envelope-relative
/// one — and a frame must clear both to count as speech.
public final class UtteranceDetector {
    /// How long a pause has to be before the utterance is considered finished.
    ///
    /// Raised from 500ms. At half a second an ordinary mid-sentence pause — the
    /// gap before a name, the beat after "so" — closes the utterance, and whisper
    /// is then asked to decode a two-word fragment with no context. Measured
    /// across 54 recorded calls: 19% of all turns were three words or fewer and
    /// 6% were a single word, and one sentence routinely arrived as five turns
    /// ("So, actually, if solving." / "problems that I have a better
    /// understanding." / "It's something that's..." / "really, uh..." / "really
    /// resonated with me.").
    ///
    /// The cost is latency: an answer waits an extra 200ms after the other party
    /// stops. That is worth it — the question is usually one clause, and the
    /// alternative is answering half of it.
    ///
    /// Emitted with the utterance samples and its start time in seconds from
    /// the beginning of the stream.
    public var onUtterance: ((_ samples: [Float], _ startSeconds: Double) -> Void)?

    private let sampleRate: Double
    private let frameSize: Int
    private let rmsThreshold: Float
    private let silenceFrameThreshold: Int
    private let minUtteranceFrames: Int
    private let maxUtteranceFrames: Int
    private let preRollFrames: Int
    private let noiseFloorAlpha: Float
    private let noiseFloorMultiplier: Float
    private let speechOnsetFrames: Int
    private let stayCutoffRatio: Float
    private let envelopeSilenceRatio: Float
    private let envelopeDecay: Float
    private let envelopeFloor: Float

    private enum State { case silence, speech }
    private var state: State = .silence

    private var preRoll: [[Float]]
    private var preRollHead = 0
    private var current: [Float] = []
    private var partial: [Float] = []
    private var silentTailFrames = 0
    private var speechFramesInCurrent = 0
    private var pendingSpeechFrames = 0
    private var pendingSpeechBuffer: [[Float]] = []
    private var samplesIngested = 0
    private var currentStartSample = 0
    private var clockOffset: Double = 0
    private var noiseFloor: Float = 0.001
    private var signalEnvelope: Float = 0

    public init(
        sampleRate: Double = WhisperAudioFormat.sampleRate,
        frameMs: Double = 30,
        rmsThreshold: Float = 0.012,
        silenceMs: Double = 700,
        minUtteranceMs: Double = 200,
        maxUtteranceMs: Double = 10_000,
        preRollMs: Double = 200,
        noiseFloorAlpha: Float = 0.02,
        noiseFloorMultiplier: Float = 3.0,
        speechOnsetMs: Double = 90,
        stayCutoffRatio: Float = 0.5,
        envelopeSilenceRatio: Float = 0.40,
        envelopeDecay: Float = 0.985,
        envelopeFloor: Float = 0.005
    ) {
        self.sampleRate = sampleRate
        frameSize = max(1, Int((sampleRate * frameMs / 1000).rounded()))
        self.rmsThreshold = rmsThreshold
        silenceFrameThreshold = max(1, Int((silenceMs / frameMs).rounded()))
        minUtteranceFrames = max(1, Int((minUtteranceMs / frameMs).rounded()))
        maxUtteranceFrames = max(1, Int((maxUtteranceMs / frameMs).rounded()))
        preRollFrames = max(0, Int((preRollMs / frameMs).rounded()))
        self.noiseFloorAlpha = noiseFloorAlpha
        self.noiseFloorMultiplier = noiseFloorMultiplier
        speechOnsetFrames = max(1, Int((speechOnsetMs / frameMs).rounded()))
        self.stayCutoffRatio = min(1, max(0, stayCutoffRatio))
        self.envelopeSilenceRatio = min(1, max(0, envelopeSilenceRatio))
        self.envelopeDecay = min(1, max(0, envelopeDecay))
        self.envelopeFloor = max(0, envelopeFloor)
        preRoll = Array(repeating: [Float](), count: preRollFrames)
    }

    public func ingest(_ samples: ArraySlice<Float>) {
        partial.append(contentsOf: samples)
        while partial.count >= frameSize {
            let frame = Array(partial.prefix(frameSize))
            partial.removeFirst(frameSize)
            samplesIngested += frameSize
            handle(frame: frame)
        }
    }

    /// Discards any in-flight utterance and wipes state.
    public func reset() { clearAllState() }

    /// Emits any in-flight utterance, then wipes state.
    ///
    /// Same wipe as `reset()`; the difference is emit-vs-discard. Call at end of
    /// call so a trailing sentence is not lost.
    public func flush() {
        if state == .speech, speechFramesInCurrent >= minUtteranceFrames { emit() }
        clearAllState()
    }

    private func clearAllState() {
        state = .silence
        preRoll = Array(repeating: [Float](), count: preRollFrames)
        preRollHead = 0
        current.removeAll(keepingCapacity: true)
        partial.removeAll(keepingCapacity: true)
        silentTailFrames = 0
        speechFramesInCurrent = 0
        pendingSpeechFrames = 0
        pendingSpeechBuffer.removeAll(keepingCapacity: true)
        samplesIngested = 0
        currentStartSample = 0
        clockOffset = 0
        noiseFloor = 0.001
        signalEnvelope = 0
    }

    // MARK: - Cutoffs

    /// The static threshold raised by measured room noise, capped at 2.5x so a
    /// loud room cannot lift the bar past real speech.
    private func absoluteCutoff() -> Float {
        max(rmsThreshold, min(rmsThreshold * 2.5, noiseFloor * noiseFloorMultiplier))
    }

    /// A fraction of the recent speech peak. Zero while the envelope is below
    /// its floor — at the start of a call, or after a long quiet, the absolute
    /// cutoff alone governs.
    private func relativeCutoff() -> Float {
        guard signalEnvelope > envelopeFloor else { return 0 }
        return signalEnvelope * envelopeSilenceRatio
    }

    /// Entering speech is absolute-only. Using the relative cutoff here would
    /// chase its own tail: envelope near zero gives a cutoff near zero, so any
    /// tiny noise qualifies, which lifts the envelope, and so on.
    private func enterCutoff() -> Float { absoluteCutoff() }

    /// Staying in speech takes the higher of the two — a frame must overcome
    /// both kinds of "this is silent" test.
    ///
    /// The absolute part is scaled down for mid-word hysteresis. The relative
    /// part is deliberately *not* scaled: `envelopeSilenceRatio` already sits
    /// between a between-syllable dip and true inter-phrase silence, and halving
    /// it again slides the cutoff into dip territory, where silence never
    /// registers at all.
    private func stayCutoff() -> Float {
        max(absoluteCutoff() * stayCutoffRatio, relativeCutoff())
    }

    // MARK: - State machine

    private func handle(frame: [Float]) {
        let energy = rms(frame)

        // Peak-with-decay, updated on every frame regardless of state, so the
        // envelope is ready the instant speech starts and can decay during a
        // long silence to release the relative cutoff.
        signalEnvelope = max(energy, signalEnvelope * envelopeDecay)

        let isSpeech: Bool
        switch state {
        case .silence: isSpeech = energy >= enterCutoff()
        case .speech: isSpeech = energy >= stayCutoff()
        }

        switch state {
        case .silence:
            if isSpeech {
                pendingSpeechFrames += 1
                pendingSpeechBuffer.append(frame)
                guard pendingSpeechFrames >= speechOnsetFrames else { return }
                // Confirmed onset. Pre-roll plus the buffered pending frames
                // become the head of the utterance, so the first phoneme is not
                // clipped off.
                let preRollSamples = orderedPreRoll().flatMap { $0 }
                let pendingSamples = pendingSpeechBuffer.flatMap { $0 }
                currentStartSample = samplesIngested - pendingSamples.count - preRollSamples.count
                current.removeAll(keepingCapacity: true)
                current.reserveCapacity(preRollSamples.count + pendingSamples.count)
                current.append(contentsOf: preRollSamples)
                current.append(contentsOf: pendingSamples)
                silentTailFrames = 0
                speechFramesInCurrent = pendingSpeechFrames
                pendingSpeechFrames = 0
                pendingSpeechBuffer.removeAll(keepingCapacity: true)
                state = .speech
            } else {
                if pendingSpeechFrames > 0 {
                    // A sub-onset spike. Recycle the pending frames into
                    // pre-roll rather than dropping them: speech may start a
                    // moment later and want them.
                    for pending in pendingSpeechBuffer where preRollFrames > 0 {
                        preRoll[preRollHead] = pending
                        preRollHead = (preRollHead + 1) % preRollFrames
                    }
                    pendingSpeechFrames = 0
                    pendingSpeechBuffer.removeAll(keepingCapacity: true)
                }
                // Track the noise floor only on deep-silence frames. Updating on
                // every below-cutoff frame lets a quiet talker's between-word
                // audio pull the floor up, which raises the cutoff, which misses
                // more speech, which raises the floor further.
                if energy < rmsThreshold * 0.5 {
                    noiseFloor = noiseFloor * (1 - noiseFloorAlpha) + energy * noiseFloorAlpha
                }
                if preRollFrames > 0 {
                    preRoll[preRollHead] = frame
                    preRollHead = (preRollHead + 1) % preRollFrames
                }
            }

        case .speech:
            current.append(contentsOf: frame)
            if isSpeech {
                silentTailFrames = 0
                speechFramesInCurrent += 1
            } else {
                silentTailFrames += 1
            }
            let endedBySilence = silentTailFrames >= silenceFrameThreshold
            let endedByCap = current.count >= maxUtteranceFrames * frameSize
            guard endedBySilence || endedByCap else { return }
            if speechFramesInCurrent >= minUtteranceFrames { emit() }
            state = .silence
            current.removeAll(keepingCapacity: true)
            silentTailFrames = 0
            speechFramesInCurrent = 0
            preRoll = Array(repeating: [Float](), count: preRollFrames)
            preRollHead = 0
        }
    }

    private func emit() {
        let startSeconds = max(0, clockOffset + Double(currentStartSample) / sampleRate)
        onUtterance?(current, startSeconds)
    }

    private func orderedPreRoll() -> [[Float]] {
        guard preRollFrames > 0 else { return [] }
        var result: [[Float]] = []
        result.reserveCapacity(preRollFrames)
        for offset in 0..<preRollFrames {
            let index = (preRollHead + offset) % preRollFrames
            if !preRoll[index].isEmpty { result.append(preRoll[index]) }
        }
        return result
    }

    private func rms(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in frame { sum += sample * sample }
        return (sum / Float(frame.count)).squareRoot()
    }
}
