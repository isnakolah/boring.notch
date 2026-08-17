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
        backlogLimit: Int = 3
    ) {
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
    public func enqueue(samples: [Float], source: TurnSource, startSeconds: Double) {
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
            await self?.process(samples: samples, source: source, startSeconds: startSeconds)
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

    private func process(samples: [Float], source: TurnSource, startSeconds: Double) async {
        defer { pendingWork -= 1 }
        guard !stopped else { return }

        // The neural gate runs before whisper, not after: the point is to spend
        // no inference at all on a keyboard burst or a fan.
        if let speechGate {
            let hasSpeech = await speechGate.containsSpeech(samples)
            guard !stopped else { return }
            guard hasSpeech else { return }
        }

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

            let segments = try await engine.transcribe(
                samples: padded, language: language, audioCtx: nil)
            guard !stopped else { return }

            for segment in segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                // Anything starting past the real audio is a hallucination on
                // the zero-padding we just added.
                guard segment.start < originalDuration else { continue }

                let turn = CallTurn(
                    seq: nextSeq,
                    source: source,
                    t0: startSeconds + segment.start,
                    t1: startSeconds + segment.end,
                    text: text)
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
