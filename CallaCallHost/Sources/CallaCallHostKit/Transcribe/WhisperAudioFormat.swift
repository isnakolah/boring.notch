import Foundation

/// What whisper.cpp expects, everywhere in this package: 16 kHz, mono, Float32.
///
/// Both capture legs converge on this before anything else touches them, so the
/// engine never has to ask where a buffer came from.
public enum WhisperAudioFormat {
    public static let sampleRate: Double = 16_000
    public static let channelCount: UInt32 = 1
}

/// Which side of the call a turn came from.
///
/// This is the whole reason the mic and system-audio legs are captured and kept
/// separate rather than mixed: the label falls out of the plumbing, so there is
/// no diarizer, no embedding clustering, and no Python runtime anywhere in this
/// app. "How should I answer that?" is only answerable because `them` is known.
public enum TurnSource: String, Codable, Sendable, CaseIterable {
    /// The microphone — the person we are helping.
    case me
    /// System audio — everyone else on the call.
    case them
}

/// One transcribed span, in seconds from the start of the call.
public struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var text: String
    /// Mean per-token probability, 0...1. Nil when the caller did not ask for it.
    public var confidence: Double?
    /// whisper's own estimate that this span contains no speech at all.
    public var noSpeech: Double?

    public init(
        id: UUID = UUID(),
        start: Double,
        end: Double,
        text: String,
        confidence: Double? = nil,
        noSpeech: Double? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
        self.noSpeech = noSpeech
    }
}

/// A transcribed utterance, tagged with the leg it arrived on.
public struct CallTurn: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Monotonic within a call. The gateway drops anything out of order, so this
    /// must never be reused or rewound.
    public var seq: Int
    public var source: TurnSource
    public var t0: Double
    public var t1: Double
    public var text: String
    /// How sure the model was, 0...1. Optional so a turn from an older archive —
    /// or from a pass that did not measure — is not silently reported as
    /// maximally untrustworthy.
    public var confidence: Double?

    public init(
        id: UUID = UUID(),
        seq: Int,
        source: TurnSource,
        t0: Double,
        t1: Double,
        text: String,
        confidence: Double? = nil
    ) {
        self.id = id
        self.seq = seq
        self.source = source
        self.t0 = t0
        self.t1 = t1
        self.text = text
        self.confidence = confidence
    }

    /// Below this the model was guessing.
    ///
    /// Read off the recorded corpus rather than picked: real speech sits well
    /// above it, and the turns underneath are overwhelmingly noise fragments and
    /// half-words. Used to keep a guess out of the ledger, never to drop it from
    /// the transcript — the transcript is the record, and a hedged line there is
    /// better than a missing one.
    public static let lowConfidence = 0.45

    public var isLowConfidence: Bool {
        guard let confidence else { return false }
        return confidence < Self.lowConfidence
    }
}
