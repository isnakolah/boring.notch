import Foundation
import Defaults

@objc protocol BoringCallaEngineStatusObserver {
    func callaEngineStatusDidChange(_ data: Data)
}

@objc protocol BoringCallaEngineProtocol {
    func start(with reply: @escaping (Data) -> Void)
    func stop(with reply: @escaping (Data) -> Void)
    func applyPreferences(_ preferences: Data, with reply: @escaping (Data) -> Void)
    func status(with reply: @escaping (Data) -> Void)
    func subscribeStatus(_ observer: BoringCallaEngineStatusObserver, with reply: @escaping (Data) -> Void)
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
    func copilotRecapDraft(_ callID: String, with reply: @escaping (Data) -> Void)
    func copilotRecapControl(_ command: Data, with reply: @escaping (Data) -> Void)
    /// The prompts the copilot would actually send, as `[path: text]`.
    func copilotPrompts(with reply: @escaping (Data) -> Void)
    func requestCopilotPermissions(with reply: @escaping (Data) -> Void)
    func submitAgyToken(_ token: String, with reply: @escaping (Data) -> Void)
    /// Create, edit, delete or list knowledge notes. Replies with the resulting
    /// list every time, because this app is sandboxed and cannot read the store
    /// to check what happened.
    func knowledgeControl(_ command: Data, with reply: @escaping (Data) -> Void)
    /// Calls recorded against a calendar event, or its whole recurring series.
    func copilotCallsForEvent(_ query: Data, with reply: @escaping (Data) -> Void)
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
    /// Who is speaking right now: `me`, `them`, or nobody.
    var speaking: String? = nil
    /// A request is in flight.
    var thinking = false
    /// Which job is in flight: `answer` or `summary`.
    var working: String? = nil
    var questionWorking = false
    var summaryWorking = false
    /// The newest pointer answers a question, rather than remarking on a statement.
    var answering = false
    /// Warm and ready, but deliberately not recording — the pre-roll before a
    /// scheduled meeting. `micActive` and `systemAudioActive` are both false while
    /// this is true, which is exactly the claim the pre-roll card makes.
    var prewarming = false
    /// A host process exists and is still paying its fixed costs — loading the
    /// model, opening the microphone. Never true at the same time as `running`.
    ///
    /// Before this existed the notch had nothing between "no call" and "call
    /// live", and the ~2s the host takes to come up was drawn as the former: the
    /// Start button sat there unchanged and the press read as lost.
    var starting = false
    /// Which fixed cost the host is on: `launching`, `permissions`, `model`,
    /// `capture`, `listening`.
    var startupStage: String? = nil
    var modelLoaded = false
    /// Both local lanes are open, so the next question is answered at
    /// conversation speed rather than paying the bootstrap.
    var brainWarm = false
    /// Nil when the gateway is not part of this call at all — standby off, or a
    /// local call that has not failed over. False means "not connected yet".
    var gatewayWarm: Bool? = nil
    /// The meeting this call was armed for.
    var meetingTitle: String? = nil
    var meetingStartsAt: Date? = nil

    /// A call that is actually capturing.
    ///
    /// `running` means only that a host process exists, which is also true
    /// throughout the pre-roll — so anything that draws "you are in a call" must
    /// ask this instead, or the notch will claim to be listening while both
    /// microphones are stopped.
    var isRecording: Bool { running && !prewarming }

    /// The end-of-call work, as the host reports it — or as this app claimed it
    /// the moment the button was pressed, whichever came first.
    var isFinishing: Bool {
        finishing
            || lifecycleState == CallLifecycleStateName.stopping
            || lifecycleState == CallLifecycleStateName.processingRecap
    }
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
    /// Where the host is in its own lifecycle: `capturing`, `stopping`,
    /// `processingRecap`, `finished`.
    var lifecycleState: String? = nil
    /// 0…1 while the recap is being written.
    var recapProgress: Double? = nil
    /// Capture has stopped and the call is being written up. The seconds this
    /// covers used to be invisible: `running` stayed true until the process
    /// exited, so End call changed nothing on screen and then the panel
    /// disappeared without explanation.
    var finishing = false

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

/// The lifecycle values the host writes. Named rather than spelled inline: the
/// host, the engine and this app each hold their own copy of the vocabulary, and
/// a typo in a string literal fails silently in exactly the place nobody looks.
enum CallLifecycleStateName {
    static let capturing = "capturing"
    static let stopping = "stopping"
    static let processingRecap = "processingRecap"
    static let finished = "finished"
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
    let question: String?
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
    /// When the gateway socket opens: off | on-failure | warm.
    let gatewayStandby: String?
    /// The calendar event this call is for.
    ///
    /// Only the identity and the event's own fields travel. The knowledge itself
    /// is composed by the engine, which is the only process that can open the
    /// store — this one is sandboxed and the file is not in its container.
    let meeting: CallaMeeting?

    enum CodingKeys: String, CodingKey {
        case action, persona, model, profile, provider, tier, fallback, meeting, question
        case summaryModel = "summary_model"
        case gatewayStandby = "gateway_standby"
        case callID = "call_id"
    }

    init(action: String,
         persona: String? = nil,
         model: String? = nil,
         callID: String? = nil,
         question: String? = nil,
         profile: CallaCopilotProfile? = nil,
         provider: String? = nil,
         tier: String? = nil,
         summaryModel: String? = nil,
         fallback: Bool? = nil,
         gatewayStandby: String? = nil,
         meeting: CallaMeeting? = nil) {
        self.action = action
        self.persona = persona
        self.model = model
        self.callID = callID
        self.question = question
        self.profile = profile
        self.provider = provider
        self.tier = tier
        self.summaryModel = summaryModel
        self.fallback = fallback
        self.gatewayStandby = gatewayStandby
        self.meeting = meeting
    }
}

struct CallaRecapItem: Codable, Identifiable, Equatable {
    let id: String
    let kind: String
    let text: String
    let fromSeq: Int
    let toSeq: Int
    let resolved: Bool

    enum CodingKeys: String, CodingKey {
        case id, kind, text
        case fromSeq = "from_seq"
        case toSeq = "to_seq"
        case resolved
    }
}

struct CallaRecapDraft: Codable, Equatable {
    let callID: String
    let overview: String
    let items: [CallaRecapItem]
    let provider: String?
    let model: String?
    let failure: String?
    let reviewState: String

    enum CodingKeys: String, CodingKey {
        case overview, items, provider, model, failure
        case callID = "call_id"
        case reviewState = "review_state"
    }
}

private struct CallaRecapCommand: Codable {
    let action: String
    let callID: String
    enum CodingKeys: String, CodingKey { case action; case callID = "call_id" }
}

/// A calendar event, on its way to the copilot.
struct CallaMeeting: Codable, Equatable {
    var eventID: String?
    var seriesID: String?
    var title: String?
    var startsAt: Double?
    var endsAt: Double?
    var location: String?
    var attendees: [String]
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case title, location, attendees, notes
        case eventID = "event_id"
        case seriesID = "series_id"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
    }

    /// Everything about an event that is worth telling a copilot, and nothing
    /// that is not. Attendee names rather than addresses where the calendar has
    /// them: a first name is what gets said out loud on the call.
    init(_ event: EventModel) {
        eventID = event.id
        seriesID = event.seriesID
        title = event.title
        startsAt = event.start.timeIntervalSince1970
        endsAt = event.end.timeIntervalSince1970
        location = event.location
        attendees = event.participants.map(\.name).filter { !$0.isEmpty }
        notes = event.notes
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
        let settings = CallaCopilotSettings.current
        let persona = settings.persona
        let overrides = settings.personaOverrides
            .merging(settings.customPersonas) { override, _ in override }
        let profile = CallaCopilotProfile(
            about: nonEmpty(settings.aboutMe),
            personaGuidance: nonEmpty(overrides[persona] ?? ""),
            baseGuidance: nonEmpty(settings.baseGuidance))
        return profile.isEmpty ? nil : profile
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Single typed ownership boundary for Call Copilot preferences. Existing keys
/// remain storage during staged migration; callers use this snapshot, validate
/// it, then atomically apply it before telling engine about next-call settings.
@MainActor
struct CallaCopilotSettings: Codable, Equatable {
    static let schemaVersion = 4
    /// The spellings the engine's own validator accepts. Kept here so an imported
    /// settings file with a mode this build does not know is rejected at the
    /// boundary rather than silently resolving to the default in the host.
    static let gatewayStandbyModes: Set<String> = ["off", "on-failure", "warm"]

    var enabled: Bool
    var persona: String
    var liveModel: String
    var autoReveal: Bool
    var archiveRetranscribe: Bool
    var prerollEnabled: Bool
    var prerollLead: Double
    var panelSurface: String
    var aboutMe: String
    var personaOverrides: [String: String]
    var customPersonas: [String: String]
    var baseGuidance: String
    var provider: String
    var liveTier: String
    var summaryModel: String
    var fallback: Bool
    /// Optional so a settings file exported before this field existed still
    /// imports — the synthesized decoder demands every non-optional key, and one
    /// missing key would throw away the whole import.
    var gatewayStandby: String?

    static var current: Self {
        Self(enabled: Defaults[.callaCopilotEnabled], persona: Defaults[.callaCopilotPersona],
             liveModel: Defaults[.callaCopilotLiveModel], autoReveal: Defaults[.callaCopilotAutoReveal],
             archiveRetranscribe: Defaults[.callaCopilotArchiveRetranscribe],
             prerollEnabled: Defaults[.callaCopilotPrerollEnabled], prerollLead: Defaults[.callaCopilotPrerollLead],
             panelSurface: Defaults[.callaCopilotPanelSurface], aboutMe: Defaults[.callaCopilotAboutMe],
             personaOverrides: Defaults[.callaCopilotPersonaOverrides], customPersonas: Defaults[.callaCopilotCustomPersonas],
             baseGuidance: Defaults[.callaCopilotBaseGuidance], provider: Defaults[.callaIntelligenceProvider],
             liveTier: Defaults[.callaIntelligenceLiveTier], summaryModel: Defaults[.callaIntelligenceSummaryModel],
             fallback: Defaults[.callaIntelligenceFallback],
             gatewayStandby: Defaults[.callaGatewayStandby])
    }

    static var defaults: Self {
        Self(enabled: true, persona: "generic", liveModel: "whisper-small-en", autoReveal: true,
             archiveRetranscribe: false, prerollEnabled: true, prerollLead: 120,
             panelSurface: "summary", aboutMe: "", personaOverrides: [:], customPersonas: [:],
             baseGuidance: "", provider: "local", liveTier: "balanced",
             summaryModel: "gemini-3.1-pro-high", fallback: true, gatewayStandby: "warm")
    }

    static func exportData() throws -> Data { try JSONEncoder().encode(current) }

    static func importData(_ data: Data) throws {
        var value = try JSONDecoder().decode(Self.self, from: data)
        if value.panelSurface == "answers" { value.panelSurface = "question" }
        try apply(value)
        Defaults[.callaCopilotSettingsSchemaVersion] = schemaVersion
    }

    static func reset() { try? apply(defaults) }

    static func migrate() {
        guard Defaults[.callaCopilotSettingsSchemaVersion] < schemaVersion else { return }
        var value = current
        if value.panelSurface == "answers" { value.panelSurface = "question" }
        if !["summary", "question"].contains(value.panelSurface) { value.panelSurface = "summary" }
        if !["local", "gateway"].contains(value.provider) { value.provider = "local" }
        if !["fast", "balanced", "deep"].contains(value.liveTier) { value.liveTier = "balanced" }
        if !Self.gatewayStandbyModes.contains(value.gatewayStandby ?? "") { value.gatewayStandby = "warm" }
        if !["whisper-small-en", "whisper-base-en"].contains(value.liveModel) { value.liveModel = "whisper-small-en" }
        try? apply(value)
        Defaults[.callaCopilotSettingsSchemaVersion] = schemaVersion
    }

    static func apply(_ value: Self) throws {
        guard ["summary", "question"].contains(value.panelSurface),
              ["local", "gateway"].contains(value.provider),
              ["fast", "balanced", "deep"].contains(value.liveTier),
              Self.gatewayStandbyModes.contains(value.gatewayStandby ?? "warm"),
              ["whisper-small-en", "whisper-base-en"].contains(value.liveModel),
              (30...300).contains(value.prerollLead) else { throw ValidationError.invalid }
        Defaults[.callaCopilotEnabled] = value.enabled
        Defaults[.callaCopilotPersona] = value.persona
        Defaults[.callaCopilotLiveModel] = value.liveModel
        Defaults[.callaCopilotAutoReveal] = value.autoReveal
        Defaults[.callaCopilotArchiveRetranscribe] = value.archiveRetranscribe
        Defaults[.callaCopilotPrerollEnabled] = value.prerollEnabled
        Defaults[.callaCopilotPrerollLead] = value.prerollLead
        Defaults[.callaCopilotPanelSurface] = value.panelSurface
        Defaults[.callaCopilotAboutMe] = value.aboutMe
        Defaults[.callaCopilotPersonaOverrides] = value.personaOverrides
        Defaults[.callaCopilotCustomPersonas] = value.customPersonas
        Defaults[.callaCopilotBaseGuidance] = value.baseGuidance
        Defaults[.callaIntelligenceProvider] = value.provider
        Defaults[.callaIntelligenceLiveTier] = value.liveTier
        Defaults[.callaIntelligenceSummaryModel] = value.summaryModel
        Defaults[.callaIntelligenceFallback] = value.fallback
        Defaults[.callaGatewayStandby] = value.gatewayStandby ?? "warm"
    }

    enum ValidationError: LocalizedError { case invalid
        var errorDescription: String? { "Copilot settings contain unsupported values" }
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
    private lazy var statusObserver = StatusObserver { [weak self] data in
        guard let self, let result = try? Self.decoder.decode(CallaEngineStatus.self, from: data) else { return }
        self.apply(result)
    }

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
                // A live call is the one case where this poll *is* the latency. The
                // host answers a question in ~2s and writes it to a file; at the idle
                // cadence it then sat there for up to 4s more, which is longer than
                // the answer took and long enough for the moment to pass.
                let onACall = self.status.copilot.running || self.callIsFinishing
                // A call on the way up is the other case where the poll *is* the
                // latency, and a tighter one: every startup step the host
                // publishes is a line the panel wants to draw, and at the idle
                // cadence the whole startup would land as one jump at the end.
                let comingUp = self.callIsComingUp
                let interval: Double = comingUp
                    ? 0.25
                    : (signingIn ? 0.5 : (onACall ? 0.6 : (teaching ? 2 : 4)))
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

        // The host now speaks for itself, so our optimistic claim stands down.
        // Also released on a host that reports a failure, and on the timeout —
        // otherwise a call that never came up would leave the notch starting
        // forever with no way back to the button.
        if result.copilot.running {
            // It is a call now, not a warm host on spec.
            armedSpeculativePrewarm = false
        }
        // The host has finished, or there is no host left to finish. Also
        // released on the timeout, so a host that died mid-recap cannot leave
        // the notch writing a recap forever.
        if endingCall {
            let done = !result.copilot.running && !result.copilot.isFinishing
                && !result.copilot.starting
            if done || result.copilot.lifecycleState == CallLifecycleStateName.finished {
                endEnding()
            } else if let deadline = endDeadline, Date() >= deadline {
                endEnding()
            }
        }

        if result.copilot.starting || result.copilot.running {
            endLaunch()
        } else if launchingCall,
                  result.copilot.lastResult != previousCopilot.lastResult,
                  CopilotStartFailure.classify(reason: result.copilot.lastResult,
                                               copilot: result.copilot).isTerminalRefusal {
            // The engine has refused outright — a host already alive, a runtime
            // that is not installed, settings that failed validation. Waiting for
            // the thirty-second deadline here meant half a minute of a progress
            // bar for a call that was never going to exist. Keyed on the result
            // having *changed*, so a stale message from an earlier command
            // cannot cancel a launch that is genuinely still coming up.
            endLaunch()
        } else if let deadline = launchDeadline, Date() >= deadline {
            endLaunch()
        }

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

    func startCall(persona: String, model: String, meeting: CallaMeeting? = nil) {
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
        // A warm host is already most of a call. Promote it rather than asking
        // the engine to spawn a second one, which it would refuse outright with
        // "Call already running" — the warm-up would have made the button dead.
        if status.copilot.prewarming {
            armedSpeculativePrewarm = false
            beginLaunch()
            releaseCall()
            return
        }

        // Set here rather than waited for.
        //
        // The engine cannot report a host that does not exist yet, and the poll
        // that would notice it is up to four seconds away. Claiming the launch
        // locally is what makes the button respond to the press; the host's own
        // status replaces this the moment it lands, and `launchDeadline` gives up
        // if it never does.
        beginLaunch()
        send(callCommand("start", persona: persona, model: model, meeting: meeting))
    }

    /// A call this app has asked for and not yet seen come up.
    ///
    /// Cleared by the host reporting for itself — either `starting`, which means
    /// the process is alive and the claim is now the host's rather than ours, or
    /// `running`, which means it beat us to it.
    @Published private(set) var launchingCall = false
    private var launchDeadline: Date?
    /// Long enough to cover a cold model load and a TCC prompt, short enough that
    /// a host that died on launch does not leave the notch waiting forever.
    private static let launchTimeout: TimeInterval = 30

    private func beginLaunch() {
        launchingCall = true
        launchDeadline = Date().addingTimeInterval(Self.launchTimeout)
    }

    private func endLaunch() {
        launchingCall = false
        launchDeadline = nil
    }

    /// True while the user should be looking at a starting call — ours by claim,
    /// or the host's by report.
    var callIsComingUp: Bool { launchingCall || status.copilot.starting }

    /// Boots everything a call needs — the model, both `agy` lanes, the knowledge —
    /// without starting either capture leg.
    ///
    /// The two-minute pre-roll. Nothing is recorded until `releaseCall()`, which is
    /// the whole reason this is a separate action rather than a flag on `start`:
    /// "warm" and "recording" are different states and the notch says which one it
    /// is in.
    func prewarmCall(persona: String, model: String, meeting: CallaMeeting) {
        // Deliberately no sign-in diversion here. A pre-roll is unattended — it
        // fires two minutes before a meeting, possibly while the Mac is locked —
        // and opening a browser for an OAuth code at that moment is exactly the
        // thing the sign-in path was built to avoid.
        guard Defaults[.callaIntelligenceProvider] != "local"
            || !status.copilot.agyAvailable
            || status.copilot.agyLoggedIn
        else { return }
        send(callCommand("prewarm", persona: persona, model: model, meeting: meeting))
    }

    /// Arms the copilot because a call now looks likely — the user has the
    /// Copilot tab open in front of them.
    ///
    /// The local brain costs ~3.4s to boot its language server and several more
    /// to bootstrap both conversation lanes, and none of that can start until a
    /// host exists. Paid at Start, it lands squarely on the first question of the
    /// call: measured ~10-15s for the opening answer against ~2.5s for every one
    /// after it. Paid while someone is looking at the tab deciding whether to
    /// begin, it is usually finished before they press anything.
    ///
    /// Deliberately reuses the pre-roll rather than adding a second warm-up path:
    /// "warm but not recording" is a state the host, the engine and the notch all
    /// already model, and the microphones stay shut until `releaseCall()`.
    func prewarmForImminentCall() {
        guard Defaults[.callaCopilotEnabled] else { return }
        // Only the local brain has anything worth warming; a gateway call has no
        // per-call boot cost to move.
        guard Defaults[.callaIntelligenceProvider] == "local" else { return }
        // Nothing to arm for, or nothing that would succeed.
        guard status.copilot.agyAvailable, status.copilot.agyLoggedIn else { return }
        // A host already exists — starting, running, or somebody else's pre-roll.
        guard !status.copilot.running, !status.copilot.starting,
              !status.copilot.prewarming, !launchingCall, !armedSpeculativePrewarm
        else { return }
        armedSpeculativePrewarm = true
        send(callCommand("prewarm", persona: Defaults[.callaCopilotPersona],
                         model: Defaults[.callaCopilotLiveModel], meeting: nil))
    }

    /// Stands the speculative pre-roll down when the user navigates away without
    /// starting a call.
    ///
    /// Only ever stops a host this method armed. A pre-roll belonging to a
    /// scheduled meeting carries a `meetingTitle` and is `MeetingPreroll`'s to
    /// cancel — tearing that one down because someone glanced at another tab
    /// would silently disarm the feature they scheduled.
    func cancelSpeculativePrewarm() {
        guard armedSpeculativePrewarm else { return }
        armedSpeculativePrewarm = false
        // Never touch a host that has become a real call, and never one armed for
        // a meeting.
        guard !status.copilot.running, status.copilot.meetingTitle == nil else { return }
        guard status.copilot.prewarming || status.copilot.starting else { return }
        endCall()
    }

    /// Whether the warm host currently up is one this app armed on spec.
    private var armedSpeculativePrewarm = false

    /// Promotes a warmed-up copilot to a recording one. This is the moment capture
    /// starts, and it only ever happens because the user pressed something.
    func releaseCall() {
        send(CallaCopilotCommand(action: "release"))
    }

    private func callCommand(
        _ action: String, persona: String, model: String, meeting: CallaMeeting?
    ) -> CallaCopilotCommand {
        let settings = CallaCopilotSettings.current
        return CallaCopilotCommand(
            action: action,
            persona: persona,
            model: model,
            profile: CallaCopilotProfile.current,
            provider: settings.provider,
            tier: settings.liveTier,
            summaryModel: settings.summaryModel,
            fallback: settings.fallback,
            gatewayStandby: settings.gatewayStandby,
            meeting: meeting)
    }

    /// Changes which brain answers. Takes effect on the next call: the capture
    /// host binds its provider at launch, so switching mid-call would report a
    /// change that did not happen. Automatic fallback is the only thing that swaps
    /// brains during a call.
    func setIntelligence(
        provider: String,
        tier: String? = nil,
        summaryModel: String? = nil,
        fallback: Bool? = nil,
        gatewayStandby: String? = nil
    ) {
        send(CallaCopilotCommand(
            action: "set_provider",
            provider: provider,
            tier: tier,
            summaryModel: summaryModel,
            fallback: fallback,
            gatewayStandby: gatewayStandby))
    }

    func endCall() {
        // Claimed locally, for the same reason `startCall` claims its launch:
        // the host cannot report a stop it has not been told about yet, and the
        // poll that would notice is up to four seconds away. Pressing End used
        // to change nothing on screen for those four seconds and then, once the
        // recap pass began, still nothing — because `running` stayed true until
        // the process exited. The button now responds to the press and the
        // host's own progress replaces this the moment it lands.
        beginEnding()
        send(CallaCopilotCommand(action: "stop"))
    }

    /// A stop this app has asked for and not yet seen finish.
    @Published private(set) var endingCall = false
    private var endDeadline: Date?
    /// Long enough for the drain, the final chunk and the deep closing pass —
    /// which is ~8.5s on its own — and short enough that a host that died
    /// mid-recap does not leave the notch finishing forever.
    private static let endTimeout: TimeInterval = 60

    private func beginEnding() {
        endingCall = true
        endDeadline = Date().addingTimeInterval(Self.endTimeout)
    }

    private func endEnding() {
        endingCall = false
        endDeadline = nil
    }

    /// True while the user should be looking at a call being written up — ours
    /// by claim, or the host's by report.
    var callIsFinishing: Bool { endingCall || status.copilot.isFinishing }

    func answerSelectedText(_ text: String) {
        send(CallaCopilotCommand(action: "answer", question: text))
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

    // MARK: - Knowledge

    /// Everything the copilot has been told, or the subset that applies to one
    /// meeting.
    ///
    /// Every one of these round-trips to the engine. The store lives in the
    /// unsandboxed runtime directory and this app cannot open it, which is also
    /// why each mutation replies with the resulting list rather than a status —
    /// there is no second way to find out what the store now holds.
    func fetchKnowledge(
        eventID: String? = nil,
        seriesID: String? = nil,
        completion: @escaping ([CallaKnowledgeNote]) -> Void
    ) {
        knowledge(CallaKnowledgeCommand(action: "list", eventID: eventID, seriesID: seriesID),
                  completion: completion)
    }

    func saveKnowledge(_ note: CallaKnowledgeNote, completion: @escaping ([CallaKnowledgeNote]) -> Void) {
        knowledge(CallaKnowledgeCommand(
            action: "upsert", id: note.id, title: note.title, body: note.body,
            scope: note.scope, scopeKey: note.scopeKey,
            source: note.source,
            originName: note.originName, originKind: note.originKind,
            byteSize: note.byteSize, pageCount: note.pageCount), completion: completion)
    }

    func deleteKnowledge(id: String, completion: @escaping ([CallaKnowledgeNote]) -> Void) {
        knowledge(CallaKnowledgeCommand(action: "delete", id: id), completion: completion)
    }

    private func knowledge(
        _ command: CallaKnowledgeCommand,
        completion: @escaping ([CallaKnowledgeNote]) -> Void
    ) {
        guard let payload = try? JSONEncoder().encode(command) else {
            completion([]); return
        }
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            NSLog("[CallaEngine] knowledge unavailable: %@", error.localizedDescription)
            Task { @MainActor in completion([]) }
        }) as? BoringCallaEngineProtocol else { return }
        proxy.knowledgeControl(payload) { data in
            let notes = (try? Self.decoder.decode([CallaKnowledgeNote].self, from: data)) ?? []
            Task { @MainActor in completion(notes) }
        }
    }

    /// Previous calls for a meeting — the same series where there is one, so a
    /// recurring standup shows every instance rather than only today's.
    func fetchCalls(
        forEvent eventID: String?,
        seriesID: String?,
        completion: @escaping ([CallaCallRecord]) -> Void
    ) {
        let query = CallaKnowledgeCommand(action: "list", eventID: eventID, seriesID: seriesID)
        guard let payload = try? JSONEncoder().encode(query) else { completion([]); return }
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            NSLog("[CallaEngine] call list unavailable: %@", error.localizedDescription)
            Task { @MainActor in completion([]) }
        }) as? BoringCallaEngineProtocol else { return }
        proxy.copilotCallsForEvent(payload) { data in
            let calls = (try? Self.decoder.decode([CallaCallRecord].self, from: data)) ?? []
            Task { @MainActor in completion(calls) }
        }
    }

    /// The engine encodes dates as ISO-8601, matching every other reply it sends.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

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

    func fetchRecapDraft(callID: String, completion: @escaping (CallaRecapDraft?) -> Void) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            Task { @MainActor in completion(nil) }
        }) as? BoringCallaEngineProtocol else { return }
        proxy.copilotRecapDraft(callID) { data in
            let recap = try? Self.decoder.decode(CallaRecapDraft.self, from: data)
            Task { @MainActor in completion(recap) }
        }
    }

    /// The effective prompt pack, keyed by its path inside the pack.
    ///
    /// The Settings pane used to hold its own copy of the default wording, which
    /// drifted until it was previewing a JSON contract the host had stopped
    /// using. This asks the side of the sandbox line that actually sends them.
    func fetchPrompts(completion: @escaping ([String: String]) -> Void) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            Task { @MainActor in completion([:]) }
        }) as? BoringCallaEngineProtocol else { return }
        proxy.copilotPrompts { data in
            let prompts = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
            Task { @MainActor in completion(prompts) }
        }
    }

    func controlRecap(_ action: String, callID: String, completion: @escaping (CallaRecapDraft?) -> Void) {
        guard let payload = try? JSONEncoder().encode(CallaRecapCommand(action: action, callID: callID)) else {
            completion(nil); return
        }
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            Task { @MainActor in completion(nil) }
        }) as? BoringCallaEngineProtocol else { return }
        proxy.copilotRecapControl(payload) { data in
            let recap = try? Self.decoder.decode(CallaRecapDraft.self, from: data)
            Task { @MainActor in completion(recap) }
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
        let remoteInterface = NSXPCInterface(with: BoringCallaEngineProtocol.self)
        remoteInterface.setInterface(
            NSXPCInterface(with: BoringCallaEngineStatusObserver.self),
            for: #selector(BoringCallaEngineProtocol.subscribeStatus(_:with:)), argumentIndex: 0, ofReply: false)
        connection.remoteObjectInterface = remoteInterface
        connection.exportedInterface = NSXPCInterface(with: BoringCallaEngineStatusObserver.self)
        connection.exportedObject = statusObserver
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.status.running = false
            }
        }
        connection.resume()
        self.connection = connection
        if let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? BoringCallaEngineProtocol {
            proxy.subscribeStatus(statusObserver) { [weak self] data in
                guard let self, let result = try? Self.decoder.decode(CallaEngineStatus.self, from: data) else { return }
                Task { @MainActor in self.apply(result) }
            }
        }
        return connection
    }
}

private final class StatusObserver: NSObject, BoringCallaEngineStatusObserver {
    private let receive: (Data) -> Void
    init(receive: @escaping (Data) -> Void) { self.receive = receive }
    func callaEngineStatusDidChange(_ data: Data) {
        Task { @MainActor in receive(data) }
    }
}

private typealias Preferences = CallaEnginePreferences
