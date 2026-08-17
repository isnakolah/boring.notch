import CallaCallHostKit
import IntelligenceCore
import CoreGraphics
import Foundation

/// CallaCallHost — the unsandboxed capture and transcription host.
///
/// Runs outside the sandboxed notch app because it needs microphone and screen
/// recording, and those TCC grants attach to the executable that actually
/// captures. It is driven by BoringCallaEngine over a Unix socket in normal use;
/// the subcommands here exist so each layer can be exercised on its own without
/// the rest of the stack.

setvbuf(stdout, nil, _IONBF, 0)
// A broken pipe must not take the host down mid-call.
signal(SIGPIPE, SIG_IGN)

/// Writes to stderr without the process betting its life on stderr existing.
///
/// `FileHandle.standardError.write` looks equivalent and is not: it raises an
/// `NSException` when the descriptor is closed or the pipe is broken, and Swift
/// cannot catch that, so the process aborts. Ignoring SIGPIPE above is what
/// turns a broken pipe into that exception rather than a signal. This host is
/// spawned by an XPC service, so a closed stderr is the ordinary case, not the
/// exotic one — and dying while reporting an error loses the error too.
func complain(_ message: String) {
    fputs(message, stderr)
}

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    let text = """
    CallaCallHost

    USAGE:
      CallaCallHost serve [options]             Run a call until SIGINT (engine-driven)
      CallaCallHost models [--model <name>]     Download and verify models
      CallaCallHost record [options]            Capture and transcribe locally
      CallaCallHost transcribe <file> [opts]    Transcribe an audio file
      CallaCallHost archive <call-id>           Re-transcribe a finished call with large-v3-turbo
      CallaCallHost retranscribe --call <id>    Same, as the engine spells it
      CallaCallHost permissions [--check]       Request and report mic / screen recording status
                                                (--check reports without prompting)
      CallaCallHost probe-gateway --gateway <url>
                                                Replay a canned call to a gateway
      CallaCallHost probe-local [--tier <t>]    Replay the same call through local agy,
                                                reporting per-suggestion latency

    SERVE OPTIONS:
      --gateway <url>     Required. Used for fallback even when --provider local.
      --persona <name>    generic | interview | sales | support
      --provider <which>  local | gateway (default local)
      --tier <tier>       fast | balanced | deep — live model tier (default balanced)
      --summary-model <m> Exact model for the end-of-call pass
      --no-fallback       Do not let the gateway answer when local fails
      --no-system-audio   Microphone only

    RECORD OPTIONS:
      --seconds <n>       How long to capture (default 30)
      --model <name>      whisper-small-en | whisper-base-en (default whisper-small-en)
      --no-system-audio   Microphone only
      --gateway <url>     Stream to a gateway; omit to stay entirely local

    MODELS:
    \(WhisperModel.all.map { "  \($0.name.padding(toLength: 24, withPad: " ", startingAt: 0))\($0.displayName)" }.joined(separator: "\n"))
    """
    print(text)
    exit(2)
}

/// Latencies from `probe-local`. A median rather than a mean: one slow first
/// answer should not decide whether the fast path is working.
actor LocalProbeResults {
    private var latencies: [Int] = []

    func record(latencyMs: Int) {
        latencies.append(latencyMs)
    }

    var count: Int { latencies.count }

    var medianMs: Double {
        guard !latencies.isEmpty else { return .infinity }
        let sorted = latencies.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return Double(sorted[middle]) }
        return Double(sorted[middle - 1] + sorted[middle]) / 2
    }
}

/// Counts suggestions arriving on the socket's callback, which fires outside
/// this file's execution context.
actor Received {
    private(set) var count = 0
    func record() { count += 1 }

    /// When each turn went out, so a suggestion can be priced against the turn
    /// it answers rather than against the gateway's own opinion of its latency.
    private var sentAt: [Int: Date] = [:]
    /// Observed round trips, in milliseconds, in arrival order.
    private(set) var observedMs: [Double] = []

    func recordSend(seq: Int, at date: Date = Date()) { sentAt[seq] = date }

    /// Milliseconds from sending turn `seq` to this suggestion landing, or nil
    /// if the gateway answered a turn we never sent.
    func recordArrival(afterSeq: Int, at date: Date = Date()) -> Double? {
        guard let sent = sentAt[afterSeq] else { return nil }
        let ms = date.timeIntervalSince(sent) * 1000
        observedMs.append(ms)
        return ms
    }
}

/// One-shot shutdown latch, so a signal handler can wake the main task.
///
/// Deliberately a semaphore rather than an actor. A `DispatchSource` signal
/// handler runs on a bare dispatch queue, and starting a `Task` from there puts
/// the Swift concurrency runtime through an executor-isolation check that
/// asserts and traps (SIGTRAP in `dispatch_assert_queue_fail`) — so the host
/// died on SIGINT instead of draining, leaving the trailing utterance unwritten
/// and a stale `active-call.json` claiming a call was still live. `signal()` is
/// one of the few things safe to do from that context.
final class Stopped: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var triggered = false
    private let lock = NSLock()

    func trigger() {
        lock.lock()
        let first = !triggered
        triggered = true
        lock.unlock()
        if first { semaphore.signal() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [semaphore] in
                semaphore.wait()
                continuation.resume()
            }
        }
    }
}

func value(for flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

/// Which brain answers. Local means `agy` on this Mac, which does not need
/// `nomonhomelab` to be reachable; anything unrecognised falls back to the
/// historical behaviour rather than refusing to start a call.
func copilotProvider() -> CopilotAdvisor.Provider {
    switch value(for: "--provider") {
    case "gateway": .gateway
    case "local", .none: .local
    default: .gateway
    }
}

func liveTier() -> ModelTier {
    ModelTier(rawValue: value(for: "--tier") ?? "") ?? .balanced
}

func resolveModel() -> WhisperModel {
    guard let name = value(for: "--model") else { return .smallEn }
    guard let model = WhisperModel.named(name) else {
        complain("unknown model: \(name)\n")
        exit(2)
    }
    return model
}

func ensureModel(_ model: WhisperModel) async throws -> URL {
    try CallHostPaths.ensureRoot()
    let store = ModelStore(directory: CallHostPaths.modelsDirectory)
    if store.isInstalled(model) {
        print("\(model.displayName) already installed")
        ModelDownloadStatus(model: model.name, receivedBytes: model.sizeBytes,
                            totalBytes: model.sizeBytes, state: "ready").write()
        return store.localURL(for: model)
    }
    print("downloading \(model.displayName) (\(model.sizeBytes / 1_048_576) MB)…")
    // Progress goes to a file as well as stdout. The engine spawns this with
    // no pipe attached, so anything printed here reached nobody — which is why
    // the first call on a new Mac looked like a hang.
    ModelDownloadStatus(model: model.name, receivedBytes: 0,
                        totalBytes: model.sizeBytes, state: "downloading").write()
    do {
        let url = try await store.ensure(model) { fraction in
            let percent = Int(fraction * 100)
            if percent % 10 == 0 { print("  \(percent)%") }
            ModelDownloadStatus(
                model: model.name,
                receivedBytes: Int64(Double(model.sizeBytes) * fraction),
                totalBytes: model.sizeBytes,
                state: fraction >= 1 ? "verifying" : "downloading").write()
        }
        print("verified and installed at \(url.path)")
        ModelDownloadStatus(model: model.name, receivedBytes: model.sizeBytes,
                            totalBytes: model.sizeBytes, state: "ready").write()
        return url
    } catch {
        ModelDownloadStatus(model: model.name, receivedBytes: 0, totalBytes: model.sizeBytes,
                            state: "failed", message: error.localizedDescription).write()
        throw error
    }
}

guard let command = arguments.first else { usage() }

switch command {
case "models":
    // `--fetch` is the engine's spelling, `--model` the human one; both mean
    // "make sure this model is on disk".
    let model = value(for: "--fetch").flatMap(WhisperModel.named) ?? resolveModel()
    do {
        _ = try await ensureModel(model)
    } catch {
        complain("model install failed: \(error.localizedDescription)\n")
        exit(1)
    }

case "serve":
    // How BoringCallaEngine runs a call: start capturing, keep going until the
    // engine sends SIGINT, then shut down cleanly so the trailing utterance and
    // the WAV headers are not lost.
    let model = resolveModel()
    let persona = value(for: "--persona") ?? "generic"
    let captureSystemAudio = !arguments.contains("--no-system-audio")
    guard let gateway = value(for: "--gateway").flatMap(URL.init(string:)) else { usage() }
    // Read before anything slow: the engine writes and closes the pipe right
    // after spawning, and this is the only chance to take it.
    let profile = CallProfile.readFromStandardInput()

    guard await MicrophoneRecorder.requestAccess() else {
        HostPermissions.probeAndWrite(mic: false, screen: await SystemAudioRecorder.hasPermission())
        complain("microphone access denied\n")
        exit(1)
    }
    HostPermissions.probeAndWrite(mic: true, screen: await SystemAudioRecorder.hasPermission())

    do {
        let modelURL = try await ensureModel(model)
        let gate = await SpeechGateFactory.makeBundledGate()
        let config = CallSession.Configuration(
            persona: persona,
            gatewayURL: gateway,
            model: model,
            captureSystemAudio: captureSystemAudio,
            profile: profile,
            provider: copilotProvider(),
            fallbackToGateway: !arguments.contains("--no-fallback"),
            liveTier: liveTier(),
            summaryModel: value(for: "--summary-model"))
        let session = try CallSession(config: config, modelURL: modelURL, speechGate: gate)
        try await session.start()
        print("serving call \(config.callID)")

        // A DispatchSource handler runs even though the default SIGINT
        // disposition is ignored, which is what lets the async teardown finish
        // instead of the process dying mid-write.
        let stopped = Stopped()
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sources = [SIGINT, SIGTERM].map { code -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: code, queue: .global())
            // No `Task` here — see `Stopped`. This runs on a dispatch queue,
            // and entering Swift concurrency from it traps.
            source.setEventHandler { stopped.trigger() }
            source.resume()
            return source
        }
        defer { sources.forEach { $0.cancel() } }

        await stopped.wait()
        await session.stop()
        print("call ended")
        // `_exit` rather than falling off the end of main.
        //
        // whisper.cpp 1.8.4 aborts inside `ggml_metal_rsets_free` when its
        // Metal device is torn down by a static destructor at exit, so a
        // perfectly clean call ends in SIGABRT and the engine reports "Call
        // host stopped (status 6)". `session.stop()` has already flushed the
        // endpointers, drained the transcription queue and closed the WAVs, so
        // there is nothing left for those destructors to do that we need.
        _exit(0)
    } catch {
        complain("serve failed: \(error.localizedDescription)\n")
        exit(1)
    }

case "transcribe":
    guard arguments.count > 1 else { usage() }
    let path = arguments[1]
    let model = resolveModel()
    do {
        let modelURL = try await ensureModel(model)
        let samples = try AudioConvert.loadAsWhisperSamples(url: URL(fileURLWithPath: path))
        guard !samples.isEmpty else {
            complain("no audio in \(path)\n")
            exit(1)
        }
        let duration = Double(samples.count) / WhisperAudioFormat.sampleRate

        let engine = WhisperEngine()
        let loadStart = Date()
        try await engine.loadIfNeeded(modelURL: modelURL, displayName: model.displayName)
        let loadElapsed = Date().timeIntervalSince(loadStart)

        // Report the truncation policy explicitly: with a CoreML encoder
        // attached whisper ignores audio_ctx, which is the whole reason the live
        // leg runs a model with no CoreML sibling.
        let coreML = await engine.coreMLStatus
        let audioCtx = WhisperEngine.computeAudioCtx(sampleCount: samples.count)

        let start = Date()
        let segments = try await engine.transcribe(samples: samples, language: model.languageHint)
        let elapsed = Date().timeIntervalSince(start)
        await engine.shutdown()

        print("model      \(model.displayName)")
        print("coreml     \(coreML.description)")
        print("audio      \(String(format: "%.2f", duration))s")
        print("audio_ctx  \(coreML == .unavailable ? String(audioCtx) : "0 (forced by CoreML)")")
        print("load       \(String(format: "%.2f", loadElapsed))s")
        print("transcribe \(String(format: "%.2f", elapsed))s  (\(String(format: "%.2f", duration / max(elapsed, 0.001)))x realtime)")
        print("")
        for segment in segments {
            print(String(format: "[%6.2f -> %6.2f] %@", segment.start, segment.end,
                         segment.text.trimmingCharacters(in: .whitespaces)))
        }
    } catch {
        complain("transcribe failed: \(error.localizedDescription)\n")
        exit(1)
    }

case "probe-local":
    // The acceptance gate for the local brain. Replays the same canned call as
    // probe-gateway, but through `agy`, and gates on *latency* as well as
    // success: if a suggestion takes longer than the fast path should, the
    // resident language server is not being used and it has silently degraded to
    // one process per request (~8.5s), which defeats the point.
    let callID = "call-\(UUID().uuidString.lowercased().prefix(16))"
    let runtimeRoot = CallHostPaths.root
    let advisor = CopilotAdvisor(config: .init(
        callID: callID,
        persona: "interview",
        profile: nil,
        preferred: .local,
        fallbackToGateway: false,
        liveTier: liveTier(),
        summaryModel: value(for: "--summary-model"),
        runtimeRoot: runtimeRoot))

    let probe = LocalProbeResults()
    await advisor.setHandlers(
        onSuggestion: { suggestion, provider in
            Task {
                await probe.record(latencyMs: suggestion.latencyMs)
                print("\nsuggestion after seq \(suggestion.afterSeq) — \(suggestion.latencyMs)ms (\(provider.rawValue))")
                print("  headline: \(suggestion.headline)")
                for angle in suggestion.angles { print("  angle:    \(angle)") }
                for item in suggestion.confirm { print("  confirm:  \(item)") }
                if !suggestion.summary.isEmpty { print("  summary:  \(suggestion.summary)") }
            }
        },
        onProviderChange: { provider, detail in
            print("provider -> \(provider.rawValue)\(detail.map { " (\($0))" } ?? "")")
        })

    print("call \(callID)")
    let preparedAt = Date()
    await advisor.prepare()
    print(String(format: "prepared local brain in %.2fs (host boot + session open)",
                 Date().timeIntervalSince(preparedAt)))

    // Phrase-level turns with several in a row per speaker, which is what the VAD
    // actually emits (it closes an utterance after 500ms of silence). A fixture
    // that alternates speaker every turn would make the segmentation ratio look
    // like 1.0 no matter how well the batching works.
    let script: [(TurnSource, String)] = [
        (.them, "Thanks for making the time today,"),
        (.them, "let's get straight into it."),
        (.me, "Happy to be here."),
        (.them, "So walk me through how you would approach"),
        (.them, "scaling this system to about ten times the traffic."),
        (.me, "Sure, so the first thing I would look at"),
        (.me, "is where the read load actually sits."),
        (.them, "And when could you realistically start?"),
    ]

    for (index, entry) in script.enumerated() {
        let turn = CallTurn(
            seq: index,
            source: entry.0,
            t0: Double(index) * 2,
            t1: Double(index) * 2 + 1.4,
            text: entry.1)
        await advisor.ingest(turn: turn)
        print("-> [\(turn.source.rawValue)] \(turn.text)")
        try? await Task.sleep(for: .milliseconds(700))
        await advisor.tick()
    }

    // Let the segmenter's idle rule fire and the last request land.
    for _ in 0 ..< 40 {
        try? await Task.sleep(for: .milliseconds(250))
        await advisor.tick()
    }

    let turnsSeen = await advisor.turnsSeen
    let statements = await advisor.statementsEmitted
    let ratio = await advisor.segmentationRatio()
    await advisor.shutdown()

    let count = await probe.count
    let median = await probe.medianMs
    print("\n--- probe-local ---")
    print("suggestions:  \(count)")
    print(String(format: "median:       %.0fms", median))
    print("segmentation: \(turnsSeen) turns -> \(statements) statements (ratio \(String(format: "%.2f", ratio)))")

    guard count > 0 else {
        complain("no suggestion arrived\n")
        exit(1)
    }
    // Hand-measured fast path is ~2.5-3.5s per suggestion; the print-transport
    // fallback is ~8.5s. 6s sits unambiguously between them.
    guard median <= 6000 else {
        complain("median \(Int(median))ms exceeds the fast-path budget — the resident host is not being used\n")
        exit(1)
    }
    print("ok")

case "probe-gateway":
    // Exercises the real Swift client against a real gateway without needing a
    // microphone or any TCC grant — this is what proves the Swift and Node
    // halves agree on the wire format.
    guard let gateway = value(for: "--gateway").flatMap(URL.init(string:)) else { usage() }
    let callID = "call-\(UUID().uuidString.lowercased().prefix(16))"
    let socket = CopilotSocket(url: gateway)

    let received = Received()
    await socket.setHandlers(
        onSuggestion: { suggestion in
            let arrivedAt = Date()
            Task {
                await received.record()
                // Two numbers, deliberately: the gateway's `latency_ms` covers
                // only its own model call, while the observed figure includes
                // the debounce it waits out plus both network legs. The gap
                // between them is what no amount of a faster model will fix.
                let observed = await received.recordArrival(afterSeq: suggestion.afterSeq, at: arrivedAt)
                let observedText = observed.map { String(format: "%.0fms observed", $0) } ?? "unmatched"
                print("\nsuggestion after seq \(suggestion.afterSeq) — \(suggestion.latencyMs)ms gateway, \(observedText)")
                print("  headline: \(suggestion.headline)")
                for angle in suggestion.angles { print("  angle:    \(angle)") }
                for item in suggestion.confirm { print("  confirm:  \(item)") }
            }
        },
        onError: { code, message in
            print("\ngateway error \(code): \(message)")
        })

    await socket.connect()
    print("connected to \(gateway.absoluteString)")
    print("call \(callID)\n")

    do {
        try await socket.startCall(callID: callID, persona: "interview", startedAt: Date())

        let script: [(TurnSource, String)] = [
            (.them, "Thanks for making the time today. Let's get into it."),
            (.me, "Happy to be here."),
            (.them, "So walk me through how you would approach scaling this system."),
            (.me, "Sure, so the first thing I would look at is where the read load sits."),
            (.them, "And when could you realistically start?"),
        ]

        for (index, entry) in script.enumerated() {
            let turn = CallTurn(
                seq: index,
                source: entry.0,
                t0: Double(index) * 4,
                t1: Double(index) * 4 + 3.5,
                text: entry.1)
            await received.recordSend(seq: turn.seq)
            try await socket.send(turn: turn, callID: callID)
            print("-> [\(turn.source.rawValue)] \(turn.text)")
            try await Task.sleep(for: .milliseconds(400))
        }

        // Give the debounce and the model turn time to land.
        try await Task.sleep(for: .seconds(20))
        try await socket.endCall(callID: callID)
        await socket.disconnect()

        let count = await received.count
        print("\nreceived \(count) suggestion(s)")
        let observed = await received.observedMs
        if !observed.isEmpty {
            let sorted = observed.sorted()
            let median = sorted[sorted.count / 2]
            print(String(format: "observed turn->suggestion: min %.0fms  median %.0fms  max %.0fms",
                         sorted.first!, median, sorted.last!))
        }
        exit(count > 0 ? 0 : 1)
    } catch {
        complain("probe failed: \(error.localizedDescription)\n")
        exit(1)
    }

case "archive", "retranscribe":
    // `retranscribe --call <id>` is the engine's spelling; the bare positional
    // form stays for driving this by hand.
    guard let callID = value(for: "--call") ?? (arguments.count > 1 ? arguments[1] : nil) else { usage() }
    let directory = CallHostPaths.callsDirectory.appendingPathComponent(callID, isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else {
        complain("no such call: \(callID)\n")
        exit(1)
    }
    do {
        let model = WhisperModel.largeV3Turbo
        let modelURL = try await ensureModel(model)
        // The CoreML encoder is what makes the archive pass worth doing; it is
        // best-effort, and a Metal-only run is simply slower.
        let store = ModelStore(directory: CallHostPaths.modelsDirectory)
        if store.coreMLDirectory(for: model).map({ !FileManager.default.fileExists(atPath: $0.path) }) == true {
            print("fetching CoreML encoder (\(model.coreMLSizeBytes / 1_048_576) MB)…")
            await store.ensureCoreML(model) { fraction in
                let percent = Int(fraction * 100)
                if percent % 20 == 0 { print("  \(percent)%") }
            }
        }
        let result = try await ArchiveTranscriber.retranscribe(
            callDirectory: directory,
            modelURL: modelURL,
            modelName: model.displayName,
            language: model.languageHint) { print($0) }
        print("wrote \(result.turns) turns in \(String(format: "%.1f", result.duration))s")
        print(directory.appendingPathComponent("transcript-archive.jsonl").path)
    } catch {
        complain("archive failed: \(error.localizedDescription)\n")
        exit(1)
    }

case "permissions":
    var mic = MicrophoneRecorder.isAuthorized
    var screen = await SystemAudioRecorder.hasPermission()
    print("microphone:      \(mic ? "granted" : "not granted")")
    print("screen recording: \(screen ? "granted" : "not granted")")
    // `--check` reports without asking. Both probes above are already
    // prompt-free, which is what lets the engine run this at startup to answer
    // "what does the host hold" without a dialog appearing out of nowhere.
    if arguments.contains("--check") {
        HostPermissions.probeAndWrite(mic: mic, screen: screen)
        exit((mic && screen) ? 0 : 1)
    }
    if !mic {
        print("\nrequesting microphone access…")
        mic = await MicrophoneRecorder.requestAccess()
        print("microphone:      \(mic ? "granted" : "denied")")
    }
    if !screen {
        // Asking here is what makes the request meaningful: the prompt is
        // attributed to this binary's signature, which is the one that will do
        // the recording. The engine cannot ask on its behalf.
        print("\nrequesting screen recording…")
        screen = CGRequestScreenCaptureAccess()
        if !screen {
            print("Grant Screen Recording to this binary in System Settings > Privacy & Security.")
            print("System audio — the other party's voice — is unavailable without it.")
        }
    }
    // Recorded where the engine can read it, so Settings reports this process's
    // grants rather than its own.
    HostPermissions.probeAndWrite(mic: mic, screen: screen)
    exit((mic && screen) ? 0 : 1)

case "record":
    let seconds = Double(value(for: "--seconds") ?? "30") ?? 30
    let model = resolveModel()
    let captureSystemAudio = !arguments.contains("--no-system-audio")

    guard await MicrophoneRecorder.requestAccess() else {
        complain("microphone access denied\n")
        exit(1)
    }
    if captureSystemAudio, await !SystemAudioRecorder.hasPermission() {
        complain("screen recording not granted; run `CallaCallHost permissions` or pass --no-system-audio\n")
        exit(1)
    }

    do {
        let modelURL = try await ensureModel(model)
        let gateway = value(for: "--gateway").flatMap(URL.init(string:))
            // Local-only default: a loopback URL that nothing answers, so the
            // socket simply fails to connect and the run stays on-device.
            ?? URL(string: "ws://127.0.0.1:1/call-copilot/stream")!

        let gate = await SpeechGateFactory.makeBundledGate()
        if gate == nil { print("warning: running without the neural speech gate") }

        let config = CallSession.Configuration(
            persona: "generic",
            gatewayURL: gateway,
            model: model,
            captureSystemAudio: captureSystemAudio)

        print("call \(config.callID)")
        print("model \(model.displayName)")
        print("capturing for \(Int(seconds))s — speak, and play audio through the speakers\n")

        let session = try CallSession(config: config, modelURL: modelURL, speechGate: gate)
        try await session.start()

        try await Task.sleep(for: .seconds(seconds))
        await session.stop()

        let archive = CallHostPaths.callsDirectory.appendingPathComponent(config.callID)
        print("\nwrote \(archive.path)")
        if let transcript = try? String(contentsOf: archive.appendingPathComponent("transcript.jsonl"), encoding: .utf8),
           !transcript.isEmpty {
            print("\ntranscript:")
            print(transcript)
        } else {
            print("\nno turns were transcribed")
        }
    } catch {
        complain("record failed: \(error.localizedDescription)\n")
        exit(1)
    }

default:
    usage()
}

// Every subcommand that got this far did its work.
//
// `_exit` skips the static destructors, because whisper.cpp 1.8.4 aborts inside
// `ggml_metal_rsets_free` when its Metal device is torn down at exit — turning a
// clean run into SIGABRT and a crash report. Nothing above defers work to a
// destructor: transcripts, WAVs and status files are all written before here.
_exit(0)
