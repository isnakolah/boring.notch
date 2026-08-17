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
    func copilotTranscript(with reply: @escaping (Data) -> Void)
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
    var suggestionAfterSeq: Int? = nil
    var lastResult: String? = nil

    var hasSuggestion: Bool {
        guard let headline else { return false }
        return !headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
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

/// Typed copilot command. Mirrors the engine's own decoder; the engine
/// re-validates every field before anything is spawned.
struct CallaCopilotCommand: Codable {
    let action: String
    let persona: String?
    let model: String?

    init(action: String, persona: String? = nil, model: String? = nil) {
        self.action = action
        self.persona = persona
        self.model = model
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
                // Idle cadence is what bounds how late the notch can be to a
                // lesson someone started from Settings or the calendar.
                try? await Task.sleep(for: .seconds(teaching ? 2 : 4))
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
        send(CallaCopilotCommand(action: "start", persona: persona, model: model))
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

    /// Fetches the live call's recent turns.
    ///
    /// Deliberately not on the status poll: the transcript is large, and only
    /// the window ever wants it.
    func fetchTranscript(completion: @escaping ([CallaCallTurn]) -> Void) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            NSLog("[CallaEngine] transcript unavailable: %@", error.localizedDescription)
            Task { @MainActor in completion([]) }
        }) as? BoringCallaEngineProtocol else { return }
        proxy.copilotTranscript { data in
            let turns = (try? JSONDecoder().decode([CallaCallTurn].self, from: data)) ?? []
            Task { @MainActor in completion(turns) }
        }
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
