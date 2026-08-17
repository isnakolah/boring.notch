import CallaCallHostKit
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
      CallaCallHost permissions                 Report mic / screen recording status
      CallaCallHost probe-gateway --gateway <url>
                                                Replay a canned call to a gateway

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

/// Counts suggestions arriving on the socket's callback, which fires outside
/// this file's execution context.
actor Received {
    private(set) var count = 0
    func record() { count += 1 }
}

/// One-shot shutdown latch, so a signal handler can wake the main task.
actor Stopped {
    private var isStopped = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func trigger() {
        guard !isStopped else { return }
        isStopped = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        if isStopped { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

func value(for flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func resolveModel() -> WhisperModel {
    guard let name = value(for: "--model") else { return .smallEn }
    guard let model = WhisperModel.named(name) else {
        FileHandle.standardError.write(Data("unknown model: \(name)\n".utf8))
        exit(2)
    }
    return model
}

func ensureModel(_ model: WhisperModel) async throws -> URL {
    try CallHostPaths.ensureRoot()
    let store = ModelStore(directory: CallHostPaths.modelsDirectory)
    if store.isInstalled(model) {
        print("\(model.displayName) already installed")
        return store.localURL(for: model)
    }
    print("downloading \(model.displayName) (\(model.sizeBytes / 1_048_576) MB)…")
    let url = try await store.ensure(model) { fraction in
        let percent = Int(fraction * 100)
        if percent % 10 == 0 { print("  \(percent)%") }
    }
    print("verified and installed at \(url.path)")
    return url
}

guard let command = arguments.first else { usage() }

switch command {
case "models":
    let model = resolveModel()
    do {
        _ = try await ensureModel(model)
    } catch {
        FileHandle.standardError.write(Data("model install failed: \(error.localizedDescription)\n".utf8))
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

    guard await MicrophoneRecorder.requestAccess() else {
        FileHandle.standardError.write(Data("microphone access denied\n".utf8))
        exit(1)
    }

    do {
        let modelURL = try await ensureModel(model)
        let gate = await SpeechGateFactory.makeBundledGate()
        let config = CallSession.Configuration(
            persona: persona,
            gatewayURL: gateway,
            model: model,
            captureSystemAudio: captureSystemAudio)
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
            source.setEventHandler { Task { await stopped.trigger() } }
            source.resume()
            return source
        }
        defer { sources.forEach { $0.cancel() } }

        await stopped.wait()
        await session.stop()
        print("call ended")
    } catch {
        FileHandle.standardError.write(Data("serve failed: \(error.localizedDescription)\n".utf8))
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
            FileHandle.standardError.write(Data("no audio in \(path)\n".utf8))
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
        FileHandle.standardError.write(Data("transcribe failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

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
            print("\nsuggestion after seq \(suggestion.afterSeq) in \(suggestion.latencyMs)ms")
            print("  headline: \(suggestion.headline)")
            for angle in suggestion.angles { print("  angle:    \(angle)") }
            for item in suggestion.confirm { print("  confirm:  \(item)") }
            Task { await received.record() }
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
        exit(count > 0 ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("probe failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case "archive":
    guard arguments.count > 1 else { usage() }
    let callID = arguments[1]
    let directory = CallHostPaths.callsDirectory.appendingPathComponent(callID, isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else {
        FileHandle.standardError.write(Data("no such call: \(callID)\n".utf8))
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
        FileHandle.standardError.write(Data("archive failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case "permissions":
    let mic = MicrophoneRecorder.isAuthorized
    let screen = await SystemAudioRecorder.hasPermission()
    print("microphone:      \(mic ? "granted" : "not granted")")
    print("screen recording: \(screen ? "granted" : "not granted")")
    if !mic {
        print("\nrequesting microphone access…")
        print("microphone:      \(await MicrophoneRecorder.requestAccess() ? "granted" : "denied")")
    }
    if !screen {
        print("\nGrant Screen Recording to this binary in System Settings > Privacy & Security.")
        print("System audio — the other party's voice — is unavailable without it.")
    }
    exit((mic && screen) ? 0 : 1)

case "record":
    let seconds = Double(value(for: "--seconds") ?? "30") ?? 30
    let model = resolveModel()
    let captureSystemAudio = !arguments.contains("--no-system-audio")

    guard await MicrophoneRecorder.requestAccess() else {
        FileHandle.standardError.write(Data("microphone access denied\n".utf8))
        exit(1)
    }
    if captureSystemAudio, await !SystemAudioRecorder.hasPermission() {
        FileHandle.standardError.write(Data(
            "screen recording not granted; run `CallaCallHost permissions` or pass --no-system-audio\n".utf8))
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
        FileHandle.standardError.write(Data("record failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

default:
    usage()
}
