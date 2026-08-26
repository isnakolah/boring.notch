import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CallaContracts
import IntelligenceStore

private struct Preferences: Codable, Equatable {
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
}

private struct Status: Codable {
    var running = false
    /// Whether the Tutor host is answering its socket, as opposed to whether
    /// the engine believes it started it.
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
    var activeLesson: ActiveLesson? = nil
    var courses: [CourseSnapshot] = []
    var tutorIntelligence: TutorIntelligenceStatus? = nil
    var copilot: CopilotStatus = CopilotStatus()
}

private struct TutorIntelligenceStatus: Codable {
    var selectedProvider = "local"
    var activeProvider: String? = nil
    var pendingFeedbackID: String? = nil
    var activeRunID: String? = nil
    var activeRevision: String? = nil
    var activeGeneration: Int? = nil
    var localAgyAvailable = false
    var localAgyVersion: String? = nil
    var localAgyAuthenticated = false
    var gatewayFeedbackAvailable = false
    var gatewayAuthoringAvailable = false
    var nodeTransportHealthy = false
    var engineIngressHealthy = false
    var captureAvailable = false
    var lastProvider: String? = nil
    var lastModel: String? = nil
    var lastLatencyMilliseconds: Int? = nil
    var lastFallbackReason: String? = nil
    var lastDeterministicVerification: String? = nil
    var historyByteCount = 0
    var captureCount = 0
    var storageFailure: String? = nil
    var protocolVersion = 4
}

/// Live-call state, folded into the same `Status` the notch already polls every
/// two seconds. A second polling loop for the copilot would double the XPC
/// traffic to report a feature that is idle most of the time.
private struct CopilotStatus: Codable {
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
    var summary: String? = nil
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
    /// this is true, which is the claim the pre-roll card makes to the user.
    var prewarming = false
    /// A host process exists and is still paying its fixed costs.
    ///
    /// Distinct from `running`, which was only ever true once the whole of the
    /// host's `start()` had finished — so the notch had nothing to show for the
    /// first seconds of every call and the button read as dead.
    var starting = false
    /// Which fixed cost the host is on: `launching`, `permissions`, `model`,
    /// `capture`, `listening`. Optional so an older host decodes.
    var startupStage: String? = nil
    var modelLoaded = false
    /// The local brain has both lanes open and can answer at conversation speed.
    var brainWarm = false
    /// Nil when the gateway is not part of this call at all.
    var gatewayWarm: Bool? = nil
    /// The meeting this call was armed for, so the card has something to name.
    var meetingTitle: String? = nil
    var meetingStartsAt: Date? = nil
    /// Which brain answered: "local" or "gateway". The notch shows this, because
    /// an automatic failover the user cannot see is indistinguishable from a
    /// broken copilot.
    var activeProvider: String? = nil
    /// The model that answered, or why the local brain stood down.
    var providerDetail: String? = nil
    /// Whether the local Antigravity CLI is installed, so Settings can say
    /// "not installed" instead of a call failing the moment someone speaks.
    var agyAvailable = false
    var agyVersion: String? = nil
    /// Whether `agy` has valid OAuth credentials on disk.
    var agyLoggedIn = false
    /// Where the sign-in has got to: `starting`, `opening_browser`,
    /// `awaiting_code`, `exchanging`, `signed_in`, `failed`.
    ///
    /// A stage rather than a sentence, so the UI can show progress as steps
    /// instead of pattern-matching a status message that anything else can
    /// overwrite.
    /// The call currently being re-transcribed, if any.
    ///
    /// Re-transcription used to report only into `lastResult`, which History never
    /// showed — so pressing the button looked like it did nothing for the minutes it
    /// takes, and the row's badge stayed stale afterwards.
    var retranscribingCallID: String? = nil
    /// Whether a previous credential is set aside and can be put back.
    var agyBackupAvailable = false
    var agyLoginStage: String? = nil
    /// The Google sign-in URL, while a sign-in is running. The pane shows it so
    /// the user is not dependent on a browser having opened by itself.
    var agyLoginURL: String? = nil
    /// True exactly while agy is at its "paste the authorization code" prompt, so
    /// the paste field appears on a fact rather than on matching a status string.
    var agyAwaitingCode = false
    /// The Google account `agy` is authenticated as.
    var agyAccount: String? = nil
    var lastResult: String? = nil
    /// What the *capture host* was granted, read back from the file it writes.
    /// Preflighting here would report this service's own TCC state, which is
    /// not the state that decides whether anything gets recorded.
    var hostMicGranted = false
    var hostScreenGranted = false
    /// False until the host has reported once. Distinguishing this from a
    /// denial is the point: the two look identical in a bare Bool, and showing
    /// "not granted" against a host that holds both is exactly the wrong answer
    /// this path exists to stop giving.
    var hostPermissionsKnown = false
    var modelDownload: ModelDownloadFile? = nil
    /// Where the host is in its own lifecycle: `capturing`, `stopping`,
    /// `processingRecap`, `finished`. The host has published this since v2 and
    /// nothing forwarded it, so the app could see a call start and could see it
    /// vanish, and knew nothing about the seconds in between — which is exactly
    /// the window where End call looked like it had done nothing.
    var lifecycleState: String? = nil
    /// 0…1 while the recap is being written; nil otherwise.
    var recapProgress: Double? = nil
    /// The call has stopped capturing and is writing itself up. Exclusive with
    /// `running` and `starting`, on the same principle those two follow: three
    /// different things are happening and one Bool cannot say which.
    var finishing = false
}

/// Mirrors `permissions.json`, written by CallaCallHost about itself.
private struct CopilotPermissionsFile: Codable {
    var micGranted: Bool
    var screenGranted: Bool
    var checkedAt: Date?

    enum CodingKeys: String, CodingKey {
        case micGranted = "mic_granted"
        case screenGranted = "screen_granted"
        case checkedAt = "checked_at"
    }
}

/// Mirrors `model-download.json`, written by the host while it fetches a model.
private struct ModelDownloadFile: Codable {
    var model: String
    var receivedBytes: Int64
    var totalBytes: Int64
    var state: String
    var message: String?

    enum CodingKeys: String, CodingKey {
        case model, state, message
        case receivedBytes = "received_bytes"
        case totalBytes = "total_bytes"
    }
}

/// Just enough of a `CallTurn` to count and order them.
///
/// Deliberately not the whole shape: this decodes every line of an archive on a
/// list refresh, and the text is the expensive part nobody is reading yet.
private struct ArchivedTurn: Codable {
    var seq: Int
}

/// A transcript turn on its way to the notch.
///
/// Only needed since the store became the source: the JSONL path replies with the
/// host's own lines verbatim, which already carry these keys. Mirrors
/// `CallaCallTurn` in the app.
private struct ArchivedTurnOut: Codable {
    var id: UUID
    var seq: Int
    var source: String
    var t0: Double
    var t1: Double
    var text: String
}

/// One archived call, as listed for the History pane.
private struct CallSummaryFile: Codable {
    var id: String
    var startedAt: Date?
    var endedAt: Date?
    var turnCount: Int
    var persona: String
    var hasAudio: Bool
    /// Whether `transcript-archive.jsonl` exists — the large model has been over
    /// this call. Without it, History could not tell a call that was re-transcribed
    /// from one that never was.
    var retranscribed: Bool = false
    /// Turns in the re-transcribed pass, so a better transcript is visibly better.
    var archivedTurnCount: Int = 0
    /// How many suggestions the copilot returned during the call. Zero on a call
    /// that transcribed fine and never answered is the signal worth seeing.
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
}

/// Mirrors `ActiveCallStatus` written by CallaCallHost.
private struct CopilotHostStatus: Codable {
    var callID: String
    var persona: String
    var startedAt: Date
    var turnCount: Int
    var gatewayConnected: Bool
    var micActive: Bool
    var systemAudioActive: Bool
    /// Optional: a status file written by an older host has neither, and a
    /// missing key must not throw away the whole status.
    var provider: String?
    var providerDetail: String?
    var speaking: String?
    var thinking: Bool?
    var working: String?
    var questionWorking: Bool?
    var summaryWorking: Bool?
    var answering: Bool?
    var prewarming: Bool?
    var meetingTitle: String?
    var meetingStartsAt: Date?
    var lifecycle: CopilotLifecycleFile?

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case persona
        case prewarming
        case meetingTitle = "meeting_title"
        case meetingStartsAt = "meeting_starts_at"
        case startedAt = "started_at"
        case turnCount = "turn_count"
        case gatewayConnected = "gateway_connected"
        case micActive = "mic_active"
        case systemAudioActive = "system_audio_active"
        case provider, speaking, thinking, answering, working
        case questionWorking = "question_working"
        case summaryWorking = "summary_working"
        case providerDetail = "provider_detail"
        case lifecycle
    }
}

/// Small, forward-compatible projection of v2 lifecycle. Keep engine status
/// sanitized: no transcript, prompt, capture path, or raw provider output.
private struct CopilotLifecycleFile: Codable {
    var contractVersion: Int
    var generation: Int
    var state: String
    /// 0…1 while the host is writing the recap. Optional for the same reason
    /// every other field here is: a host older than it must still decode.
    var recapProgress: Double?
    /// Absent once the call is up, and absent entirely from a host older than
    /// the startup checklist.
    var startup: CopilotStartupFile?

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contractVersion"
        case generation, state, startup, recapProgress
    }
}

/// Mirrors `CallStartupProgress`. Every field optional: this is read from a file
/// another executable writes, and one renamed key must not cost the whole status.
private struct CopilotStartupFile: Codable {
    var stage: String?
    var modelLoaded: Bool?
    var brainWarm: Bool?
    var gatewayWarm: Bool?
}

/// Mirrors the gateway's `suggestion` frame as persisted by the host.
private struct CopilotSuggestionFile: Codable {
    var callID: String
    var afterSeq: Int
    var headline: String
    var angles: [String]
    var confirm: [String]
    var summary: String?
    var openQuestions: [String]?

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case afterSeq = "after_seq"
        case headline
        case angles
        case confirm
        case summary
        case openQuestions = "open_questions"
    }
}

/// Typed copilot command from the owner UI.
private struct CopilotCommand: Codable {
    var action: String
    var persona: String?
    var model: String?
    var callID: String?
    var question: String?
    var profile: CopilotProfile?
    /// "local" or "gateway". Absent means leave the stored preference alone.
    var provider: String?
    /// Live model tier for the local brain: fast | balanced | deep.
    var tier: String?
    /// Exact model for the end-of-call pass.
    var summaryModel: String?
    /// Whether the gateway may answer when the local brain cannot.
    var fallback: Bool?
    /// When the gateway socket opens: off | on-failure | warm.
    var gatewayStandby: String?
    /// The calendar event this call belongs to. The app sends the identity and
    /// the event's own fields; the knowledge itself is composed here, because the
    /// app is sandboxed and cannot open the store.
    var meeting: CopilotMeeting?

    enum CodingKeys: String, CodingKey {
        case action, persona, model, profile, provider, tier, fallback, meeting, question
        case summaryModel = "summary_model"
        case gatewayStandby = "gateway_standby"
        case callID = "call_id"
    }
}

private struct CopilotRecapCommand: Codable {
    let action: String
    let callID: String

    enum CodingKeys: String, CodingKey { case action; case callID = "call_id" }
}

/// The calendar event a call is for, as the app sends it.
private struct CopilotMeeting: Codable {
    var eventID: String?
    var seriesID: String?
    var title: String?
    var startsAt: Double?
    var endsAt: Double?
    var location: String?
    var attendees: [String]?
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case title, location, attendees, notes
        case eventID = "event_id"
        case seriesID = "series_id"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
    }
}

/// The user's prompt text, on its way to the gateway.
///
/// Free text, unlike every other field a command carries — which is why it is
/// kept in its own type and handed to the host on stdin. Nothing in here is ever
/// allowed to become a process argument.
private struct CopilotProfile: Codable {
    var about: String?
    var personaGuidance: String?
    var baseGuidance: String?

    enum CodingKeys: String, CodingKey {
        case about
        case personaGuidance = "persona_guidance"
        case baseGuidance = "base_guidance"
    }
}

extension JSONEncoder {
    /// ISO-8601 dates, matching the decoder the app already uses for every other
    /// reply this service sends.
    static var calla: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

/// A mutable cell for handing one value back out of a detached task.
///
/// `@unchecked Sendable` is accurate rather than lazy here: exactly one task
/// writes it, and the reader only runs after that task has signalled a semaphore,
/// which is a full barrier.
private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

/// A knowledge note crossing the XPC boundary in either direction.
///
/// The app owns the editing UI and the store lives on this side of the sandbox
/// line, so every create, edit and delete is one of these.
private struct KnowledgeCommand: Codable {
    /// `upsert`, `delete`, or `list`.
    var action: String
    var id: String?
    var title: String?
    var body: String?
    var scope: String?
    var scopeKey: String?
    /// For `list`: restrict to one event and its series.
    var eventID: String?
    var seriesID: String?
    /// `manual` or `document`. A document is a file the app read on its own side
    /// of the sandbox line; only the text it extracted ever reaches this process.
    var source: String?
    var originName: String?
    var originKind: String?
    var byteSize: Int?
    var pageCount: Int?

    enum CodingKeys: String, CodingKey {
        case action, id, title, body, scope, source
        case scopeKey = "scope_key"
        case eventID = "event_id"
        case seriesID = "series_id"
        case originName = "origin_name"
        case originKind = "origin_kind"
        case byteSize = "byte_size"
        case pageCount = "page_count"
    }
}

private struct ActiveLesson: Codable {
    let courseID: String
    let lessonID: String
    let lessonTitle: String
    let active: Bool
    enum CodingKeys: String, CodingKey { case courseID = "course_id", lessonID = "lesson_id", lessonTitle = "lesson_title", active }
}

private struct LessonSnapshot: Codable {
    let id: String
    let title: String
    let stepCount: Int
    let completed: Bool
    let dueForReview: Bool
    enum CodingKeys: String, CodingKey { case id, title, completed; case stepCount = "step_count", dueForReview = "due_for_review" }
}

private struct CourseSnapshot: Codable {
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
    let lessons: [LessonSnapshot]

    enum CodingKeys: String, CodingKey {
        case id, title, summary, icon, hidden, lessons
        case targetApp = "target_app", completedCount = "completed_count", dueForReview = "due_for_review"
        case checkpointLessonID = "checkpoint_lesson_id", recentThread = "recent_thread"
        case lifecyclePhase = "lifecycle_phase", lifecycleNote = "lifecycle_note"
        case runtimeVersion = "runtime_version", runtimeBlocked = "runtime_blocked"
    }
}

private struct CatalogueCourse: Decodable {
    let id: String
    let title: String
    let summary: String
    let icon: String?
    let bundleIDs: [String]?
    let lessons: [CatalogueLesson]

    enum CodingKeys: String, CodingKey { case id, title, summary, icon, lessons; case bundleIDs = "bundle_ids" }
}

private struct CatalogueLesson: Decodable { let id: String; let title: String }

private struct LifecycleCourse: Decodable {
    let id: String; let phase: String; let error: String?; let nextAction: String?
    enum CodingKeys: String, CodingKey { case id, phase, error; case nextAction = "next_action" }
}

private struct CourseRunFile: Decodable {
    let checkpointLessonID: String?
    let entries: [CourseRunEntry]
    enum CodingKeys: String, CodingKey { case entries; case checkpointLessonID = "checkpointLessonID" }
}
private struct CourseRunEntry: Decodable { let text: String }

private struct RuntimeManifest: Decodable {
    let format: String
    let formatVersion: Int
    let courses: [RuntimeCourse]
    enum CodingKeys: String, CodingKey { case format, courses; case formatVersion = "format_version" }
}
private struct RuntimeCourse: Decodable {
    let courseID: String; let courseRevision: String; let appBundleID: String; let appVersion: String; let lessons: [RuntimeLesson]
    enum CodingKeys: String, CodingKey { case lessons; case courseID = "course_id", courseRevision = "course_revision", appBundleID = "app_bundle_id", appVersion = "app_version" }
}
private struct RuntimeLesson: Decodable {
    let id: String; let steps: [RuntimeStep]
}
private struct RuntimeStep: Decodable {
    let id: String
    /// Runtime v1 always publishes authored text. Optional keeps transitional
    /// diagnostics decodable, but missing text never grants a model authority.
    let text: String?
}
private struct LearningRecord: Decodable {
    let lessonID: String; let bundleID: String; let successes: Int; let nextDueAt: Double?
    enum CodingKeys: String, CodingKey { case successes; case lessonID = "lesson_id", bundleID = "bundle_id", nextDueAt = "next_due_at" }
}
private struct LegacyLearningRecord: Decodable {
    let format: String
    let formatVersion: Int
    let lessonID: String
    let bundleID: String
    let successes: Int
    let intervalDays: Double
    let nextDueAt: Double?
    enum CodingKeys: String, CodingKey {
        case format, successes
        case formatVersion = "format_version"
        case lessonID = "lesson_id", bundleID = "bundle_id", intervalDays = "interval_days", nextDueAt = "next_due_at"
    }
}

private struct CourseCommand: Decodable {
    let action: String; let courseID: String?; let lessonID: String?; let outline: String?
    let assetBundlePath: String?; let targetApp: String?; let targetVersion: String?
    enum CodingKeys: String, CodingKey {
        case action, outline
        case courseID = "course_id", lessonID = "lesson_id", assetBundlePath = "asset_bundle_path"
        case targetApp = "target_app", targetVersion = "target_version"
    }
}

private struct CapabilityHandshake: Codable {
    let engineBuild: String
    let nodeContractHash: String
    let receivedAt: Date

    enum CodingKeys: String, CodingKey {
        case engineBuild = "engine_build"
        case nodeContractHash = "node_contract_hash"
        case receivedAt = "received_at"
    }
}

/// Permission state as observed by CallaTutorHost, which is the executable TCC
/// actually grants. Mirrors `CallaRuntime.HostStatus` on the host side.
private struct HostStatus: Decodable {
    let screenRecordingGranted: Bool
    let accessibilityGranted: Bool
    let captureActive: Bool
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case screenRecordingGranted = "screen_recording_granted"
        case accessibilityGranted = "accessibility_granted"
        case captureActive = "capture_active"
        case updatedAt = "updated_at"
    }
}

/// Boring keeps a bounded local summary of each private Gateway transaction so
/// Settings can show result after the XPC process restarts. Gateway remains
/// authoritative for full receipts under its release root.
private struct GatewayUpdateRecord: Codable {
    let currentRelease: String?
    let previousRelease: String?
    let summary: String
    let completedAt: Date

    enum CodingKeys: String, CodingKey {
        case currentRelease = "current_release"
        case previousRelease = "previous_release"
        case summary
        case completedAt = "completed_at"
    }
}

/// Privileged Tutor process. Preferences arrive as complete snapshots from
/// Boring UI; this process never reads Boring or legacy Calla preferences.
final class BoringCallaEngine: NSObject, BoringCallaEngineProtocol {
    private let queue = DispatchQueue(label: "theboringteam.boringnotch.calla-engine")
    private let fileManager = FileManager.default
    private var preferences: Preferences?
    private var isRunning = false
    private var lastResult = "Engine not started"
    private var runtime: Process?
    private var nodeRuntime: Process?
    private var copilotProcess: Process?
    /// Monotonic per-engine call epoch. A host from an earlier run can finish
    /// after a restart; its file/event must not replace current call state.
    private var copilotGeneration = 0
    private var copilotPersona = "generic"
    private var copilotModel = "whisper-small-en"
    /// Which brain the next call starts on. Local by default, so a call still
    /// gets suggestions when `nomonhomelab` is unreachable.
    private var copilotProvider = "local"
    private var copilotTier = "balanced"
    private var copilotSummaryModel = "gemini-3.1-pro-high"
    private var copilotFallback = true
    /// When the gateway socket opens on a call the local brain is answering.
    /// Warm matches what every host did before this was a setting.
    private var copilotGatewayStandby: GatewayStandby = .warm
    /// Mirrors the notch's "Answers only" toggle.
    private var retranscribingCallID: String?
    private var copilotResult: String?
    /// `agy --version`, probed once. Cached because it costs a process and the
    /// status poll runs every two seconds.
    private var agyProbe: (available: Bool, version: String?)?
    private var agyAuthCache: (loggedIn: Bool, account: String?)?
    /// Existence, size and modification date of the credential file, so a change
    /// to it invalidates the cached answer.
    private var agyAuthCacheFingerprint: String?
    /// The pty master: both where the TUI's screen is read from and where a pasted
    /// code is written to.
    private var agyLoginInput: FileHandle?
    private var agyLoginChoseMethod = false
    private var agyLoginStage: String?
    /// Set only for a rehearsal, and the thing that keeps it away from the real
    /// credential.
    private var agyLoginRehearsalHome: URL?
    /// Set by `sign_out`, so the auto-repair that protects a failed
    /// re-authentication does not quietly sign the user back in.
    private var agyExplicitSignOut = false
    private var agyLoginLogURL: URL {
        copilotRoot.appendingPathComponent("agy-login.log")
    }
    private var agyLoginProcess: Process?
    /// Tail of the pty stream, kept so a failure can be explained in the words
    /// agy used rather than an exit code.
    private var agyLoginBuffer = ""
    private var agyLoginURL: String?
    private var agyLoginAwaitingCode = false
    /// One-shot channel for the prompt profile, held only between building the
    /// process and writing to it.
    private var copilotProfilePipe: Pipe?
    private var copilotPendingProfile: Data?
    /// Knowledge and call history.
    ///
    /// This process opens it because the app cannot: the app is sandboxed, the
    /// store lives in the unsandboxed runtime directory, and every read the
    /// Settings panes do comes through XPC. Opened lazily so a broken file costs
    /// the knowledge features rather than the whole engine.
    private lazy var store: CallaStore? = {
        do {
            return try CallaStore(path: copilotRoot.appendingPathComponent("calla.sqlite"))
        } catch {
            NSLog("[CallaEngine] knowledge store unavailable: %@", error.localizedDescription)
            return nil
        }
    }()
    private var archiveProcess: Process?
    private var modelProcess: Process?
    private var permissionProcess: Process?
    private var hostPermissionCheckStarted = false
    /// The host writes ISO-8601 dates; the default decoder would reject them.
    private lazy var jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private var gatewayUpdate: Process?
    private var courseControlProcess: Process?
    private var tutorFeedbackProcess: Process?
    private var activeTutorFeedbackID: String?
    private var activeTutorFeedback: TutorFeedbackRecord?
    /// Deterministic observation runs twice per second. Remember one automatic
    /// help trigger per exact held step so an unsatisfied detector cannot start
    /// a new remote request immediately after every completed reply.
    private var automaticTutorFeedbackTrigger: (runID: String, generation: Int, stepID: String, outcome: String)?
    private var gatewayReachable = false
    private var gatewayMonitor: DispatchSourceTimer?
    private var diagnostics: [String] = []
    private let statusObservers = NSHashTable<AnyObject>.weakObjects()
    private var statusMonitor: DispatchSourceTimer?
    private var engineIngress: TutorEngineIngress?
    /// Rotated for each Engine process. Only its child node receives this in
    /// environment; no token is persisted or surfaced through XPC/status.
    private var engineIngressToken = UUID().uuidString.lowercased()
    private var activeTutorRun: TutorRunRecord?
    private var tutorGeneration = 0
    private var tutorObservationTimer: DispatchSourceTimer?
    private var tutorCaptureVault: TutorCaptureVault?
    private var tutorCaptureFailure: String?
    private var lastTutorVerification: String?

    private var root: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("boringNotch/Calla", isDirectory: true)
    }

    private var socketURL: URL { root.appendingPathComponent("tutor-host.sock") }
    private var engineIngressURL: URL { root.appendingPathComponent("engine-ingress.sock") }
    private var tutorCaptureURL: URL { root.appendingPathComponent("TutorAttachments", isDirectory: true) }
    private var runtimePIDURL: URL { root.appendingPathComponent("runtime.pid") }
    private var nodePIDURL: URL { root.appendingPathComponent("node.pid") }

    func start(with reply: @escaping (Data) -> Void) {
        queue.async {
            NSLog("[CallaEngine] start requested")
            do {
                try self.prepareRuntimeDirectories()
                self.restorePreferences()
                self.importBoringTutorState()
                self.importArchivesOnce()
                self.reclaimStaleOwnedChildren()
                self.detectConflicts()
                try self.startEngineIngress()
                // Teaching depends on the host, so a failure here is fatal.
                try self.startRuntime()
                self.isRunning = true
                // The node only carries Gateway traffic. It used to be started
                // before `isRunning` was set, so a missing plugin file left the
                // engine permanently "still starting" with a healthy host
                // already running — every command refused, notch stuck offline.
                do {
                    try self.startNodeRuntime()
                    self.lastResult = "Engine ready; Tutor runtime and Calla Mac node starting"
                } catch {
                    self.appendDiagnostic("Calla Mac node did not start: \(error.localizedDescription)")
                    self.lastResult = "Tutor runtime ready; Calla Mac node unavailable"
                }
                self.startGatewayMonitor()
                NSLog("[CallaEngine] runtime launched")
            } catch {
                self.isRunning = false
                self.lastResult = "Engine startup failed: \(error.localizedDescription)"
                NSLog("[CallaEngine] startup failed: %@", error.localizedDescription)
            }
            reply(self.encodedStatus())
        }
    }

    /// Everything this service started, brought down.
    ///
    /// Called both by `stop()` and when the app's XPC connection drops — a force
    /// quit or a crash must not leave a call host holding the microphone, or a
    /// resident `agy` language server holding ~190MB, with nothing driving either.
    func shutdownEverything() {
        stopGatewayMonitor()
        stopTutorObservation()
        engineIngress?.stop()
        engineIngress = nil
        if let runtime { terminateProcessTree(runtime.processIdentifier) }
        runtime = nil
        clearOwnedPID(at: runtimePIDURL)
        if let nodeRuntime { terminateProcessTree(nodeRuntime.processIdentifier) }
        nodeRuntime = nil
        clearOwnedPID(at: nodePIDURL)
        if let copilot = copilotProcess, copilot.isRunning {
            // SIGINT first: the host drains the trailing utterance on it.
            kill(copilot.processIdentifier, SIGINT)
            terminateProcessTree(copilot.processIdentifier)
        }
        copilotProcess = nil
        clearOwnedPID(at: copilotPIDURL)
        try? fileManager.removeItem(at: copilotStatusURL)
        if let login = agyLoginProcess, login.isRunning {
            terminateProcessTree(login.processIdentifier)
        }
        agyLoginProcess = nil
        agyLoginInput = nil
        cancelActiveTutorFeedback(reason: "engine_stopped")
        terminateStrayAgyHosts()
        gatewayReachable = false
        isRunning = false
        removeSocketIfUnbound()
    }

    /// Kills `agy` hosts that are ours but no longer anyone's child.
    ///
    /// A host orphaned by an earlier crash has been reparented to launchd, so no
    /// tree walk reaches it. They are identifiable because every host is launched
    /// with `--log-file` inside this app's runtime directory — the user's own `agy`
    /// in a terminal has nothing to do with that path and is never matched.
    private func terminateStrayAgyHosts() {
        let marker = copilotRoot.appendingPathComponent("agy").path
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard line.contains(marker), line.contains("agy") else { continue }
            let fields = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard let first = fields.first, let pid = pid_t(first), pid > 1 else { continue }
            Darwin.kill(pid, SIGTERM)
        }
    }

    func stop(with reply: @escaping (Data) -> Void) {
        queue.async {
            // The call host holds the microphone, so it goes down with everything
            // else rather than leaving a recording indicator lit.
            self.shutdownEverything()
            self.lastResult = "Engine stopped"
            reply(self.encodedStatus())
        }
    }

    func applyPreferences(_ data: Data, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let decoded = try? JSONDecoder().decode(Preferences.self, from: data) else {
                self.lastResult = "Rejected invalid preference snapshot"
                reply(self.encodedStatus())
                return
            }
            guard [1024, 1600, 2048].contains(decoded.captureLongEdge),
                  [300, 340, 380, 440, 520].contains(decoded.tooltipWidth),
                  [24, 30, 38].contains(decoded.cursorSize),
                  (0.5...1.0).contains(decoded.tooltipOpacity),
                  decoded.allowedBundleIDs.allSatisfy({ !$0.isEmpty }),
                  decoded.hiddenCourseIDs.allSatisfy({ !$0.isEmpty }),
                  decoded.learnerID.range(of: "^[A-Za-z0-9-]{8,80}$", options: .regularExpression) != nil else {
                self.lastResult = "Rejected invalid preference values"
                reply(self.encodedStatus())
                return
            }
            self.preferences = decoded
            do {
                try self.writePreferences(decoded)
            } catch {
                self.lastResult = "Could not persist preference snapshot: \(error.localizedDescription)"
                reply(self.encodedStatus())
                return
            }
            self.lastResult = self.isRunning ? "Live preference snapshot applied" : "Preferences saved for engine start"
            reply(self.encodedStatus())
        }
    }

    func status(with reply: @escaping (Data) -> Void) {
        queue.async { reply(self.encodedStatus()) }
    }

    func subscribeStatus(_ observer: BoringCallaEngineStatusObserver, with reply: @escaping (Data) -> Void) {
        queue.async {
            self.statusObservers.add(observer)
            self.startStatusMonitorIfNeeded()
            reply(self.encodedStatus())
        }
    }

    private func startStatusMonitorIfNeeded() {
        guard statusMonitor == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(400), repeating: .milliseconds(400))
        timer.setEventHandler { [weak self] in
            guard let self, !self.statusObservers.allObjects.isEmpty else { return }
            _ = self.encodedStatus()
        }
        timer.resume()
        statusMonitor = timer
    }

    func requestGatewayUpdate(with reply: @escaping (Data) -> Void) {
        queue.async {
            guard self.isInstalledBoringApp else {
                self.lastResult = "Debug Gateway updates stage from Xcode build"
                reply(self.encodedStatus())
                return
            }
            self.requestGatewayUpdate(trigger: "manual retry")
            reply(self.encodedStatus())
        }
    }

    func requestScreenRecording(with reply: @escaping (Data) -> Void) {
        queue.async {
            // This request must originate in the executable that owns capture.
            // Selecting an embedded XPC bundle in System Settings does not make
            // it the TCC client on current macOS.
            self.invokeRuntime(operation: "request_screen_recording", payload: [:])
            reply(self.encodedStatus())
        }
    }

    func requestAccessibility(with reply: @escaping (Data) -> Void) {
        queue.async {
            // Same reason as requestScreenRecording above: prompting from here
            // asked TCC about this XPC bundle, but CallaTutorHost is what calls
            // AXUIElement, so approval landed on an executable that never uses
            // it and the host stayed untrusted.
            self.invokeRuntime(operation: "request_accessibility", payload: [:])
            reply(self.encodedStatus())
        }
    }

    func startCourse(_ courseID: String, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard courseID.range(of: "^[A-Za-z0-9._-]{1,160}$", options: .regularExpression) != nil else {
                self.lastResult = "Rejected invalid course identifier"
                reply(self.encodedStatus())
                return
            }
            self.startEngineCourse(courseID: courseID, lessonID: nil)
            reply(self.encodedStatus())
        }
    }

    func resumeCourse(with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let run = self.activeTutorRun else {
                self.lastResult = "No Engine-owned course run is ready to resume"
                reply(self.encodedStatus())
                return
            }
            self.renderEngineStep(run: run)
            reply(self.encodedStatus())
        }
    }

    func stopLesson(with reply: @escaping (Data) -> Void) {
        queue.async {
            self.stopEngineCourse()
            reply(self.encodedStatus())
        }
    }

    func ask(_ text: String, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let clean = Self.sanitizeTutorQuestion(text) else {
                self.lastResult = "Ask needs one short question"
                reply(self.encodedStatus())
                return
            }
            self.requestTutorFeedback(question: clean, kind: "question")
            reply(self.encodedStatus())
        }
    }

    func setTutorProvider(_ provider: String, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let preference = TutorProviderPreference(rawValue: provider), let store = self.store else {
                self.lastResult = "Rejected Tutor provider preference"; reply(self.encodedStatus()); return
            }
            let saved = self.awaitOnQueue {
                do { try await store.setTutorProviderPreference(preference); return true } catch { return false }
            } ?? false
            self.lastResult = saved ? "Tutor provider preference saved" : "Tutor provider preference could not be saved"
            reply(self.encodedStatus())
        }
    }

    func tutorHistory(_ query: Data, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard query.count <= 16 * 1024,
                  let request = try? JSONDecoder().decode(TutorHistoryQuery.self, from: query),
                  request.pageSize > 0, request.pageSize <= 50,
                  (request.query?.utf8.count ?? 0) <= 800,
                  let store = self.store else { reply(Data()); return }
            let page = self.awaitOnQueue {
                try? await store.tutorFeedbackHistory(cursor: request.cursor, query: request.query, pageSize: request.pageSize)
            } ?? nil
            reply((try? JSONEncoder().encode(page)) ?? Data())
        }
    }

    func tutorCapture(_ captureID: String, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard Self.validTutorID(captureID), let store = self.store, let vault = self.resolveTutorCaptureVault() else {
                reply(Data()); return
            }
            let record = self.awaitOnQueue { try? await store.tutorCapture(id: captureID) } ?? nil
            guard let capture = record, let image = try? vault.readJPEG(relativePath: capture.relativePath) else {
                reply(Data()); return
            }
            reply(image)
        }
    }

    func cancelTutorFeedback(_ feedbackID: String, generation: Int, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard Self.validTutorID(feedbackID), generation >= 0, let store = self.store else {
                self.lastResult = "Rejected Tutor feedback cancellation"; reply(self.encodedStatus()); return
            }
            let changed = self.awaitOnQueue {
                do { try await store.transitionTutorFeedback(id: feedbackID, generation: generation, state: .cancelled, errorCode: "owner_cancelled"); return true }
                catch { return false }
            } ?? false
            if changed, self.activeTutorFeedbackID == feedbackID {
                if let process = self.tutorFeedbackProcess, process.isRunning { self.terminateProcessTree(process.processIdentifier) }
                self.tutorFeedbackProcess = nil
                self.activeTutorFeedbackID = nil
            }
            self.lastResult = changed ? "Tutor feedback cancelled" : "Tutor feedback was no longer pending"
            reply(self.encodedStatus())
        }
    }

    func courseControl(_ data: Data, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let command = try? JSONDecoder().decode(CourseCommand.self, from: data) else {
                self.lastResult = "Rejected invalid course command"; reply(self.encodedStatus()); return
            }
            self.performCourseCommand(command)
            reply(self.encodedStatus())
        }
    }

    private func performCourseCommand(_ command: CourseCommand) {
        let allowedActions: Set<String> = ["start_lesson", "start_again", "import", "cancel", "retry", "publish", "archive", "restore", "revise", "refresh_runtime"]
        guard allowedActions.contains(command.action) else { lastResult = "Rejected unknown course command"; return }
        let courseID = CallaCourseCommandValidation.identifier(command.courseID)
        if command.action != "import" && command.action != "refresh_runtime" {
            guard let courseID else { lastResult = "Rejected invalid course identifier"; return }
            guard currentCourses().contains(where: { $0.id == courseID }) || currentLifecycleIDs().contains(courseID) else {
                lastResult = "Course is not in Boring library"; return
            }
        }
        switch command.action {
        case "start_lesson":
            guard let courseID, let lessonID = CallaCourseCommandValidation.identifier(command.lessonID),
                  currentCourses().first(where: { $0.id == courseID })?.lessons.contains(where: { $0.id == lessonID }) == true else {
                lastResult = "Lesson is not in selected course"; return
            }
            startEngineCourse(courseID: courseID, lessonID: lessonID)
        case "start_again":
            guard let courseID else { lastResult = "Rejected invalid course identifier"; return }
            stopEngineCourse()
            startEngineCourse(courseID: courseID, lessonID: nil)
        case "import", "revise":
            guard let outline = CallaCourseCommandValidation.outline(command.outline),
                  let target = CallaCourseCommandValidation.bundleID(command.targetApp),
                  preferences?.allowedBundleIDs.contains(target) == true,
                  let version = CallaCourseCommandValidation.version(command.targetVersion),
                  let zip = validatedZip(command.assetBundlePath) else {
                lastResult = "Course needs allowed app, short outline, version, and local scene ZIP"; return
            }
            var payload: [String: Any] = ["outline": outline, "target_app": target, "target_version": version,
                                          "target_frontmost": true, "target_allowlisted": true, "asset_bundle_local": zip.path]
            if let courseID { payload["course_id"] = courseID }
            runCourseScript(command.action == "revise" ? "edit-as-new-revision" : "import", payload: payload)
        case "cancel", "retry", "publish", "archive", "restore":
            guard let courseID else { lastResult = "Rejected invalid course identifier"; return }
            runCourseScript(command.action, payload: ["course_id": courseID])
        case "refresh_runtime":
            runCourseScript("refresh-runtime", payload: [:])
        default: break
        }
    }

    private func validatedZip(_ value: String?) -> URL? {
        CallaCourseCommandValidation.zipURL(value, fileManager: fileManager)
    }

    // MARK: - Live call copilot

    /// The capture host's own directory, written by CallaCallHost and read here.
    private var copilotRoot: URL { root.appendingPathComponent("copilot", isDirectory: true) }
    private var copilotStatusURL: URL { copilotRoot.appendingPathComponent("active-call.json") }
    private var copilotControlSocketURL: URL { copilotRoot.appendingPathComponent("call-host.sock") }
    private var copilotSuggestionURL: URL { copilotRoot.appendingPathComponent("latest-suggestion.json") }
    private var copilotPermissionsURL: URL { copilotRoot.appendingPathComponent("permissions.json") }
    private var copilotModelDownloadURL: URL { copilotRoot.appendingPathComponent("model-download.json") }
    private var copilotCallsRoot: URL { copilotRoot.appendingPathComponent("calls", isDirectory: true) }
    private var copilotPIDURL: URL { root.appendingPathComponent("callhost.pid") }

    /// The gateway route the copilot streams to. Fixed, like `probeGateway`'s
    /// URL — a transcript must not be steerable to another host.
    private static let copilotGateway = "wss://nomonhomelab.tailec0dca.ts.net/call-copilot/stream"

    private var copilotExecutable: URL? {
        let embedded = Bundle.main.resourceURL?
            .appendingPathComponent("CallaRuntime/CallaCallHost.app/Contents/MacOS/CallaCallHost")
        if let embedded, fileManager.isExecutableFile(atPath: embedded.path) { return embedded }
        // Development fallback: the standalone bundle installed by
        // scripts/calla/build-callhost.sh, so the feature is testable before a
        // full app deployment.
        let standalone = URL(fileURLWithPath: "/Applications/CallaCallHost.app/Contents/MacOS/CallaCallHost")
        return fileManager.isExecutableFile(atPath: standalone.path) ? standalone : nil
    }

    func copilotControl(_ data: Data, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let command = try? JSONDecoder().decode(CopilotCommand.self, from: data),
                  let action = CallaCopilotCommandValidation.action(command.action) else {
                self.lastResult = "Rejected invalid copilot command"
                self.copilotResult = "Rejected invalid copilot command"
                reply(self.encodedStatus()); return
            }
            switch action {
            case "start": self.startCopilot(command)
            case "prewarm": self.startCopilot(command, prewarm: true)
            case "release": self.releasePrewarm()
            case "stop": self.stopCopilot()
            case "answer": self.answerSelectedText(command.question)
            case "archive": self.retranscribeCall(command)
            case "fetch_model": self.fetchModel(command)
            case "set_provider":
                guard let provider = CallaCopilotCommandValidation.provider(command.provider) else {
                    self.copilotResult = "Rejected unknown intelligence provider"; break
                }
                self.copilotProvider = provider
                if let tier = CallaCopilotCommandValidation.tier(command.tier) { self.copilotTier = tier }
                if let summary = CallaCopilotCommandValidation.summaryModel(command.summaryModel) {
                    self.copilotSummaryModel = summary
                }
                if let fallback = command.fallback { self.copilotFallback = fallback }
                if let standby = CallaCopilotCommandValidation.gatewayStandby(command.gatewayStandby),
                   let mode = GatewayStandby.named(standby) {
                    self.copilotGatewayStandby = mode
                }
                // Like persona: the host binds its provider at launch, so a
                // change mid-call would be a lie. Automatic fallback is the only
                // thing that switches brains during a call.
                self.copilotResult = self.copilotProcess?.isRunning == true
                    ? "Intelligence set to \(provider); applies to the next call"
                    : "Intelligence set to \(provider)"
            case "set_persona":
                guard let persona = CallaCopilotCommandValidation.persona(command.persona) else {
                    self.copilotResult = "Rejected unknown persona"; break
                }
                self.copilotPersona = persona
                // Persona is fixed for the life of a call; the gateway binds it
                // at call_start. Changing it takes effect on the next call.
                self.copilotResult = self.copilotProcess?.isRunning == true
                    ? "Persona set to \(persona); applies to the next call"
                    : "Persona set to \(persona)"
            case "login":
                self.loginAgy(force: command.fallback == true)
            case "test_login":
                self.testLoginFlow()
            case "sign_out":
                self.signOutAgy()
            case "restore_login":
                self.restoreAgyCredentials()
            default: break
            }
            reply(self.encodedStatus())
        }
    }

    private func startCopilot(_ command: CopilotCommand, prewarm: Bool = false) {
        if copilotProcess?.isRunning == true {
            // A warm host is already most of a call, so a start that lands on
            // one promotes it rather than being refused.
            //
            // Boring's own `startCall` tries this first, but it can only ask the
            // question of the status snapshot it last polled — and the snapshot
            // is up to four seconds old, so a start pressed shortly after a
            // pre-roll armed reached here with `prewarming` still false and got
            // "Call already running" for a host that was sitting there waiting
            // to be released. The engine owns the process and can answer for it
            // now, which is the only place the answer is never stale.
            //
            // A start that is itself a pre-roll is not promoted: two warm-ups
            // arriving together should leave the first one warm, not begin
            // recording nobody asked for.
            if !prewarm, currentCopilotStatus().prewarming == true {
                releasePrewarm()
                return
            }
            copilotResult = "Call already running"
            return
        }
        guard let executable = copilotExecutable else {
            copilotResult = "Call host is not installed"; return
        }
        if let persona = CallaCopilotCommandValidation.persona(command.persona) { copilotPersona = persona }
        if let model = CallaCopilotCommandValidation.liveModel(command.model) { copilotModel = model }
        if let provider = CallaCopilotCommandValidation.provider(command.provider) { copilotProvider = provider }
        if let tier = CallaCopilotCommandValidation.tier(command.tier) { copilotTier = tier }
        if let summary = CallaCopilotCommandValidation.summaryModel(command.summaryModel) { copilotSummaryModel = summary }
        if let fallback = command.fallback { copilotFallback = fallback }
        if let standby = CallaCopilotCommandValidation.gatewayStandby(command.gatewayStandby),
           let mode = GatewayStandby.named(standby) {
            copilotGatewayStandby = mode
        }
        guard let gateway = CallaCopilotCommandValidation.gatewayURL(Self.copilotGateway) else {
            copilotResult = "Copilot gateway route is not valid"; return
        }

        // Screen Recording is what captures the other party. Without it the
        // call still runs, but only our own side is transcribed — which makes
        // the suggestions close to useless, so say so rather than fail quietly.
        //
        // Asked of the *host's* own report, not of this process: this used to
        // call `CGPreflightScreenCaptureAccess()` here, which answers for the
        // engine's signature and so could say "granted" while the host that
        // does the recording had nothing. Same bug already fixed for the Tutor
        // host.
        // Only warn on a definite no. Unknown resolves itself a moment later
        // when the host writes its own status, and `serve` reports both grants
        // as it starts anyway.
        if hostPermissions()?.screenGranted == false {
            copilotResult = "Grant Screen Recording to capture the other party"
        }

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        copilotGeneration &+= 1
        let generation = copilotGeneration
        var arguments = [
            "serve",
            "--gateway", gateway.absoluteString,
            "--persona", copilotPersona,
            "--model", copilotModel,
            "--provider", copilotProvider,
            "--tier", copilotTier,
            "--generation", String(generation),
        ]
        // Every value here came back from an allowlist above, so nothing the UI
        // sent can widen this command line.
        if let summaryModel = CallaCopilotCommandValidation.summaryModel(copilotSummaryModel) {
            arguments += ["--summary-model", summaryModel]
        }
        if !copilotFallback { arguments.append("--no-fallback") }
        // Validated to a known mode before it reaches argv, like every other
        // value here — nothing the UI sends can widen this command line.
        arguments += ["--gateway-standby", copilotGatewayStandby.argument]
        // Warm everything, record nothing. The flag is ours, not the caller's:
        // it is derived from which action was validated, never from a string the
        // app sent, so nothing the UI says can turn a pre-roll into a recording.
        if prewarm { arguments.append("--prewarm") }
        process.arguments = arguments
        // The user's prompt text goes in over stdin rather than as arguments.
        // It is the only free-text field this service accepts, and an argument
        // list is exactly where free text stops being only a prompt.
        let meeting = command.meeting.flatMap { incoming in
            CallaCopilotCommandValidation.meeting(
                eventID: incoming.eventID, seriesID: incoming.seriesID, title: incoming.title,
                startsAt: incoming.startsAt, endsAt: incoming.endsAt, location: incoming.location,
                attendees: incoming.attendees, notes: incoming.notes)
        }
        if command.meeting != nil, meeting == nil {
            copilotResult = "The meeting details were rejected; the call was not started"
            return
        }
        // Composed here rather than sent by the app. The app cannot open the
        // store — it is sandboxed and the file is not in its container — so the
        // only process that sees both the meeting the app names and the notes the
        // user wrote is this one.
        let knowledge = meeting.flatMap { composedKnowledge(for: $0) }

        if let profile = CallaCopilotCommandValidation.profile(
            about: command.profile?.about,
            personaGuidance: command.profile?.personaGuidance,
            baseGuidance: command.profile?.baseGuidance,
            knowledge: knowledge,
            meeting: meeting),
           let payload = try? JSONEncoder().encode(profile) {
            let pipe = Pipe()
            process.standardInput = pipe
            copilotProfilePipe = pipe
            copilotPendingProfile = payload
        } else if command.profile != nil || meeting != nil {
            // A profile that fails validation must not silently become "no
            // profile" — the call would run with different guidance than the
            // settings pane shows.
            copilotResult = "Prompt settings were rejected; fix them in Settings › Prompts"
            return
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CALLA_RUNTIME_ROOT"] = root.path
        process.environment = environment
        let pidFile = copilotPIDURL
        process.terminationHandler = { [weak self] child in
            self?.queue.async {
                guard self?.copilotGeneration == generation else { return }
                self?.clearOwnedPID(at: pidFile, matching: child.processIdentifier)
                self?.copilotProcess = nil
                if child.terminationStatus != 0 {
                    self?.copilotResult = "Call host stopped (status \(child.terminationStatus))"
                }
                // The host removes its own status file on a clean exit; clear it
                // here too so a crash cannot leave the notch showing a live call.
                try? FileManager.default.removeItem(at: self?.copilotStatusURL ?? pidFile)
            }
        }
        do {
            try fileManager.createDirectory(at: copilotRoot, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try process.run()
            copilotProcess = process
            try? writeOwnedPID(process.processIdentifier, to: copilotPIDURL)
            // Written after the child exists, and closed straight away so the
            // host sees EOF and starts rather than blocking on a read.
            if let payload = copilotPendingProfile, let pipe = copilotProfilePipe {
                pipe.fileHandleForWriting.write(payload)
                pipe.fileHandleForWriting.write(Data("\n".utf8))
                try? pipe.fileHandleForWriting.close()
            }
            copilotPendingProfile = nil
            copilotProfilePipe = nil
            if copilotResult == nil {
                copilotResult = prewarm ? "Copilot warmed up; not recording" : "Call started"
            }
        } catch {
            copilotPendingProfile = nil
            copilotProfilePipe = nil
            copilotResult = "Could not start call host: \(error.localizedDescription)"
        }
    }

    /// Copies calls recorded before the store existed into it, once.
    ///
    /// Detached rather than on the engine queue: it walks every call directory and
    /// parses every transcript this Mac has ever recorded, and the engine queue
    /// also serves the status poll the notch is waiting on. Nothing depends on it
    /// having finished — every reader falls back to the files until it has.
    private func importArchivesOnce() {
        guard let store else { return }
        let directory = copilotCallsRoot
        Task.detached(priority: .utility) {
            let imported = await store.importArchives(from: directory)
            if imported > 0 {
                NSLog("[CallaEngine] imported %d archived call(s) into the store", imported)
            }
            // Loads the embedding backend and vectors anything that has none.
            //
            // The host does this too, but only when a call starts — which left a
            // note written in Settings lexically searchable and nothing more until
            // the next meeting. Ordered after the import on purpose, so the pass
            // that follows covers the calls that just arrived as well.
            await store.prepare()
        }
    }

    // MARK: - Knowledge

    /// The app's only way to touch the knowledge base.
    ///
    /// Replies with the resulting note list in every case, including deletes, so
    /// the Settings pane never has to guess what the store now holds — the app
    /// cannot read the file to check.
    func knowledgeControl(_ data: Data, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let command = try? JSONDecoder().decode(KnowledgeCommand.self, from: data),
                  let store = self.store else {
                reply(Data("[]".utf8)); return
            }

            switch command.action {
            case "upsert":
                // Bounded and control-character-checked on exactly the same rules
                // as the rest of the prompt payload. This text goes straight into
                // a model prompt, so it is no more trusted for having been typed
                // in Settings than for having arrived in a calendar invite.
                //
                // A document gets a far larger ceiling than a typed note, because
                // it is never packed into a prompt whole — it is chunked and
                // searched, and the thing being bounded is how much of a file the
                // store will hold rather than how much of it a model will read.
                let isDocument = command.source == "document"
                let bodyLimit = isDocument
                    ? CallaCopilotCommandValidation.documentLimit
                    : CallaCopilotCommandValidation.knowledgeLimit
                guard case .accepted(let title) = CallaCopilotCommandValidation.promptText(
                        command.title, limit: CallaCopilotCommandValidation.meetingTitleLimit),
                      case .accepted(let body) = CallaCopilotCommandValidation.promptText(
                        command.body, limit: bodyLimit),
                      case .accepted(let originName) = CallaCopilotCommandValidation.promptText(
                        command.originName, limit: CallaCopilotCommandValidation.meetingTitleLimit),
                      let scope = self.scope(command.scope, key: command.scopeKey),
                      title != nil || body != nil
                else { break }
                var note = KnowledgeNote(
                    title: title ?? "", body: body ?? "",
                    source: isDocument ? .document : .manual,
                    scope: scope,
                    originName: originName,
                    originKind: CallaCopilotCommandValidation.documentKind(command.originKind),
                    byteSize: max(0, command.byteSize ?? 0),
                    pageCount: max(0, command.pageCount ?? 0))
                if let id = command.id, !id.isEmpty { note.id = id }
                _ = self.awaitOnQueue { try? await store.upsert(note) }
            case "delete":
                guard let id = command.id, !id.isEmpty else { break }
                _ = self.awaitOnQueue { try? await store.deleteNote(id: id) }
            default:
                break
            }

            let notes = self.awaitOnQueue { () -> [KnowledgeNote] in
                // A listing for one event carries everything that would actually
                // reach a call there — the always-on notes and the persona's
                // included — because "what will the copilot know in this meeting"
                // is the only question the pane is really asking.
                if command.eventID != nil || command.seriesID != nil {
                    let context = MeetingContext(eventID: command.eventID, seriesID: command.seriesID)
                    return (try? await store.notes(for: context, persona: self.copilotPersona)) ?? []
                }
                return (try? await store.notes()) ?? []
            } ?? []
            reply((try? JSONEncoder.calla.encode(notes)) ?? Data("[]".utf8))
        }
    }

    func copilotCallsForEvent(_ data: Data, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let query = try? JSONDecoder().decode(KnowledgeCommand.self, from: data),
                  let store = self.store else {
                reply(Data("[]".utf8)); return
            }
            let calls = self.awaitOnQueue { () -> [CallRecord] in
                // No event named means "every call that knows which meeting it
                // was", which is what the Knowledge pane asks for to put a name
                // on each group. Filtering to a single meeting is the other case.
                if query.eventID == nil, query.seriesID == nil {
                    return (try? await store.calls(limit: 500)) ?? []
                }
                return (try? await store.calls(forEvent: query.eventID, seriesID: query.seriesID)) ?? []
            } ?? []
            reply((try? JSONEncoder.calla.encode(calls)) ?? Data("[]".utf8))
        }
    }

    private func scope(_ kind: String?, key: String?) -> KnowledgeScope? {
        switch kind {
        case "always", nil: .always
        case "event": CallaCopilotCommandValidation.eventIdentifier(key).map(KnowledgeScope.event)
        case "series": CallaCopilotCommandValidation.eventIdentifier(key).map(KnowledgeScope.series)
        case "persona": CallaCopilotCommandValidation.persona(key).map(KnowledgeScope.persona)
        default: nil
        }
    }

    /// Promotes a ready host through its owner-only control socket. The 0600
    /// marker is retained only while an older host is still starting.
    private func releasePrewarm() {
        guard copilotProcess?.isRunning == true else {
            copilotResult = "Nothing is warmed up"
            return
        }
        let callID = currentCopilotStatus().callID
        if let callID,
           let event = requestHostControl(.release, callID: callID),
           event.kind != .fatal {
            copilotResult = "Recording"
            return
        }
        let payload = ["call_id": callID].compactMapValues { $0 }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let marker = copilotRoot.appendingPathComponent("prewarm-release.json")
        do {
            try fileManager.createDirectory(at: copilotRoot, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try data.write(to: marker, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            copilotResult = "Recording"
        } catch {
            copilotResult = "Could not start recording: \(error.localizedDescription)"
        }
    }

    /// Every note that applies to this meeting, as one block for the prompt.
    ///
    /// Synchronous on the engine's own queue, which is a deliberate trade: the
    /// store is an actor and this is the one call that must finish before the host
    /// is spawned, because the prompt blocks are bound at bootstrap and a lane
    /// that opened without them stays without them for the whole call. It is a
    /// handful of indexed reads on a local file.
    ///
    /// Ordered general to specific, so the note about *this* meeting is the last
    /// thing read. Truncated to the validator's ceiling rather than refused: a
    /// knowledge base that grew past the limit should cost its oldest notes, not
    /// the call.
    private func composedKnowledge(
        for meeting: CallaCopilotCommandValidation.MeetingFields
    ) -> String? {
        guard let store else { return nil }
        let context = MeetingContext(
            eventID: meeting.eventID,
            seriesID: meeting.seriesID,
            title: meeting.title,
            startsAt: meeting.startsAt.map(Date.init(timeIntervalSince1970:)),
            endsAt: meeting.endsAt.map(Date.init(timeIntervalSince1970:)),
            location: meeting.location,
            attendees: meeting.attendees,
            notes: meeting.notes)

        // The packing policy lives with the data rather than here: which notes go
        // in whole and which only get a line naming themselves is a fact about
        // what a note *is*, and it is unit-tested next to the store.
        let limit = CallaCopilotCommandValidation.knowledgeLimit
        return awaitOnQueue {
            (try? await store.promptBlock(
                for: context, persona: self.copilotPersona, limit: limit)) ?? nil
        } ?? nil
    }

    /// Runs an async store call to completion from the engine's serial queue.
    ///
    /// The engine is callback-based `@objc` XPC code with no async context of its
    /// own, and the store is an actor. A semaphore is the honest bridge; it is
    /// never taken on the actor's executor, so it cannot deadlock against the very
    /// task it is waiting for.
    private func awaitOnQueue<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            box.value = await body()
            semaphore.signal()
        }
        // A store query is milliseconds. The timeout exists so a pathological
        // lock cannot wedge the engine's only queue and take the notch with it.
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            NSLog("[CallaEngine] store call timed out")
            return nil
        }
        return box.value
    }

    /// Re-runs the archive model over a finished call's saved audio.
    private func retranscribeCall(_ command: CopilotCommand) {
        guard let callID = CallaCopilotCommandValidation.callID(command.callID) else {
            copilotResult = "Rejected invalid call id"; return
        }
        guard archiveProcess?.isRunning != true else {
            copilotResult = "A re-transcribe is already running"; return
        }
        guard let executable = copilotExecutable else {
            copilotResult = "Call host is not installed"; return
        }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.arguments = ["retranscribe", "--call", callID]
        var environment = ProcessInfo.processInfo.environment
        environment["CALLA_RUNTIME_ROOT"] = root.path
        process.environment = environment
        process.terminationHandler = { [weak self] child in
            self?.queue.async {
                self?.archiveProcess = nil
                self?.retranscribingCallID = nil
                self?.copilotResult = child.terminationStatus == 0
                    ? "Re-transcribed \(callID)"
                    : "Re-transcribe failed (status \(child.terminationStatus))"
            }
        }
        do {
            try process.run()
            archiveProcess = process
            retranscribingCallID = callID
            copilotResult = "Re-transcribing \(callID)…"
        } catch {
            copilotResult = "Could not re-transcribe: \(error.localizedDescription)"
        }
    }

    /// Downloads a transcription model ahead of a call.
    ///
    /// Same work the first call would do anyway, moved to a moment where a
    /// several-minute wait is not sitting between the user and a meeting.
    private func fetchModel(_ command: CopilotCommand) {
        guard let model = CallaCopilotCommandValidation.liveModel(command.model) else {
            copilotResult = "Rejected unknown model"; return
        }
        guard modelProcess?.isRunning != true else {
            copilotResult = "A model download is already running"; return
        }
        guard let executable = copilotExecutable else {
            copilotResult = "Call host is not installed"; return
        }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.arguments = ["models", "--fetch", model]
        var environment = ProcessInfo.processInfo.environment
        environment["CALLA_RUNTIME_ROOT"] = root.path
        process.environment = environment
        process.terminationHandler = { [weak self] child in
            self?.queue.async {
                self?.modelProcess = nil
                if child.terminationStatus != 0 {
                    self?.copilotResult = "Model download failed (status \(child.terminationStatus))"
                }
            }
        }
        do {
            try process.run()
            modelProcess = process
            copilotResult = "Downloading \(model)…"
        } catch {
            copilotResult = "Could not download model: \(error.localizedDescription)"
        }
    }

    /// Runs the host's own permission request, so the prompts are attributed to
    /// the signature that captures.
    func requestCopilotPermissions(with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let executable = self.copilotExecutable else {
                self.copilotResult = "Call host is not installed"
                reply(self.encodedStatus()); return
            }
            guard self.permissionProcess?.isRunning != true else {
                reply(self.encodedStatus()); return
            }
            let process = Process()
            process.executableURL = executable
            process.currentDirectoryURL = executable.deletingLastPathComponent()
            process.arguments = ["permissions"]
            var environment = ProcessInfo.processInfo.environment
            environment["CALLA_RUNTIME_ROOT"] = self.root.path
            process.environment = environment
            process.terminationHandler = { [weak self] _ in
                self?.queue.async { self?.permissionProcess = nil }
            }
            do {
                try process.run()
                self.permissionProcess = process
                self.copilotResult = "Requesting microphone and screen recording…"
            } catch {
                self.copilotResult = "Could not request permissions: \(error.localizedDescription)"
            }
            reply(self.encodedStatus())
        }
    }

    /// What the host last reported about its own grants.
    ///
    /// Absent means *unknown*, not denied — after a fresh install nothing has
    /// written the file yet, and reporting "not granted" against a host that
    /// holds both is the same wrong answer this whole path was fixing. A
    /// prompt-free `permissions --check` fills it in once per engine lifetime.
    private func hostPermissions() -> (micGranted: Bool, screenGranted: Bool)? {
        guard let data = try? Data(contentsOf: copilotPermissionsURL),
              let file = try? jsonDecoder.decode(CopilotPermissionsFile.self, from: data) else {
            refreshHostPermissionsOnce()
            return nil
        }
        return (file.micGranted, file.screenGranted)
    }

    /// Asks the host to report its grants without prompting for them.
    ///
    /// `--check` never raises a dialog, so this is safe to fire on a status
    /// poll; the answer lands on the next one.
    private func refreshHostPermissionsOnce() {
        guard !hostPermissionCheckStarted, permissionProcess?.isRunning != true,
              let executable = copilotExecutable else { return }
        hostPermissionCheckStarted = true

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.arguments = ["permissions", "--check"]
        var environment = ProcessInfo.processInfo.environment
        environment["CALLA_RUNTIME_ROOT"] = root.path
        process.environment = environment
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.permissionProcess = nil }
        }
        if (try? process.run()) != nil { permissionProcess = process }
    }

    private func stopCopilot() {
        guard let process = copilotProcess, process.isRunning else {
            copilotResult = "No call running"
            try? fileManager.removeItem(at: copilotStatusURL)
            return
        }
        if let callID = currentCopilotStatus().callID,
           let event = requestHostControl(.stop, callID: callID),
           event.kind == .finished {
            copilotResult = "Ending call…"
            return
        }
        // SIGINT rather than terminate(): the host flushes its endpointers,
        // drains the transcription queue and closes the WAVs on it, so a
        // trailing sentence is not lost.
        kill(process.processIdentifier, SIGINT)
        copilotResult = "Ending call…"
    }

    private func answerSelectedText(_ text: String?) {
        guard let callID = currentCopilotStatus().callID else {
            copilotResult = "No call running"
            return
        }
        guard case .accepted(let prompt?) = CallaCopilotCommandValidation.promptText(
            text, limit: CallaCopilotCommandValidation.manualQuestionLimit
        ) else {
            copilotResult = "Select up to \(CallaCopilotCommandValidation.manualQuestionLimit) characters"
            return
        }
        guard let event = requestHostControl(.answer, callID: callID, text: prompt),
              event.kind == .answer else {
            copilotResult = "Copilot unavailable; try again"
            return
        }
        copilotResult = "Answering selected text…"
    }

    /// One bounded JSON request/reply over the host's mode-0600 Unix socket.
    /// No transcript, prompt, coordinates, or raw provider output crosses it.
    private func requestHostControl(
        _ kind: CallHostCommandKind, callID: String, text: String? = nil
    ) -> CallHostEvent? {
        guard fileManager.fileExists(atPath: copilotControlSocketURL.path) else { return nil }
        let command = CallHostCommand(callID: callID, generation: copilotGeneration, kind: kind, text: text)
        guard let payload = try? JSONEncoder().encode(command) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let maximumPathLength = MemoryLayout.size(ofValue: address.sun_path) - 1
        copilotControlSocketURL.path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                let destination = UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self)
                strncpy(destination, source, maximumPathLength)
            }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        let sent = payload.withUnsafeBytes { send(descriptor, $0.baseAddress, payload.count, 0) }
        guard sent == payload.count else { return nil }
        _ = shutdown(descriptor, SHUT_WR)
        var reply = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while reply.count < 64 * 1024 {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count > 0 { reply.append(buffer, count: Int(count)); continue }
            if count == 0 { break }
            if errno == EINTR { continue }
            return nil
        }
        guard let event = try? JSONDecoder().decode(CallHostEvent.self, from: reply),
              event.callID == callID, event.generation == copilotGeneration,
              event.contractVersion == CallaContract.version else { return nil }
        return event
    }

    func copilotTranscript(since seq: Int, with reply: @escaping (Data) -> Void) {
        queue.async {
            reply(self.currentCopilotTranscript(since: seq))
        }
    }

    /// What the copilot returned during a finished call.
    ///
    /// The suggestions were already archived line by line; nothing could read them
    /// back, so a call's advice died with the call.
    func copilotCallSuggestions(_ callID: String, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let callID = CallaCopilotCommandValidation.callID(callID) else {
                reply(Data("[]".utf8)); return
            }
            // The store is the record now. The JSONL file is still written and is
            // still the fallback: a call recorded before the import ran, or one
            // whose store write failed, must not read as a call with no advice.
            if let store = self.store {
                let stored = self.awaitOnQueue {
                    (try? await store.suggestions(forCall: callID)) ?? []
                } ?? []
                if !stored.isEmpty {
                    let mapped = stored.map { entry in
                        CopilotSuggestionFile(
                            callID: callID, afterSeq: entry.afterSeq, headline: entry.headline,
                            angles: entry.angles, confirm: entry.confirm,
                            summary: entry.summary, openQuestions: entry.openQuestions)
                    }
                    reply((try? JSONEncoder().encode(mapped)) ?? Data("[]".utf8))
                    return
                }
            }
            let url = self.copilotCallsRoot
                .appendingPathComponent(callID, isDirectory: true)
                .appendingPathComponent("suggestions.jsonl")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                reply(Data("[]".utf8)); return
            }
            let suggestions = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { line -> CopilotSuggestionFile? in
                    guard let data = line.data(using: .utf8) else { return nil }
                    return try? self.jsonDecoder.decode(CopilotSuggestionFile.self, from: data)
                }
            reply((try? JSONEncoder().encode(suggestions)) ?? Data("[]".utf8))
        }
    }

    func copilotRecapDraft(_ callID: String, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let callID = CallaCopilotCommandValidation.callID(callID),
                  let store = self.store,
                  let draft = try? store.recapDraft(forCall: callID) else {
                reply(Data()); return
            }
            reply((try? JSONEncoder().encode(draft)) ?? Data())
        }
    }

    func copilotPrompts(with reply: @escaping (Data) -> Void) {
        queue.async {
            reply((try? JSONEncoder().encode(self.effectivePrompts())) ?? Data())
        }
    }

    /// The prompt files as they stand, exporting the defaults first if the user
    /// has never taken a copy.
    ///
    /// Reading files rather than asking the host over a pipe: the export is
    /// idempotent and never overwrites, so this costs one directory walk and
    /// cannot block the reply on a process that might not start. An empty result
    /// simply leaves the pane showing its own placeholders, which is what it did
    /// before this existed.
    private func effectivePrompts() -> [String: String] {
        let directory = root.appendingPathComponent("copilot/prompts", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            exportPromptDefaults()
        }
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil) else { return [:] }

        var prompts: [String: String] = [:]
        let base = directory.standardizedFileURL.path
        for case let url as URL in enumerator where url.pathExtension == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            let relative = String(path.dropFirst(base.count)).trimmingCharacters(
                in: CharacterSet(charactersIn: "/"))
            prompts[relative] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prompts
    }

    /// Runs the host's own `prompts export`, which is the only thing that knows
    /// the bundled wording.
    private func exportPromptDefaults() {
        guard let executable = copilotExecutable else { return }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.arguments = ["prompts", "export"]
        var environment = ProcessInfo.processInfo.environment
        environment["CALLA_RUNTIME_ROOT"] = root.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Not worth surfacing: the pane falls back to its own placeholders,
            // which is exactly what it did before this method existed.
            copilotResult = "Could not export prompts: \(error.localizedDescription)"
        }
    }

    func copilotRecapControl(_ payload: Data, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let command = try? JSONDecoder().decode(CopilotRecapCommand.self, from: payload),
                  ["approve", "reject", "delete"].contains(command.action),
                  let callID = CallaCopilotCommandValidation.callID(command.callID),
                  let store = self.store else {
                reply(Data()); return
            }
            switch command.action {
            case "approve":
                let record = try? store.call(id: callID)
                let meeting = record.map {
                    MeetingContext(eventID: $0.eventID, seriesID: $0.seriesID,
                                   title: $0.eventTitle, startsAt: $0.eventStart)
                }
                _ = self.awaitOnQueue { try? await store.approve(recapDraftFor: callID, meeting: meeting) }
            case "reject":
                try? store.reject(recapDraftFor: callID)
            case "delete":
                try? store.delete(recapDraftFor: callID)
            default: break
            }
            let draft = try? store.recapDraft(forCall: callID)
            reply((try? JSONEncoder().encode(draft)) ?? Data())
        }
    }

    func copilotCalls(with reply: @escaping (Data) -> Void) {
        queue.async {
            reply(self.archivedCalls())
        }
    }

    func copilotCallTranscript(_ callID: String, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let validID = CallaCopilotCommandValidation.callID(callID) else {
                reply(Data("[]".utf8)); return
            }
            reply(self.transcriptData(forCall: validID, since: -1, limit: 5000))
        }
    }

    /// Reads the live call's `transcript.jsonl`, newest turns last.
    ///
    /// Bounded on purpose: an hour-long call is thousands of turns, and the
    /// panel only ever shows the tail. Reading the whole file into an XPC reply
    /// would stall the engine queue that also serves the status poll.
    ///
    /// `since` is what makes a sub-second poll affordable: past the first read
    /// the reply is almost always empty, because turns arrive at the pace of
    /// human speech and not at the pace of the poll.
    private func currentCopilotTranscript(since seq: Int, limit: Int = 400) -> Data {
        guard let callID = (try? Data(contentsOf: copilotStatusURL))
            .flatMap({ try? jsonDecoder.decode(CopilotHostStatus.self, from: $0) })?.callID,
            let validID = CallaCopilotCommandValidation.callID(callID) else {
            return Data("[]".utf8)
        }
        // The live pass, deliberately: this is the transcript the copilot is
        // reasoning over right now.
        return transcriptData(forCall: validID, since: seq, limit: limit, revision: 0)
    }

    /// `revision`: nil takes the best transcript available — the archive pass
    /// when it has run. The live panel passes `0` explicitly, because it is
    /// showing turns beside suggestions that were made from those exact words,
    /// and swapping in a better transcript mid-call would show advice next to
    /// text that never appeared on screen.
    private func transcriptData(
        forCall callID: String,
        since seq: Int,
        limit: Int,
        revision: Int? = nil
    ) -> Data {
        // Indexed on `(call_id, seq)`, so `since` is a range scan rather than a
        // whole-file read and filter. That matters here more than anywhere else:
        // the live panel polls this sub-second for the length of a call.
        if let store {
            let turns = awaitOnQueue {
                (try? await store.turns(forCall: callID, since: seq, revision: revision)) ?? []
            } ?? []
            if !turns.isEmpty {
                let mapped = turns.suffix(limit).map { turn in
                    ArchivedTurnOut(
                        id: UUID(), seq: turn.seq, source: turn.source,
                        t0: turn.t0, t1: turn.t1, text: turn.text)
                }
                return (try? JSONEncoder().encode(mapped)) ?? Data("[]".utf8)
            }
        }
        let file = copilotCallsRoot
            .appendingPathComponent(callID, isDirectory: true)
            .appendingPathComponent("transcript.jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return Data("[]".utf8) }
        var lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(limit)
            .map(String.init)
        if seq >= 0 {
            // Filtering on the decoded `seq` rather than on line position: the
            // file is appended to while this runs, and counting lines would
            // skip or repeat a turn depending on the timing.
            lines = lines.filter { line in
                guard let data = line.data(using: .utf8),
                      let turn = try? jsonDecoder.decode(ArchivedTurn.self, from: data) else { return false }
                return turn.seq > seq
            }
        }
        return Data(("[" + lines.joined(separator: ",") + "]").utf8)
    }

    /// Every call this Mac has recorded, newest first.
    ///
    /// The list, the times and the turn counts come from the store, which is one
    /// indexed query rather than parsing every transcript on disk — the old path
    /// read and decoded every line of every call to count them, which is why
    /// History took visibly longer the more you used it.
    ///
    /// Three fields still come from the filesystem, because only the filesystem
    /// knows them: whether the WAVs are still there, whether the large model has
    /// been over the call, and how many turns that pass produced.
    private func archivedCalls(limit: Int = 200) -> Data {
        if let store {
            let records = awaitOnQueue { (try? await store.calls(limit: limit)) ?? [] } ?? []
            if !records.isEmpty {
                let summaries = records.map { record -> CallSummaryFile in
                    let facts = archiveFacts(forCall: record.id)
                    return CallSummaryFile(
                        id: record.id,
                        startedAt: record.startedAt,
                        endedAt: record.endedAt,
                        turnCount: record.turnCount,
                        persona: record.persona,
                        hasAudio: facts.hasAudio,
                        retranscribed: facts.archivedTurnCount > 0,
                        archivedTurnCount: facts.archivedTurnCount,
                        suggestionCount: facts.suggestionCount)
                }
                return (try? JSONEncoder().encode(summaries)) ?? Data("[]".utf8)
            }
        }

        guard let ids = try? fileManager.contentsOfDirectory(atPath: copilotCallsRoot.path) else {
            return Data("[]".utf8)
        }
        let summaries: [CallSummaryFile] = ids
            .compactMap { CallaCopilotCommandValidation.callID($0) }
            .compactMap { summary(forCall: $0) }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
        // Plain encoder, like `encodedStatus()` — the notch decodes both with a
        // plain decoder, so the date strategies have to match.
        return (try? JSONEncoder().encode(summaries)) ?? Data("[]".utf8)
    }

    /// What only the call's directory can answer.
    ///
    /// Counted by scanning for newlines rather than decoding: these are line
    /// counts, and decoding every suggestion of every call to arrive at one
    /// integer is what made the old listing slow.
    private func archiveFacts(forCall callID: String) -> (hasAudio: Bool, archivedTurnCount: Int, suggestionCount: Int) {
        let directory = copilotCallsRoot.appendingPathComponent(callID, isDirectory: true)
        let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        let hasAudio = contents.contains { $0.hasSuffix(".wav") }
        let archived = lineCount(directory.appendingPathComponent("transcript-archive.jsonl"))
        let suggestions = lineCount(directory.appendingPathComponent("suggestions.jsonl"))
        return (hasAudio, archived, suggestions)
    }

    private func lineCount(_ url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    private func summary(forCall callID: String) -> CallSummaryFile? {
        let directory = copilotCallsRoot.appendingPathComponent(callID, isDirectory: true)
        let transcript = directory.appendingPathComponent("transcript.jsonl")
        guard let text = try? String(contentsOf: transcript, encoding: .utf8) else { return nil }

        let turns = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> ArchivedTurn? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? jsonDecoder.decode(ArchivedTurn.self, from: data)
            }
        guard !turns.isEmpty else { return nil }

        // The call's own metadata file is the authority when it exists; a call
        // killed mid-flight has none, and the transcript's timestamps are still
        // enough to list it.
        let meta = (try? Data(contentsOf: directory.appendingPathComponent("call.json")))
            .flatMap { try? jsonDecoder.decode(CopilotHostStatus.self, from: $0) }
        let started = meta?.startedAt
            ?? (try? fileManager.attributesOfItem(atPath: transcript.path)[.creationDate] as? Date) ?? nil
        let ended = (try? fileManager.attributesOfItem(atPath: transcript.path)[.modificationDate] as? Date) ?? nil
        let audio = (try? fileManager.contentsOfDirectory(atPath: directory.path))?
            .contains { $0.hasSuffix(".wav") } ?? false

        let archive = directory.appendingPathComponent("transcript-archive.jsonl")
        let archivedLines = (try? String(contentsOf: archive, encoding: .utf8))
            .map { $0.split(separator: "\n", omittingEmptySubsequences: true).count } ?? 0
        let suggestionLines = (try? String(
            contentsOf: directory.appendingPathComponent("suggestions.jsonl"), encoding: .utf8))
            .map { $0.split(separator: "\n", omittingEmptySubsequences: true).count } ?? 0

        return CallSummaryFile(
            id: callID,
            startedAt: started,
            endedAt: ended,
            turnCount: turns.count,
            persona: meta?.persona ?? "generic",
            hasAudio: audio,
            retranscribed: archivedLines > 0,
            archivedTurnCount: archivedLines,
            suggestionCount: suggestionLines)
    }

    private func currentCopilotStatus() -> CopilotStatus {
        var status = CopilotStatus()
        status.available = copilotExecutable != nil
        status.persona = copilotPersona
        status.lastResult = copilotResult
        // Preference until a live call reports otherwise, so Settings and the
        // notch agree before the first suggestion lands.
        status.activeProvider = copilotProvider
        let agy = agyAvailability()
        status.agyAvailable = agy.available
        status.agyVersion = agy.version
        let auth = agyAuthStatus()
        status.agyLoggedIn = auth.loggedIn
        status.agyLoginURL = agyLoginURL
        status.agyAwaitingCode = agyLoginAwaitingCode
        status.agyLoginStage = agyLoginStage
        status.agyBackupAvailable = fileManager.fileExists(atPath: Self.supersededCredentialURL.path)
        status.retranscribingCallID = archiveProcess?.isRunning == true ? retranscribingCallID : nil
        status.agyAccount = auth.account

        let permissions = hostPermissions()
        status.hostPermissionsKnown = permissions != nil
        status.hostMicGranted = permissions?.micGranted ?? false
        status.hostScreenGranted = permissions?.screenGranted ?? false
        status.modelDownload = (try? Data(contentsOf: copilotModelDownloadURL))
            .flatMap { try? jsonDecoder.decode(ModelDownloadFile.self, from: $0) }

        if let data = try? Data(contentsOf: copilotStatusURL),
           let host = try? jsonDecoder.decode(CopilotHostStatus.self, from: data),
           // V2 host reports generation. Refuse stale lifecycle state before it
           // can change notch UI; old archives have no lifecycle and remain
           // readable through history, never as active calls.
           host.lifecycle?.generation == copilotGeneration {
            let alive = copilotProcess?.isRunning == true
            // `starting` and `running` are deliberately exclusive. A host that is
            // still loading its model is not a call the notch should draw as live,
            // but it is emphatically not nothing either — that gap is what made
            // pressing Start look like it had failed.
            let booting = host.lifecycle?.state == CallLifecycleState.starting.rawValue
            status.lifecycleState = host.lifecycle?.state
            status.recapProgress = host.lifecycle?.recapProgress
            // Winding down is not capturing. A host writing its recap has both
            // microphones closed, so drawing it as a live call is the same lie
            // in the other direction — and it is what made the panel sit there
            // unchanged after End call until the process finally exited.
            let winding = host.lifecycle.map {
                $0.state == CallLifecycleState.stopping.rawValue
                    || $0.state == CallLifecycleState.processingRecap.rawValue
            } ?? false
            status.starting = alive && booting
            status.running = alive && !booting && !winding
            status.finishing = alive && winding
            if let startup = host.lifecycle?.startup {
                status.startupStage = startup.stage
                status.modelLoaded = startup.modelLoaded ?? false
                status.brainWarm = startup.brainWarm ?? false
                status.gatewayWarm = startup.gatewayWarm
            }
            status.callID = host.callID
            status.persona = host.persona
            status.startedAt = host.startedAt
            status.turnCount = host.turnCount
            status.gatewayConnected = host.gatewayConnected
            status.micActive = host.micActive
            status.systemAudioActive = host.systemAudioActive
            // The host is the authority once a call is live: it knows whether the
            // local brain actually answered or handed over to the gateway.
            status.activeProvider = host.provider ?? copilotProvider
            status.providerDetail = host.providerDetail
            status.speaking = host.speaking
            status.thinking = host.thinking ?? false
            status.working = host.working
            status.questionWorking = host.questionWorking ?? false
            status.summaryWorking = host.summaryWorking ?? false
            status.answering = host.answering ?? false
            status.prewarming = host.prewarming ?? false
            status.meetingTitle = host.meetingTitle
            status.meetingStartsAt = host.meetingStartsAt

            if let suggestionData = try? Data(contentsOf: copilotSuggestionURL),
               let suggestion = try? jsonDecoder.decode(CopilotSuggestionFile.self, from: suggestionData),
               // A suggestion left over from an earlier call must never be
               // shown against the current one.
               suggestion.callID == host.callID {
                status.headline = suggestion.headline
                status.angles = suggestion.angles
                status.confirm = suggestion.confirm
                status.summary = suggestion.summary
                status.openQuestions = suggestion.openQuestions ?? []
                status.suggestionAfterSeq = suggestion.afterSeq
            }
        }
        return status
    }

    /// Whether the local Antigravity CLI is installed, and its version.
    ///
    /// Looked up the same way the provider does — well-known install paths first,
    /// because a GUI app inherits a minimal `PATH` — and cached for the life of
    /// the service: the answer only changes when the user installs or removes
    /// `agy`, and this is read by a 2s poll.
    private func agyAvailability() -> (available: Bool, version: String?) {
        if let agyProbe { return agyProbe }
        let candidates = [
            "~/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy",
        ].map { ($0 as NSString).expandingTildeInPath }
        guard let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            let probe = (available: false, version: String?.none)
            agyProbe = probe
            return probe
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var version: String?
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            version = text.isEmpty ? nil : text
        }
        let probe = (available: true, version: version)
        agyProbe = probe
        return probe
    }

    /// Whether `agy` has OAuth credentials on disk, and which account.
    ///
    /// Same cache strategy as `agyAvailability`: looked up once and held for
    /// the life of the service. Cleared when a login command completes.
    /// The user's real home, whatever this process's sandbox says.
    ///
    /// `NSHomeDirectory()` is redirected to the container in a sandboxed process
    /// and not in an unsandboxed one, so using it here is how "Settings says
    /// signed in" could coexist with a call popping a fresh OAuth page: two
    /// processes were answering the same question from two different homes. The
    /// passwd database is not redirected, so everything agrees.
    private static let userHome: String = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty { return path }
        }
        return NSHomeDirectory()
    }()

    private func agyAuthStatus() -> (loggedIn: Bool, account: String?) {
        // Keyed on the credential file itself, so the answer cannot go stale.
        //
        // This used to cache once per engine instance and only invalidate on
        // sign-in or sign-out — so an engine that happened to start while the
        // credential was absent reported "not signed in" forever, and one that
        // cached "signed in" never noticed it disappearing. Either way the call
        // path made the wrong decision and said nothing. A `stat` per poll is
        // cheap; the JSON is only re-read when the file actually changes.
        let fingerprint = credentialFingerprint()
        if let agyAuthCache, agyAuthCacheFingerprint == fingerprint { return agyAuthCache }
        agyAuthCacheFingerprint = fingerprint
        let home = Self.userHome
        let credsURL = URL(fileURLWithPath: home).appendingPathComponent(".gemini/oauth_creds.json")
        let accountsURL = URL(fileURLWithPath: home).appendingPathComponent(".gemini/google_accounts.json")

        var loggedIn = false
        if let data = try? Data(contentsOf: credsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = json["refresh_token"] as? String, !token.isEmpty {
            loggedIn = true
        }
        var account: String?
        if let data = try? Data(contentsOf: accountsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let active = json["active"] as? String, !active.isEmpty {
            account = active
        }
        let result = (loggedIn: loggedIn, account: account)
        agyAuthCache = result
        return result
    }

    /// Runs `agy`'s own interactive sign-in and surfaces it to the UI.
    ///
    /// Driving the **TUI**, not print mode, and the difference is the whole reason
    /// sign-in used to fail:
    ///
    ///  * `agy -p` gives the flow a hard **60 seconds** and then kills it. That is
    ///    shorter than a human browser round-trip, so the paste field vanished
    ///    mid-sign-in — and pressing the button again minted a **new PKCE
    ///    challenge**, which is why a code from the earlier tab came back
    ///    "expired". The TUI has no such deadline (verified alive past 60s).
    ///  * The TUI first shows `Select login method` with `1. Google OAuth`
    ///    preselected, so a bare Return starts the flow.
    ///  * It then prints the accounts.google.com URL and accepts the pasted code
    ///    for as long as it is running.
    ///
    /// It needs a real terminal: with a pipe on stdin `agy` refuses outright, and
    /// its TUI opens `/dev/tty`, which needs a controlling terminal and therefore
    /// `setsid`. `/usr/bin/script` supplies both — and it sizes its inner pty from
    /// its own stdin, so handing it a **1000-column** pty is what keeps the
    /// 704-character URL on one line instead of wrapped beyond reassembly.
    /// A rehearsal of the sign-in against a throwaway `HOME`.
    ///
    /// Exists because the only other way to see this flow is to sign out, and
    /// signing out is what caused the damage this code now guards against. Every
    /// step is identical — menu, link, browser, code, error handling — but `agy`
    /// reads and writes credentials in a temporary directory, so the real one is
    /// untouched whatever happens.
    private func testLoginFlow() {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("calla-signin-rehearsal-\(UUID().uuidString.prefix(8))")
        try? fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        agyLoginRehearsalHome = scratch
        loginAgy(force: false, rehearsing: true)
    }

    private func loginAgy(force: Bool = false, rehearsing: Bool = false) {
        guard copilotProcess?.isRunning != true else {
            copilotResult = "Cannot sign in while a call is running"; return
        }
        guard agyLoginProcess?.isRunning != true else {
            copilotResult = "Sign-in already in progress"; return
        }
        guard let binary = agyBinaryPath() else {
            copilotResult = "agy is not installed"; return
        }

        let auth = agyAuthStatus()
        if auth.loggedIn, !force, !rehearsing {
            copilotResult = auth.account.map { "Already signed in as \($0)" } ?? "Already signed in"
            return
        }
        if force, auth.loggedIn, !rehearsing {
            // `agy` caches credentials, so a forced sign-in on a *working* one is
            // pure damage — that is how a good token got moved aside, leaving every
            // call unauthenticated and every retry minting a new PKCE challenge
            // that rejected the previous tab's code. So check first, but never on
            // this thread: the check is a full model round trip.
            agyLoginStage = "checking"
            copilotResult = "Checking your existing sign-in…"
            let probeQueue = DispatchQueue.global(qos: .userInitiated)
            probeQueue.async { [weak self] in
                guard let self else { return }
                let works = self.credentialWorks()
                self.queue.async {
                    if works {
                        self.agyLoginStage = nil
                        self.copilotResult = auth.account.map { "Already signed in as \($0) — nothing to fix" }
                            ?? "Already signed in and working"
                        return
                    }
                    // Moved aside, not deleted, and put back by
                    // `restoreSupersededCredentialIfNeeded()` unless a new one arrives.
                    try? self.fileManager.removeItem(at: Self.supersededCredentialURL)
                    try? self.fileManager.moveItem(at: Self.credentialURL, to: Self.supersededCredentialURL)
                    self.agyAuthCache = nil
                    self.startAgySignIn(binary: binary, rehearsing: false)
                }
            }
            return
        }

        startAgySignIn(binary: binary, rehearsing: rehearsing)
    }

    /// Spawns the TUI and starts watching it. Split out so the immediate path and
    /// the post-probe path cannot drift apart.
    private func startAgySignIn(binary: String, rehearsing: Bool) {
        agyAuthCache = nil
        agyProbe = nil
        agyLoginURL = nil
        agyLoginAwaitingCode = false
        agyLoginBuffer = ""
        agyLoginChoseMethod = false
        agyLoginStage = "starting"

        // A pty of our own, wide enough that the sign-in URL is never wrapped.
        var master: Int32 = 0
        var slave: Int32 = 0
        var window = winsize(ws_row: 50, ws_col: 1000, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &window) == 0 else {
            copilotResult = "Could not allocate a terminal for sign-in"; return
        }
        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = [
            "-q", "/dev/null", binary,
            "--log-file", agyLoginLogURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = rehearsing ? (agyLoginRehearsalHome?.path ?? Self.userHome) : Self.userHome
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        masterHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            self?.queue.async { self?.consumeLoginOutput(chunk) }
        }

        process.terminationHandler = { [weak self] child in
            masterHandle.readabilityHandler = nil
            self?.queue.async {
                guard let self else { return }
                self.agyLoginProcess = nil
                self.agyLoginInput = nil
                self.agyLoginAwaitingCode = false
                self.agyLoginURL = nil
                self.agyAuthCache = nil
                self.agyProbe = nil
                self.restoreSupersededCredentialIfNeeded()
                if let rehearsal = self.agyLoginRehearsalHome {
                    try? self.fileManager.removeItem(at: rehearsal)
                    self.agyLoginRehearsalHome = nil
                    self.agyLoginStage = "signed_in"
                    self.copilotResult = "Sign-in rehearsal finished — your real sign-in was untouched"
                    self.agyLoginBuffer = ""
                    return
                }
                if self.agyAuthStatus().loggedIn {
                    let account = self.agyAuthStatus().account
                    self.agyExplicitSignOut = false
                    self.agyLoginStage = "signed_in"
                    self.copilotResult = account.map { "Signed in as \($0)" } ?? "Signed in"
                } else {
                    self.agyLoginStage = "failed"
                    self.copilotResult = CallaAgyLoginParsing.failureMessage(
                        from: self.agyLoginBuffer,
                        status: child.terminationStatus)
                }
                self.agyLoginBuffer = ""
            }
        }

        do {
            try process.run()
            // The parent's copy must go, or reads never see EOF when agy exits.
            try? slaveHandle.close()
            agyLoginProcess = process
            agyLoginInput = masterHandle
            agyLoginStage = "starting"
            copilotResult = "Starting sign-in…"
            watchLoginForCompletion()
        } catch {
            try? slaveHandle.close()
            copilotResult = "Could not start sign-in: \(error.localizedDescription)"
        }
    }

    /// Reacts to the TUI: answer its menu, publish the URL, open the browser.
    private func consumeLoginOutput(_ chunk: String) {
        agyLoginBuffer = String((agyLoginBuffer + chunk).suffix(16_000))

        if !agyLoginChoseMethod, CallaAgyLoginParsing.isAtLoginMethodMenu(agyLoginBuffer) {
            agyLoginChoseMethod = true
            // `1. Google OAuth` is already selected; Return accepts it.
            agyLoginInput?.write(Data("\r".utf8))
            agyLoginStage = "opening_browser"
            copilotResult = "Opening Google sign-in…"
        }

        if agyLoginURL == nil, let url = CallaAgyLoginParsing.signInURL(in: agyLoginBuffer) {
            agyLoginURL = url
            // The TUI accepts the pasted code from the moment the link is shown,
            // so this is the honest point to offer the field.
            agyLoginAwaitingCode = true
            agyLoginStage = "awaiting_code"
            let opened = openInBrowser(url)
            copilotResult = opened
                ? "Approve in your browser, then paste the code"
                : "Use the Open button — the browser could not be launched from here"
        }

        if CallaAgyLoginParsing.hasError(agyLoginBuffer) {
            agyLoginStage = "failed"
            copilotResult = CallaAgyLoginParsing.failureMessage(from: agyLoginBuffer, status: 0)
            // The screen sits on "Press any key to go back", so the flow is over
            // whatever the process does next.
            agyLoginAwaitingCode = false
        }
    }

    /// Credentials on disk are the authority on success, not the screen.
    ///
    /// Polls until they appear, then shuts the TUI down. Also the long stop: a
    /// sign-in nobody finishes must not leave a terminal running forever.
    private func watchLoginForCompletion(deadline: Date = Date().addingTimeInterval(600)) {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let process = self.agyLoginProcess, process.isRunning else { return }
            self.agyAuthCache = nil
            if self.agyAuthStatus().loggedIn {
                self.stopAgyLogin(reason: nil)
                return
            }
            if Date() >= deadline {
                self.stopAgyLogin(reason: "Sign-in timed out — start it again")
                return
            }
            self.watchLoginForCompletion(deadline: deadline)
        }
    }

    /// Ends a sign-in, killing the whole tree.
    ///
    /// `terminate()` reaches `script`; the `agy` underneath it is a separate
    /// process and would otherwise be left holding a terminal.
    private func stopAgyLogin(reason: String?) {
        if let process = agyLoginProcess, process.isRunning {
            for child in Self.childPIDs(of: process.processIdentifier) {
                kill(child, SIGTERM)
            }
            process.terminate()
        }
        if let reason { copilotResult = reason }
    }

    static func childPIDs(of pid: Int32) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { Int32($0) }
    }

    /// Best-effort only, and it says so.
    ///
    /// An XPC service is not guaranteed a GUI session, so `open` can fail here for
    /// reasons no amount of retrying fixes. The app opens the same URL from its own
    /// process — it is the GUI one — and this is the belt to that braces. Returns
    /// whether it worked so a failure is visible rather than a browser that never
    /// appears.
    @discardableResult
    private func openInBrowser(_ url: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    func submitAgyToken(_ token: String, with reply: @escaping (Data) -> Void) {
        queue.async {
            let code = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else {
                self.copilotResult = "Paste the code from the browser first"
                reply(self.encodedStatus()); return
            }
            guard let input = self.agyLoginInput, self.agyLoginProcess?.isRunning == true else {
                self.copilotResult = "No sign-in is waiting for a code — press Sign in again"
                reply(self.encodedStatus()); return
            }
            // Return, because the TUI is reading a line.
            input.write(Data((code + "\r").utf8))
            self.agyLoginStage = "exchanging"
            self.copilotResult = "Exchanging the code…"
            reply(self.encodedStatus())
        }
    }

    /// Clears the stored Google credential so the next sign-in starts fresh.
    ///
    /// Kept as a backup rather than deleted, and *not* auto-restored the way a
    /// failed re-authentication is — signing out is a decision, so undoing it is
    /// the user's call too (`restore_login`).
    private func signOutAgy() {
        guard copilotProcess?.isRunning != true else {
            copilotResult = "Cannot sign out while a call is running"; return
        }
        if let login = agyLoginProcess, login.isRunning {
            terminateProcessTree(login.processIdentifier)
            agyLoginProcess = nil
            agyLoginInput = nil
        }
        guard fileManager.fileExists(atPath: Self.credentialURL.path) else {
            copilotResult = "Not signed in"; return
        }
        try? fileManager.removeItem(at: Self.supersededCredentialURL)
        try? fileManager.moveItem(at: Self.credentialURL, to: Self.supersededCredentialURL)
        // The account file only records which account was active; a fresh sign-in
        // rewrites it, and leaving it behind makes the UI claim an account that no
        // longer has a credential.
        try? fileManager.removeItem(at: Self.accountsBackupURL)
        try? fileManager.moveItem(at: Self.accountsURL, to: Self.accountsBackupURL)
        // Resident hosts hold a language server authenticated as the old account.
        terminateStrayAgyHosts()
        agyExplicitSignOut = true
        agyAuthCache = nil
        agyProbe = nil
        agyLoginStage = nil
        agyLoginURL = nil
        agyLoginAwaitingCode = false
        copilotResult = "Signed out — press Sign in to authenticate again"
    }

    /// Puts back what `sign_out` set aside.
    private func restoreAgyCredentials() {
        guard fileManager.fileExists(atPath: Self.supersededCredentialURL.path) else {
            copilotResult = "No previous sign-in to restore"; return
        }
        try? fileManager.removeItem(at: Self.credentialURL)
        try? fileManager.moveItem(at: Self.supersededCredentialURL, to: Self.credentialURL)
        if fileManager.fileExists(atPath: Self.accountsBackupURL.path) {
            try? fileManager.removeItem(at: Self.accountsURL)
            try? fileManager.moveItem(at: Self.accountsBackupURL, to: Self.accountsURL)
        }
        agyExplicitSignOut = false
        agyAuthCache = nil
        agyProbe = nil
        let auth = agyAuthStatus()
        copilotResult = auth.account.map { "Restored sign-in for \($0)" } ?? "Restored the previous sign-in"
    }

    static var accountsURL: URL {
        URL(fileURLWithPath: userHome).appendingPathComponent(".gemini/google_accounts.json")
    }

    static var accountsBackupURL: URL {
        accountsURL.appendingPathExtension("superseded")
    }

    private func credentialFingerprint() -> String {
        let path = Self.credentialURL.path
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { return "absent" }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(size)-\(modified)"
    }

    static var credentialURL: URL {
        URL(fileURLWithPath: userHome).appendingPathComponent(".gemini/oauth_creds.json")
    }

    static var supersededCredentialURL: URL {
        credentialURL.appendingPathExtension("superseded")
    }

    /// Whether the stored credential can actually reach the model.
    ///
    /// The file existing only proves a sign-in happened once; it can be revoked or
    /// expired. This is the difference between "signed in" and "working", and it is
    /// the question a re-authentication actually turns on. Costs one tiny model
    /// call, which is the right price for not destroying a good credential.
    private func credentialWorks() -> Bool {
        guard let binary = agyBinaryPath() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-p", "ok", "--output-format", "json", "--print-timeout", "25s"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = Self.userHome
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        return process.terminationStatus == 0 && output.contains("\"status\":\"SUCCESS\"")
    }

    /// Puts a superseded credential back when a sign-in did not replace it.
    ///
    /// Without this, an abandoned or failed re-authentication leaves the user with
    /// no credential at all — worse off than before they pressed the button.
    private func restoreSupersededCredentialIfNeeded() {
        // A deliberate sign-out is not an accident to be repaired.
        guard !agyExplicitSignOut else { return }
        guard fileManager.fileExists(atPath: Self.supersededCredentialURL.path) else { return }
        if fileManager.fileExists(atPath: Self.credentialURL.path) {
            // A new credential arrived; the old one is genuinely superseded.
            try? fileManager.removeItem(at: Self.supersededCredentialURL)
            return
        }
        try? fileManager.moveItem(at: Self.supersededCredentialURL, to: Self.credentialURL)
        agyAuthCache = nil
    }


    private func agyBinaryPath() -> String? {
        ["~/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
            .map { ($0 as NSString).expandingTildeInPath }
            .first { fileManager.isExecutableFile(atPath: $0) }
    }

    private func runCourseScript(_ action: String, payload: [String: Any]) {
        guard courseControlProcess?.isRunning != true else { lastResult = "Course command already running"; return }
        guard let resource = Bundle.main.resourceURL?
            .appendingPathComponent("CallaRuntime/scripts/calla-course.sh"),
              fileManager.isExecutableFile(atPath: resource.path),
              JSONSerialization.isValidJSONObject(payload),
              let input = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            lastResult = "Course control script unavailable"; return
        }
        let process = Process(); process.executableURL = resource; process.arguments = [action]
        let stdin = Pipe(); process.standardInput = stdin
        process.standardOutput = Pipe(); process.standardError = Pipe()
        process.terminationHandler = { [weak self] process in
            self?.queue.async {
                self?.courseControlProcess = nil
                self?.lastResult = process.terminationStatus == 0 ? "Course command accepted" : "Course command did not complete"
                self?.appendDiagnostic("course control \(action): \(process.terminationStatus == 0 ? "accepted" : "failed")")
            }
        }
        do {
            try process.run(); stdin.fileHandleForWriting.write(input); stdin.fileHandleForWriting.closeFile()
            courseControlProcess = process; lastResult = "Course command sent"; appendDiagnostic("course control \(action): sent")
        } catch { lastResult = "Course command could not start" }
    }

    private func appendDiagnostic(_ line: String) {
        diagnostics.append(String(line.prefix(160)))
        diagnostics = Array(diagnostics.suffix(12))
    }

    private func prepareRuntimeDirectories() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["catalogue", "courses", "learning", "overlay", "logs", "cache"] {
            try fileManager.createDirectory(at: root.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    /// One-way, Boring-owned compatibility import. Never touches standalone
    /// Calla paths. Inputs are copied before decoding so malformed JSON remains
    /// available for repair and retries on a later Engine launch.
    private func importBoringTutorState() {
        guard let store else { return }
        let sourceRoot = root
        let importRoot = root.appendingPathComponent("legacy-import/v1", isDirectory: true)
        // Runtime precedes course-runs: a legacy run can be imported only after
        // the exact published revision is known to the Store.
        let candidates = ["catalogue.json", "course-status.json", "course-runtime.json", "course-runs.json"]
        let learningRoot = sourceRoot.appendingPathComponent("learning", isDirectory: true)
        let learning = (try? fileManager.contentsOfDirectory(at: learningRoot, includingPropertiesForKeys: [.isRegularFileKey]))?
            .filter { $0.pathExtension == "json" }.map { "learning/\($0.lastPathComponent)" } ?? []
        for relative in candidates + learning {
            let source = sourceRoot.appendingPathComponent(relative)
            guard let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize, size >= 0, size <= 5 * 1024 * 1024,
                  let bytes = try? Data(contentsOf: source) else { continue }
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let destination = importRoot.appendingPathComponent(relative)
            do {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
                if !fileManager.fileExists(atPath: destination.path) {
                    try bytes.write(to: destination, options: .atomic)
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                }
                let outcome = importBoringTutorDomain(relative: relative, data: bytes)
                _ = awaitOnQueue {
                    try? await store.recordTutorImport(sourceFile: relative, digest: digest,
                                                        status: outcome == nil ? "malformed" : "imported",
                                                        importedCount: outcome ?? 0,
                                                        errorCode: outcome == nil ? "invalid_shape" : nil)
                    return true
                }
            } catch {
                _ = awaitOnQueue {
                    try? await store.recordTutorImport(sourceFile: relative, digest: digest, status: "failed", importedCount: 0, errorCode: "copy_failed")
                    return true
                }
            }
        }
    }

    private func importBoringTutorDomain(relative: String, data: Data) -> Int? {
        let operation: String
        let payload: [String: Any]
        switch relative {
        case "catalogue.json":
            guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
            payload = object as? [String: Any] ?? ["courses": object]
            operation = "catalogue"
        case "course-status.json":
            guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
            payload = object as? [String: Any] ?? ["courses": object]
            operation = "course_status"
        case "course-runtime.json":
            guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
            payload = ["runtime": object]
            operation = "course_runtime"
        case "course-runs.json":
            guard let records = try? JSONDecoder().decode([String: CourseRunFile].self, from: data),
                  records.count <= 200, let store else { return nil }
            let values = records.compactMap { courseID, run -> TutorLegacyRunImport? in
                guard Self.validTutorID(courseID), run.entries.count <= 40,
                      run.checkpointLessonID.map(Self.validTutorID) ?? true else { return nil }
                let id = "legacy-" + SHA256.hash(data: Data(courseID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
                return TutorLegacyRunImport(runID: String(id), courseKey: courseID,
                                            checkpointLessonID: run.checkpointLessonID, eventCount: run.entries.count)
            }
            guard values.count == records.count else { return nil }
            return awaitOnQueue { try? await store.importTutorLegacyRuns(values) } ?? nil
        case let learningFile where learningFile.hasPrefix("learning/"):
            guard let legacy = try? JSONDecoder().decode(LegacyLearningRecord.self, from: data),
                  legacy.format == "calla-learning-record", legacy.formatVersion == 1,
                  Self.validTutorID(legacy.bundleID), Self.validTutorID(legacy.lessonID),
                  legacy.successes >= 0, legacy.intervalDays >= 0, legacy.intervalDays <= 36_500,
                  let store else { return nil }
            let due = legacy.nextDueAt.map(Date.init(timeIntervalSince1970:))
            let value = TutorLearningImport(bundleID: legacy.bundleID, lessonID: legacy.lessonID,
                                            successCount: legacy.successes, intervalDays: legacy.intervalDays, dueAt: due)
            return awaitOnQueue { try? await store.importTutorLearning([value]) } ?? nil
        default:
            return nil
        }
        let request: [String: Any] = [
            "protocol_version": 4, "request_id": "import-" + UUID().uuidString.lowercased(),
            "operation": operation, "session_id": "calla-import-v1", "payload": payload,
            "capability_token": engineIngressToken, "source_epoch": "legacy-import-v1", "source_sequence": 0,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: request),
              let response = try? JSONSerialization.jsonObject(with: handleEngineIngress(body)) as? [String: Any] else { return nil }
        return response["ok"] as? Bool == true ? 1 : nil
    }

    /// Node-only ingress for Gateway snapshots. Host has no receive path for
    /// these writes in Engine mode: Engine commits durable normalized state,
    /// then emits the compatibility projection Host may read.
    private func startEngineIngress() throws {
        guard engineIngress == nil else { return }
        engineIngressToken = UUID().uuidString.lowercased()
        let ingress = TutorEngineIngress(path: engineIngressURL.path) { [weak self] data in
            guard let self else {
                return Self.ingressReply(ok: false, code: "engine_unavailable", message: "Boring Engine is unavailable")
            }
            return self.queue.sync { self.handleEngineIngress(data) }
        }
        try ingress.start()
        engineIngress = ingress
    }

    private func handleEngineIngress(_ data: Data) -> Data {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Self.ingressReply(ok: false, code: "invalid_frame", message: "Engine ingress requires JSON object")
        }
        let allowed = Set(["protocol_version", "request_id", "operation", "session_id", "payload", "capability_token", "source_epoch", "source_sequence"])
        guard Set(object.keys).isSubset(of: allowed),
              let version = object["protocol_version"] as? Int, (2...4).contains(version),
              let requestID = object["request_id"] as? String, Self.validTutorID(requestID),
              let operation = object["operation"] as? String,
              let sessionID = object["session_id"] as? String, sessionID.count >= 8,
              let token = object["capability_token"] as? String, token == engineIngressToken,
              let payload = object["payload"] as? [String: Any] else {
            return Self.ingressReply(ok: false, code: "invalid_envelope", message: "Engine ingress rejected envelope")
        }
        let permitted = Set(["session_start", "catalogue", "course_status", "course_runtime", "gateway_health"])
        guard permitted.contains(operation) else {
            return Self.ingressReply(ok: false, code: "OPERATION_NOT_AVAILABLE_IN_ENGINE_MODE", message: "Operation unavailable in Boring Engine mode")
        }
        // v2/v3 transition snapshots had no source ordering. They may seed an
        // empty local cache once; current senders must carry epoch/sequence.
        let epoch = object["source_epoch"] as? String ?? "transition"
        let sequence = object["source_sequence"] as? Int ?? 0
        guard Self.validTutorID(epoch), sequence >= 0 else {
            return Self.ingressReply(ok: false, code: "invalid_snapshot_identity", message: "Gateway snapshot identity is invalid")
        }
        do {
            switch operation {
            case "session_start":
                guard let range = payload["supported_protocol_range"] as? [String: Any],
                      range["min"] as? Int != nil, range["max"] as? Int != nil,
                      let build = payload["engine_build"] as? String, !build.isEmpty,
                      let contract = payload["node_contract_hash"] as? String,
                      contract.range(of: "^[A-Fa-f0-9]{16,128}$", options: .regularExpression) != nil else {
                    return Self.ingressReply(ok: false, code: "invalid_session_start", message: "Capability handshake is invalid")
                }
                try writeCapabilityHandshake(CapabilityHandshake(engineBuild: build, nodeContractHash: contract, receivedAt: Date()))
            case "catalogue":
                guard payload["courses"] is [Any] else { return Self.ingressReply(ok: false, code: "invalid_catalogue", message: "Catalogue requires courses") }
                try writeEngineProjection("catalogue.json", payload["courses"]!)
            case "course_status":
                guard payload["courses"] is [Any] else { return Self.ingressReply(ok: false, code: "invalid_course_status", message: "Course status requires courses") }
                try writeEngineProjection("course-status.json", payload["courses"]!)
                if let courses = try? JSONDecoder().decode([LifecycleCourse].self,
                                                           from: JSONSerialization.data(withJSONObject: payload["courses"]!)),
                   let store {
                    _ = awaitOnQueue {
                        for course in courses {
                            if let lifecycle = TutorRevisionLifecycle(rawValue: course.phase) {
                                try? await store.setTutorRevisionLifecycle(courseKey: course.id, lifecycle: lifecycle)
                            }
                        }
                        return true
                    }
                }
            case "course_runtime":
                guard let runtime = payload["runtime"], JSONSerialization.isValidJSONObject(runtime) else {
                    return Self.ingressReply(ok: false, code: "invalid_course_runtime", message: "Runtime manifest is invalid")
                }
                let runtimeData = try JSONSerialization.data(withJSONObject: runtime, options: [.sortedKeys])
                guard runtimeData.count <= 5 * 1024 * 1024,
                      let manifest = try? JSONDecoder().decode(RuntimeManifest.self, from: runtimeData),
                      manifest.format == "calla-course-runtime", manifest.formatVersion == 1,
                      !manifest.courses.isEmpty else {
                    return Self.ingressReply(ok: false, code: "invalid_course_runtime", message: "Runtime manifest is unsupported")
                }
                try persistRuntimeManifest(manifest, rawData: runtimeData, epoch: epoch, sequence: sequence)
                try writeEngineProjection("course-runtime.json", runtime)
            case "gateway_health":
                try writeEngineProjection("gateway-health.json", payload)
            default: break
            }
            return Self.ingressReply(ok: true, code: nil, message: nil)
        } catch {
            appendDiagnostic("Engine ingress \(operation) refused: \(error.localizedDescription)")
            return Self.ingressReply(ok: false, code: "snapshot_refused", message: "Engine could not commit Gateway snapshot")
        }
    }

    private func persistRuntimeManifest(_ manifest: RuntimeManifest, rawData: Data, epoch: String, sequence: Int) throws {
        let catalogue = Dictionary(uniqueKeysWithValues: (try? JSONDecoder().decode([CatalogueCourse].self, from: Data(contentsOf: root.appendingPathComponent("catalogue.json"))))?.map { ($0.id, $0) } ?? [])
        let lifecycle = Dictionary(uniqueKeysWithValues: currentLifecycle().map { ($0.id, $0.phase) })
        let digest = SHA256.hash(data: rawData).map { String(format: "%02x", $0) }.joined()
        guard let store else { throw TutorRuntimeError.socketUnavailable }
        let result: String = awaitOnQueue {
            do {
                for course in manifest.courses {
                    let title = catalogue[course.courseID]?.title ?? course.courseID
                    let phase = TutorRevisionLifecycle(rawValue: lifecycle[course.courseID] ?? "ready_for_review") ?? .readyForReview
                    let lessons = course.lessons.enumerated().map { index, lesson in
                        TutorLessonRecord(lessonID: lesson.id, ordinal: index,
                                          title: catalogue[course.courseID]?.lessons.first(where: { $0.id == lesson.id })?.title ?? lesson.id,
                                          stepCount: lesson.steps.count)
                    }
                    try await store.upsertTutorCourseRevision(TutorCourseRevisionRecord(
                        courseKey: course.courseID, revision: course.courseRevision, lifecycle: phase,
                        title: title, targetBundleID: course.appBundleID, targetVersion: course.appVersion,
                        artifactDigest: digest, packContractVersion: 1), lessons: lessons)
                    try await store.upsertTutorRuntimeManifest(TutorRuntimeManifestRecord(
                        courseKey: course.courseID, revision: course.courseRevision,
                        manifestJSON: String(decoding: rawData, as: UTF8.self), digest: digest,
                        sourceEpoch: epoch, sourceSequence: sequence))
                }
                return "ok"
            } catch { return String(error.localizedDescription.prefix(240)) }
        } ?? "store_timeout"
        guard result == "ok" else {
            throw NSError(domain: "BoringCallaEngine.TutorRuntime", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Runtime persistence failed: \(result)"])
        }
    }

    private func writeEngineProjection(_ name: String, _ object: Any) throws {
        let allowed = Set(["catalogue.json", "course-status.json", "course-runtime.json", "gateway-health.json"])
        guard allowed.contains(name), JSONSerialization.isValidJSONObject(object) else { throw TutorRuntimeError.invalidResponse }
        let destination = root.appendingPathComponent(name)
        let temporary = root.appendingPathComponent(".\(name).\(UUID().uuidString)")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary, backupItemName: nil, options: [])
        } else { try fileManager.moveItem(at: temporary, to: destination) }
    }

    private func writeCapabilityHandshake(_ value: CapabilityHandshake) throws {
        let destination = root.appendingPathComponent("capability-handshake.json")
        let data = try JSONEncoder().encode(value)
        try data.write(to: destination, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private static func validTutorID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9._-]{1,160}$", options: .regularExpression) != nil
    }

    /// Normalize user whitespace before applying Tutor's 800-character limit.
    /// Directional controls survive normal trimming and can make provider text
    /// render differently from what was reviewed, so reject them outright.
    private static func sanitizeTutorQuestion(_ raw: String) -> String? {
        let forbiddenBidi: Set<UInt32> = [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
        for scalar in raw.unicodeScalars {
            if forbiddenBidi.contains(scalar.value) { return nil }
            if scalar.properties.generalCategory == .control && !CharacterSet.whitespacesAndNewlines.contains(scalar) { return nil }
        }
        let normalized = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !normalized.isEmpty, normalized.count <= 800,
              !normalized.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        return normalized
    }

    private func tutorFeedbackContext(run: TutorRunRecord, lessonID: String, stepID: String,
                                      verifierOutcome: String?, store: CallaStore) -> String {
        let outcome = verifierOutcome.map { " Deterministic verifier outcome: \($0)." } ?? ""
        let authored = storedRuntime(courseID: run.courseKey, revision: run.revision)?
            .courses.first(where: { $0.courseID == run.courseKey && $0.courseRevision == run.revision })?
            .lessons.first(where: { $0.id == lessonID })?
            .steps.first(where: { $0.id == stepID })?.text
            .map { " Authored current-step instruction: \(String($0.prefix(2_000)))." } ?? ""
        let historyPage: TutorHistoryPage? = awaitOnQueue {
            try? await store.tutorFeedbackHistory(pageSize: 6)
        } ?? nil
        let previous = historyPage?.entries ?? []
        let history = previous.reversed().compactMap { record -> String? in
            let question = record.question.map { "Q: \($0)" }
            let answer = record.answer.map { "A: \($0)" }
            let pair = [question, answer].compactMap { $0 }.joined(separator: " ")
            return pair.isEmpty ? nil : pair
        }.joined(separator: " | ")
        let recent = history.isEmpty ? "" : " Recent feedback: \(String(history.prefix(8 * 1024)))"
        return String("Course \(run.courseKey), revision \(run.revision), lesson \(lessonID), step \(stepID).\(authored)\(outcome)\(recent)".prefix(16 * 1024))
    }

    /// Re-decode Host bytes before encryption. Marker bytes do not establish
    /// JPEG MIME, dimensions, or meaningful visual variance.
    private static func validTutorJPEG(_ data: Data, expectedWidth: Int, expectedHeight: Int) -> Bool {
        guard expectedWidth > 0, expectedHeight > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let sourceType = CGImageSourceGetType(source),
              sourceType as String == UTType.jpeg.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == expectedWidth, image.height == expectedHeight,
              max(image.width, image.height) <= 2048 else { return false }
        let sampleWidth = min(32, image.width), sampleHeight = min(32, image.height)
        guard sampleWidth > 0, sampleHeight > 0 else { return false }
        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        guard let context = CGContext(data: &pixels, width: sampleWidth, height: sampleHeight,
                                      bitsPerComponent: 8, bytesPerRow: sampleWidth * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
        var minimum: UInt8 = .max, maximum: UInt8 = .min
        for value in pixels where value != 255 { minimum = min(minimum, value); maximum = max(maximum, value) }
        return maximum > minimum && maximum - minimum >= 4
    }

    private static func ingressReply(ok: Bool, code: String?, message: String?) -> Data {
        var body: [String: Any] = ["ok": ok]
        if let code { body["code"] = code }
        if let message { body["message"] = message }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{\"ok\":false}".utf8)
    }

    /// Both children inherit the XPC service's stdio, which goes nowhere. Until
    /// this existed the only node log on disk was the one the retired
    /// `com.calla.openclaw-node-host` LaunchAgent wrote via `StandardOutPath`,
    /// so disabling that agent also blinded `BackendStatus`. Give each child its
    /// own owner-only file under the private runtime root instead of sharing
    /// `~/Library/Logs/Calla`, where two hosts' lines were indistinguishable.
    private func childLogHandle(_ name: String) -> FileHandle? {
        let file = root.appendingPathComponent("logs/\(name).log")
        if !fileManager.fileExists(atPath: file.path) {
            fileManager.createFile(atPath: file.path, contents: nil,
                                   attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return nil }
        // Append: a restart must not truncate the evidence of why the last run died.
        _ = try? handle.seekToEnd()
        return handle
    }

    private func writePreferences(_ preferences: Preferences) throws {
        let destination = root.appendingPathComponent("engine-preferences.json")
        let temporary = root.appendingPathComponent(".engine-preferences-\(UUID().uuidString)")
        let data = try JSONEncoder().encode(preferences)
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    /// XPC may restart before Boring redraws Settings. Restore only the
    /// engine's own last complete Boring snapshot, never legacy Calla data.
    private func restorePreferences() {
        let file = root.appendingPathComponent("engine-preferences.json")
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(Preferences.self, from: data) else { return }
        preferences = stored
    }

    private func startRuntime() throws {
        guard runtime?.isRunning != true else { return }
        let resource = Bundle.main.resourceURL?
            .appendingPathComponent("CallaRuntime/CallaTutorHost.app/Contents/MacOS/CallaTutorHost")
        guard let executable = resource, fileManager.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "CallaRuntime/CallaTutorHost.app"])
        }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["CALLA_RUNTIME_ROOT"] = root.path
        // Engine mode is a security boundary, not presentation detail. Host may
        // execute bounded capture/verifier/overlay work only; it must never
        // revive standalone Gateway teaching relays for Boring.
        environment["CALLA_RUNTIME_MODE"] = "engine"
        process.environment = environment
        if let log = childLogHandle("tutor-host") {
            process.standardOutput = log
            process.standardError = log
        }
        let pidFile = runtimePIDURL
        process.terminationHandler = { [weak self] child in
            self?.queue.async {
                guard let self else { return }
                self.clearOwnedPID(at: pidFile, matching: child.processIdentifier)
                self.isRunning = false
                // The host calls NSApp.terminate(nil) — a clean exit 0 — when it
                // finds another host already holding the socket. Reporting that
                // as a plain stop hid the one failure with an obvious cause, so
                // ask who is still answering before naming it.
                if RuntimeSocketClient.answers(path: self.socketURL.path) {
                    let message = "Another Tutor host already holds the runtime socket; Boring stood down"
                    self.lastResult = message
                    self.appendDiagnostic(message)
                } else {
                    self.lastResult = "Tutor runtime stopped (status \(child.terminationStatus))"
                }
            }
        }
        try process.run()
        runtime = process
        try writeOwnedPID(process.processIdentifier, to: runtimePIDURL)
    }

    /// Node process has no UI and never owns preferences. Its plugin location
    /// is installed by Boring's narrow runtime installer; the engine only
    /// keeps the one Boring-owned Calla Mac connection alive while Boring runs.
    private func startNodeRuntime() throws {
        guard ProcessInfo.processInfo.environment["CALLA_DISABLE_NODE"] != "1" else { return }
        guard nodeRuntime?.isRunning != true else { return }
        // Refuse to be the second node. Starting one anyway is what produced the
        // flap: the Gateway accepts one `Calla Mac`, evicts the duplicate, and
        // the survivor's KeepAlive brings it straight back. This holds even if
        // somebody re-enables the retired LaunchAgent.
        if let pid = foreignNodeProcess() {
            appendDiagnostic("Not starting a node: another Calla Mac node is running (pid \(pid))")
            return
        }
        guard let appResources = appCallaResources(),
              fileManager.fileExists(atPath: appResources.appendingPathComponent("openclaw/openclaw.plugin.json").path),
              fileManager.isExecutableFile(atPath: appResources.appendingPathComponent("scripts/calla-node-host.sh").path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "Calla node resources"])
        }
        let process = Process()
        process.executableURL = appResources.appendingPathComponent("scripts/calla-node-host.sh")
        process.currentDirectoryURL = appResources
        var environment = ProcessInfo.processInfo.environment
        // Fixed private Tailscale Serve route for nomonhomelab. Short DNS is
        // intentionally not used: it resolves but does not present gateway
        // TLS identity on this owner network.
        environment["CALLA_NODE_GATEWAY_HOST"] = "nomonhomelab.tailec0dca.ts.net"
        environment["CALLA_NODE_GATEWAY_PORT"] = "443"
        environment["CALLA_NODE_GATEWAY_TLS"] = "true"
        environment["CALLA_NODE_DISPLAY_NAME"] = "Calla Mac"
        environment["CALLA_RUNTIME_ROOT"] = root.path
        environment["CALLA_RUNTIME_MODE"] = "engine"
        environment["CALLA_ENGINE_INGRESS_SOCKET"] = engineIngressURL.path
        environment["CALLA_ENGINE_CAPABILITY_TOKEN"] = engineIngressToken
        process.environment = environment
        if let log = childLogHandle("node-host") {
            process.standardOutput = log
            process.standardError = log
        }
        let pidFile = nodePIDURL
        process.terminationHandler = { [weak self] child in
            self?.queue.async {
                self?.clearOwnedPID(at: pidFile, matching: child.processIdentifier)
                guard self?.isRunning == true else { return }
                self?.lastResult = "Calla Mac node stopped (status \(child.terminationStatus)); re-pairing will retry"
            }
        }
        try process.run()
        nodeRuntime = process
        try writeOwnedPID(process.processIdentifier, to: nodePIDURL)
    }

    /// Drop the socket file once nothing is bound to it, so the next `start`
    /// does not meet a leftover from the last one.
    ///
    /// Only ever when the probe says dead. Unlinking a live socket is exactly
    /// how two hosts end up believing they each own the runtime.
    private func removeSocketIfUnbound(waitingUpTo seconds: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !RuntimeSocketClient.answers(path: socketURL.path) {
                try? fileManager.removeItem(at: socketURL)
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// The retired standalone install listens here. Boring moved its own socket
    /// under the private runtime root, so the two hosts never see each other:
    /// each one's stand-down check probes only its own path, and both then run,
    /// both claim the same global and lesson hotkeys, and both draw an overlay.
    private var legacyHostSocketPath: String {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/CallaTutor/tutor-host.sock").path
    }

    /// Report a competing install. Detection only — never kill and never
    /// delete, by the same rule that governs `reclaimStaleOwnedChildren`.
    /// Boring owns its own children and nothing else.
    private func detectConflicts() {
        if RuntimeSocketClient.answers(path: legacyHostSocketPath) {
            appendDiagnostic("A legacy Calla TutorHost is running and will fight for lesson shortcuts")
        }
        if let pid = foreignNodeProcess() {
            appendDiagnostic("Another Calla Mac node is already running (pid \(pid))")
        }
    }

    /// A node process that is not ours. Two nodes registering the same
    /// `Calla Mac` identity make the Gateway evict one, and whichever agent
    /// holds KeepAlive respawns it, so the pair flap indefinitely.
    private func foreignNodeProcess() -> pid_t? {
        let ours = nodeRuntime?.processIdentifier
        let ourDescendants = ours.map { Set(childProcesses(of: $0) + [$0]) } ?? []
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        process.standardOutput = output
        guard (try? process.run()) != nil else { return nil }
        // Drain before waiting. Full command lines run to tens of kilobytes, and
        // a pipe holds 64K: waiting first deadlocks the engine's serial queue
        // against a `ps` that is blocked writing into a buffer nobody is reading.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: " "),
                  let pid = pid_t(trimmed[trimmed.startIndex..<separator]) else { continue }
            let command = trimmed[separator...]
            guard command.contains("openclaw-node") else { continue }
            if ourDescendants.contains(pid) { continue }
            return pid
        }
        return nil
    }

    private func appCallaResources() -> URL? {
        // XPC bundle lives at App/Contents/XPCServices/Engine.xpc. Production
        // and Debug both place immutable plugin resources at App/Contents/Resources/Calla.
        let xpc = Bundle.main.bundleURL
        return xpc.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Calla", isDirectory: true)
    }

    /// launchd can reclaim an XPC instance before its descendants. Reclaim
    /// only Boring-recorded PIDs; never scan or kill generic OpenClaw work.
    private func reclaimStaleOwnedChildren() {
        if runtime?.isRunning != true {
            reclaimOwnedProcess(at: runtimePIDURL)
            runtime = nil
            // A reclaimed host leaves its socket file behind the same way a
            // stopped one does.
            removeSocketIfUnbound(waitingUpTo: 0.5)
        }
        if nodeRuntime?.isRunning != true {
            reclaimOwnedProcess(at: nodePIDURL)
            nodeRuntime = nil
        }
        if copilotProcess?.isRunning != true {
            reclaimOwnedProcess(at: copilotPIDURL)
            copilotProcess = nil
            // A reclaimed host is a dead call. Clear the status file so the
            // notch cannot keep showing a call that ended with the process.
            try? fileManager.removeItem(at: copilotStatusURL)
        }
    }

    private func reclaimOwnedProcess(at file: URL) {
        guard let value = try? String(contentsOf: file, encoding: .utf8),
              let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1, pid != getpid() else {
            clearOwnedPID(at: file)
            return
        }
        terminateProcessTree(pid)
        clearOwnedPID(at: file)
    }

    private func writeOwnedPID(_ pid: pid_t, to file: URL) throws {
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent)-\(UUID().uuidString)")
        guard let data = "\(pid)\n".data(using: .utf8) else { return }
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: file.path) {
            _ = try fileManager.replaceItemAt(file, withItemAt: temporary, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: temporary, to: file)
        }
    }

    private func clearOwnedPID(at file: URL, matching pid: pid_t? = nil) {
        if let pid,
           let value = try? String(contentsOf: file, encoding: .utf8),
           value.trimmingCharacters(in: .whitespacesAndNewlines) != "\(pid)" { return }
        try? fileManager.removeItem(at: file)
    }

    private func terminateProcessTree(_ pid: pid_t) {
        guard pid > 1, pid != getpid() else { return }
        for descendant in childProcesses(of: pid).reversed() { Darwin.kill(descendant, SIGTERM) }
        Darwin.kill(pid, SIGTERM)
    }

    private func childProcesses(of rootPID: pid_t) -> [pid_t] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]
        process.standardOutput = output
        guard (try? process.run()) != nil else { return [] }
        // Drain before waiting, for the same reason as `foreignNodeProcess`.
        // This output is small enough to have got away with it so far.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return [] }
        let parents = text.split(separator: "\n").reduce(into: [pid_t: [pid_t]]()) { result, line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return }
            result[parent, default: []].append(pid)
        }
        func descendants(_ parent: pid_t) -> [pid_t] {
            let children = parents[parent, default: []]
            return children + children.flatMap(descendants)
        }
        return descendants(rootPID)
    }

    private func startGatewayMonitor() {
        guard gatewayMonitor == nil else { return }
        probeGateway()
        let monitor = DispatchSource.makeTimerSource(queue: queue)
        monitor.schedule(deadline: .now() + 15, repeating: 15)
        monitor.setEventHandler { [weak self] in self?.probeGateway() }
        monitor.resume()
        gatewayMonitor = monitor
    }

    private func stopGatewayMonitor() {
        gatewayMonitor?.cancel()
        gatewayMonitor = nil
    }

    /// Fixed private Tailscale Serve route. Capability receipt separately
    /// proves Tutor contract, while this tracks current route reachability.
    private func probeGateway() {
        guard let url = URL(string: "https://nomonhomelab.tailec0dca.ts.net/") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            let reachable = (response as? HTTPURLResponse).map { (200..<400).contains($0.statusCode) } ?? false
            self?.queue.async { self?.gatewayReachable = reachable }
        }.resume()
    }

    private var isInstalledBoringApp: Bool {
        let app = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return app.path.hasPrefix("/Applications/")
    }

    /// Installed Boring owns one immutable Gateway artifact. Debug deployment
    /// is staged by Xcode instead. This merely requests private owner-SSH
    /// update; the Gateway manifest short-circuits unchanged digests.
    private func requestGatewayUpdate(trigger: String) {
        guard gatewayUpdate?.isRunning != true else {
            lastResult = "Gateway update already running"
            return
        }
        guard let resources = appCallaResources() else {
            lastResult = "Gateway update unavailable: Calla resources missing"
            return
        }
        let script = resources.appendingPathComponent("scripts/gateway-update.sh")
        let artifact = resources.appendingPathComponent("Gateway/calla-gateway.tar.gz")
        guard fileManager.isExecutableFile(atPath: script.path), fileManager.fileExists(atPath: artifact.path) else {
            lastResult = "Gateway update unavailable: bundled release missing"
            return
        }
        let output = Pipe()
        let process = Process()
        process.executableURL = script
        process.arguments = ["--bundle", artifact.path]
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { [weak self] child in
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self?.queue.async {
                self?.gatewayUpdate = nil
                self?.recordGatewayUpdate(output: text, succeeded: child.terminationStatus == 0,
                                          terminationStatus: child.terminationStatus)
            }
        }
        do {
            try process.run()
            gatewayUpdate = process
            lastResult = "Gateway update requested (\(trigger))"
        } catch {
            lastResult = "Gateway update could not start: \(error.localizedDescription)"
        }
    }

    private func startEngineCourse(courseID: String, lessonID: String?) {
        guard activeTutorRun == nil else { lastResult = "Stop current Tutor run before starting another"; return }
        guard let store, let published = awaitOnQueue({ try? await store.publishedTutorRevision(courseKey: courseID) }) ?? nil,
              published.artifactDigest.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil else {
            lastResult = "Course revision is not published locally; requesting resync"
            return
        }
        guard let runtime = storedRuntime(courseID: courseID, revision: published.revision),
              let course = runtime.courses.first(where: { $0.courseID == courseID && $0.courseRevision == published.revision }),
              let lesson = lessonID.flatMap({ wanted in course.lessons.first(where: { $0.id == wanted }) }) ?? course.lessons.first,
              let step = lesson.steps.first else {
            lastResult = "Exact course runtime is unavailable; requesting resync"
            return
        }
        let run = TutorRunRecord(runID: "run-" + UUID().uuidString.lowercased(), courseKey: courseID,
                                 revision: course.courseRevision, generation: tutorGeneration, status: .starting,
                                 lessonID: lesson.id, stepID: step.id)
        guard awaitOnQueue({
            do { try await store.createTutorRun(run); return true } catch { return false }
        }) == true else {
            lastResult = "Could not persist Tutor run before start"
            return
        }
        let response = invokeRuntimeResponse(operation: "engine_start_run", payload: [
            "run_id": run.runID, "generation": run.generation, "course_id": courseID,
            "revision": run.revision, "lesson_id": lesson.id, "step_id": step.id,
        ])
        guard response.ok else {
            _ = awaitOnQueue { try? await store.updateTutorRun(runID: run.runID, generation: run.generation, status: .failed, event: "host_start_refused", note: response.message); return true }
            lastResult = response.message
            return
        }
        _ = awaitOnQueue { try? await store.updateTutorRun(runID: run.runID, generation: run.generation, status: .active, event: "host_started"); return true }
        activeTutorRun = TutorRunRecord(runID: run.runID, courseKey: run.courseKey, revision: run.revision,
                                        generation: run.generation, status: .active, lessonID: lesson.id, stepID: step.id,
                                        startedAt: run.startedAt)
        automaticTutorFeedbackTrigger = nil
        startTutorObservation()
        lastResult = "Tutor course started"
    }

    private func renderEngineStep(run: TutorRunRecord) {
        guard let runtime = storedRuntime(courseID: run.courseKey, revision: run.revision),
              let course = runtime.courses.first(where: { $0.courseID == run.courseKey && $0.courseRevision == run.revision }),
              let lesson = course.lessons.first(where: { $0.id == run.lessonID }),
              let stepID = run.stepID,
              let index = lesson.steps.firstIndex(where: { $0.id == stepID }) else {
            lastResult = "Exact runtime changed; Tutor run blocked pending resync"; return
        }
        let response = invokeRuntimeResponse(operation: "engine_render_step", payload: [
            "run_id": run.runID, "generation": run.generation, "revision": run.revision,
            "lesson_id": lesson.id, "step_id": stepID, "step_index": index,
        ])
        lastResult = response.ok ? "Tutor step rendered" : response.message
    }

    /// Deterministic checks poll Host. A satisfied receipt is the only input
    /// that advances Engine's persisted run; Host never selects the next step.
    private func startTutorObservation() {
        guard tutorObservationTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.observeEngineRun() }
        timer.resume()
        tutorObservationTimer = timer
    }

    private func stopTutorObservation() {
        tutorObservationTimer?.cancel(); tutorObservationTimer = nil
    }

    private func observeEngineRun() {
        guard let run = activeTutorRun, let lessonID = run.lessonID, let stepID = run.stepID else { return }
        let receipt = invokeRuntimeResponse(operation: "engine_verify_step", payload: [
            "run_id": run.runID, "generation": run.generation, "revision": run.revision,
            "lesson_id": lessonID, "step_id": stepID,
        ])
        guard receipt.ok else {
            // A Host restart cannot leave a stored run silently advancing.
            if receipt.message.contains("stale_engine_run") {
                lastResult = "Tutor Host restarted; resume this run to render its exact step"
            }
            return
        }
        let outcome = receipt.payload?["outcome"] as? String ?? "unknown"
        lastTutorVerification = outcome
        guard outcome == "satisfied" else {
            guard outcome == "unsatisfied" || outcome == "unknown" else { return }
            if let store {
                _ = awaitOnQueue {
                    try? await store.updateTutorRun(runID: run.runID, generation: run.generation,
                                                     status: .active, event: "deterministic_hold",
                                                     verifierOutcome: outcome)
                    return true
                }
            }
            let trigger = (runID: run.runID, generation: run.generation, stepID: stepID, outcome: outcome)
            if activeTutorFeedbackID == nil,
               automaticTutorFeedbackTrigger?.runID != trigger.runID ||
               automaticTutorFeedbackTrigger?.generation != trigger.generation ||
               automaticTutorFeedbackTrigger?.stepID != trigger.stepID ||
               automaticTutorFeedbackTrigger?.outcome != trigger.outcome {
                automaticTutorFeedbackTrigger = trigger
                requestTutorFeedback(question: nil, kind: "verification_\(outcome)", verifierOutcome: outcome)
            }
            return
        }
        guard let runtime = storedRuntime(courseID: run.courseKey, revision: run.revision),
              let course = runtime.courses.first(where: { $0.courseID == run.courseKey && $0.courseRevision == run.revision }),
              let lesson = course.lessons.first(where: { $0.id == lessonID }),
              let index = lesson.steps.firstIndex(where: { $0.id == stepID }) else {
            blockEngineRun(run, reason: "Exact runtime disappeared during verification")
            return
        }
        if index == lesson.steps.count - 1 {
            if let store { _ = awaitOnQueue { try? await store.updateTutorRun(runID: run.runID, generation: run.generation, status: .completed, event: "deterministic_completion", verifierOutcome: "satisfied"); return true } }
            _ = invokeRuntimeResponse(operation: "engine_stop_run", payload: [
                "run_id": run.runID, "generation": run.generation, "revision": run.revision, "lesson_id": lessonID,
            ])
            activeTutorRun = nil; automaticTutorFeedbackTrigger = nil; tutorGeneration += 1; stopTutorObservation(); lastResult = "Tutor course completed"
            return
        }
        let next = lesson.steps[index + 1]
        if let store { _ = awaitOnQueue { try? await store.updateTutorRun(runID: run.runID, generation: run.generation, status: .active, lessonID: lessonID, stepID: next.id, event: "deterministic_advance", verifierOutcome: "satisfied"); return true } }
        let advanced = TutorRunRecord(runID: run.runID, courseKey: run.courseKey, revision: run.revision,
                                      generation: run.generation, status: .active, lessonID: lessonID, stepID: next.id,
                                      startedAt: run.startedAt)
        activeTutorRun = advanced
        automaticTutorFeedbackTrigger = nil
        renderEngineStep(run: advanced)
    }

    private func blockEngineRun(_ run: TutorRunRecord, reason: String) {
        if let store { _ = awaitOnQueue { try? await store.updateTutorRun(runID: run.runID, generation: run.generation, status: .blockedRuntime, event: "runtime_blocked", note: reason); return true } }
        activeTutorRun = nil; automaticTutorFeedbackTrigger = nil; stopTutorObservation(); lastResult = reason
    }

    /// Captures exactly current target window, encrypts and commits history,
    /// then (and only then) makes a provider route eligible. Host never writes
    /// a screenshot; Gateway never sees one on storage/key failure.
    private func requestTutorFeedback(question: String?, kind: String, verifierOutcome: String? = nil) {
        guard let run = activeTutorRun, let lessonID = run.lessonID, let stepID = run.stepID else {
            lastResult = "No active Tutor run to ask about"; return
        }
        guard let store else { lastResult = "Tutor history storage is unavailable"; return }
        let feedbackID = "feedback-" + UUID().uuidString.lowercased()
        let context = tutorFeedbackContext(run: run, lessonID: lessonID, stepID: stepID,
                                           verifierOutcome: verifierOutcome, store: store)
        guard let vault = resolveTutorCaptureVault() else {
            recordTutorFeedbackFailure(id: feedbackID, run: run, kind: kind, question: question, context: context,
                                       code: "history_encryption_unavailable", store: store)
            lastResult = tutorCaptureFailure ?? "Tutor history encryption is unavailable"; return
        }
        let response = invokeRuntimeResponse(operation: "engine_capture_feedback", payload: [
            "run_id": run.runID, "generation": run.generation, "revision": run.revision,
            "lesson_id": lessonID, "step_id": stepID,
        ])
        guard response.ok,
              let payload = response.payload,
              payload["mime_type"] as? String == "image/jpeg",
              let encoded = payload["bytes_base64"] as? String,
              let image = Data(base64Encoded: encoded),
              image.count <= 3 * 1024 * 1024,
              image.starts(with: [0xFF, 0xD8, 0xFF]), image.suffix(2) == Data([0xFF, 0xD9]),
              let width = payload["pixel_width"] as? Int, let height = payload["pixel_height"] as? Int,
              Self.validTutorJPEG(image, expectedWidth: width, expectedHeight: height) else {
            recordTutorFeedbackFailure(id: feedbackID, run: run, kind: kind, question: question, context: context,
                                       code: response.ok ? "capture_invalid" : "capture_unavailable", store: store)
            lastResult = response.ok ? "Target window capture was invalid" : response.message
            return
        }
        let captureID = "capture-" + UUID().uuidString.lowercased()
        do {
            let stored = try vault.storeJPEG(image, id: captureID)
            let capture = TutorCaptureRecord(id: captureID, relativePath: stored.relativePath,
                                             ciphertextDigest: stored.ciphertextDigest, width: width, height: height,
                                             byteCount: image.count)
            let preference = awaitOnQueue { (try? await store.tutorProviderPreference()) ?? .local } ?? .local
            let feedback = TutorFeedbackRecord(id: feedbackID, runID: run.runID, generation: run.generation,
                                                kind: kind, question: question,
                                                context: context,
                                                state: .pending, selectedProvider: preference, captureID: captureID)
            let committed = awaitOnQueue {
                do { try await store.commitTutorCaptureAndPendingFeedback(capture: capture, feedback: feedback); return true }
                catch { return false }
            } ?? false
            guard committed else {
                vault.removeUncommitted(relativePath: stored.relativePath)
                lastResult = "Tutor feedback was not stored; screenshot was not sent"
                return
            }
            // Provider integration is intentionally a separate method. Keeping
            // this call after the commit is a hard ordering boundary reviewers
            // can verify without reading model transport code.
            routeCommittedTutorFeedback(feedback, image: image, width: width, height: height, run: run)
        } catch {
            recordTutorFeedbackFailure(id: feedbackID, run: run, kind: kind, question: question, context: context,
                                       code: "capture_encryption_failed", store: store)
            lastResult = "Tutor feedback capture could not be secured"
        }
    }

    private func recordTutorFeedbackFailure(id: String, run: TutorRunRecord, kind: String, question: String?, context: String,
                                            code: String, store: CallaStore) {
        _ = awaitOnQueue {
            try? await store.recordTerminalTutorFeedback(TutorFeedbackRecord(
                id: id, runID: run.runID, generation: run.generation, kind: kind,
                question: question, context: context, state: .failed,
                selectedProvider: (try? await store.tutorProviderPreference()) ?? .local,
                errorCode: code))
            return true
        }
    }

    private func resolveTutorCaptureVault() -> TutorCaptureVault? {
        if let tutorCaptureVault { return tutorCaptureVault }
        do {
            let vault = try TutorCaptureVault(root: tutorCaptureURL, key: TutorHistoryKey.loadOrCreate())
            vault.removeTemporaryFiles()
            tutorCaptureVault = vault
            tutorCaptureFailure = nil
            return vault
        } catch {
            tutorCaptureFailure = "Tutor history encryption is unavailable"
            return nil
        }
    }

    /// The fallback boundary starts only after encrypted capture metadata and
    /// pending feedback committed. Local `agy` image attachment support is
    /// capability-gated; unsupported local binaries fall through once to this
    /// dedicated tool-free Gateway lane. Gateway preference never reverses.
    private func routeCommittedTutorFeedback(_ feedback: TutorFeedbackRecord, image: Data, width: Int, height: Int, run: TutorRunRecord) {
        guard tutorFeedbackProcess == nil else { lastResult = "Tutor feedback already pending"; return }
        let fallback = feedback.selectedProvider == .local ? "local_attachment_unsupported" : nil
        startGatewayTutorFeedback(feedback, image: image, width: width, height: height, run: run, fallbackReason: fallback)
    }

    private func startGatewayTutorFeedback(_ feedback: TutorFeedbackRecord, image: Data, width: Int, height: Int, run: TutorRunRecord, fallbackReason: String?) {
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("CallaRuntime/scripts/calla-feedback.sh"),
              fileManager.isExecutableFile(atPath: script.path) else {
            finishTutorFeedback(feedback, state: .failed, actualProvider: nil, fallbackReason: fallbackReason, errorCode: "gateway_feedback_script_missing")
            return
        }
        let request: [String: Any] = [
            "protocol_version": 4, "request_id": feedback.id, "run_id": run.runID, "generation": run.generation,
            "course_key": run.courseKey, "revision": run.revision, "lesson_id": run.lessonID ?? "", "step_id": run.stepID ?? "",
            "question": feedback.question ?? NSNull(), "context": feedback.context,
            "image": ["mime_type": "image/jpeg", "pixel_width": width, "pixel_height": height, "bytes_base64": image.base64EncodedString()],
        ]
        guard JSONSerialization.isValidJSONObject(request),
              let input = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]), input.count <= 5 * 1024 * 1024 else {
            finishTutorFeedback(feedback, state: .failed, actualProvider: nil, fallbackReason: fallbackReason, errorCode: "gateway_feedback_request_invalid")
            return
        }
        let process = Process(); process.executableURL = script; process.arguments = []
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        let started = Date()
        let timeout = DispatchWorkItem { [weak self, weak process] in
            guard let self, let process, self.activeTutorFeedbackID == feedback.id, process.isRunning else { return }
            self.terminateProcessTree(process.processIdentifier)
        }
        process.terminationHandler = { [weak self] completed in
            timeout.cancel()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            self?.queue.async {
                guard let self else { return }
                if self.tutorFeedbackProcess === completed { self.tutorFeedbackProcess = nil }
                if self.activeTutorFeedbackID == feedback.id { self.activeTutorFeedbackID = nil }
                if self.activeTutorFeedback?.id == feedback.id { self.activeTutorFeedback = nil }
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                guard completed.terminationStatus == 0,
                      let reply = Self.parseTutorGatewayReply(output) else {
                    self.finishTutorFeedback(feedback, state: .failed, actualProvider: .gateway, fallbackReason: fallbackReason, errorCode: "gateway_feedback_unavailable", latencyMilliseconds: elapsed)
                    return
                }
                guard self.activeTutorRun?.runID == feedback.runID,
                      self.activeTutorRun?.generation == feedback.generation else {
                    self.finishTutorFeedback(feedback, state: .stale, actualProvider: .gateway, fallbackReason: fallbackReason, errorCode: "run_generation_changed", latencyMilliseconds: elapsed)
                    return
                }
                self.finishTutorFeedback(feedback, state: .completed, answer: reply.message, actualProvider: .gateway,
                                         model: reply.model, fallbackReason: fallbackReason, latencyMilliseconds: elapsed)
            }
        }
        do {
            try process.run()
            stdin.fileHandleForWriting.write(input); stdin.fileHandleForWriting.closeFile()
            tutorFeedbackProcess = process; activeTutorFeedbackID = feedback.id; activeTutorFeedback = feedback
            // Gateway preference is deliberately one-way and gets its own
            // twelve-second ceiling. A local-selected request keeps the full
            // fifteen-second total budget because its single eligible fallback
            // consumes that same end-to-end budget.
            let deadlineSeconds = feedback.selectedProvider == .gateway ? 12 : 15
            queue.asyncAfter(deadline: .now() + .seconds(deadlineSeconds), execute: timeout)
            lastResult = fallbackReason == nil ? "Tutor feedback requested from Gateway" : "Local feedback unavailable; requesting Gateway feedback"
        } catch {
            finishTutorFeedback(feedback, state: .failed, actualProvider: .gateway, fallbackReason: fallbackReason, errorCode: "gateway_feedback_start_failed")
        }
    }

    private struct TutorGatewayReply { let message: String; let model: String? }

    private static func parseTutorGatewayReply(_ data: Data) -> TutorGatewayReply? {
        guard data.count <= 16 * 1024,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["ok"] as? Bool == true,
              let reply = value["reply"] as? [String: Any], Set(reply.keys) == ["message", "assessment", "basis"],
              let message = reply["message"] as? String, message.count > 0, message.count <= 800,
              let assessment = reply["assessment"] as? String, ["on_track", "needs_help", "uncertain"].contains(assessment),
              let basis = reply["basis"] as? String, ["screenshot", "verifier", "authored"].contains(basis) else { return nil }
        let model = (value["model"] as? String).map { String($0.prefix(256)) }
        return TutorGatewayReply(message: message, model: model)
    }

    private func finishTutorFeedback(_ feedback: TutorFeedbackRecord, state: TutorFeedbackState, answer: String? = nil,
                                     actualProvider: TutorProviderPreference?, model: String? = nil, fallbackReason: String? = nil,
                                     errorCode: String? = nil, latencyMilliseconds: Int? = nil) {
        guard let store else { return }
        let committed = awaitOnQueue {
            try? await store.finishTutorFeedback(TutorFeedbackRecord(
                id: feedback.id, runID: feedback.runID, generation: feedback.generation, kind: feedback.kind,
                question: feedback.question, context: feedback.context, state: state, answer: answer,
                selectedProvider: feedback.selectedProvider, actualProvider: actualProvider, model: model,
                latencyMilliseconds: latencyMilliseconds, fallbackReason: fallbackReason, errorCode: errorCode,
                captureID: feedback.captureID)); return true
        } ?? false
        guard committed else { return }
        if activeTutorFeedback?.id == feedback.id { activeTutorFeedback = nil }
        if state == .completed { lastResult = "Tutor feedback ready" }
        else if state == .stale { lastResult = "Tutor feedback became stale" }
        else { lastResult = "Tutor feedback unavailable; authored guidance remains" }
    }

    private func stopEngineCourse() {
        guard let run = activeTutorRun else { lastResult = "No Tutor run is active"; return }
        _ = invokeRuntimeResponse(operation: "engine_stop_run", payload: [
            "run_id": run.runID, "generation": run.generation, "revision": run.revision, "lesson_id": run.lessonID ?? "",
        ])
        if let store { _ = awaitOnQueue { try? await store.updateTutorRun(runID: run.runID, generation: run.generation, status: .stopped, event: "owner_stopped"); return true } }
        cancelActiveTutorFeedback(reason: "run_stopped")
        activeTutorRun = nil
        automaticTutorFeedbackTrigger = nil
        tutorGeneration += 1
        stopTutorObservation()
        lastResult = "Tutor run stopped"
    }

    private func cancelActiveTutorFeedback(reason: String) {
        if let process = tutorFeedbackProcess, process.isRunning { terminateProcessTree(process.processIdentifier) }
        tutorFeedbackProcess = nil
        activeTutorFeedbackID = nil
        guard let feedback = activeTutorFeedback else { return }
        activeTutorFeedback = nil
        if let store {
            _ = awaitOnQueue { try? await store.transitionTutorFeedback(id: feedback.id, generation: feedback.generation, state: .cancelled, errorCode: reason); return true }
        }
    }

    private func invokeRuntime(operation: String, payload: [String: Any]) {
        _ = invokeRuntimeResponse(operation: operation, payload: payload)
    }

    private func invokeRuntimeResponse(operation: String, payload: [String: Any]) -> (ok: Bool, message: String, payload: [String: Any]?) {
        // Probe rather than stat. `stop()` used to leave the socket file behind,
        // so `fileExists` passed against a host that was gone and every command
        // then failed at connect with a generic transport error.
        guard RuntimeSocketClient.answers(path: socketURL.path) else {
            lastResult = fileManager.fileExists(atPath: socketURL.path)
                ? "Tutor runtime is not listening"
                : "Tutor runtime is still starting"
            return (false, lastResult, nil)
        }
        let request: [String: Any] = [
            "protocol_version": 4,
            "request_id": UUID().uuidString.lowercased(),
            "operation": operation,
            "session_id": "calla-boring-ui",
            "payload": payload,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: request)
            let response = try RuntimeSocketClient.invoke(path: socketURL.path, request: data)
            guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let ok = object["ok"] as? Bool else {
                throw TutorRuntimeError.invalidResponse
            }
            if ok {
                let responsePayload = object["payload"] as? [String: Any]
                lastResult = responsePayload?["status"] as? String ?? "Tutor command complete"
                return (true, lastResult, responsePayload)
            } else {
                let message = ((object["error"] as? [String: Any])?["message"] as? String) ?? "Tutor command refused"
                lastResult = message
                return (false, message, nil)
            }
        } catch {
            lastResult = "Tutor command failed: \(error.localizedDescription)"
            return (false, lastResult, nil)
        }
    }

    private func recordGatewayUpdate(output: String, succeeded: Bool, terminationStatus: Int32) {
        let previous = currentGatewayUpdate()
        let marker = output.split(separator: "\n").last(where: { $0.hasPrefix("CALLA_GATEWAY_RESULT\t") })
        let fields = marker?.split(separator: "\t", omittingEmptySubsequences: false) ?? []
        let outcome = fields.count > 1 ? String(fields[1]) : ""
        let current = fields.count > 2 && !fields[2].isEmpty ? String(fields[2]) : previous?.currentRelease
        let prior = fields.count > 3 && !fields[3].isEmpty ? String(fields[3]) : previous?.previousRelease
        let fallback: String
        if succeeded, outcome == "unchanged" {
            fallback = "Gateway release unchanged"
        } else if succeeded {
            fallback = "Gateway update complete"
        } else {
            fallback = "Gateway update failed: exit \(terminationStatus)"
        }
        // Gateway stdout can include transport and tool detail. Boring keeps a
        // receipt state only, never raw Gateway output.
        let summary = fallback
        let record = GatewayUpdateRecord(currentRelease: current, previousRelease: prior,
                                         summary: summary, completedAt: Date())
        do {
            try writeGatewayUpdate(record)
            lastResult = summary
        } catch {
            lastResult = "\(summary) (could not persist receipt: \(error.localizedDescription))"
        }
    }

    private func currentGatewayUpdate() -> GatewayUpdateRecord? {
        let file = root.appendingPathComponent("gateway-update.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(GatewayUpdateRecord.self, from: data)
    }

    private func writeGatewayUpdate(_ record: GatewayUpdateRecord) throws {
        let destination = root.appendingPathComponent("gateway-update.json")
        let temporary = root.appendingPathComponent(".gateway-update-\(UUID().uuidString)")
        let data = try JSONEncoder().encode(record)
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private func encodedStatus() -> Data {
        let handshake = currentCapabilityHandshake()
        let gatewayUpdate = currentGatewayUpdate()
        let hasVerifiedHandshake = handshake != nil
        // Read from the host's receipt, not from this process. TCC grants are
        // per executable and CallaTutorHost is what captures, so preflighting
        // here reported the XPC service's own grant — which is why Settings
        // said "Required" against a host holding both.
        let hostStatus = currentHostStatus()
        let status = Status(
            running: isRunning,
            hostReady: RuntimeSocketClient.answers(path: socketURL.path),
            socketPath: socketURL.path,
            screenRecordingGranted: hostStatus?.screenRecordingGranted ?? false,
            accessibilityGranted: hostStatus?.accessibilityGranted ?? false,
            gatewayReachable: gatewayReachable,
            nodeConnected: gatewayReachable && hasVerifiedHandshake && nodeRuntime?.isRunning == true,
            releaseVersion: gatewayUpdate?.currentRelease,
            previousGatewayRelease: gatewayUpdate?.previousRelease,
            lastGatewayUpdate: gatewayUpdate?.summary,
            lastGatewayUpdateAt: gatewayUpdate?.completedAt,
            engineBuild: handshake?.engineBuild,
            lastResult: lastResult,
            diagnostics: diagnostics,
            activeLesson: currentActiveLesson(),
            courses: currentCourses(),
            tutorIntelligence: currentTutorIntelligenceStatus(hostStatus: hostStatus),
            copilot: currentCopilotStatus()
        )
        do {
            let data = try JSONEncoder().encode(status)
            for object in statusObservers.allObjects {
                (object as? BoringCallaEngineStatusObserver)?.callaEngineStatusDidChange(data)
            }
            return data
        } catch {
            // Empty Data decodes to nothing on the far side, which looked
            // exactly like a dropped reply. The client logs its half; this is
            // the other one.
            NSLog("[CallaEngine] could not encode status: %@", String(describing: error))
            return Data()
        }
    }

    private func currentTutorIntelligenceStatus(hostStatus: HostStatus?) -> TutorIntelligenceStatus {
        let preference: TutorProviderPreference
        if let store {
            preference = awaitOnQueue { (try? await store.tutorProviderPreference()) ?? .local } ?? .local
        } else {
            preference = .local
        }
        let agy = agyAvailability()
        let auth = agyAuthStatus()
        let capability = currentCapabilityHandshake()
        let statusStore = store
        let history: TutorHistoryPage? = awaitOnQueue {
            try? await statusStore?.tutorFeedbackHistory(pageSize: 1)
        } ?? nil
        let statistics: TutorHistoryStats? = awaitOnQueue {
            try? await statusStore?.tutorHistoryStats()
        } ?? nil
        let latest = history?.entries.first
        return TutorIntelligenceStatus(
            selectedProvider: preference.rawValue,
            activeProvider: activeTutorFeedbackID == nil ? nil : "gateway",
            pendingFeedbackID: activeTutorFeedbackID,
            activeRunID: activeTutorRun?.runID,
            activeRevision: activeTutorRun?.revision,
            activeGeneration: activeTutorRun?.generation,
            localAgyAvailable: agy.available,
            localAgyVersion: agy.version,
            localAgyAuthenticated: auth.loggedIn,
            gatewayFeedbackAvailable: gatewayReachable,
            gatewayAuthoringAvailable: gatewayReachable,
            nodeTransportHealthy: gatewayReachable && capability != nil && nodeRuntime?.isRunning == true,
            engineIngressHealthy: engineIngress != nil,
            captureAvailable: preferences?.captureEnabled == true && hostStatus?.screenRecordingGranted == true,
            lastProvider: latest?.actualProvider?.rawValue,
            lastModel: latest?.model,
            lastLatencyMilliseconds: latest?.latencyMilliseconds,
            lastFallbackReason: latest?.fallbackReason,
            lastDeterministicVerification: lastTutorVerification,
            historyByteCount: statistics?.captureByteCount ?? 0,
            captureCount: statistics?.captureCount ?? 0,
            storageFailure: tutorCaptureFailure,
            protocolVersion: 4
        )
    }

    private func currentCourses() -> [CourseSnapshot] {
        let file = root.appendingPathComponent("catalogue.json")
        guard let data = try? Data(contentsOf: file),
              let courses = try? JSONDecoder().decode([CatalogueCourse].self, from: data) else { return [] }
        let hidden = Set(preferences?.hiddenCourseIDs ?? [])
        let lifecycle = currentLifecycle().reduce(into: [String: LifecycleCourse]()) { $0[$1.id] = $1 }
        let runs = currentCourseRuns()
        let runtime = currentRuntime().reduce(into: [String: RuntimeCourse]()) { $0[$1.courseID] = $1 }
        let learning = currentLearning()
        return courses.prefix(100).map { course in
            let target = course.bundleIDs?.first
            let run = runs[course.id]
            let runtimeCourse = runtime[course.id]
            let lessons = course.lessons.prefix(100).map { lesson -> LessonSnapshot in
                let record = target.flatMap { learning["\($0)|\(lesson.id)"] }
                return LessonSnapshot(id: lesson.id, title: String(lesson.title.prefix(160)),
                                      stepCount: runtimeCourse?.lessons.first(where: { $0.id == lesson.id })?.steps.count ?? 0,
                                      completed: (record?.successes ?? 0) > 0,
                                      dueForReview: (record?.successes ?? 0) > 0 && (record?.nextDueAt ?? .greatestFiniteMagnitude) <= Date().timeIntervalSince1970)
            }
            let life = lifecycle[course.id]
            let progress = CallaCoursePresentation.progress(lessons.map { (completed: $0.completed, due: $0.dueForReview) })
            return CourseSnapshot(
                id: course.id, title: String(course.title.prefix(160)), summary: String(course.summary.prefix(360)),
                icon: String((course.icon ?? "books.vertical.fill").prefix(80)), targetApp: target,
                hidden: CallaCoursePresentation.isHidden(courseID: course.id, hiddenIDs: hidden), completedCount: progress.completed,
                dueForReview: progress.due, checkpointLessonID: run?.checkpointLessonID,
                recentThread: Array((run?.entries ?? []).suffix(8).map { safeThread($0.text) }),
                lifecyclePhase: CallaCoursePresentation.lifecyclePhase(life?.phase), lifecycleNote: safeLifecycle(life?.nextAction ?? life?.error),
                runtimeVersion: runtimeCourse?.appVersion,
                runtimeBlocked: runtimeCourse != nil && target != runtimeCourse?.appBundleID,
                lessons: lessons)
        }
    }

    private func currentLifecycle() -> [LifecycleCourse] {
        decodeFile("course-status.json", as: [LifecycleCourse].self) ?? []
    }

    private func currentLifecycleIDs() -> Set<String> { Set(currentLifecycle().map(\.id)) }

    private func currentCourseRuns() -> [String: CourseRunFile] {
        decodeFile("course-runs.json", as: [String: CourseRunFile].self) ?? [:]
    }

    private func currentRuntime() -> [RuntimeCourse] {
        guard let store else { return [] }
        let records: [TutorRuntimeManifestRecord] = awaitOnQueue {
            (try? await store.tutorRuntimeManifestRecords()) ?? []
        } ?? []
        return records.compactMap { record in
            guard let runtime = try? JSONDecoder().decode(RuntimeManifest.self, from: Data(record.manifestJSON.utf8)) else { return nil }
            return runtime.courses.first(where: { $0.courseID == record.courseKey && $0.courseRevision == record.revision })
        }
    }

    /// Reads one exact, Store-committed revision. Projections are intentionally
    /// excluded: a stale file may aid legacy rollback diagnostics but may never
    /// start, render, verify, or advance a Boring-owned Tutor run.
    private func storedRuntime(courseID: String, revision: String) -> RuntimeManifest? {
        guard let store else { return nil }
        let stored: TutorRuntimeManifestRecord? = awaitOnQueue {
            do { return try await store.tutorRuntimeManifest(courseKey: courseID, revision: revision) }
            catch { return nil }
        } ?? nil
        guard let record = stored,
              let runtime = try? JSONDecoder().decode(RuntimeManifest.self, from: Data(record.manifestJSON.utf8)),
              runtime.format == "calla-course-runtime", runtime.formatVersion == 1,
              runtime.courses.contains(where: { $0.courseID == courseID && $0.courseRevision == revision }) else { return nil }
        return runtime
    }

    private func currentLearning() -> [String: LearningRecord] {
        let directory = root.appendingPathComponent("learning", isDirectory: true)
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.prefix(300).reduce(into: [String: LearningRecord]()) { result, file in
            guard let record = try? JSONDecoder().decode(LearningRecord.self, from: Data(contentsOf: file)),
                  CallaCourseCommandValidation.bundleID(record.bundleID) != nil,
                  CallaCourseCommandValidation.identifier(record.lessonID) != nil else { return }
            result["\(record.bundleID)|\(record.lessonID)"] = record
        }
    }

    private func currentActiveLesson() -> ActiveLesson? {
        guard let lesson = decodeFile("active-lesson.json", as: ActiveLesson.self), lesson.active,
              currentCourses().contains(where: { $0.id == lesson.courseID && $0.lessons.contains(where: { $0.id == lesson.lessonID }) }) else { return nil }
        return lesson
    }

    private func decodeFile<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        let file = root.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func safeThread(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        return String(clean.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(240))
    }

    private func safeLifecycle(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.replacingOccurrences(of: #"https?://\S+|(?:~|/)[^\s]+"#, with: "[redacted]", options: .regularExpression)
        return String(clean.replacingOccurrences(of: "\n", with: " ").prefix(240))
    }

    private func currentCapabilityHandshake() -> CapabilityHandshake? {
        let file = root.appendingPathComponent("capability-handshake.json")
        guard let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(CapabilityHandshake.self, from: data),
              !value.engineBuild.isEmpty,
              value.nodeContractHash.range(of: "^[A-Fa-f0-9]{16,128}$", options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    /// The host refreshes this every five seconds while it is alive. A stale
    /// receipt means the host is gone or wedged, and reporting its last known
    /// grants as current would show "Allowed" for a process that is not there.
    private func currentHostStatus(maximumAge: TimeInterval = 60) -> HostStatus? {
        guard let value = decodeFile("host-status.json", as: HostStatus.self),
              Date().timeIntervalSince(value.updatedAt) <= maximumAge else { return nil }
        return value
    }
}

private enum TutorRuntimeError: LocalizedError {
    case socketUnavailable
    case invalidResponse
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .socketUnavailable: return "Tutor runtime socket is unavailable"
        case .invalidResponse: return "Tutor runtime returned an invalid response"
        case .responseTooLarge: return "Tutor runtime response exceeded limit"
        }
    }
}

/// Engine-to-runtime half of the owner-only local socket. The node has a
/// JavaScript client; Boring UI must cross XPC through this bounded native one.
private enum RuntimeSocketClient {
    /// Engine capture replies may carry a 3 MiB JPEG plus base64 framing. They
    /// never leave this owner-local socket and ordinary control requests remain
    /// bounded by Host's 64 KiB input limit.
    private static let maximumResponseBytes = 5 * 1024 * 1024

    static func invoke(path: String, request: Data) throws -> Data {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TutorRuntimeError.socketUnavailable }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 12, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let byteCount = path.utf8.count + 1
        guard byteCount <= MemoryLayout.size(ofValue: address.sun_path) else { throw TutorRuntimeError.socketUnavailable }
        _ = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { strncpy($0, source, byteCount) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sa_family_t>.size + byteCount))
            }
        }
        guard connected == 0 else { throw TutorRuntimeError.socketUnavailable }
        var message = request
        message.append(0x0A)
        let sent = message.withUnsafeBytes { write(descriptor, $0.baseAddress, message.count) }
        guard sent == message.count else { throw TutorRuntimeError.socketUnavailable }
        _ = shutdown(descriptor, SHUT_WR)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let received = read(descriptor, &buffer, buffer.count)
            if received == 0 { break }
            guard received > 0 else { throw TutorRuntimeError.socketUnavailable }
            response.append(buffer, count: received)
            if response.count > maximumResponseBytes { throw TutorRuntimeError.responseTooLarge }
            if response.contains(0x0A) { break }
        }
        guard let newline = response.firstIndex(of: 0x0A) else { throw TutorRuntimeError.invalidResponse }
        return response.prefix(upTo: newline)
    }

    /// Whether anything is listening. `FileManager.fileExists` cannot answer
    /// this: a socket file outlives the process that bound it, so a stale one
    /// reads as present and every command then fails at connect instead.
    ///
    /// Connect-only, no write — this must never disturb a host mid-lesson, and
    /// it is also how a foreign host on the retired path is detected.
    static func answers(path: String, timeoutSeconds: Int32 = 1) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: Int(timeoutSeconds), tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let byteCount = path.utf8.count + 1
        guard byteCount <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        _ = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { strncpy($0, source, byteCount) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sa_family_t>.size + byteCount))
            }
        }
        return connected == 0
    }
}
