import Foundation

/// One side of the call: raw samples in, endpointed utterances out.
///
/// `UtteranceDetector` is explicitly not thread-safe and must be fed from a
/// single serial context. Capture callbacks arrive on the recorder's own queue
/// while `flush()` is called from the session actor at end of call, so this type
/// funnels *every* touch of the detector through one private serial queue. That
/// is the invariant; holding the detector directly on the actor would look
/// tidier and would race.
public final class CaptureLeg: @unchecked Sendable {
    public let source: TurnSource

    /// Called on the leg's queue for each endpointed utterance.
    public var onUtterance: ((_ samples: [Float], _ startSeconds: Double, _ source: TurnSource) -> Void)?
    /// Called on the leg's queue with every converted sample block, before
    /// endpointing — this is what the archive records.
    public var onSamples: ((_ samples: [Float], _ source: TurnSource) -> Void)?

    private let detector: UtteranceDetector
    private let queue: DispatchQueue

    public init(source: TurnSource, detector: UtteranceDetector = UtteranceDetector()) {
        self.source = source
        self.detector = detector
        queue = DispatchQueue(label: "callhost.leg.\(source.rawValue)", qos: .userInitiated)

        detector.onUtterance = { [weak self] samples, start in
            guard let self else { return }
            self.onUtterance?(samples, start, self.source)
        }
    }

    /// Accepts converted 16 kHz mono samples from this leg's recorder.
    public func ingest(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.onSamples?(samples, self.source)
            self.detector.ingest(samples[...])
        }
    }

    /// Emits any in-flight utterance. Synchronous so a caller can be sure the
    /// trailing turn has been handed on before the engine is torn down.
    public func flush() {
        queue.sync { detector.flush() }
    }

    public func reset() {
        queue.sync { detector.reset() }
    }
}
