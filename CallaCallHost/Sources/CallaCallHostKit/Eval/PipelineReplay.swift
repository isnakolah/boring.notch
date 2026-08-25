import Foundation

/// Runs a recorded call back through the *live* pipeline.
///
/// The archive pass answers "how good could this audio be" with a large model
/// over the whole file. This answers the different and more useful question:
/// "what would the live path produce from this audio *today*" — same energy
/// endpointing, same neural gate, same echo test, same small model, same
/// conditioning.
///
/// That is what makes a change to any of those measurable. Before this, a
/// tweak to the VAD thresholds or the decoder prompt could only be judged by
/// making another call and forming an impression.
///
/// Both legs are fed in interleaved blocks against one synthetic clock, because
/// the echo test correlates the microphone against what the speakers were
/// playing *at the same moment* — feeding one leg and then the other would put
/// them hours apart and suppress nothing.
public enum PipelineReplay {
    public struct Result: Sendable {
        public var turns: [CallTurn]
        public var echoDropped: Int
        public var duration: TimeInterval
        /// Every microphone utterance's best correlation against the system leg.
        ///
        /// Reported rather than discarded because the threshold is the one number
        /// in this design that cannot be derived — it has to be read off the gap
        /// between the echo population and the genuine-speech population, and
        /// that gap is only visible from real calls.
        public var correlations: [Float] = []
    }

    /// ~256 ms at 16 kHz, close to what the microphone tap actually delivers.
    static let blockSamples = 4096

    public static func replay(
        callDirectory: URL,
        modelURL: URL,
        modelName: String,
        language: String = "en",
        vocabulary: [String] = [],
        speechGate: SileroVAD?,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        let started = Date()
        let micSamples = try loadLeg(callDirectory.appendingPathComponent("mic.wav"))
        let systemSamples = try loadLeg(callDirectory.appendingPathComponent("system.wav"))
        guard !micSamples.isEmpty || !systemSamples.isEmpty else {
            return Result(turns: [], echoDropped: 0, duration: 0)
        }

        let transcriber = CallTranscriber(
            speechGate: speechGate,
            modelURL: modelURL,
            modelName: modelName,
            language: language,
            // No backlog dropping in a replay: it exists to protect a live call's
            // latency, and here nothing is waiting. Dropping turns would make the
            // measured transcript worse than the pipeline actually is.
            backlogLimit: .max,
            vocabulary: vocabulary)
        try await transcriber.prepare()

        let collected = TurnCollector()
        await transcriber.setTurnHandler { turn in collected.append(turn) }

        let echo = EchoReference()
        // The synthetic epoch. Any fixed instant works; the legs only have to
        // agree with each other.
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)

        let micLeg = CaptureLeg(source: .me)
        let systemLeg = CaptureLeg(source: .them)
        let echoDropped = Counter()

        systemLeg.onUtterance = { samples, start, source in
            enqueue(transcriber, samples, source, start, epoch)
        }
        let correlations = CorrelationLog()
        micLeg.onUtterance = { samples, start, source in
            let duration = Double(samples.count) / WhisperAudioFormat.sampleRate
            let endedAt = epoch.addingTimeInterval(start + duration)
            let verdict = echo.verdict(forMicrophone: samples, endedAt: endedAt)
            correlations.append(verdict.correlation)
            if verdict.isEcho {
                echoDropped.increment()
                return
            }
            enqueue(transcriber, samples, source, start, epoch)
        }

        // Interleaved, so the echo reference holds the right moment when the
        // microphone leg asks about it.
        let blocks = (max(micSamples.count, systemSamples.count) + blockSamples - 1) / blockSamples
        var reported = 0
        for index in 0..<blocks {
            let lower = index * blockSamples
            let blockTime = epoch.addingTimeInterval(
                Double(lower) / WhisperAudioFormat.sampleRate)

            if lower < systemSamples.count {
                let block = Array(systemSamples[lower ..< min(lower + blockSamples, systemSamples.count)])
                echo.append(systemSamples: block, at: blockTime)
                systemLeg.ingest(block)
            }
            if lower < micSamples.count {
                micLeg.ingest(Array(micSamples[lower ..< min(lower + blockSamples, micSamples.count)]))
            }

            // Both legs settle before the next block is written.
            //
            // Without this the loop pushes the whole call into two async queues
            // in milliseconds: the echo reference — which is written
            // synchronously — races to the end of the call while the detectors
            // are still near the beginning, so every microphone utterance is
            // compared against a reference window that scrolled past minutes ago.
            // It looked exactly like a detector that never fires.
            systemLeg.waitForPendingWork()
            micLeg.waitForPendingWork()

            let percent = index * 100 / max(1, blocks)
            if percent >= reported + 20 {
                reported = percent - percent % 20
                progress?("  \(reported)%")
            }
        }

        systemLeg.flush()
        micLeg.flush()
        await transcriber.drain()
        await transcriber.stop()

        let turns = collected.drain().sorted { $0.t0 < $1.t0 }
        let ordered = turns.enumerated().map { index, turn in
            CallTurn(id: turn.id, seq: index, source: turn.source,
                     t0: turn.t0, t1: turn.t1, text: turn.text)
        }
        return Result(
            turns: ordered,
            echoDropped: echoDropped.value,
            duration: Date().timeIntervalSince(started),
            correlations: correlations.drain())
    }

    /// `CaptureLeg` hands utterances out on its own serial queue, so the hop into
    /// the transcriber actor is the same one the live session makes.
    private static func enqueue(
        _ transcriber: CallTranscriber,
        _ samples: [Float],
        _ source: TurnSource,
        _ start: Double,
        _ epoch: Date
    ) {
        let duration = Double(samples.count) / WhisperAudioFormat.sampleRate
        let endpointedAt = epoch.addingTimeInterval(start + duration)
        Task {
            await transcriber.enqueue(
                samples: samples, source: source,
                startSeconds: start, endpointedAt: endpointedAt)
        }
    }

    private static func loadLeg(_ url: URL) throws -> [Float] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try AudioConvert.loadAsWhisperSamples(url: url)
    }
}

/// Collects turns arriving from the transcriber's callback.
private final class TurnCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [CallTurn] = []

    func append(_ turn: CallTurn) {
        lock.lock()
        turns.append(turn)
        lock.unlock()
    }

    func drain() -> [CallTurn] {
        lock.lock()
        defer { lock.unlock() }
        return turns
    }
}

private final class CorrelationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Float] = []

    func append(_ value: Float) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
