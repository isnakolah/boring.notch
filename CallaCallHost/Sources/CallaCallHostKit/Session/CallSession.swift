import Foundation
import os.log

private let sessionLog = Logger(subsystem: "theboringteam.boringnotch.callhost", category: "session")

/// Where the four processes meet.
///
/// Mirrors the tutor runtime's convention: a 0700 directory of small JSON files
/// under Application Support, written atomically at 0600. `BoringCallaEngine`
/// reads these on its existing status poll, so the notch picks up call state
/// without a second polling loop anywhere.
public enum CallHostPaths {
    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment["CALLA_RUNTIME_ROOT"],
           override.hasPrefix("/"), !override.contains("..") {
            return URL(fileURLWithPath: override).appendingPathComponent("copilot", isDirectory: true)
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/boringNotch/Calla/copilot", isDirectory: true)
    }

    public static var callsDirectory: URL { root.appendingPathComponent("calls", isDirectory: true) }
    public static var modelsDirectory: URL { root.appendingPathComponent("models", isDirectory: true) }
    public static var activeCallFile: URL { root.appendingPathComponent("active-call.json") }
    public static var latestSuggestionFile: URL { root.appendingPathComponent("latest-suggestion.json") }
    public static var socketFile: URL { root.appendingPathComponent("call-host.sock") }

    public static func ensureRoot() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    /// Atomic replace at 0600 — a half-written status file would be parsed by
    /// the engine's next poll, which arrives every two seconds.
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    public static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Status the engine polls while a call is live.
public struct ActiveCallStatus: Codable, Sendable {
    public var callID: String
    public var persona: String
    public var startedAt: Date
    public var turnCount: Int
    public var gatewayConnected: Bool
    public var micActive: Bool
    public var systemAudioActive: Bool

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case persona
        case startedAt = "started_at"
        case turnCount = "turn_count"
        case gatewayConnected = "gateway_connected"
        case micActive = "mic_active"
        case systemAudioActive = "system_audio_active"
    }
}

/// One live call: two capture legs, two endpointers, one transcriber, an
/// archive, and the gateway socket.
public actor CallSession {
    public struct Configuration: Sendable {
        public var callID: String
        public var persona: String
        public var gatewayURL: URL
        public var model: WhisperModel
        public var captureSystemAudio: Bool

        public init(
            callID: String = "call-\(UUID().uuidString.lowercased().prefix(16))",
            persona: String = "generic",
            gatewayURL: URL,
            model: WhisperModel = .smallEn,
            captureSystemAudio: Bool = true
        ) {
            self.callID = callID
            self.persona = persona
            self.gatewayURL = gatewayURL
            self.model = model
            self.captureSystemAudio = captureSystemAudio
        }
    }

    private let config: Configuration
    private let archive: CallArchive
    private let transcriber: CallTranscriber
    private let socket: CopilotSocket
    private let microphone = MicrophoneRecorder()
    private let systemAudio = SystemAudioRecorder()

    /// One leg per side. Sharing an endpointer would merge both sides of the
    /// call into single utterances and destroy the labelling this whole feature
    /// depends on.
    private let micLeg = CaptureLeg(source: .me)
    private let systemLeg = CaptureLeg(source: .them)

    private let startedAt = Date()
    private var turnCount = 0
    private var micActive = false
    private var systemActive = false
    private var stopped = false

    public private(set) var latestSuggestion: CopilotFrame.Suggestion?

    public init(config: Configuration, modelURL: URL, speechGate: SileroVAD?) throws {
        self.config = config
        archive = try CallArchive(root: CallHostPaths.callsDirectory, callID: config.callID)
        transcriber = CallTranscriber(
            speechGate: speechGate,
            modelURL: modelURL,
            modelName: config.model.displayName,
            language: config.model.languageHint)
        socket = CopilotSocket(url: config.gatewayURL)
    }

    public func start() async throws {
        try CallHostPaths.ensureRoot()
        try await transcriber.prepare()

        await transcriber.setTurnHandler { [weak self] turn in
            guard let self else { return }
            Task { await self.handle(turn: turn) }
        }

        await socket.setHandlers(
            onSuggestion: { [weak self] suggestion in
                guard let self else { return }
                Task { await self.handle(suggestion: suggestion) }
            },
            onClose: { [weak self] in
                guard let self else { return }
                Task { await self.writeStatus() }
            })

        await socket.connect()
        try await socket.startCall(callID: config.callID, persona: config.persona, startedAt: startedAt)

        wireMicrophone()
        try microphone.start()
        micActive = true

        if config.captureSystemAudio {
            wireSystemAudio()
            do {
                try await systemAudio.start()
                systemActive = true
            } catch {
                // A call with only the mic leg is degraded but still useful, and
                // far better than refusing to start. The status file records it
                // so the notch can say so.
                sessionLog.error("system audio unavailable: \(error.localizedDescription, privacy: .public)")
                systemActive = false
            }
        }

        await writeStatus()
        sessionLog.notice("call \(self.config.callID, privacy: .public) started")
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true

        microphone.stop()
        await systemAudio.stop()
        micActive = false
        systemActive = false

        // Emit whatever was mid-sentence when the call ended, then let the
        // queue drain before tearing the engine down.
        micLeg.flush()
        systemLeg.flush()
        await transcriber.drain()

        try? await socket.endCall(callID: config.callID)
        await socket.disconnect()

        archive.write(meta: CallArchive.Meta(
            callID: config.callID,
            persona: config.persona,
            startedAt: startedAt,
            endedAt: Date(),
            liveModel: config.model.name,
            turnCount: turnCount,
            droppedSelfTurns: await transcriber.droppedSelfTurns))
        archive.close()
        await transcriber.stop()

        CallHostPaths.remove(CallHostPaths.activeCallFile)
        sessionLog.notice("call \(self.config.callID, privacy: .public) ended after \(self.turnCount, privacy: .public) turns")
    }

    // MARK: - Internal

    private nonisolated func wire(leg: CaptureLeg) {
        leg.onSamples = { [weak self] samples, source in
            self?.archive.append(samples: samples, source: source)
        }
        leg.onUtterance = { [weak self] samples, start, source in
            guard let self else { return }
            Task { await self.transcriber.enqueue(samples: samples, source: source, startSeconds: start) }
        }
    }

    private func wireMicrophone() {
        wire(leg: micLeg)
        microphone.onSamples = { [weak self] samples in
            self?.micLeg.ingest(samples)
        }
    }

    private func wireSystemAudio() {
        wire(leg: systemLeg)
        systemAudio.onSamples = { [weak self] samples in
            self?.systemLeg.ingest(samples)
        }
    }

    private func handle(turn: CallTurn) async {
        turnCount += 1
        archive.record(turn: turn)
        do {
            try await socket.send(turn: turn, callID: config.callID)
        } catch {
            // The archive already has it; a dropped frame costs a suggestion,
            // not the transcript.
            sessionLog.error("turn \(turn.seq, privacy: .public) not delivered: \(error.localizedDescription, privacy: .public)")
        }
        await writeStatus()
    }

    private func handle(suggestion: CopilotFrame.Suggestion) async {
        latestSuggestion = suggestion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(suggestion) else { return }
        if let line = String(data: data, encoding: .utf8) {
            archive.record(suggestionLine: line)
        }
        try? CallHostPaths.writeAtomically(data, to: CallHostPaths.latestSuggestionFile)
    }

    private func writeStatus() async {
        let status = ActiveCallStatus(
            callID: config.callID,
            persona: config.persona,
            startedAt: startedAt,
            turnCount: turnCount,
            gatewayConnected: await socket.connected,
            micActive: micActive,
            systemAudioActive: systemActive)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(status) else { return }
        try? CallHostPaths.writeAtomically(data, to: CallHostPaths.activeCallFile)
    }
}
