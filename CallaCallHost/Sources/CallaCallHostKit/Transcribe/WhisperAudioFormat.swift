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

    public init(id: UUID = UUID(), start: Double, end: Double, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
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

    public init(id: UUID = UUID(), seq: Int, source: TurnSource, t0: Double, t1: Double, text: String) {
        self.id = id
        self.seq = seq
        self.source = source
        self.t0 = t0
        self.t1 = t1
        self.text = text
    }
}
