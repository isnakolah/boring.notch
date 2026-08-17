import Foundation
import IntelligenceCore
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
    public static var permissionsFile: URL { root.appendingPathComponent("permissions.json") }
    public static var modelDownloadFile: URL { root.appendingPathComponent("model-download.json") }
    public static var socketFile: URL { root.appendingPathComponent("call-host.sock") }

    public static func callMetadataFile(for callID: String) -> URL {
        callsDirectory
            .appendingPathComponent(callID, isDirectory: true)
            .appendingPathComponent("call.json")
    }

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

/// What this executable was granted, written by the `permissions` subcommand.
///
/// A grant belongs to the signature that asks for it, so only this process can
/// answer honestly for this process. The engine used to preflight on its own
/// behalf and report the answer as if it were the host's.
public struct HostPermissions: Codable, Sendable {
    public var micGranted: Bool
    public var screenGranted: Bool
    public var checkedAt: Date

    enum CodingKeys: String, CodingKey {
        case micGranted = "mic_granted"
        case screenGranted = "screen_granted"
        case checkedAt = "checked_at"
    }

    public init(micGranted: Bool, screenGranted: Bool, checkedAt: Date = Date()) {
        self.micGranted = micGranted
        self.screenGranted = screenGranted
        self.checkedAt = checkedAt
    }

    /// Checks both grants and records the answer where the engine can read it.
    public static func probeAndWrite(mic: Bool, screen: Bool) {
        let record = HostPermissions(micGranted: mic, screenGranted: screen)
        guard let data = try? JSONEncoder.callHost.encode(record) else { return }
        try? CallHostPaths.ensureRoot()
        try? CallHostPaths.writeAtomically(data, to: CallHostPaths.permissionsFile)
    }
}

/// Progress of a model fetch, so the first call on a new Mac is a visible wait
/// rather than a silent one.
public struct ModelDownloadStatus: Codable, Sendable {
    public var model: String
    public var receivedBytes: Int64
    public var totalBytes: Int64
    /// `downloading`, `verifying`, `ready` or `failed`.
    public var state: String
    public var message: String?

    enum CodingKeys: String, CodingKey {
        case model, state, message
        case receivedBytes = "received_bytes"
        case totalBytes = "total_bytes"
    }

    public init(model: String, receivedBytes: Int64, totalBytes: Int64, state: String, message: String? = nil) {
        self.model = model
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.state = state
        self.message = message
    }

    public func write() {
        guard let data = try? JSONEncoder.callHost.encode(self) else { return }
        try? CallHostPaths.ensureRoot()
        try? CallHostPaths.writeAtomically(data, to: CallHostPaths.modelDownloadFile)
    }
}

/// The user's own prompt text, handed in on stdin at launch.
///
/// Arrives on stdin rather than as arguments precisely because it is free text:
/// an argument list is visible in `ps` and is one quoting mistake away from
/// being more than a prompt.
public struct CallProfile: Codable, Sendable {
    public var about: String?
    public var personaGuidance: String?
    public var baseGuidance: String?

    enum CodingKeys: String, CodingKey {
        case about
        case personaGuidance = "persona_guidance"
        case baseGuidance = "base_guidance"
    }

    /// Reads one JSON line from stdin without blocking a run that has none.
    ///
    /// The engine closes the pipe straight after writing, so EOF is the normal
    /// case and an empty read simply means "no profile".
    ///
    /// POSIX `read`, not `FileHandle`. This host is spawned by an XPC service,
    /// where the inherited descriptors may be closed or already broken, and
    /// `FileHandle` answers that by raising an `NSException` — which Swift
    /// cannot catch, so the process aborts. `read` returns -1 and sets errno
    /// like a reasonable thing.
    public static func readFromStandardInput() -> CallProfile? {
        var info = stat()
        guard fstat(0, &info) == 0, isatty(0) == 0 else { return nil }
        // Only a pipe carries a profile. A terminal, a file or /dev/null means
        // nobody is sending one, and reading a terminal would block forever.
        guard (info.st_mode & S_IFMT) == S_IFIFO else { return nil }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(0, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
                continue
            }
            if count == 0 { break }                    // EOF
            if errno == EINTR { continue }
            return nil                                  // any other error: no profile
        }
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(CallProfile.self, from: data)
    }
}

extension JSONEncoder {
    /// ISO-8601 dates, matching what the engine's decoder expects from every
    /// other file this host writes.
    public static var callHost: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
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
    /// Which brain is answering right now: `local` or `gateway`. Optional so an
    /// archived status written by an older host still decodes.
    public var provider: String?
    /// The model that answered, or why the local brain stood down. Shown in the
    /// notch, because a silent failover is indistinguishable from a broken one.
    public var providerDetail: String?

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case persona
        case startedAt = "started_at"
        case turnCount = "turn_count"
        case gatewayConnected = "gateway_connected"
        case micActive = "mic_active"
        case systemAudioActive = "system_audio_active"
        case provider
        case providerDetail = "provider_detail"
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
        /// The user's own prompt text. Rides `call_start`; nil means the
        /// gateway's own wording is used, which is the untouched-install case.
        public var profile: CallProfile?
        /// Which brain answers. `local` runs `agy` on this Mac and does not need
        /// `nomonhomelab` to be reachable.
        public var provider: CopilotAdvisor.Provider
        /// Let the gateway answer when the local brain cannot.
        public var fallbackToGateway: Bool
        public var liveTier: ModelTier
        /// Exact model for the end-of-call pass.
        public var summaryModel: String?

        public init(
            callID: String = "call-\(UUID().uuidString.lowercased().prefix(16))",
            persona: String = "generic",
            gatewayURL: URL,
            model: WhisperModel = .smallEn,
            captureSystemAudio: Bool = true,
            profile: CallProfile? = nil,
            provider: CopilotAdvisor.Provider = .local,
            fallbackToGateway: Bool = true,
            liveTier: ModelTier = .balanced,
            summaryModel: String? = nil
        ) {
            self.callID = callID
            self.persona = persona
            self.gatewayURL = gatewayURL
            self.model = model
            self.captureSystemAudio = captureSystemAudio
            self.profile = profile
            self.provider = provider
            self.fallbackToGateway = fallbackToGateway
            self.liveTier = liveTier
            self.summaryModel = summaryModel
        }
    }

    private let config: Configuration
    private let archive: CallArchive
    private let transcriber: CallTranscriber
    private let socket: CopilotSocket
    /// Owns the local brain, the statement batching, and the decision about whose
    /// suggestion gets published.
    private let advisor: CopilotAdvisor
    /// Drives the segmenter's idle and request-floor rules, which are time-based
    /// and would otherwise only fire when the next turn happens to arrive.
    private var advisorTicker: Task<Void, Never>?
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
        advisor = CopilotAdvisor(config: .init(
            callID: config.callID,
            persona: config.persona,
            profile: config.profile,
            preferred: config.provider,
            fallbackToGateway: config.fallbackToGateway,
            liveTier: config.liveTier,
            summaryModel: config.summaryModel,
            runtimeRoot: CallHostPaths.root
        ))
    }

    public func start() async throws {
        try CallHostPaths.ensureRoot()
        try await transcriber.prepare()

        await transcriber.setTurnHandler { [weak self] turn in
            guard let self else { return }
            Task { await self.handle(turn: turn) }
        }

        await advisor.setHandlers(
            onSuggestion: { [weak self] suggestion, _ in
                guard let self else { return }
                Task { await self.handle(suggestion: suggestion) }
            },
            onProviderChange: { [weak self] provider, detail in
                guard let self else { return }
                sessionLog.notice("""
                copilot provider is now \(provider.rawValue, privacy: .public)\
                \(detail.map { " (\($0))" } ?? "", privacy: .public)
                """)
                Task { await self.writeStatus() }
            })

        // Warmed up *alongside* the call, never in front of it.
        //
        // Booting the local language server and opening its conversation measured
        // 5.91s. Awaiting that here delayed the socket, the microphone and the
        // screen capture with it — so a call took six seconds to start and the
        // opening seconds of the meeting went unrecorded. It is only an
        // optimisation: if a statement completes first, `AgyProvider` opens the
        // conversation on demand.
        Task { [advisor] in await advisor.prepare() }

        await socket.setHandlers(
            onSuggestion: { [weak self] suggestion in
                guard let self else { return }
                Task { await self.handleGateway(suggestion: suggestion) }
            },
            onClose: { [weak self] in
                guard let self else { return }
                Task { await self.writeStatus() }
            })

        await socket.connect()
        try await socket.startCall(
            callID: config.callID,
            persona: config.persona,
            startedAt: startedAt,
            profile: config.profile)

        // A record of what this call was, so History can list it after the
        // status file is gone. Written once — nothing in it changes.
        writeCallMetadata()

        // The segmenter's idle and request-floor rules are time-based: without a
        // tick, a sentence someone trailed off from would sit in the buffer until
        // the next turn happened to arrive.
        advisorTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                await self.advisor.tick()
            }
        }

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

        // Unhook the callbacks before tearing anything down. Both fire on their
        // own dispatch queues and hop onto this actor; a buffer that lands
        // mid-teardown puts the concurrency runtime through an isolation check
        // that traps (SIGTRAP in `dispatch_assert_queue_fail`), which turned an
        // otherwise clean end-of-call into a crash report. Stopping the flow
        // first makes that race unreachable rather than unlikely.
        microphone.onSamples = nil
        microphone.onLevel = nil
        systemAudio.onSamples = nil

        microphone.stop()
        await systemAudio.stop()
        micActive = false
        systemActive = false

        // Emit whatever was mid-sentence when the call ended, then let the
        // queue drain before tearing the engine down.
        micLeg.flush()
        systemLeg.flush()
        await transcriber.drain()

        advisorTicker?.cancel()
        advisorTicker = nil

        // One deeper pass now that latency no longer matters. Whatever it returns
        // goes through the same handoff as a live suggestion, so History and the
        // panel need no special case.
        let turnsSeen = await advisor.turnsSeen
        let statements = await advisor.statementsEmitted
        let ratio = await advisor.segmentationRatio()
        sessionLog.notice("""
        segmentation: \(turnsSeen, privacy: .public) turns -> \
        \(statements, privacy: .public) statements \
        (ratio \(ratio, format: .fixed(precision: 2), privacy: .public))
        """)
        if let summary = await advisor.summarise() {
            await handle(suggestion: summary)
        }
        await advisor.shutdown()

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
            // Stamped here rather than inside the transcriber: this callback
            // fires the instant the detector endpoints, so it is the last point
            // that is still free of queueing.
            let endpointedAt = Date()
            Task {
                await self.transcriber.enqueue(
                    samples: samples,
                    source: source,
                    startSeconds: start,
                    endpointedAt: endpointedAt)
            }
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
        if isSpeakerEcho(turn) {
            echoedTurns += 1
            sessionLog.debug("dropped echo of a them turn: \(turn.text, privacy: .private)")
            return
        }
        remember(turn)

        turnCount += 1
        archive.record(turn: turn)
        // The local brain is asked about complete statements, not every phrase the
        // VAD closes. The gateway still gets every turn below, because it batches
        // on its own side and must be able to take over instantly.
        await advisor.ingest(turn: turn)
        do {
            let sendStart = Date()
            try await socket.send(turn: turn, callID: config.callID)
            sentAt[turn.seq] = Date()
            sessionLog.notice(
                "timing turn \(turn.seq, privacy: .public): send \(Date().timeIntervalSince(sendStart) * 1000, format: .fixed(precision: 0), privacy: .public)ms")
        } catch {
            // The archive already has it; a dropped frame costs a suggestion,
            // not the transcript.
            sessionLog.error("turn \(turn.seq, privacy: .public) not delivered: \(error.localizedDescription, privacy: .public)")
        }
        await writeStatus()
    }

    // MARK: - Speaker echo

    /// Recent turns, newest last, used only for echo matching.
    private var recentTurns: [CallTurn] = []
    private var echoedTurns = 0

    /// How far apart the two copies of one utterance can land.
    ///
    /// The legs are endpointed independently, so the same sentence surfaces on
    /// each within a few hundred milliseconds — but a slow transcription can
    /// stretch that, and the window has to cover the gap without reaching so
    /// far that a genuine "yes, exactly" reply to the other party is mistaken
    /// for an echo of it.
    /// Measured against real captures: 4s catches 39% of turns as echoes, 6s
    /// catches 41%, 8s catches nothing further. Perfect suppression would be
    /// near 50%, since every utterance arrives twice.
    private static let echoWindow: Double = 6

    /// True when this is our microphone hearing the speakers rather than a
    /// person.
    ///
    /// Without headphones the microphone picks up the other party's voice, and
    /// it is transcribed a second time as if it were you — so the transcript
    /// doubles, the two-sided layout stops meaning anything, and the model is
    /// handed a conversation where every line is said twice by alternating
    /// speakers. Only `me` is ever dropped: system audio cannot contain your
    /// own voice, so a `them` turn is never an echo of a `me` one.
    private func isSpeakerEcho(_ turn: CallTurn) -> Bool {
        guard turn.source == .me else { return false }
        let candidate = Self.echoKey(turn.text)
        guard !candidate.isEmpty else { return false }

        // A very short utterance landing on top of the other party is echo in
        // all but name. The two legs hear the same words through different
        // paths and whisper renders them differently — "full stop" against
        // "all stop" — which no text comparison should be asked to reconcile.
        // Nothing is lost by being strict here: your own short interjections
        // never trigger a suggestion anyway, since only the other party's turns
        // do.
        let words = candidate.split(separator: " ").count
        if words <= 3, recentTurns.contains(where: { other in
            other.source == .them && abs(other.t0 - turn.t0) <= 2
        }) {
            return true
        }

        return recentTurns.contains { other in
            guard other.source == .them else { return false }
            guard abs(other.t0 - turn.t0) <= Self.echoWindow else { return false }
            return Self.isEcho(candidate, of: Self.echoKey(other.text))
        }
    }

    private func remember(_ turn: CallTurn) {
        recentTurns.append(turn)
        // Only the last few seconds can match, so the buffer stays tiny.
        let cutoff = turn.t0 - Self.echoWindow
        recentTurns.removeAll { $0.t0 < cutoff }
        if recentTurns.count > 24 { recentTurns.removeFirst(recentTurns.count - 24) }
    }

    /// Normalised for comparison: the two legs hear the same words through
    /// different paths, so punctuation, case and spacing all differ.
    static func echoKey(_ text: String) -> String {
        text.lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// One is an echo of the other when either is contained in the other, or
    /// they share most of their words.
    ///
    /// Containment matters as much as similarity: the legs endpoint at
    /// different moments, so one copy is regularly a prefix or a fragment of
    /// the other ("then" against "then other people aren't obstacles").
    static func isEcho(_ candidate: String, of other: String) -> Bool {
        guard !candidate.isEmpty, !other.isEmpty else { return false }
        if candidate == other { return true }

        let shorter = candidate.count <= other.count ? candidate : other
        let longer = candidate.count <= other.count ? other : candidate
        // A fragment is only convincing when it is a real phrase; two words in
        // common happens by chance all through a conversation.
        if shorter.count >= 8, longer.contains(shorter) { return true }

        let candidateWords = Set(candidate.split(separator: " "))
        let otherWords = Set(other.split(separator: " "))
        guard candidateWords.count >= 3, otherWords.count >= 3 else { return false }
        let shared = candidateWords.intersection(otherWords).count
        let smallest = min(candidateWords.count, otherWords.count)
        return Double(shared) / Double(smallest) >= 0.7
    }

    /// When each turn reached the gateway, so a suggestion can be priced
    /// against the turn it answers. Only the tail is kept; a long call would
    /// otherwise grow this without bound.
    private var sentAt: [Int: Date] = [:]

    /// A suggestion the gateway pushed on its own.
    ///
    /// Suppressed while the local brain is answering: both are fed the same call,
    /// and letting both write to one panel makes it flicker between two opinions.
    /// The gateway keeps receiving turns regardless, so it can take over the
    /// instant the local brain stands down.
    private func handleGateway(suggestion: CopilotFrame.Suggestion) async {
        guard await advisor.acceptsGatewaySuggestion() else { return }
        await handle(suggestion: suggestion)
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

        // The gateway's own `latency_ms` is its model call and nothing else.
        // The observed figure adds its debounce and both network legs, and is
        // the one that decides whether a pointer is still worth reading by the
        // time it appears. Neither includes the app's status poll, which is
        // measured on the other side of the XPC boundary.
        let observed = sentAt[suggestion.afterSeq].map { Date().timeIntervalSince($0) * 1000 }
        sessionLog.notice(
            """
            timing suggestion after seq \(suggestion.afterSeq, privacy: .public): \
            gateway \(suggestion.latencyMs, privacy: .public)ms, \
            observed \(observed ?? -1, format: .fixed(precision: 0), privacy: .public)ms
            """)
        if sentAt.count > 64 {
            let cutoff = suggestion.afterSeq - 32
            sentAt = sentAt.filter { $0.key >= cutoff }
        }
    }

    private func writeStatus() async {
        let status = ActiveCallStatus(
            callID: config.callID,
            persona: config.persona,
            startedAt: startedAt,
            turnCount: turnCount,
            gatewayConnected: await socket.connected,
            micActive: micActive,
            systemAudioActive: systemActive,
            provider: await advisor.activeProvider.rawValue,
            providerDetail: await advisor.providerDetail)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(status) else { return }
        try? CallHostPaths.writeAtomically(data, to: CallHostPaths.activeCallFile)
    }

    /// The same shape as the live status file, parked inside the call's own
    /// directory so a finished call still knows when it started and what
    /// persona it ran as. `active-call.json` is deleted on exit; this is not.
    private func writeCallMetadata() {
        let status = ActiveCallStatus(
            callID: config.callID,
            persona: config.persona,
            startedAt: startedAt,
            turnCount: 0,
            gatewayConnected: false,
            micActive: micActive,
            systemAudioActive: systemActive)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(status) else { return }
        try? CallHostPaths.writeAtomically(
            data, to: CallHostPaths.callMetadataFile(for: config.callID))
    }
}
