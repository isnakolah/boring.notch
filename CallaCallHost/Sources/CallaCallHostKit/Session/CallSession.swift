import Foundation
import CallaContracts
import IntelligenceCore
import IntelligenceStore
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
    /// Written by the engine to tell a prewarmed host to start recording.
    ///
    /// A file rather than a socket because there is no live command channel to a
    /// running host — the engine spawns it with argv plus a stdin blob and then
    /// only ever reads status files back. Adding a socket server for one boolean
    /// would be a second IPC mechanism to keep correct; the host already wakes
    /// every 250ms for the segmenter, so noticing a file costs nothing.
    public static var prewarmReleaseFile: URL { root.appendingPathComponent("prewarm-release.json") }
    /// Knowledge and call history. One file, WAL mode, written by the host and
    /// read by the engine on behalf of the sandboxed app.
    public static var storeFile: URL { root.appendingPathComponent("calla.sqlite") }
    /// The user's editable copy of the prompt pack. Any file present here wins
    /// over the bundled one; anything absent falls through to the bundle, so a
    /// partial copy is a supported state rather than a broken one.
    public static var promptsDirectory: URL {
        root.appendingPathComponent("prompts", isDirectory: true)
    }

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
    /// What this particular call is about: notes the user attached to the
    /// meeting, the event's own fields, and what the last occurrence concluded.
    ///
    /// Composed by the engine, not here and not by the app. The app is sandboxed
    /// and cannot open the store; the engine can, and it is the only process that
    /// sees both the meeting identity the app sends and the knowledge base the
    /// host will need.
    public var knowledge: String?
    /// Which meeting this is. Carried separately from `knowledge` because it is
    /// structured — the call row is keyed on it, so history can link back to the
    /// calendar event and the end-of-call summary knows what to file itself under.
    public var meeting: MeetingContext?

    enum CodingKeys: String, CodingKey {
        case about, knowledge, meeting
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
    /// Who is speaking right now — `me`, `them`, or nobody. Taken from the last
    /// transcribed turn, so it means "was understood" rather than "made a noise".
    public var speaking: String?
    /// A request is in flight. The one state the panel cannot infer for itself: a
    /// copilot thinking and a copilot with nothing to say look identical.
    public var thinking: Bool = false
    /// Which job is in flight: `answer` or `summary`. They take different lengths of
    /// time, so naming them stops the slower one reading as a stall.
    public var working: String?
    /// Independent live lanes. Both may be true at once.
    public var questionWorking: Bool = false
    public var summaryWorking: Bool = false
    /// The newest pointer answers a question that was actually asked, rather than
    /// remarking on a statement.
    public var answering: Bool = false
    /// Warm, but deliberately not recording: the pre-roll before a scheduled
    /// meeting. `mic_active` and `system_audio_active` are both false while this
    /// is true, and the notch says so.
    public var prewarming: Bool = false
    /// The meeting this call was armed for, so the pre-roll card has a title.
    public var meetingTitle: String?
    public var meetingStartsAt: Date?
    /// V2 lifecycle envelope. Legacy readers ignore this and retain the fields
    /// above until their next host update.
    public var lifecycle: CallLifecycleSnapshot?

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case persona
        case startedAt = "started_at"
        case turnCount = "turn_count"
        case gatewayConnected = "gateway_connected"
        case micActive = "mic_active"
        case systemAudioActive = "system_audio_active"
        case provider, speaking, thinking, answering, working, prewarming
        case questionWorking = "question_working"
        case summaryWorking = "summary_working"
        case providerDetail = "provider_detail"
        case meetingTitle = "meeting_title"
        case meetingStartsAt = "meeting_starts_at"
        case lifecycle
    }
}

/// The status file a host writes before it has a session to write one from.
///
/// `CallSession` publishes `active-call.json` on every state change, but it does
/// not exist until the model is loaded and the store is open — and the engine
/// reports a call as running only once that file names the current generation.
/// So the first seconds of every call were invisible: the process was alive, the
/// button had worked, and nothing anywhere said so.
///
/// Deliberately a free function on the same file rather than a method: the whole
/// point is that it runs when there is no session.
public enum CallBootStatus {
    public static func write(
        callID: String,
        generation: Int,
        persona: String,
        prewarm: Bool,
        stage: CallStartupStage,
        standby: GatewayStandby
    ) {
        let status = ActiveCallStatus(
            callID: callID,
            // The real one, not a placeholder: anything reading this file reads
            // persona too, and a blank flash before the session's own first write
            // is a visible glitch for no reason.
            persona: persona,
            startedAt: Date(),
            turnCount: 0,
            gatewayConnected: false,
            micActive: false,
            systemAudioActive: false,
            prewarming: prewarm,
            lifecycle: CallLifecycleSnapshot(
                callID: callID,
                generation: generation,
                state: .starting,
                startup: CallStartupProgress(
                    stage: stage,
                    modelLoaded: false,
                    brainWarm: false,
                    gatewayWarm: standby == .off ? nil : false)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(status) else { return }
        try? CallHostPaths.ensureRoot()
        try? CallHostPaths.writeAtomically(data, to: CallHostPaths.activeCallFile)
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
        /// When the gateway socket is opened. Never blocks capture in any mode —
        /// see `GatewayStandby`.
        public var gatewayStandby: GatewayStandby
        public var liveTier: ModelTier
        /// Exact model for the end-of-call pass.
        public var summaryModel: String?
        /// Knowledge and call history. Nil in probes and tests, where the call is
        /// synthetic and there is nothing worth remembering about it.
        public var store: CallaStore?
        /// Warm everything but record nothing until told to.
        ///
        /// The two-minute pre-roll: the model loads, both `agy` lanes bootstrap
        /// and the knowledge is packed while the meeting has not started. The
        /// capture legs stay stopped until `beginCapture()`, so a copilot that
        /// booted early is not a copilot that recorded early.
        public var prewarm: Bool
        /// Engine-owned monotonically increasing run number. This makes a late
        /// event from a dead host unable to overwrite a newer call.
        public var generation: Int

        public init(
            callID: String = "call-\(UUID().uuidString.lowercased().prefix(16))",
            persona: String = "generic",
            gatewayURL: URL,
            model: WhisperModel = .smallEn,
            captureSystemAudio: Bool = true,
            profile: CallProfile? = nil,
            provider: CopilotAdvisor.Provider = .local,
            fallbackToGateway: Bool = true,
            gatewayStandby: GatewayStandby = .warm,
            liveTier: ModelTier = .balanced,
            summaryModel: String? = nil,
            store: CallaStore? = nil,
            prewarm: Bool = false,
            generation: Int = 0
        ) {
            self.callID = callID
            self.persona = persona
            self.gatewayURL = gatewayURL
            self.model = model
            self.captureSystemAudio = captureSystemAudio
            self.profile = profile
            self.provider = provider
            self.fallbackToGateway = fallbackToGateway
            // Resolved here rather than trusted from the caller, so no combination
            // of flags can produce a call that contradicts itself.
            //
            // A gateway that may never answer must not be kept warm on the side:
            // that was the shape that shipped every turn off the Mac with fallback
            // switched off. `off` is the only honest reading of "no fallback".
            if provider == .gateway {
                // It is not standing by, it is the brain.
                self.gatewayStandby = .warm
            } else {
                self.gatewayStandby = fallbackToGateway ? gatewayStandby : .off
            }
            self.liveTier = liveTier
            self.summaryModel = summaryModel
            self.store = store
            self.prewarm = prewarm
            self.generation = max(0, generation)
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
    private var lastTurnSource: TurnSource?
    private var lastTurnAt: Date?
    private var micActive = false
    private var systemActive = false
    private var stopped = false
    private var lifecycleState: CallLifecycleState
    private var lifecycleError: String?
    private var recapProgress: Double?

    /// The startup checklist the live panel draws. Kept as state rather than
    /// derived, because "the model is loaded" and "the brain is warm" become true
    /// on different tasks at different times and neither is inferable from the
    /// capture flags.
    private var startup = CallStartupProgress()
    /// Opening the gateway, if this call opens one at all. Held so a failover that
    /// arrives while the background connect is still in flight waits for it rather
    /// than starting a second one.
    private var gatewayOpen: Task<Void, Never>?
    /// The tail of the transcript, newest last.
    ///
    /// Two readers with different appetites. A gateway handover wants as much
    /// recent context as it can get — `backfillTurnLimit` turns — so its first
    /// suggestion is about this call rather than about one sentence. Echo
    /// matching wants only the last few seconds, and gets that by filtering on
    /// `echoWindow` when it looks rather than by the buffer being short.
    ///
    /// So the buffer is bounded by turns, not by time. It used to be pruned to
    /// `echoWindow` seconds, which is correct for echo and leaves a handover
    /// with almost nothing.
    private var recentTurns: [CallTurn] = []
    /// The tail of the gateway send chain, so turns reach the wire in `seq` order.
    private var gatewaySend: Task<Void, Never>?
    private static let backfillTurnLimit = 40

    public private(set) var latestSuggestion: CopilotFrame.Suggestion?

    public init(config: Configuration, modelURL: URL, speechGate: SileroVAD?) throws {
        self.config = config
        archive = try CallArchive(root: CallHostPaths.callsDirectory, callID: config.callID)
        transcriber = CallTranscriber(
            speechGate: speechGate,
            modelURL: modelURL,
            modelName: config.model.displayName,
            language: config.model.languageHint,
            vocabulary: Self.vocabulary(for: config.profile))
        socket = CopilotSocket(url: config.gatewayURL)
        advisor = CopilotAdvisor(config: .init(
            callID: config.callID,
            persona: config.persona,
            profile: config.profile,
            preferred: config.provider,
            fallbackToGateway: config.fallbackToGateway,
            liveTier: config.liveTier,
            summaryModel: config.summaryModel,
            runtimeRoot: CallHostPaths.root,
            store: config.store
        ))
        // Not `.ready` yet: nothing has been loaded and no microphone is open.
        // `start()` walks this forward, and the notch draws each step.
        lifecycleState = .starting
        startup = CallStartupProgress(
            stage: .launching,
            modelLoaded: false,
            brainWarm: false,
            // Nil means "not part of this call", which is a different claim from
            // "not connected yet" and is drawn differently.
            gatewayWarm: config.gatewayStandby == .off ? nil : false)
    }

    /// Brings the call up, shortest path to a live microphone first.
    ///
    /// The ordering here is the whole point. Everything that recording does not
    /// depend on — the gateway handshake, the call record, the store row, the
    /// local brain — now runs behind `beginCapture()` on its own task, and the
    /// only thing still awaited in front of it is the model, which transcription
    /// genuinely cannot start without. Measured before: 987ms between the gateway
    /// connect and the microphone opening, all of it a TLS handshake for a socket
    /// whose suggestions a local call discards.
    ///
    /// Each step publishes a status file as it lands, so the notch can draw the
    /// startup rather than showing an unchanged button until the whole thing is
    /// finished.
    public func start() async throws {
        try CallHostPaths.ensureRoot()

        await advance(stage: .model)
        try await transcriber.prepare()
        startup.modelLoaded = true

        await transcriber.setTurnHandler { [weak self] turn in
            guard let self else { return }
            Task { await self.handle(turn: turn) }
        }

        await advisor.setHandlers(
            onActivity: { [weak self] in
                guard let self else { return }
                Task { await self.writeStatus() }
            },
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
                Task { await self.handleProviderChange(to: provider) }
            })

        await socket.setHandlers(
            onSuggestion: { [weak self] suggestion in
                guard let self else { return }
                Task { await self.handleGateway(suggestion: suggestion) }
            },
            onClose: { [weak self] in
                guard let self else { return }
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
        Task { [weak self] in
            guard let self else { return }
            await self.advisor.prepare()
            await self.noteBrainWarm()
        }

        // The gateway, on the same terms as the brain: behind the microphone, on
        // its own task, and never awaited. `warm` is the mode that opens it here;
        // `onFailure` waits for `handleProviderChange`, and `off` never opens it.
        if config.gatewayStandby == .warm { openGateway() }

        // The segmenter's idle and request-floor rules are time-based: without a
        // tick, a sentence someone trailed off from would sit in the buffer until
        // the next turn happened to arrive.
        advisorTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                await self.advisor.tick()
                await self.checkPrewarmRelease()
            }
        }

        if config.prewarm {
            // The model is loaded, both `agy` lanes are opening and the knowledge
            // is packed. The two microphones are the only thing that has not
            // started, which is the whole point — the user is told the copilot is
            // ready and that nothing is being recorded, and both are true.
            lifecycleState = .prewarming
            await advance(stage: .listening)
            recordCallOnce()
            sessionLog.notice("call \(self.config.callID, privacy: .public) prewarmed; capture held")
            return
        }

        try await beginCapture()
        sessionLog.notice("call \(self.config.callID, privacy: .public) started")
    }

    /// The two pieces of bookkeeping a call owes the rest of the app: a metadata
    /// file History can read once `active-call.json` is gone, and a row in the
    /// store that a calendar event can be joined to.
    ///
    /// Both were awaited between the gateway handshake and the microphone. Neither
    /// has anything to do with recording, and the store write in particular is a
    /// disk round-trip on the one path where latency is visible, so both now run
    /// behind capture. Opened at start rather than at end so a call that crashes
    /// still leaves its turns attached to something.
    private var callRecorded = false
    private func recordCallOnce() {
        guard !callRecorded else { return }
        callRecorded = true
        let config = config
        let startedAt = startedAt
        let micActive = micActive
        let systemActive = systemActive
        Task { [weak self] in
            await self?.writeCallMetadata(micActive: micActive, systemActive: systemActive)
            guard let store = config.store else { return }
            let meeting = config.profile?.meeting
            try? await store.beginCall(CallRecord(
                id: config.callID,
                eventID: meeting?.eventID,
                seriesID: meeting?.seriesID,
                eventTitle: meeting?.title,
                eventStart: meeting?.startsAt,
                persona: config.persona,
                startedAt: startedAt,
                liveModel: config.model.name,
                provider: config.provider.rawValue))
        }
    }

    /// Opens the gateway socket without ever making the call wait for it.
    ///
    /// Idempotent and re-entrant: a failover arriving while the `warm` connect is
    /// still handshaking joins the existing task instead of opening a second
    /// socket. Failure is not fatal in any mode — a gateway that cannot be reached
    /// is a gateway that cannot take over, which the notch already has a way to say.
    private func openGateway() {
        guard config.gatewayStandby != .off, !stopped, gatewayOpen == nil else { return }
        gatewayOpen = Task { [weak self] in
            guard let self else { return }
            await self.connectGateway()
        }
    }

    private func connectGateway() async {
        await socket.connect()
        do {
            try await socket.startCall(
                callID: config.callID,
                persona: config.persona,
                startedAt: startedAt,
                profile: config.profile)
        } catch {
            sessionLog.error("gateway call_start failed: \(error.localizedDescription, privacy: .public)")
            startup.gatewayWarm = false
            await writeStatus()
            return
        }
        // Everything said before the socket existed, so a handover does not start
        // blind. In `warm` this is normally empty — the socket is up within a
        // second of the call — and after a failover it is the reason the gateway's
        // first suggestion is about this call rather than about one turn.
        let backfill = recentTurns
        for turn in backfill {
            try? await socket.send(turn: turn, callID: config.callID)
        }
        if !backfill.isEmpty {
            sessionLog.notice("backfilled \(backfill.count, privacy: .public) turn(s) to the gateway")
        }
        startup.gatewayWarm = true
        await writeStatus()
    }

    /// A failover is the moment an `onFailure` gateway stops being hypothetical.
    private func handleProviderChange(to provider: CopilotAdvisor.Provider) async {
        if provider == .gateway, config.gatewayStandby == .onFailure {
            openGateway()
        }
        await writeStatus()
    }

    private func noteBrainWarm() async {
        startup.brainWarm = true
        await writeStatus()
    }

    /// Moves the startup checklist on and publishes it.
    private func advance(stage: CallStartupStage) async {
        startup.stage = stage
        await writeStatus()
    }

    /// Starts the two capture legs. This is the moment recording begins.
    ///
    /// Split out of `start()` so the pre-roll can pay every other cost early and
    /// leave exactly this until the user presses Join. Idempotent: a release file
    /// that is noticed twice must not open a second microphone.
    public func beginCapture() async throws {
        guard !capturing, !stopped else { return }
        capturing = true
        lifecycleState = .capturing
        await advance(stage: .capture)

        // A prewarmed host may have been sitting for minutes; nothing it heard
        // before capture began is a reference for anything said after.
        echoReference.reset()

        wireMicrophone()
        try microphone.start()
        micActive = true

        if config.captureSystemAudio {
            // Whole display, deliberately.
            //
            // Narrowing to a bundle-id allowlist was meant to keep music out of
            // the other party's transcript. What it actually does is decide, from
            // a hard-coded list, whether a call is captured at all — and the
            // list is wrong by construction: the audio may come from a helper
            // process, a browser tab in a browser nobody listed, or an app that
            // shipped after the list did. When it misses, the `them` leg is
            // silent and the whole feature is dead with no error anywhere.
            //
            // A stray song in the transcript is a bad line. A missed meeting is
            // the product not working. The filter stays available on the
            // recorder for a caller that can be certain, and the session is not
            // that caller.
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

        // Recording, so the checklist is done — whatever the brain and the gateway
        // are still doing, which the panel keeps drawing on their own rows.
        await advance(stage: .listening)
        // Deliberately after capture: this is the first point where the metadata
        // file can record which legs actually came up.
        recordCallOnce()
    }

    /// Current sanitized state for private control replies and recovery status.
    public func lifecycleSnapshot() async -> CallLifecycleSnapshot {
        CallLifecycleSnapshot(
            callID: config.callID,
            generation: config.generation,
            state: lifecycleState,
            actionableError: lifecycleError,
            capture: .init(microphone: micActive, systemAudio: systemActive,
                           detail: systemActive || !config.captureSystemAudio ? nil : "System audio unavailable"),
            provider: await advisor.activeProvider.rawValue,
            recapProgress: recapProgress,
            startup: lifecycleState == .starting || lifecycleState == .prewarming
                || startup.stage != .listening || !startup.brainWarm
                ? startup
                : nil)
    }

    public func answerSelectedText(_ text: String) async {
        await advisor.askManual(text)
        await writeStatus()
    }

    /// Whether the capture legs are running. Distinct from `micActive`, which
    /// reports whether the microphone in particular came up.
    public private(set) var capturing = false

    /// True while the host is warm but deliberately not recording.
    public var isPrewarming: Bool { config.prewarm && !capturing && !stopped }

    /// Promotes a prewarmed call to a recording one when the engine says so.
    ///
    /// The file is consumed rather than merely read: leaving it in place would
    /// start the *next* prewarmed call the instant it began polling, which is the
    /// one failure mode that would record a meeting nobody agreed to.
    private func checkPrewarmRelease() async {
        guard isPrewarming else { return }
        let marker = CallHostPaths.prewarmReleaseFile
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        // Only ours. The engine stamps the call id so a marker left behind by a
        // host that died cannot release an unrelated call later.
        let released = (try? Data(contentsOf: marker))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?["call_id"]
        guard released == nil || released == config.callID else { return }
        CallHostPaths.remove(marker)
        sessionLog.notice("prewarm released; capture starting for \(self.config.callID, privacy: .public)")
        do {
            try await beginCapture()
        } catch {
            sessionLog.error("capture failed to start after prewarm: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        lifecycleState = .stopping
        await writeStatus()

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
        lifecycleState = .processingRecap
        recapProgress = 0.2
        await writeStatus()
        if let summary = await advisor.summarise() {
            await handle(suggestion: summary)
        }
        recapProgress = 0.75
        await writeStatus()

        // The account outlives the process here, and nowhere else.
        //
        // Everything the advisor holds dies with the host, which is why a
        // recurring meeting used to start from nothing every week. Filed against
        // the *series* when there is one, so next Tuesday's standup retrieves last
        // Tuesday's conclusions; a call with no meeting is still recorded, but has
        // nothing to be filed under and is not indexed.
        if let store = config.store {
            let account = await advisor.durableSummary()
            try? await store.endCall(id: config.callID)
            // V2 deliberately leaves recap knowledge unfiled. This is a durable,
            // user-reviewable draft; only Store.approve may index it for later
            // meetings. Legacy `call_summary` stays untouched.
            let endSeq = max(1, turnCount)
            // The deep pass's own words first. `ledger.standing` is only ever
            // written by a *fold*, which needs more than twelve accumulated
            // points, so a call that ends before then had an empty overview —
            // which is what two of the first three recap drafts on this machine
            // actually look like. The expensive pass had already produced a good
            // paragraph and it was being thrown away.
            let closing = await advisor.closingSummary
            let overview = closing?.overview.isEmpty == false
                ? closing!.overview
                : account.standing
            let points = account.points.enumerated().map { index, text in
                SourcedCallItem(id: "point-\(index)", kind: Self.kind(of: text),
                                text: text, fromSeq: 1, toSeq: endSeq)
            }
            // The deep pass's open questions win when it produced any: it saw the
            // whole call at once, where the ledger's list is whatever survived
            // being carried forward chunk by chunk.
            let openQuestions = closing?.openQuestions.isEmpty == false
                ? closing!.openQuestions
                : account.openQuestions
            let questions = openQuestions.enumerated().map {
                SourcedCallItem(id: "question-\($0.offset)", kind: .openQuestion,
                                text: $0.element, fromSeq: 1, toSeq: endSeq)
            }
            let draft = CallRecapDraft(callID: config.callID, overview: overview,
                                       items: points + questions,
                                       provider: await advisor.activeProvider.rawValue,
                                       model: config.summaryModel)
            try? await store.save(recapDraft: draft)
        }

        await advisor.shutdown()

        // The last turns are on the send chain rather than already on the wire,
        // now that sending does not block the transcript. Let them land before
        // the call is closed under them.
        await gatewaySend?.value
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
        sessionLog.notice(
            "echo: \(self.acousticEchoCount.value, privacy: .public) dropped acoustically, \(self.echoedTurns, privacy: .public) by text")
        archive.close()
        await transcriber.stop()

        // The accurate transcript, produced now that nothing is waiting on it.
        //
        // The live pass is a small model on truncated context because a pointer
        // that arrives late is worthless; that tradeoff inverts the moment the
        // call ends. Measured on this machine: the live microphone leg scores
        // 68.8% word error against this pass. It has always existed as a manual
        // button almost nobody pressed, so History and every filed note rested on
        // the worse transcript.
        //
        // Detached, so ending a call never waits on it, and best-effort — a
        // failure leaves the live transcript exactly as it is today.
        scheduleArchivePass()

        lifecycleState = .finished
        recapProgress = 1
        await writeStatus()
        // `active-call.json` is transient. Preserve final lifecycle only in the
        // call's 0600 archive record for crash recovery and History.
        writeCallMetadata(micActive: micActive, systemActive: systemActive)
        CallHostPaths.remove(CallHostPaths.activeCallFile)
        sessionLog.notice("call \(self.config.callID, privacy: .public) ended after \(self.turnCount, privacy: .public) turns")
    }

    // MARK: - Internal

    private nonisolated func wire(leg: CaptureLeg) {
        leg.onSamples = { [weak self] samples, source in
            guard let self else { return }
            self.archive.append(samples: samples, source: source)
            // The reference the echo test correlates against. Fed from the raw
            // stream rather than from endpointed utterances, because the mic may
            // hear a stretch the system leg's own detector never called speech.
            if source == .them {
                self.echoReference.append(systemSamples: samples)
            }
        }
        leg.onUtterance = { [weak self] samples, start, source in
            guard let self else { return }
            // Stamped here rather than inside the transcriber: this callback
            // fires the instant the detector endpoints, so it is the last point
            // that is still free of queueing.
            let endpointedAt = Date()

            // Echo is decided on the audio, before any inference is spent on it.
            // Comparing the two transcripts afterwards — which is what this used
            // to do, and still does as a last resort — cannot reconcile two
            // whisper renderings of one sound, and could not run at all in the
            // common case where the microphone leg publishes first.
            if source == .me {
                let verdict = self.echoReference.verdict(
                    forMicrophone: samples, endedAt: endpointedAt)
                if verdict.isEcho {
                    self.noteAcousticEcho(verdict)
                    return
                }
            }

            Task {
                await self.transcriber.enqueue(
                    samples: samples,
                    source: source,
                    startSeconds: start,
                    endpointedAt: endpointedAt)
            }
        }
    }

    /// Counted and logged rather than silent: the lag is the machine's own output
    /// latency and should be stable across a call, so a wandering one is the
    /// first sign the two capture clocks have drifted apart.
    private nonisolated func noteAcousticEcho(_ verdict: EchoReference.Verdict) {
        acousticEchoCount.increment()
        sessionLog.debug(
            """
            dropped speaker bleed: correlation \(verdict.correlation, format: .fixed(precision: 2), privacy: .public), \
            lag \(verdict.lagSeconds, format: .fixed(precision: 2), privacy: .public)s
            """)
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

    /// Who is speaking, judged from the last transcribed turn.
    ///
    /// Two seconds: long enough to survive the gap between phrases, short enough
    /// that the panel stops claiming someone is talking after they have stopped.
    private func currentSpeaker() -> String? {
        guard let last = lastTurnAt, Date().timeIntervalSince(last) < 2 else { return nil }
        return lastTurnSource?.rawValue
    }

    private func handle(turn: CallTurn) async {
        if isSpeakerEcho(turn) {
            echoedTurns += 1
            sessionLog.debug("dropped echo of a them turn: \(turn.text, privacy: .private)")
            return
        }
        remember(turn)
        lastTurnSource = turn.source
        lastTurnAt = Date()

        turnCount += 1
        archive.record(turn: turn)
        if let store = config.store {
            try? await store.record(
                turn: StoredTurn(
                    seq: turn.seq, source: turn.source.rawValue,
                    t0: turn.t0, t1: turn.t1, text: turn.text,
                    confidence: turn.confidence),
                callID: config.callID)
        }
        // The local brain is asked about complete statements, not every phrase the
        // VAD closes. The gateway gets every turn, because it batches on its own
        // side and must be able to take over instantly.
        await advisor.ingest(turn: turn)
        keepForBackfill(turn)
        sendToGateway(turn)
        await writeStatus()
    }

    /// Keeps the tail of the transcript for a gateway that is not connected yet.
    ///
    /// Only worth holding while there is a socket that might still open. Once one
    /// is up it has had every turn since, and in `off` there is nothing to hand to.
    private func keepForBackfill(_ turn: CallTurn) {
        guard config.gatewayStandby == .onFailure, gatewayOpen == nil else { return }
        recentTurns.append(turn)
        if recentTurns.count > Self.backfillTurnLimit {
            recentTurns.removeFirst(recentTurns.count - Self.backfillTurnLimit)
        }
    }

    /// Hands a turn to the gateway without making the transcript wait for it.
    ///
    /// Was `try await socket.send(...)` inline, which put a network write on the
    /// path between whisper finishing an utterance and the notch being told about
    /// it — on a healthy socket that is a few milliseconds, and on a stalled one
    /// it is the whole turn pipeline. The archive and the store already have the
    /// turn by this point, so a dropped frame costs a gateway suggestion and
    /// nothing else.
    private func sendToGateway(_ turn: CallTurn) {
        guard config.gatewayStandby != .off, gatewayOpen != nil else { return }
        // Chained, not merely detached.
        //
        // Independent tasks would each await the open and then race each other to
        // the socket, so turn 5 could arrive before turn 4 — and `seq` is what the
        // gateway batches and answers on. Linking each send to the previous one
        // keeps the wire order that the inline `await` used to give for free,
        // while still keeping all of it off the transcript's path.
        let previous = gatewaySend
        gatewaySend = Task { [weak self] in
            guard let self else { return }
            await self.gatewayOpen?.value
            await previous?.value
            await self.deliver(turn)
        }
    }

    private func deliver(_ turn: CallTurn) async {
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
    }

    /// Kicks off the archive re-transcription after the call.
    ///
    /// Only when there is audio to work with and a store to put it in. The model
    /// is 1.6GB and is fetched on demand, so the first call on a new Mac simply
    /// does not get one — which is the right failure: it costs accuracy in
    /// History, never the call itself.
    private func scheduleArchivePass() {
        guard config.store != nil else { return }
        let directory = archive.directory
        let hasAudio = TurnSource.allCases.contains { source in
            let url = directory.appendingPathComponent(source == .me ? "mic.wav" : "system.wav")
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                as? NSNumber)??.intValue ?? 0
            // Header only means nothing was captured.
            return size > 8192
        }
        guard hasAudio else { return }

        let store = config.store
        let callID = config.callID
        Task.detached(priority: .background) {
            let model = WhisperModel.largeV3Turbo
            let models = ModelStore(directory: CallHostPaths.modelsDirectory)
            guard models.isInstalled(model) else {
                sessionLog.notice(
                    "skipping the archive pass for \(callID, privacy: .public): \(model.name, privacy: .public) is not installed")
                return
            }
            do {
                let modelURL = models.localURL(for: model)
                // Best-effort: without the CoreML encoder this is slower, not
                // broken, and nothing is waiting.
                await models.ensureCoreML(model)
                let result = try await ArchiveTranscriber.retranscribe(
                    callDirectory: directory,
                    modelURL: modelURL,
                    modelName: model.displayName,
                    language: model.languageHint,
                    store: store)
                sessionLog.notice(
                    "archive pass for \(callID, privacy: .public): \(result.turns, privacy: .public) turns in \(result.duration, format: .fixed(precision: 1), privacy: .public)s")
            } catch {
                sessionLog.error(
                    "archive pass for \(callID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The names this call is about, for the decoder.
    ///
    /// Attendees first: a participant list is the single most valuable thing to
    /// bias toward, because a name is exactly what a general model has no way to
    /// guess and exactly what is most jarring to get wrong on screen. Then the
    /// meeting title, then whatever proper nouns the user's own profile and
    /// knowledge block contain.
    static func vocabulary(for profile: CallProfile?) -> [String] {
        guard let profile else { return [] }
        var terms: [String] = []
        if let meeting = profile.meeting {
            // An attendee may be an email address; the local part is usually the
            // name and the domain is usually the company, and both are worth
            // biasing toward.
            for attendee in meeting.attendees {
                terms.append(contentsOf: Self.nameParts(of: attendee))
            }
            if let title = meeting.title {
                terms.append(contentsOf: DecodingContext.terms(fromProfileText: title))
            }
        }
        terms.append(contentsOf: DecodingContext.terms(fromProfileText: profile.about ?? ""))
        terms.append(contentsOf: DecodingContext.terms(fromProfileText: profile.knowledge ?? ""))
        return terms
    }

    /// Splits an attendee entry into the words worth biasing toward.
    static func nameParts(of attendee: String) -> [String] {
        let trimmed = attendee.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let atSign = trimmed.firstIndex(of: "@") else {
            return trimmed.split(separator: " ").map(String.init).filter { $0.count > 1 }
        }
        let local = trimmed[trimmed.startIndex..<atSign]
        let domain = trimmed[trimmed.index(after: atSign)...]
        var parts = local
            .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" || $0 == "+" })
            .map { $0.capitalized }
            .filter { $0.count > 1 }
        // "acme.com" -> "Acme". The public suffix is noise.
        if let company = domain.split(separator: ".").first, company.count > 1 {
            parts.append(company.capitalized)
        }
        return parts
    }

    /// What sort of item a recap line is.
    ///
    /// Every item ever written was stamped `actionItem`, including plain
    /// observations, so the four kinds the contract defines carried no
    /// information at all. This is a heuristic on the model's own wording rather
    /// than a second request: the lanes are already told to say when something
    /// was decided or promised, and the vocabulary they use to do it is narrow.
    static func kind(of text: String) -> SourcedCallItem.Kind {
        let lower = text.lowercased()
        if lower.hasSuffix("?") { return .openQuestion }
        for marker in ["will ", "to send", "to share", "owes", "by friday", "by monday",
                       "follow up", "follow-up", "action:", "next step"]
        where lower.contains(marker) {
            return .commitment
        }
        for marker in ["decided", "agreed", "settled on", "chose", "picked", "going with"]
        where lower.contains(marker) {
            return .decision
        }
        return .actionItem
    }

    // MARK: - Speaker echo

    /// Correlates the microphone against what the speakers were playing.
    ///
    /// `nonisolated let` because both capture callbacks touch it from their own
    /// queues; the type is internally locked.
    private nonisolated let echoReference = EchoReference()
    private nonisolated let acousticEchoCount = Counter()

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
        // Bounded by count so a handover has something to send. Echo matching
        // does its own time filtering, so the extra history costs it nothing.
        if recentTurns.count > Self.backfillTurnLimit {
            recentTurns.removeFirst(recentTurns.count - Self.backfillTurnLimit)
        }
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

    /// The part of a suggestion that makes it *different advice*, as opposed to
    /// the same advice with a refreshed account beneath it.
    private struct SuggestionIdentity: Equatable {
        let headline: String
        let angles: [String]
        let confirm: [String]

        init(_ suggestion: CopilotFrame.Suggestion) {
            headline = suggestion.headline
            angles = suggestion.angles
            confirm = suggestion.confirm
        }
    }

    private var lastStoredSuggestion: SuggestionIdentity?

    private func handle(suggestion: CopilotFrame.Suggestion) async {
        latestSuggestion = suggestion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(suggestion) else { return }
        if let line = String(data: data, encoding: .utf8) {
            archive.record(suggestionLine: line)
        }
        try? CallHostPaths.writeAtomically(data, to: CallHostPaths.latestSuggestionFile)
        // A pointer is republished every time the account behind it changes, so
        // the same advice is re-persisted many times over — 1,972 stored rows for
        // 814 distinct headlines across 54 calls, one of them written 34 times.
        // The panel wants every refresh; history wants the advice once.
        let identity = SuggestionIdentity(suggestion)
        if let store = config.store, identity != lastStoredSuggestion {
            lastStoredSuggestion = identity
            try? await store.record(
                suggestion: StoredSuggestion(
                    afterSeq: suggestion.afterSeq,
                    headline: suggestion.headline,
                    angles: suggestion.angles,
                    confirm: suggestion.confirm,
                    summary: suggestion.summary,
                    openQuestions: suggestion.openQuestions,
                    latencyMs: suggestion.latencyMs),
                callID: config.callID)
        }

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
        let lifecycle = await lifecycleSnapshot()
        let status = ActiveCallStatus(
            callID: config.callID,
            persona: config.persona,
            startedAt: startedAt,
            turnCount: turnCount,
            gatewayConnected: await socket.connected,
            micActive: micActive,
            systemAudioActive: systemActive,
            provider: await advisor.activeProvider.rawValue,
            providerDetail: await advisor.providerDetail,
            speaking: currentSpeaker(),
            thinking: await advisor.isThinking,
            working: await advisor.workingOn,
            questionWorking: await advisor.questionWorking,
            summaryWorking: await advisor.summaryWorking,
            answering: await advisor.lastAnswerWasToAQuestion,
            prewarming: isPrewarming,
            meetingTitle: config.profile?.meeting?.title,
            meetingStartsAt: config.profile?.meeting?.startsAt,
            lifecycle: lifecycle)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(status) else { return }
        try? CallHostPaths.writeAtomically(data, to: CallHostPaths.activeCallFile)
    }

    /// The same shape as the live status file, parked inside the call's own
    /// directory so a finished call still knows when it started and what
    /// persona it ran as. `active-call.json` is deleted on exit; this is not.
    /// `micActive` / `systemActive` are passed in rather than read off `self`.
    ///
    /// The caller hops onto a detached task to write this, and reading the
    /// actor's own state after that hop would report whatever is true when the
    /// write lands rather than what was true when the call started.
    private func writeCallMetadata(micActive: Bool, systemActive: Bool) {
        let status = ActiveCallStatus(
            callID: config.callID,
            persona: config.persona,
            startedAt: startedAt,
            turnCount: 0,
            gatewayConnected: false,
            micActive: micActive,
            systemAudioActive: systemActive,
            lifecycle: CallLifecycleSnapshot(
                callID: config.callID, generation: config.generation,
                state: config.prewarm ? .prewarming : .ready))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(status) else { return }
        try? CallHostPaths.writeAtomically(
            data, to: CallHostPaths.callMetadataFile(for: config.callID))
    }
}
