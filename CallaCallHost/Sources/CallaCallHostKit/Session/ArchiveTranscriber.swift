import Foundation
import IntelligenceStore
import os.log

private let archiveLog = Logger(subsystem: "theboringteam.boringnotch.callhost", category: "retranscribe")

/// Re-runs a finished call through the large model.
///
/// The live leg trades accuracy for latency: a small model, Metal-only, with a
/// truncated encoder context, because a pointer that arrives after the moment
/// has passed is worthless. Once the call is over that tradeoff inverts —
/// nothing is waiting on the result, so the archive gets `large-v3-turbo` with
/// its CoreML encoder, where the fixed 30s encode cost is amortized across the
/// whole recording instead of paid per utterance.
///
/// Writes `transcript-archive.jsonl` beside the live transcript rather than
/// replacing it, so the two can be compared and the live one is never lost to a
/// failed re-run.
public enum ArchiveTranscriber {
    public struct Result: Sendable {
        public var turns: Int
        public var duration: TimeInterval
    }

    public static func retranscribe(
        callDirectory: URL,
        modelURL: URL,
        modelName: String,
        language: String = "en",
        store: CallaStore? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        let started = Date()
        let engine = WhisperEngine()
        try await engine.loadIfNeeded(modelURL: modelURL, displayName: modelName)
        defer { Task { await engine.shutdown() } }

        var turns: [CallTurn] = []
        for source in TurnSource.allCases {
            let wav = callDirectory.appendingPathComponent(source == .me ? "mic.wav" : "system.wav")
            guard FileManager.default.fileExists(atPath: wav.path) else { continue }

            progress?("transcribing \(source.rawValue)…")
            let samples = try AudioConvert.loadAsWhisperSamples(url: wav)
            guard !samples.isEmpty, !AudioSignal.isSilent(samples) else { continue }

            // audioCtx 0: the whole recording, no truncation. The live path's
            // 750 only holds for clips under 15s.
            //
            // VAD on, unlike the live path: this buffer is a whole call leg and
            // is mostly silence, which whisper fills with invented sentences.
            let segments = try await engine.transcribe(
                samples: samples,
                language: language,
                audioCtx: 0,
                vadModelPath: SpeechGateFactory.bundledModelPath())
            for segment in segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                turns.append(CallTurn(seq: 0, source: source, t0: segment.start, t1: segment.end, text: text))
            }
        }

        // Both legs were transcribed independently against the same call clock,
        // so interleaving by start time reconstructs the conversation.
        turns.sort { $0.t0 < $1.t0 }
        let ordered = turns.enumerated().map { index, turn in
            CallTurn(id: turn.id, seq: index, source: turn.source, t0: turn.t0, t1: turn.t1, text: turn.text)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = try ordered.map { turn -> String in
            let data = try encoder.encode(turn)
            return String(data: data, encoding: .utf8) ?? ""
        }
        let output = callDirectory.appendingPathComponent("transcript-archive.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)

        // Into the store as its own revision, beside the live pass rather than
        // over it. Without this the better transcript existed only as a file
        // nothing read: History, the recap and any note filed from it all went on
        // using the live text.
        if let store {
            try? await store.replace(
                turns: ordered.map {
                    StoredTurn(seq: $0.seq, source: $0.source.rawValue,
                               t0: $0.t0, t1: $0.t1, text: $0.text,
                               revision: StoredTurn.archiveRevision)
                },
                callID: callDirectory.lastPathComponent,
                revision: StoredTurn.archiveRevision)
        }

        let elapsed = Date().timeIntervalSince(started)
        archiveLog.notice("re-transcribed \(callDirectory.lastPathComponent, privacy: .public): \(ordered.count, privacy: .public) turns in \(elapsed, privacy: .public)s")
        return Result(turns: ordered.count, duration: elapsed)
    }
}
