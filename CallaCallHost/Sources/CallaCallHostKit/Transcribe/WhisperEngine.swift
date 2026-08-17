import Foundation
import os.log
import whisper

private let whisperLog = Logger(subsystem: "theboringteam.boringnotch.callhost", category: "whisper")

/// Whether whisper's encoder ended up on CoreML/ANE after the last load.
///
/// whisper.cpp auto-loads a sibling `<model>-encoder.mlmodelc` next to the
/// `.bin`. This is derived from whisper.cpp's own init log rather than guessed
/// from file presence, because a sibling that exists but fails to init is a
/// materially different situation from one that was never there.
public enum CoreMLStatus: Sendable, Equatable, CustomStringConvertible {
    case unavailable
    case loaded(path: String)
    case failed(reason: String)

    public var description: String {
        switch self {
        case .unavailable: return "unavailable"
        case .loaded(let path): return "loaded(\(path))"
        case .failed(let reason): return "failed(\(reason))"
        }
    }
}

/// whisper.cpp's `whisper_log_set` is a process-global single-slot callback, so
/// capture lives at file scope. Lines are only retained while a load is in
/// flight; steady-state allocation is one empty array.
private final class WhisperLogCapture: @unchecked Sendable {
    static let shared = WhisperLogCapture()
    private let lock = NSLock()
    private var capturing = false
    private var lines: [String] = []

    func install() {
        whisper_log_set({ _, text, _ in
            guard let text else { return }
            WhisperLogCapture.shared.append(String(cString: text))
        }, nil)
    }

    private func append(_ line: String) {
        lock.lock()
        if capturing { lines.append(line) }
        lock.unlock()
    }

    func startCapture() {
        lock.lock()
        lines.removeAll(keepingCapacity: true)
        capturing = true
        lock.unlock()
    }

    func stopCapture() -> [String] {
        lock.lock()
        let snapshot = lines
        capturing = false
        lines.removeAll(keepingCapacity: false)
        lock.unlock()
        return snapshot
    }
}

private let installLogCaptureOnce: Void = {
    WhisperLogCapture.shared.install()
}()

/// Swift wrapper around the whisper.cpp C API.
///
/// An actor, so the whole package gets one serialized inference queue for free.
/// Both capture legs feed this; ordering is what keeps a transcript readable.
public actor WhisperEngine {
    public enum Failure: Swift.Error, LocalizedError {
        case modelLoadFailed(String)
        case transcribeFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let path): return "Failed to load whisper model at \(path)"
            case .transcribeFailed(let code): return "whisper_full failed (code \(code))"
            }
        }
    }

    private var ctx: OpaquePointer?
    private var loadedPath: String?
    public private(set) var modelName: String?
    public private(set) var coreMLStatus: CoreMLStatus = .unavailable

    public init() {}

    // No deinit: an actor's deinit is nonisolated and cannot touch `ctx` under
    // strict concurrency. That suits this type anyway — `shutdown()` has to be
    // called explicitly at terminate time so ggml-metal tears down while the
    // process is still healthy, rather than during static destruction.

    public func loadIfNeeded(modelURL: URL, displayName: String) throws {
        _ = installLogCaptureOnce

        if loadedPath == modelURL.path {
            // Reload only when a sibling .mlmodelc appeared after we loaded
            // without it — otherwise the first load would pin us to Metal for
            // the rest of the process even once the encoder lands.
            let siblingPath = Self.coreMLSiblingPath(for: modelURL)
            let siblingExists = FileManager.default.fileExists(atPath: siblingPath)
            let alreadyOnCoreML = coreMLStatus != .unavailable
            if !(siblingExists && !alreadyOnCoreML) { return }
        }

        if let ctx {
            whisper_free(ctx)
            self.ctx = nil
            loadedPath = nil
        }
        coreMLStatus = .unavailable

        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true

        let started = Date()
        WhisperLogCapture.shared.startCapture()
        let created = modelURL.path.withCString { whisper_init_from_file_with_params($0, params) }
        let captured = WhisperLogCapture.shared.stopCapture()
        let elapsed = Date().timeIntervalSince(started)

        guard let created else { throw Failure.modelLoadFailed(modelURL.path) }
        ctx = created
        loadedPath = modelURL.path
        modelName = displayName
        coreMLStatus = Self.parseCoreMLStatus(from: captured)
        whisperLog.notice("loaded \(displayName, privacy: .public) coreml=\(self.coreMLStatus.description, privacy: .public) in \(elapsed, privacy: .public)s")

        warmup(ctx: created)
    }

    /// Transcribes a complete sample buffer.
    ///
    /// `audioCtx`: `nil` uses the live-tuned formula, `0` means whisper's full
    /// 1500-token context, a positive value is an explicit override. See
    /// `computeAudioCtx` for why only two values are actually safe.
    public func transcribe(
        samples rawSamples: [Float],
        language: String = "en",
        audioCtx: Int32? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> [TranscriptSegment] {
        guard let ctx else { throw Failure.modelLoadFailed("(no model loaded)") }

        let samples = Self.normalize(rawSamples)

        // Beam search is the quality/speed sweet spot; greedy was measurably
        // worse on real recordings.
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.beam_search.beam_size = 5
        params.beam_search.patience = -1.0
        params.print_realtime = false
        params.print_progress = false
        params.print_special = false
        params.print_timestamps = false
        params.no_context = true
        params.single_segment = false
        params.translate = false
        params.n_threads = max(1, Int32(ProcessInfo.processInfo.activeProcessorCount - 2))
        params.suppress_blank = true
        params.no_speech_thold = 0.3

        // A CoreML-compiled encoder has a fixed (1, mel, 3000) input shape and
        // ignores audio_ctx entirely — asking it to truncate yields zero
        // segments in ~0.2s, which looks exactly like silence. So when CoreML
        // is engaged, take the full context; the ANE is fast enough that the
        // truncation speedup is not worth the failure mode.
        //
        // This is precisely why the live leg runs a small model with no
        // CoreML sibling: it can use audio_ctx=750 and be 4x faster per
        // utterance.
        if case .loaded = coreMLStatus {
            params.audio_ctx = 0
        } else {
            params.audio_ctx = audioCtx ?? Self.computeAudioCtx(sampleCount: samples.count)
        }

        let box = CallbackBox(isCancelled: isCancelled)
        let boxPtr = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<CallbackBox>.fromOpaque(boxPtr).release() }
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue().isCancelled?() ?? false
        }
        params.abort_callback_user_data = boxPtr

        let lang = Self.languageParams(for: language)
        let langCString = strdup(lang.language)
        defer { free(langCString) }
        params.language = UnsafePointer(langCString)
        params.detect_language = lang.detectLanguage

        let result: Int32 = samples.withUnsafeBufferPointer { pointer in
            whisper_full(ctx, params, pointer.baseAddress, Int32(pointer.count))
        }
        if isCancelled?() == true { throw CancellationError() }
        if result != 0 { throw Failure.transcribeFailed(result) }

        let count = Int(whisper_full_n_segments(ctx))
        var segments: [TranscriptSegment] = []
        segments.reserveCapacity(count)
        for index in 0..<count {
            let t0 = Double(whisper_full_get_segment_t0(ctx, Int32(index))) / 100.0
            let t1 = Double(whisper_full_get_segment_t1(ctx, Int32(index))) / 100.0
            let text = whisper_full_get_segment_text(ctx, Int32(index)).flatMap { String(cString: $0) } ?? ""
            segments.append(TranscriptSegment(start: t0, end: t1, text: text))
        }
        return segments
    }

    /// Frees the context while the process is still healthy.
    ///
    /// Doing this at terminate time rather than leaving it to static destruction
    /// is what keeps ggml-metal's teardown out of libc++ exit ordering.
    public func shutdown() {
        guard let ctx else { return }
        whisper_free(ctx)
        self.ctx = nil
        loadedPath = nil
        modelName = nil
    }

    // MARK: - Internal

    /// One-shot dummy run on a second of silence.
    ///
    /// Forces ggml-metal to finish its async resource-set init now. Without it,
    /// quitting while `ggml_metal_rsets_init` is still pending aborts in
    /// `ggml_metal_rsets_free` during static destruction. Best-effort: a
    /// non-zero return has still done the job.
    private func warmup(ctx: OpaquePointer) {
        let silence = [Float](repeating: 0, count: Int(WhisperAudioFormat.sampleRate))
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_special = false
        params.print_timestamps = false
        params.no_context = true
        params.single_segment = true
        params.suppress_blank = true
        params.n_threads = 2
        let langCString = strdup("en")
        defer { free(langCString) }
        params.language = UnsafePointer(langCString)
        _ = silence.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) }
    }

    static func coreMLSiblingPath(for modelURL: URL) -> String {
        modelURL.deletingPathExtension().path + "-encoder.mlmodelc"
    }

    /// Picks the encoder's mel-context truncation for a clip.
    ///
    /// The obvious formula — tokens proportional to duration — does not work.
    /// A fixture sweep on large-v3-turbo found only two safe values; everything
    /// else either silently emits zero segments or degrades specific clips:
    ///
    ///   audio_ctx | pass | WER  | elapsed
    ///   0 (=1500) | 9/9  | 0.06 | 13s   baseline
    ///   500       | 8/9  |      | fails one fixture
    ///   600       | 0/9  |      | silent fail
    ///   700       | 8/9  |      | fails one fixture
    ///   750       | 9/9  | 0.06 | 3s    <- 4x faster, identical quality
    ///   800       | 0/9  |      | silent fail
    ///   1500      | 9/9  | 0.06 | 5s    explicit full context
    ///
    /// So: 750 for clips that fit inside its 15s capacity, otherwise whisper's
    /// default. Returning 750 for a longer clip would silently truncate it.
    public static func computeAudioCtx(sampleCount: Int) -> Int32 {
        guard sampleCount > 0 else { return 0 }
        let truncatedCapacitySamples = Int(WhisperAudioFormat.sampleRate * 15.0)
        if sampleCount >= truncatedCapacitySamples { return 0 }
        return 750
    }

    /// The `(language, detect_language)` pair for `whisper_full`.
    ///
    /// `detect_language` does not mean "auto-detect" — it means "return right
    /// after detection, skip transcription". Setting it yields zero segments and
    /// no error. whisper already auto-detects when `language` is "auto", so that
    /// is the only lever we touch.
    static func languageParams(for language: String) -> (language: String, detectLanguage: Bool) {
        (language: language.isEmpty ? "auto" : language, detectLanguage: false)
    }

    /// Classifies whisper.cpp's init log into a `CoreMLStatus`.
    ///
    /// whisper emits a "failed to load" line even when no sibling exists, so a
    /// failure is only reported when the referenced path is actually on disk.
    /// Otherwise "you did not install CoreML weights" would read as an error.
    static func parseCoreMLStatus(from lines: [String]) -> CoreMLStatus {
        let joined = lines.joined()
        if joined.contains("Core ML model loaded") {
            for line in lines {
                guard let range = line.range(of: "loading Core ML model from '") else { continue }
                let tail = line[range.upperBound...]
                if let endQuote = tail.firstIndex(of: "'") {
                    return .loaded(path: String(tail[..<endQuote]))
                }
            }
            return .loaded(path: "")
        }
        if joined.contains("failed to load Core ML model") {
            for line in lines {
                guard let range = line.range(of: "failed to load Core ML model from '") else { continue }
                let tail = line[range.upperBound...]
                guard let endQuote = tail.firstIndex(of: "'") else { continue }
                let path = String(tail[..<endQuote])
                if FileManager.default.fileExists(atPath: path) {
                    return .failed(reason: "init failed at \(path)")
                }
            }
        }
        return .unavailable
    }

    /// Auto-gain so a quiet leg still clears whisper's speech threshold.
    ///
    /// Targets a peak near 0.5 (about -6 dB), capped at 20x so room noise is
    /// never amplified into something that looks like speech.
    static func normalize(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var peak: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
        }
        guard peak > 0 else { return samples }
        let gain = min(0.5 / peak, 20.0)
        if gain <= 1.05 { return samples }
        var out = samples
        for index in 0..<out.count { out[index] = max(-1, min(1, out[index] * gain)) }
        return out
    }
}

private final class CallbackBox: @unchecked Sendable {
    let isCancelled: (@Sendable () -> Bool)?
    init(isCancelled: (@Sendable () -> Bool)?) { self.isCancelled = isCancelled }
}
