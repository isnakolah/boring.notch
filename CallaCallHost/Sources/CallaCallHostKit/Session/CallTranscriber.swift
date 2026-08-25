import Foundation
import os.log

private let transcriberLog = Logger(subsystem: "theboringteam.boringnotch.callhost", category: "transcriber")

/// Turns two live audio legs into an ordered, source-tagged transcript.
///
/// One whisper engine, one serialized queue. Utterances from both legs chain
/// onto it so publish order is stable — a transcript whose turns interleave
/// unpredictably is worse than a slightly late one.
public actor CallTranscriber {
    /// Emitted for every accepted turn, in `seq` order.
    public var onTurn: ((CallTurn) -> Void)?

    private let engine: WhisperEngine
    private let speechGate: SileroVAD?
    private let modelURL: URL
    private let modelName: String
    private let language: String

    /// Queue depth past which `me` utterances are dropped.
    ///
    /// Under crosstalk one engine cannot keep up with two legs. What the other
    /// party said is what a suggestion is built from, so `them` wins and our own
    /// speech is what gets sacrificed.
    private let backlogLimit: Int

    /// Names and per-leg recent text, biasing each decode.
    private var context: DecodingContext

    private var nextSeq = 0
    private var pendingWork = 0
    private var chain: Task<Void, Never>?
    private var loaded = false
    private var stopped = false

    public private(set) var droppedSelfTurns = 0

    public init(
        engine: WhisperEngine = WhisperEngine(),
        speechGate: SileroVAD?,
        modelURL: URL,
        modelName: String,
        language: String = "en",
        backlogLimit: Int = 3,
        vocabulary: [String] = []
    ) {
        context = DecodingContext(vocabulary: vocabulary)
        self.engine = engine
        self.speechGate = speechGate
        self.modelURL = modelURL
        self.modelName = modelName
        self.language = language
        self.backlogLimit = backlogLimit
    }

    public func setTurnHandler(_ handler: @escaping (CallTurn) -> Void) {
        onTurn = handler
    }

    public func prepare() async throws {
        guard !loaded else { return }
        try await engine.loadIfNeeded(modelURL: modelURL, displayName: modelName)
        loaded = true
    }

    /// Queues one VAD-bounded utterance for transcription.
    ///
    /// Returns immediately; the turn arrives on `onTurn` once whisper reaches it.
    public func enqueue(
        samples: [Float],
        source: TurnSource,
        startSeconds: Double,
        endpointedAt: Date = Date()
    ) {
        guard !stopped else { return }
        guard !samples.isEmpty, !AudioSignal.isSilent(samples) else { return }

        if source == .me, pendingWork >= backlogLimit {
            droppedSelfTurns += 1
            transcriberLog.notice("dropping own utterance under backlog (\(self.pendingWork, privacy: .public) queued)")
            return
        }

        pendingWork += 1
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            await self?.process(
                samples: samples,
                source: source,
                startSeconds: startSeconds,
                endpointedAt: endpointedAt)
        }
    }

    /// Waits for queued work to drain.
    public func drain() async {
        await chain?.value
    }

    public func stop() async {
        stopped = true
        await chain?.value
        await engine.shutdown()
        await speechGate?.shutdown()
    }

    // MARK: - Internal

    /// Joins segments that belong to one utterance.
    ///
    /// A boundary is kept only where the text actually finished — terminal
    /// punctuation, or a real gap. Everything else is stitched back together,
    /// with the confidences averaged by duration so a long confident span is not
    /// dragged down by a short shaky one.
    static func merge(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard segments.count > 1 else { return segments }
        var merged: [TranscriptSegment] = []
        for segment in segments {
            guard var previous = merged.last else {
                merged.append(segment)
                continue
            }
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            let previousText = previous.text.trimmingCharacters(in: .whitespaces)
            let ended = previousText.last.map { ".!?…".contains($0) } ?? false
            let gap = segment.start - previous.end
            guard !ended, gap < mergeGapSeconds, !previousText.isEmpty, !text.isEmpty else {
                merged.append(segment)
                continue
            }

            let previousSpan = max(0.01, previous.end - previous.start)
            let span = max(0.01, segment.end - segment.start)
            previous.text = previousText + " " + text
            previous.end = segment.end
            previous.confidence = weighted(
                previous.confidence, previousSpan, segment.confidence, span)
            // The stricter of the two: if any part of a merged turn looked like
            // silence, the whole thing is suspect.
            previous.noSpeech = [previous.noSpeech, segment.noSpeech].compactMap { $0 }.max()
            merged[merged.count - 1] = previous
        }
        return merged
    }

    /// Segments closer than this are one utterance. whisper's own splits are
    /// typically contiguous, so this only has to be larger than zero to catch
    /// them, and small enough not to swallow a real pause.
    static let mergeGapSeconds: Double = 0.4

    private static func weighted(
        _ lhs: Double?, _ lhsSpan: Double, _ rhs: Double?, _ rhsSpan: Double
    ) -> Double? {
        switch (lhs, rhs) {
        case let (left?, right?): return (left * lhsSpan + right * rhsSpan) / (lhsSpan + rhsSpan)
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    /// Whether a segment is too uncertain to condition the next decode on, or to
    /// let into the ledger as established fact.
    private func turnIsAGuess(_ segment: TranscriptSegment) -> Bool {
        if let noSpeech = segment.noSpeech, noSpeech > 0.6 { return true }
        guard let confidence = segment.confidence else { return false }
        return confidence < CallTurn.lowConfidence
    }

    private func process(
        samples: [Float],
        source: TurnSource,
        startSeconds: Double,
        endpointedAt: Date
    ) async {
        defer { pendingWork -= 1 }
        guard !stopped else { return }

        // Wall clock, not the stream clock in `CallTurn.t0`/`t1`. Those are
        // offsets from the start of capture and cannot be differenced against
        // `Date()`, which is why nothing on this path was measurable before.
        let dequeuedAt = Date()
        let queuedMs = dequeuedAt.timeIntervalSince(endpointedAt) * 1000

        // The neural gate runs before whisper, not after: the point is to spend
        // no inference at all on a keyboard burst or a fan.
        if let speechGate {
            let hasSpeech = await speechGate.containsSpeech(samples)
            guard !stopped else { return }
            guard hasSpeech else { return }
        }
        let gatedAt = Date()

        do {
            if !loaded {
                try await engine.loadIfNeeded(modelURL: modelURL, displayName: modelName)
                loaded = true
            }

            // whisper.cpp's beam search with patience = -1 infinite-loops on
            // inputs much shorter than its receptive field. Padding to 5s lets
            // it converge; the tail is trimmed back off below.
            let originalDuration = Double(samples.count) / WhisperAudioFormat.sampleRate
            let minimum = Int(WhisperAudioFormat.sampleRate * 5)
            let padded = samples.count < minimum
                ? samples + [Float](repeating: 0, count: minimum - samples.count)
                : samples

            let decoded = try await engine.transcribe(
                samples: padded,
                language: language,
                audioCtx: nil,
                initialPrompt: context.prompt(for: source))
            // whisper splits a single utterance into several segments at its own
            // internal boundaries, which are not sentence boundaries. Publishing
            // each as a turn fragments one clause across several rows of the
            // panel and several inputs to the segmenter.
            let segments = Self.merge(decoded)
            guard !stopped else { return }

            let transcribedAt = Date()
            let gateMs = gatedAt.timeIntervalSince(dequeuedAt) * 1000
            let whisperMs = transcribedAt.timeIntervalSince(gatedAt) * 1000
            let totalMs = transcribedAt.timeIntervalSince(endpointedAt) * 1000
            // One line per utterance covering the whole on-device leg. `rt` is
            // the multiple of real time: below 1 the machine is keeping up with
            // the conversation, above it the backlog only grows.
            transcriberLog.notice(
                """
                timing \(source.rawValue, privacy: .public): \
                queued \(queuedMs, format: .fixed(precision: 0), privacy: .public)ms, \
                gate \(gateMs, format: .fixed(precision: 0), privacy: .public)ms, \
                whisper \(whisperMs, format: .fixed(precision: 0), privacy: .public)ms, \
                total \(totalMs, format: .fixed(precision: 0), privacy: .public)ms, \
                audio \(originalDuration, format: .fixed(precision: 2), privacy: .public)s, \
                rt \(totalMs / max(1, originalDuration * 1000), format: .fixed(precision: 2), privacy: .public)
                """)

            for segment in segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                // `suppress_nst` stops most of these at the decoder; a bracketed
                // line that still gets through is an annotation about the audio,
                // not a thing anyone said, and it must not become a turn.
                guard !CallEvaluator.isArtifact(text) else {
                    transcriberLog.debug("dropped a non-speech annotation: \(text, privacy: .public)")
                    continue
                }
                // Anything starting past the real audio is a hallucination on
                // the zero-padding we just added.
                guard segment.start < originalDuration else { continue }

                // Conditioning the next fragment on a guess is how one bad
                // decode becomes several, so only text the model was reasonably
                // sure of is carried forward. The turn itself is still published
                // — the transcript is the record, and a hedged line in it beats a
                // hole.
                if !turnIsAGuess(segment) { context.record(text, for: source) }

                let turn = CallTurn(
                    seq: nextSeq,
                    source: source,
                    t0: startSeconds + segment.start,
                    t1: startSeconds + segment.end,
                    text: text,
                    confidence: segment.confidence)
                nextSeq += 1
                onTurn?(turn)
            }
        } catch is CancellationError {
            return
        } catch {
            transcriberLog.error("transcribe failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
