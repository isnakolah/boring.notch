import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

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
    var copilot: CopilotStatus = CopilotStatus()
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
    var suggestionAfterSeq: Int? = nil
    var lastResult: String? = nil
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

/// Mirrors the gateway's `suggestion` frame as persisted by the host.
private struct CopilotSuggestionFile: Codable {
    var callID: String
    var afterSeq: Int
    var headline: String
    var angles: [String]
    var confirm: [String]

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case afterSeq = "after_seq"
        case headline
        case angles
        case confirm
    }
}

/// Typed copilot command from the owner UI.
private struct CopilotCommand: Codable {
    var action: String
    var persona: String?
    var model: String?
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

private struct RuntimeManifest: Decodable { let courses: [RuntimeCourse] }
private struct RuntimeCourse: Decodable {
    let courseID: String; let appBundleID: String; let appVersion: String; let lessons: [RuntimeLesson]
    enum CodingKeys: String, CodingKey { case lessons; case courseID = "course_id", appBundleID = "app_bundle_id", appVersion = "app_version" }
}
private struct RuntimeLesson: Decodable {
    let id: String; let steps: [RuntimeStep]
}
private struct RuntimeStep: Decodable { let id: String }
private struct LearningRecord: Decodable {
    let lessonID: String; let bundleID: String; let successes: Int; let nextDueAt: Double?
    enum CodingKeys: String, CodingKey { case successes; case lessonID = "lesson_id", bundleID = "bundle_id", nextDueAt = "next_due_at" }
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

private struct CapabilityHandshake: Decodable {
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
    private var copilotPersona = "generic"
    private var copilotModel = "whisper-small-en"
    private var copilotResult: String?
    /// The host writes ISO-8601 dates; the default decoder would reject them.
    private lazy var jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private var gatewayUpdate: Process?
    private var courseControlProcess: Process?
    private var gatewayReachable = false
    private var gatewayMonitor: DispatchSourceTimer?
    private var diagnostics: [String] = []

    private var root: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("boringNotch/Calla", isDirectory: true)
    }

    private var socketURL: URL { root.appendingPathComponent("tutor-host.sock") }
    private var runtimePIDURL: URL { root.appendingPathComponent("runtime.pid") }
    private var nodePIDURL: URL { root.appendingPathComponent("node.pid") }

    func start(with reply: @escaping (Data) -> Void) {
        queue.async {
            NSLog("[CallaEngine] start requested")
            do {
                try self.prepareRuntimeDirectories()
                self.restorePreferences()
                self.reclaimStaleOwnedChildren()
                self.detectConflicts()
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

    func stop(with reply: @escaping (Data) -> Void) {
        queue.async {
            self.stopGatewayMonitor()
            if let runtime = self.runtime { self.terminateProcessTree(runtime.processIdentifier) }
            self.runtime = nil
            self.clearOwnedPID(at: self.runtimePIDURL)
            if let nodeRuntime = self.nodeRuntime { self.terminateProcessTree(nodeRuntime.processIdentifier) }
            self.nodeRuntime = nil
            self.clearOwnedPID(at: self.nodePIDURL)
            // The call host holds the microphone. Leaving it running after the
            // engine stops would keep a recording indicator lit with nothing
            // driving it, so it goes down with everything else.
            if let copilot = self.copilotProcess, copilot.isRunning {
                kill(copilot.processIdentifier, SIGINT)
                self.terminateProcessTree(copilot.processIdentifier)
            }
            self.copilotProcess = nil
            self.clearOwnedPID(at: self.copilotPIDURL)
            try? self.fileManager.removeItem(at: self.copilotStatusURL)
            self.gatewayReachable = false
            self.isRunning = false
            self.removeSocketIfUnbound()
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
            self.invokeRuntime(operation: "course_start", payload: ["course_id": courseID])
            reply(self.encodedStatus())
        }
    }

    func resumeCourse(with reply: @escaping (Data) -> Void) {
        queue.async {
            self.invokeRuntime(operation: "course_resume", payload: [:])
            reply(self.encodedStatus())
        }
    }

    func stopLesson(with reply: @escaping (Data) -> Void) {
        queue.async {
            self.invokeRuntime(operation: "course_stop", payload: [:])
            reply(self.encodedStatus())
        }
    }

    func ask(_ text: String, with reply: @escaping (Data) -> Void) {
        queue.async {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= 800 else {
                self.lastResult = "Ask needs one short question"
                reply(self.encodedStatus())
                return
            }
            self.invokeRuntime(operation: "course_ask", payload: ["text": clean])
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
        let allowedActions: Set<String> = ["start_lesson", "start_again", "import", "cancel", "retry", "archive", "restore", "revise", "refresh_runtime"]
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
            invokeRuntime(operation: "course_start", payload: ["course_id": courseID, "lesson_id": lessonID])
        case "start_again":
            guard let courseID else { lastResult = "Rejected invalid course identifier"; return }
            invokeRuntime(operation: "course_start_again", payload: ["course_id": courseID])
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
        case "cancel", "retry", "archive", "restore":
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
    private var copilotSuggestionURL: URL { copilotRoot.appendingPathComponent("latest-suggestion.json") }
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
            case "stop": self.stopCopilot()
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
            default: break
            }
            reply(self.encodedStatus())
        }
    }

    private func startCopilot(_ command: CopilotCommand) {
        guard copilotProcess?.isRunning != true else { copilotResult = "Call already running"; return }
        guard let executable = copilotExecutable else {
            copilotResult = "Call host is not installed"; return
        }
        if let persona = CallaCopilotCommandValidation.persona(command.persona) { copilotPersona = persona }
        if let model = CallaCopilotCommandValidation.liveModel(command.model) { copilotModel = model }
        guard let gateway = CallaCopilotCommandValidation.gatewayURL(Self.copilotGateway) else {
            copilotResult = "Copilot gateway route is not valid"; return
        }

        // Screen Recording is what captures the other party. Without it the
        // call still runs, but only our own side is transcribed — which makes
        // the suggestions close to useless, so say so rather than fail quietly.
        if !CGPreflightScreenCaptureAccess() {
            copilotResult = "Grant Screen Recording to capture the other party"
        }

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.arguments = [
            "serve",
            "--gateway", gateway.absoluteString,
            "--persona", copilotPersona,
            "--model", copilotModel,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["CALLA_RUNTIME_ROOT"] = root.path
        process.environment = environment
        let pidFile = copilotPIDURL
        process.terminationHandler = { [weak self] child in
            self?.queue.async {
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
            if copilotResult == nil { copilotResult = "Call started" }
        } catch {
            copilotResult = "Could not start call host: \(error.localizedDescription)"
        }
    }

    private func stopCopilot() {
        guard let process = copilotProcess, process.isRunning else {
            copilotResult = "No call running"
            try? fileManager.removeItem(at: copilotStatusURL)
            return
        }
        // SIGINT rather than terminate(): the host flushes its endpointers,
        // drains the transcription queue and closes the WAVs on it, so a
        // trailing sentence is not lost.
        kill(process.processIdentifier, SIGINT)
        copilotResult = "Ending call…"
    }

    func copilotTranscript(with reply: @escaping (Data) -> Void) {
        queue.async {
            reply(self.currentCopilotTranscript())
        }
    }

    /// Reads the live call's `transcript.jsonl`, newest turns last.
    ///
    /// Bounded on purpose: an hour-long call is thousands of turns, and the
    /// window only ever shows the tail. Reading the whole file into an XPC
    /// reply would stall the engine queue that also serves the status poll.
    private func currentCopilotTranscript(limit: Int = 400) -> Data {
        guard let callID = (try? Data(contentsOf: copilotStatusURL))
            .flatMap({ try? jsonDecoder.decode(CopilotHostStatus.self, from: $0) })?.callID,
            let validID = CallaCopilotCommandValidation.callID(callID) else {
            return Data("[]".utf8)
        }
        let file = copilotRoot
            .appendingPathComponent("calls", isDirectory: true)
            .appendingPathComponent(validID, isDirectory: true)
            .appendingPathComponent("transcript.jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return Data("[]".utf8) }
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(limit)
        return Data(("[" + lines.joined(separator: ",") + "]").utf8)
    }

    private func currentCopilotStatus() -> CopilotStatus {
        var status = CopilotStatus()
        status.available = copilotExecutable != nil
        status.persona = copilotPersona
        status.lastResult = copilotResult

        if let data = try? Data(contentsOf: copilotStatusURL),
           let host = try? jsonDecoder.decode(CopilotHostStatus.self, from: data) {
            status.running = copilotProcess?.isRunning == true
            status.callID = host.callID
            status.persona = host.persona
            status.startedAt = host.startedAt
            status.turnCount = host.turnCount
            status.gatewayConnected = host.gatewayConnected
            status.micActive = host.micActive
            status.systemAudioActive = host.systemAudioActive

            if let suggestionData = try? Data(contentsOf: copilotSuggestionURL),
               let suggestion = try? jsonDecoder.decode(CopilotSuggestionFile.self, from: suggestionData),
               // A suggestion left over from an earlier call must never be
               // shown against the current one.
               suggestion.callID == host.callID {
                status.headline = suggestion.headline
                status.angles = suggestion.angles
                status.confirm = suggestion.confirm
                status.suggestionAfterSeq = suggestion.afterSeq
            }
        }
        return status
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
        environment["CALLA_RUNTIME_MODE"] = "boring"
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

    private func invokeRuntime(operation: String, payload: [String: Any]) {
        // Probe rather than stat. `stop()` used to leave the socket file behind,
        // so `fileExists` passed against a host that was gone and every command
        // then failed at connect with a generic transport error.
        guard RuntimeSocketClient.answers(path: socketURL.path) else {
            lastResult = fileManager.fileExists(atPath: socketURL.path)
                ? "Tutor runtime is not listening"
                : "Tutor runtime is still starting"
            return
        }
        let request: [String: Any] = [
            "protocol_version": 2,
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
                lastResult = (object["payload"] as? [String: Any])?["status"] as? String ?? "Tutor command complete"
            } else {
                let message = ((object["error"] as? [String: Any])?["message"] as? String) ?? "Tutor command refused"
                lastResult = message
            }
        } catch {
            lastResult = "Tutor command failed: \(error.localizedDescription)"
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
            copilot: currentCopilotStatus()
        )
        do {
            return try JSONEncoder().encode(status)
        } catch {
            // Empty Data decodes to nothing on the far side, which looked
            // exactly like a dropped reply. The client logs its half; this is
            // the other one.
            NSLog("[CallaEngine] could not encode status: %@", String(describing: error))
            return Data()
        }
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
        (decodeFile("course-runtime.json", as: RuntimeManifest.self)?.courses ?? []).prefix(200).map { $0 }
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
    private static let maximumResponseBytes = 1_500_000

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
