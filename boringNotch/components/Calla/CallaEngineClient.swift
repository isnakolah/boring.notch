import Foundation
import Defaults

@objc protocol BoringCallaEngineProtocol {
    func start(with reply: @escaping (Data) -> Void)
    func stop(with reply: @escaping (Data) -> Void)
    func applyPreferences(_ preferences: Data, with reply: @escaping (Data) -> Void)
    func status(with reply: @escaping (Data) -> Void)
    func requestGatewayUpdate(with reply: @escaping (Data) -> Void)
    func requestScreenRecording(with reply: @escaping (Data) -> Void)
    func requestAccessibility(with reply: @escaping (Data) -> Void)
    func startCourse(_ courseID: String, with reply: @escaping (Data) -> Void)
    func resumeCourse(with reply: @escaping (Data) -> Void)
    func stopLesson(with reply: @escaping (Data) -> Void)
    func ask(_ text: String, with reply: @escaping (Data) -> Void)
    func courseControl(_ command: Data, with reply: @escaping (Data) -> Void)
    func copilotControl(_ command: Data, with reply: @escaping (Data) -> Void)
    /// Turns newer than `seq`. Pass -1 for the whole tail.
    func copilotTranscript(since seq: Int, with reply: @escaping (Data) -> Void)
    func copilotCalls(with reply: @escaping (Data) -> Void)
    func copilotCallTranscript(_ callID: String, with reply: @escaping (Data) -> Void)
    /// What the copilot returned during that call.
    func copilotCallSuggestions(_ callID: String, with reply: @escaping (Data) -> Void)
    func requestCopilotPermissions(with reply: @escaping (Data) -> Void)
    func submitAgyToken(_ token: String, with reply: @escaping (Data) -> Void)
}

struct CallaEnginePreferences: Codable, Equatable {
    let captureEnabled: Bool
    let allowedBundleIDs: [String]
    let captureLongEdge: Int
    let tooltipWidth: Int
    let hideTooltipOnHover: Bool
    let cursorSize: Int
    let tooltipOpacity: Double
    let showStatusHUD: Bool
    let learnerID: String
    let hiddenCourseIDs: [String]

    static var current: CallaEnginePreferences {
        let learnerID = learnerIdentifier()
        return CallaEnginePreferences(
            captureEnabled: Defaults[.callaCaptureEnabled],
            allowedBundleIDs: Defaults[.callaAllowedBundleIDs],
            captureLongEdge: Defaults[.callaCaptureLongEdge],
            tooltipWidth: Defaults[.callaTooltipWidth],
            hideTooltipOnHover: Defaults[.callaHideTooltipOnHover],
            cursorSize: Defaults[.callaCursorSize],
            tooltipOpacity: Defaults[.callaTooltipOpacity],
            showStatusHUD: Defaults[.callaShowStatusHUD],
            learnerID: learnerID,
            hiddenCourseIDs: Defaults[.callaHiddenCourseIDs]
        )
    }

    private static func learnerIdentifier() -> String {
        let stored = Defaults[.callaLearnerID]
        if stored.range(of: "^[A-Za-z0-9-]{8,80}$", options: .regularExpression) != nil { return stored }
        let identifier = "learner-" + UUID().uuidString.lowercased()
        Defaults[.callaLearnerID] = identifier
        return identifier
    }
}

struct CallaEngineStatus: Codable, Equatable {
    var running = false
    /// Whether the Tutor host answers its socket, as opposed to whether the
    /// engine believes it started it.
    var hostReady = false
    var socketPath = ""
    var screenRecordingGranted = false
    var accessibilityGranted = false
    var gatewayReachable = false
    var nodeConnected = false
    var releaseVersion: String? = nil
    var previousGatewayRelease: String? = nil
    var lastGatewayUpdate: String? = nil
    var lastGatewayUpdateAt: Date? = nil
    var engineBuild: String? = nil
    var lastResult = "Engine not started"
    var diagnostics: [String] = []
    var activeLesson: CallaActiveLesson? = nil
    var courses: [CallaCourseSnapshot] = []
    var copilot = CallaCopilotStatus()
}

/// Live-call state, carried on the engine's existing status poll.
struct CallaCopilotStatus: Codable, Equatable {
    var available = false
    var running = false
    var callID: String? = nil
    var persona = "generic"
    var startedAt: Date? = nil
    var turnCount = 0
    var gatewayConnected = false
    var micActive = false
    var systemAudioActive = false
    var headline: String? = nil
    var angles: [String] = []
    var confirm: [String] = []
    /// Where the conversation has got to, refreshed on every reply. This is
    /// what the panel shows between questions.
    var summary: String? = nil
    /// Raised and unresolved, likeliest to come back to you first.
    var openQuestions: [String] = []
    var suggestionAfterSeq: Int? = nil
    /// Which brain answered this call: "local" or "gateway". Shown in the notch,
    /// because a failover the user cannot see looks exactly like a broken copilot.
    var activeProvider: String? = nil
    /// The model that answered, or why the local brain stood down.
    var providerDetail: String? = nil
    /// Whether the local Antigravity CLI is installed at all.
    var agyAvailable = false
    var agyVersion: String? = nil
    /// The call currently being re-transcribed, if any.
    var retranscribingCallID: String? = nil
    /// Whether a previous credential is set aside and can be put back.
    var agyBackupAvailable = false
    /// Where the sign-in has got to: `starting`, `opening_browser`,
    /// `awaiting_code`, `exchanging`, `signed_in`, `failed`.
    var agyLoginStage: String? = nil
    /// The Google sign-in URL while a sign-in is running.
    var agyLoginURL: String? = nil
    /// True exactly while agy is waiting for the authorization code.
    var agyAwaitingCode = false
    /// Whether `agy` has valid OAuth credentials on disk.
    var agyLoggedIn = false
    /// The Google account `agy` is authenticated as.
    var agyAccount: String? = nil
    var lastResult: String? = nil
    /// Reported by the capture host about itself. The engine used to preflight
    /// these in its own process, which answered a question nobody asked: TCC
    /// grants are keyed to the signature that captures, and that is the host.
    var hostMicGranted = false
    var hostScreenGranted = false
    /// False until the host has reported. Absent is not the same as denied —
    /// after a fresh install nothing has asked yet.
    var hostPermissionsKnown = false
    var modelDownload: CallaModelDownload? = nil

    var hasSuggestion: Bool {
        guard let headline else { return false }
        return !headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A sign-in is on screen and waiting for the user.
    ///
    /// True from the moment the link exists, because that is the moment `agy`
    /// starts accepting the code — and the moment the notch should be showing a
    /// field to paste it into.
    var isSigningIn: Bool {
        switch agyLoginStage {
        case "checking", "starting", "opening_browser", "awaiting_code", "exchanging": true
        // `failed` stays on screen so the reason can be read and retried.
        case "failed": true
        default: agyLoginURL != nil || agyAwaitingCode
        }
    }

    /// Whether to offer the code field.
    ///
    /// From the moment a link exists, not from a narrower "awaiting" flag: `agy`
    /// accepts the pasted code as soon as it prints the URL, and a field that is
    /// missing while the user is holding a code is the whole complaint.
    var canAcceptCode: Bool {
        agyLoginURL != nil || agyAwaitingCode || agyLoginStage == "exchanging"
    }
}

/// Progress of a transcription model fetch.
///
/// The first call on a new Mac blocks for minutes pulling ~487MB with no sign
/// that anything is happening; this is what makes that visible.
struct CallaModelDownload: Codable, Equatable {
    let model: String
    let receivedBytes: Int64
    let totalBytes: Int64
    /// `downloading`, `verifying`, `ready` or `failed`.
    let state: String
    let message: String?

    enum CodingKeys: String, CodingKey {
        case model, state, message
        case receivedBytes = "received_bytes"
        case totalBytes = "total_bytes"
    }

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }

    var isActive: Bool { state == "downloading" || state == "verifying" }
}

/// One transcribed turn, tagged with the side of the call it came from.
///
/// `source` is what makes the copilot possible at all: the two capture legs are
/// never mixed, so "who said this" is known rather than inferred.
struct CallaCallTurn: Codable, Equatable, Identifiable {
    let id: UUID
    let seq: Int
    let source: String
    let t0: Double
    let t1: Double
    let text: String

    var isRemote: Bool { source == "them" }
}

/// One suggestion as it was archived during a call.
///
/// Mirrors the engine's `CopilotSuggestionFile`. Kept so a finished call can show
/// what the copilot actually said, not only what was said to it.
struct CallaCopilotArchivedSuggestion: Codable, Equatable, Identifiable {
    let callID: String
    let afterSeq: Int
    let headline: String
    let angles: [String]
    let confirm: [String]
    let summary: String?
    let openQuestions: [String]?

    var id: Int { afterSeq }

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case afterSeq = "after_seq"
        case headline, angles, confirm, summary
        case openQuestions = "open_questions"
    }
}

/// Typed copilot command. Mirrors the engine's own decoder; the engine
/// re-validates every field before anything is spawned.
struct CallaCopilotCommand: Codable {
    let action: String
    let persona: String?
    let model: String?
    let callID: String?
    /// Prompt text the user edited. Never reaches a process argument — the
    /// engine hands it to the capture host on stdin.
    let profile: CallaCopilotProfile?
    /// "local" or "gateway". Absent leaves the engine's stored choice alone.
    let provider: String?
    /// Live model tier for the local brain: fast | balanced | deep.
    let tier: String?
    /// Exact model for the end-of-call pass.
    let summaryModel: String?
    /// Whether the gateway may answer when the local brain cannot.
    let fallback: Bool?
    /// Answer only when asked.
    let answersOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case action, persona, model, profile, provider, tier, fallback
        case answersOnly = "answers_only"
        case summaryModel = "summary_model"
        case callID = "call_id"
    }

    init(action: String,
         persona: String? = nil,
         model: String? = nil,
         callID: String? = nil,
         profile: CallaCopilotProfile? = nil,
         provider: String? = nil,
         tier: String? = nil,
         summaryModel: String? = nil,
         fallback: Bool? = nil,
         answersOnly: Bool? = nil) {
        self.action = action
        self.persona = persona
        self.model = model
        self.callID = callID
        self.profile = profile
        self.provider = provider
        self.tier = tier
        self.summaryModel = summaryModel
        self.fallback = fallback
        self.answersOnly = answersOnly
    }
}

/// The user's own prompt text, carried to the gateway on `call_start`.
///
/// Every field is free text, which is exactly why it is fenced off into its own
/// type: it is a prompt payload and nothing else, and the engine's validator
/// refuses to let any of it name a process or become a command-line argument.
struct CallaCopilotProfile: Codable, Equatable {
    /// Who the user is — role, company, product. Injected into every call.
    let about: String?
    /// Replaces the gateway's own persona block for the persona in play.
    let personaGuidance: String?
    /// Replaces the gateway's base guidance. Empty means "use the gateway's".
    let baseGuidance: String?

    enum CodingKeys: String, CodingKey {
        case about
        case personaGuidance = "persona_guidance"
        case baseGuidance = "base_guidance"
    }

    var isEmpty: Bool {
        [about, personaGuidance, baseGuidance]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .allSatisfy(\.isEmpty)
    }

    /// Reads the current settings into a profile, or nil when nothing is set.
    @MainActor
    static var current: CallaCopilotProfile? {
        let persona = Defaults[.callaCopilotPersona]
        let overrides = Defaults[.callaCopilotPersonaOverrides]
            .merging(Defaults[.callaCopilotCustomPersonas]) { override, _ in override }
        let profile = CallaCopilotProfile(
            about: nonEmpty(Defaults[.callaCopilotAboutMe]),
            personaGuidance: nonEmpty(overrides[persona] ?? ""),
            baseGuidance: nonEmpty(Defaults[.callaCopilotBaseGuidance]))
        return profile.isEmpty ? nil : profile
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One archived call, as listed in settings.
struct CallaCallSummary: Codable, Equatable, Identifiable {
    let id: String
    let startedAt: Date?
    let endedAt: Date?
    let turnCount: Int
    let persona: String
    /// Whether raw audio is still on disk, which is what re-transcribing needs.
    let hasAudio: Bool
    /// Whether the large model has been over this call.
    var retranscribed: Bool = false
    /// Turns in that better pass, so the improvement is visible.
    var archivedTurnCount: Int = 0
    /// How many suggestions the copilot returned. Zero against a full transcript is
    /// the case worth noticing.
    var suggestionCount: Int = 0

    enum CodingKeys: String, CodingKey {
        case id, persona, retranscribed
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case turnCount = "turn_count"
        case hasAudio = "has_audio"
        case archivedTurnCount = "archived_turn_count"
        case suggestionCount = "suggestion_count"
    }

    var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
}

struct CallaActiveLesson: Codable, Equatable {
    let courseID: String
    let lessonID: String
    let lessonTitle: String
    let active: Bool

    enum CodingKeys: String, CodingKey { case courseID = "course_id", lessonID = "lesson_id", lessonTitle = "lesson_title", active }
}

struct CallaLessonSnapshot: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let stepCount: Int
    let completed: Bool
    let dueForReview: Bool

    enum CodingKeys: String, CodingKey { case id, title, completed; case stepCount = "step_count", dueForReview = "due_for_review" }
}

struct CallaCourseSnapshot: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let summary: String
    let icon: String
    let targetApp: String?
    let hidden: Bool
    let completedCount: Int
    let dueForReview: Bool
    let checkpointLessonID: String?
    let recentThread: [String]
    let lifecyclePhase: String?
    let lifecycleNote: String?
    let runtimeVersion: String?
    let runtimeBlocked: Bool
    let lessons: [CallaLessonSnapshot]

    enum CodingKeys: String, CodingKey {
        case id, title, summary, icon, hidden, lessons
        case targetApp = "target_app", completedCount = "completed_count", dueForReview = "due_for_review"
        case checkpointLessonID = "checkpoint_lesson_id", recentThread = "recent_thread"
        case lifecyclePhase = "lifecycle_phase", lifecycleNote = "lifecycle_note"
        case runtimeVersion = "runtime_version", runtimeBlocked = "runtime_blocked"
    }

    var lessonCount: Int { lessons.count }
    var nextLesson: CallaLessonSnapshot? { lessons.first { !$0.completed } ?? lessons.first { $0.id == checkpointLessonID } ?? lessons.first }
}

struct CallaCourseCommand: Codable {
    let action: String
    let courseID: String?
    let lessonID: String?
    let outline: String?
    let assetBundlePath: String?
    let targetApp: String?
    let targetVersion: String?

    init(action: String, courseID: String? = nil, lessonID: String? = nil, outline: String? = nil,
         assetBundlePath: String? = nil, targetApp: String? = nil, targetVersion: String? = nil) {
        self.action = action; self.courseID = courseID; self.lessonID = lessonID; self.outline = outline
        self.assetBundlePath = assetBundlePath; self.targetApp = targetApp; self.targetVersion = targetVersion
    }

    enum CodingKeys: String, CodingKey {
        case action
        case courseID = "course_id", lessonID = "lesson_id", outline
        case assetBundlePath = "asset_bundle_path", targetApp = "target_app", targetVersion = "target_version"
    }
}

extension Notification.Name {
    /// Posted the moment a lesson goes live, from wherever it was started —
    /// notch, Settings, or the calendar binding.
    static let callaLessonDidStart = Notification.Name("callaLessonDidStart")
    /// Posted when the gateway pushes a new answer pointer during a live call.
    static let callaCopilotSuggestion = Notification.Name("callaCopilotSuggestion")
}

@MainActor
final class CallaEngineClient: ObservableObject {
    static let shared = CallaEngineClient()

    @Published private(set) var status = CallaEngineStatus()
    private var connection: NSXPCConnection?
    private var monitorTask: Task<Void, Never>?

    private init() {}

    func start() {
        invoke { $0.start(with: $1) }
    }

    /// A lesson can start without the notch being open, so status polling has
    /// to outlive the Tutor tab — otherwise nothing is watching to raise it.
    /// Status is read-only over XPC, so this never launches or mutates runtime.
    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                let teaching = self.status.activeLesson?.active == true
                // A sign-in is a handful of states that each last a second or two.
                // At the idle cadence the UI looks dead and a step can come and go
                // between polls, so it is worth the extra chatter while it lasts.
                let signingIn = self.status.copilot.isSigningIn
                let interval: Double = signingIn ? 0.5 : (teaching ? 2 : 4)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func stop() {
        invoke { $0.stop(with: $1) }
    }

    func applyCurrentPreferences() {
        guard let data = try? JSONEncoder().encode(Preferences.current) else { return }
        invoke { $0.applyPreferences(data, with: $1) }
    }

    /// Brings the engine and everything it started down, and waits for it.
    ///
    /// Called from `applicationWillTerminate`, where async is not good enough: the
    /// process is about to go away, and a fire-and-forget XPC message loses the race
    /// often enough to leave a call host holding the microphone. macOS allows a few
    /// seconds here, so a bounded wait is both safe and the point.
    func shutdownAndWait(timeout: TimeInterval = 2.5) {
        let done = DispatchSemaphore(value: 0)
        invoke { proxy, reply in
            proxy.stop(with: { data in
                reply(data)
                done.signal()
            })
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    func refresh() {
        // Status is read-only. Settings opens this path, so it must never
        // launch a runtime or mutate Gateway state as a side effect.
        invoke { $0.status(with: $1) }
    }

    func requestGatewayUpdate() {
        invoke { $0.requestGatewayUpdate(with: $1) }
    }

    func requestScreenRecording() {
        invoke { $0.requestScreenRecording(with: $1) }
    }

    func requestAccessibility() {
        invoke { $0.requestAccessibility(with: $1) }
    }

    func startCourse(_ courseID: String, completion: ((CallaEngineStatus) -> Void)? = nil) {
        invoke({ $0.startCourse(courseID, with: $1) }, completion: completion)
    }

    func startLesson(courseID: String, lessonID: String) {
        courseControl(.init(action: "start_lesson", courseID: courseID, lessonID: lessonID))
    }

    func startAgain(courseID: String) { courseControl(.init(action: "start_again", courseID: courseID)) }

    func courseControl(_ command: CallaCourseCommand) {
        guard let data = try? JSONEncoder().encode(command) else { return }
        invoke { $0.courseControl(data, with: $1) }
    }

    func resumeCourse() {
        invoke { $0.resumeCourse(with: $1) }
    }

    func stopLesson() {
        invoke { $0.stopLesson(with: $1) }
    }

    func ask(_ text: String) {
        invoke { $0.ask(text, with: $1) }
    }

    func reportLocalFailure(_ message: String) {
        status.lastResult = message
    }

    private func invoke(_ call: @escaping (BoringCallaEngineProtocol, @escaping (Data) -> Void) -> Void,
                        completion: ((CallaEngineStatus) -> Void)? = nil) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            NSLog("[CallaEngine] XPC unavailable: %@", error.localizedDescription)
            Task { @MainActor in
                self?.status.lastResult = "Engine unavailable: \(error.localizedDescription)"
                self?.status.running = false
            }
        }) as? BoringCallaEngineProtocol else { return }
        call(proxy) { [weak self] data in
            let result: CallaEngineStatus
            do {
                result = try JSONDecoder().decode(CallaEngineStatus.self, from: data)
            } catch {
                // This used to be `try?` with a bare `return`, so a status
                // struct that drifted from the engine's own copy dropped every
                // reply forever with no log and no visible change — the UI just
                // stayed on whatever it last showed. The two structs are still
                // hand-maintained in separate targets, so say so out loud.
                NSLog("[CallaEngine] undecodable status reply (%d bytes): %@",
                      data.count, String(describing: error))
                Task { @MainActor in
                    // Deliberately not clearing `running`: the engine may be
                    // perfectly healthy and only the encoding drifted, and
                    // asserting otherwise trades one wrong answer for another.
                    self?.status.lastResult = "Engine reply could not be read"
                }
                return
            }
            Task { @MainActor in
                self?.apply(result)
                completion?(result)
            }
        }
    }

    /// Every status path funnels through here so a lesson start is detected
    /// once, whether it arrived from polling or from a command's own reply.
    private func apply(_ result: CallaEngineStatus) {
        let previous = status.activeLesson
        let previousCopilot = status.copilot
        status = result

        // A new pointer is the one copilot event worth interrupting for. Keyed
        // on the turn it answers, so a poll that re-reads the same suggestion
        // does not re-open the notch every two seconds.
        let copilot = result.copilot
        if copilot.running, copilot.hasSuggestion,
           copilot.suggestionAfterSeq != previousCopilot.suggestionAfterSeq
            || copilot.callID != previousCopilot.callID {
            NotificationCenter.default.post(name: .callaCopilotSuggestion, object: nil)
        }

        guard let current = result.activeLesson, current.active else { return }
        guard previous?.active != true || previous?.lessonID != current.lessonID else { return }
        NotificationCenter.default.post(name: .callaLessonDidStart, object: nil)
    }

    // MARK: - Live call copilot

    func startCall(persona: String, model: String) {
        // Starting a call on the local brain without credentials used to mean a
        // browser popping open mid-meeting with nowhere to put the code. Sign in
        // first, and let the notch show the field.
        if Defaults[.callaIntelligenceProvider] == "local",
           status.copilot.agyAvailable,
           !status.copilot.agyLoggedIn
        {
            loginAgy()
            return
        }
        send(CallaCopilotCommand(
            action: "start",
            persona: persona,
            model: model,
            profile: CallaCopilotProfile.current,
            provider: Defaults[.callaIntelligenceProvider],
            tier: Defaults[.callaIntelligenceLiveTier],
            summaryModel: Defaults[.callaIntelligenceSummaryModel],
            fallback: Defaults[.callaIntelligenceFallback]))
    }

    /// Changes which brain answers. Takes effect on the next call: the capture
    /// host binds its provider at launch, so switching mid-call would report a
    /// change that did not happen. Automatic fallback is the only thing that swaps
    /// brains during a call.
    func setIntelligence(
        provider: String,
        tier: String? = nil,
        summaryModel: String? = nil,
        fallback: Bool? = nil
    ) {
        send(CallaCopilotCommand(
            action: "set_provider",
            provider: provider,
            tier: tier,
            summaryModel: summaryModel,
            fallback: fallback))
    }

    func endCall() {
        send(CallaCopilotCommand(action: "stop"))
    }

    func setCallPersona(_ persona: String) {
        send(CallaCopilotCommand(action: "set_persona", persona: persona))
    }

    private func send(_ command: CallaCopilotCommand) {
        guard let data = try? JSONEncoder().encode(command) else { return }
        invoke { proxy, reply in proxy.copilotControl(data, with: reply) }
    }

    /// Fetches the live call's turns.
    ///
    /// Deliberately not on the status poll: the transcript is large, and only
    /// the live panel wants it. Pass the newest `seq` already held to get back
    /// just what arrived since — the live panel polls sub-second, and re-reading
    /// the whole call at that rate is what made the old window feel slow.
    func fetchTranscript(since seq: Int? = nil, completion: @escaping ([CallaCallTurn]) -> Void) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            NSLog("[CallaEngine] transcript unavailable: %@", error.localizedDescription)
            Task { @MainActor in completion([]) }
        }) as? BoringCallaEngineProtocol else { return }
        proxy.copilotTranscript(since: seq ?? -1) { data in
            let turns = (try? JSONDecoder().decode([CallaCallTurn].self, from: data)) ?? []
            Task { @MainActor in completion(turns) }
        }
    }

    /// Lists the calls this Mac has archived, newest first.
    func fetchCalls(completion: @escaping ([CallaCallSummary]) -> Void) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            NSLog("[CallaEngine] call list unavailable: %@", error.localizedDescription)
            Task { @MainActor in completion([]) }
        }) as? BoringCallaEngineProtocol else { return }
        proxy.copilotCalls { data in
            let calls = (try? JSONDecoder().decode([CallaCallSummary].self, from: data)) ?? []
            Task { @MainActor in completion(calls) }
        }
    }

    /// Reads one archived call's transcript in full.
    /// What the copilot returned during a finished call.
    func fetchCallSuggestions(_ callID: String, completion: @escaping ([CallaCopilotArchivedSuggestion]) -> Void) {
        invoke { proxy, reply in
            proxy.copilotCallSuggestions(callID, with: { data in
                reply(data)
                let decoded = (try? JSONDecoder().decode([CallaCopilotArchivedSuggestion].self, from: data)) ?? []
                DispatchQueue.main.async { completion(decoded) }
            })
        }
    }

    func fetchCallTranscript(callID: String, completion: @escaping ([CallaCallTurn]) -> Void) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            NSLog("[CallaEngine] archive unavailable: %@", error.localizedDescription)
            Task { @MainActor in completion([]) }
        }) as? BoringCallaEngineProtocol else { return }
        proxy.copilotCallTranscript(callID) { data in
            let turns = (try? JSONDecoder().decode([CallaCallTurn].self, from: data)) ?? []
            Task { @MainActor in completion(turns) }
        }
    }

    /// Re-runs the large model over a finished call's saved audio.
    func retranscribe(callID: String) {
        send(CallaCopilotCommand(action: "archive", callID: callID))
    }

    /// Asks the capture host — not the engine — for microphone and screen
    /// recording. TCC keys a grant to the code signature that asks, so asking
    /// from here would prompt for the wrong process and grant nothing useful.
    func requestCopilotPermissions() {
        invoke { $0.requestCopilotPermissions(with: $1) }
    }

    /// Downloads a transcription model ahead of a call.
    func prefetchModel(_ model: String) {
        send(CallaCopilotCommand(action: "fetch_model", model: model))
    }

    /// Triggers the `agy` OAuth login flow through the engine.
    /// Starts `agy`'s Google sign-in.
    ///
    /// `force` replaces a credential that already exists — the case where Settings
    /// reports "signed in" but a call still cannot reach the model. Without it, a
    /// sign-in with valid-looking credentials on disk is a no-op, because running
    /// it anyway would spend a model call to learn what is already known.
    func loginAgy(force: Bool = false) {
        send(CallaCopilotCommand(action: "login", fallback: force))
    }

    /// Rehearses the sign-in against a throwaway `HOME`.
    ///
    /// While credentials are valid no real sign-in will start — correctly, since
    /// `agy` caches them — so this is the only way to watch the flow without
    /// signing out, and signing out is what broke things once already.
    func testSignInFlow() {
        send(CallaCopilotCommand(action: "test_login"))
    }

    /// Tells a running call whether to answer only when asked.
    ///
    /// The panel filters what it shows immediately; this is the half that changes
    /// what the copilot is *asked*, so an interview stops being narrated.
    func setAnswersOnly(_ answersOnly: Bool) {
        send(CallaCopilotCommand(action: "set_detail", answersOnly: answersOnly))
    }

    /// Clears the stored Google credential so the next sign-in starts fresh.
    ///
    /// Kept as a backup, and deliberately not auto-restored — see `restoreSignIn()`.
    func signOutAgy() {
        send(CallaCopilotCommand(action: "sign_out"))
    }

    /// Puts back the credential that `signOutAgy()` set aside.
    func restoreSignIn() {
        send(CallaCopilotCommand(action: "restore_login"))
    }

    /// Submits a token to a running `agy` login flow.
    func submitAgyToken(_ token: String) {
        invoke { $0.submitAgyToken(token, with: $1) }
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: "theboringteam.boringnotch.BoringCallaEngine")
        connection.remoteObjectInterface = NSXPCInterface(with: BoringCallaEngineProtocol.self)
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.status.running = false
            }
        }
        connection.resume()
        self.connection = connection
        return connection
    }
}

private typealias Preferences = CallaEnginePreferences
