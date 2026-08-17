import Foundation
import whisper

/// Neural speech gate in front of whisper.
///
/// The energy detector tells loud from quiet, not voice from noise. A fan
/// spinning up, a keyboard burst or a door closing all clear the RMS cutoff,
/// and whisper answers a noise clip by hallucinating filler — which would then
/// be sent to the gateway as a call turn. This gate is what stops that.
///
/// Runs on CPU deliberately: the model is under a megabyte and must not contend
/// with the transcription engine for GPU or ANE.
public actor SileroVAD {
    public enum Failure: Swift.Error, LocalizedError {
        case modelLoadFailed(String)

        public var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let path): return "Failed to load Silero VAD model at \(path)"
            }
        }
    }

    private var vctx: OpaquePointer?

    public init(modelPath: String) throws {
        var params = whisper_vad_default_context_params()
        params.use_gpu = false
        params.n_threads = 2
        guard let ctx = modelPath.withCString({ whisper_vad_init_from_file_with_params($0, params) }) else {
            throw Failure.modelLoadFailed(modelPath)
        }
        vctx = ctx
    }

    /// True when the clip contains speech.
    ///
    /// **Fails open.** Any error returns `true`, so a malfunctioning gate can
    /// never silently eat real speech — the worst case is that a noise clip
    /// reaches whisper, which is exactly the behaviour without the gate at all.
    public func containsSpeech(
        _ samples: [Float],
        threshold: Float = 0.5,
        minSpeechMs: Int32 = 250,
        minSilenceMs: Int32 = 100
    ) -> Bool {
        guard let vctx else { return true }
        guard !samples.isEmpty else { return false }

        var params = whisper_vad_default_params()
        params.threshold = threshold
        params.min_speech_duration_ms = minSpeechMs
        params.min_silence_duration_ms = minSilenceMs

        let segments = samples.withUnsafeBufferPointer {
            whisper_vad_segments_from_samples(vctx, params, $0.baseAddress, Int32($0.count))
        }
        guard let segments else { return true }
        defer { whisper_vad_free_segments(segments) }
        return whisper_vad_segments_n_segments(segments) > 0
    }

    public func shutdown() {
        guard let vctx else { return }
        whisper_vad_free(vctx)
        self.vctx = nil
    }
}
