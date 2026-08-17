import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI
import TutorProtocol

/// What this request may observe.
///
/// The lesson says which applications it is about; the user says which ones
/// Calla is allowed near at all. The answer is the intersection, so a lesson can
/// narrow the user's choice and never widen it.
@MainActor
private func allowlist(from payload: [String: JSONValue]) -> Set<String> {
    var requested: Set<String>?
    if case .array(let ids)? = payload["allowed_bundle_ids"] {
        requested = Set(ids.compactMap { value -> String? in
            if case .string(let id) = value, !id.isEmpty, id.count <= 255 { return id }
            return nil
        })
    }
    return TutorSettings.shared.effectiveAllowlist(requested: requested)
}
private let maxRequestFrameBytes = 64 * 1024
private let maxResponseFrameBytes = Int(1.5 * 1024 * 1024)
private let maxCaptureJPEGBytes = 1024 * 1024
private let forbiddenCoordinateKeys: Set<String> = [
    "x", "y", "left", "top", "width", "height", "coordinate", "coordinates", "screen_x", "screen_y", "bounds", "frame",
]

private struct TutorRequest: Codable, Sendable {
    let protocolVersion: Int
    let requestID: String
    let operation: String
    let sessionID: String
    let payload: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestID = "request_id"
        case operation
        case sessionID = "session_id"
        case payload
    }
}

private struct TutorError: Codable, Sendable { let code: String; let message: String }
private struct TutorResponse: Codable, Sendable {
    let requestID: String
    let ok: Bool
    let payload: [String: JSONValue]?
    let error: TutorError?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case ok
        case payload
        case error
    }
}

struct Snapshot {
    let id = UUID().uuidString
    let createdAt = Date()
    let processID: pid_t
    let windowID: CGWindowID
    let windowFrame: CGRect
    let appBundleID: String
    let appVersion: String
    /// The rectangle the image handed to the model actually covered, as
    /// ScreenCaptureKit reported it. A normalized region is a fraction of *that*
    /// picture, so this — not the window server's bounds — is what it must be
    /// mapped back onto. The two are usually identical and occasionally are not.
    var captureFrame: CGRect?
}

/// How precisely local evidence identified a target.
///
/// A bridge rectangle names an application area, not necessarily one control.
/// Accessibility and a Vision text match name the control itself. The overlay
/// needs this distinction: an arrow at an area's midpoint is useful direction,
/// but it must carry the area outline so it does not pretend to be an icon.
enum TargetPresentation: Equatable {
    case exactControl
    case broadArea

    init(evidence: [String]) {
        // A tab located by its highlight is a control, not a region: it is one
        // row of the strip, the size of the icon on it. Outlining it says
        // "somewhere in here", which is exactly the thing it stopped being.
        if evidence.contains("local_vision_text_match")
            || evidence.contains("local_vision_icon_template_match")
            || evidence.contains("local_property_tab_highlight")
            || evidence.contains(where: { $0.hasPrefix("accessibility-role:") }) {
            self = .exactControl
        } else {
            self = .broadArea
        }
    }

    func outlineFrame(for frame: CGRect) -> CGRect? {
        self == .broadArea ? frame : nil
    }
}

private struct ResolvedTarget {
    let element: AXUIElement
    let frame: CGRect
    let confidence: Double
    let snapshot: Snapshot
    let descriptor: UITargetDescriptor
    let evidence: [String]

    var presentation: TargetPresentation { TargetPresentation(evidence: evidence) }
}

private struct FocusedApplication {
    let application: NSRunningApplication
    let element: AXUIElement
}

struct PendingApproval {
    let id: UUID
    let summary: String
    let continuation: CheckedContinuation<Bool, Never>
}

struct TutorHostFailure: Error {
    let code: String
    let message: String
}

@MainActor
final class TutorHostController: ObservableObject {
    /// Shared so the app delegate can start the socket at launch and the menu
    /// can observe the same instance.
    static let shared = TutorHostController()

    @Published var captureActive = true
    /// False once the learner has stopped the lesson, until they start another.
    ///
    /// Stopping has to be enforced here rather than asked of the model: a turn
    /// already in flight will come back with another step, and "stop" that
    /// leaves one more instruction on the screen is not a stop.
    @Published var lessonActive = false
    /// What the tooltip is currently saying, mirrored for the menu bar.
    ///
    /// The tooltip lives on the window being taught, which is the right place for
    /// it and the wrong place to look when it is behind something, on another
    /// display, or hidden under the learner's own pointer. Published from the one
    /// place that already knows — wherever a step is sent to the renderer.
    @Published private(set) var currentStep = ""
    @Published private(set) var currentStepText = ""
    /// Where the lesson has got to, for the menu bar to show.
    ///
    /// Held by the engine already — it owns the plan — but nothing published it,
    /// so the panel could say what the current step was and never how far in the
    /// learner had got. Counted from one for display; `stepIndex` is zero-based
    /// everywhere else.
    @Published private(set) var stepIndex = 0
    @Published private(set) var stepCount = 0
    /// The lesson being taught, named when the learner picked it.
    @Published private(set) var lessonTitle = ""
    /// True while the learner has stepped out of the lesson to ask something.
    ///
    /// The lesson is held rather than ended: the plan and the step it is on stay
    /// exactly as they were, and nothing may move them until the learner comes
    /// back. Published so the tooltip and the menu bar can both say plainly that
    /// this is not the lesson.
    @Published private(set) var inAside = false
    /// The teaching session the learner stopped, until something else starts.
    ///
    /// `lessonActive` alone was not enough. Observing used to un-stop a lesson,
    /// on the reasoning that observing is how one begins — but the model
    /// re-observes constantly, so a turn landing after a stop brought the whole
    /// lesson back and the learner's decision quietly lost.
    ///
    /// Keyed by session rather than a bare flag, because "the learner is
    /// finished" and "no lesson may ever start again" are different claims. The
    /// turns still in flight from the stopped lesson carry its id and are
    /// refused; a genuinely new lesson arrives under a new id and is not. That
    /// distinction is the only thing separating a stale step from a fresh
    /// request, since a remote `/teach` reaches this Mac as an ordinary observe.
    private var stoppedSession: String?
    /// The session of the lesson currently on screen, so a stop knows what it is
    /// stopping. Set by the first request that starts or continues a lesson.
    private var currentSession: String?
    @Published var status = "Starting local TutorHost"
    @Published var pendingApproval: PendingApproval?

    private let engine = AccessibilityTutorEngine()
    private var socketServer: UnixSocketServer?
    /// Set only when a completion needs the normal observe → feedback handoff.
    /// It contains no capture, title, or learner text.
    private var pendingCompletion: (id: String, startedAt: UInt64)?
    private var feedbackStartedAt: UInt64?
    /// Non-model course route. Nil preserves ordinary Ask teaching behavior.
    private var fastRun: FastLessonRun?
    private var fastAdvanceInFlight = false
    /// Watches the application while a course step is on screen.
    private var liveWatch: Task<Void, Never>?
    /// The last correction said out loud, so a mistake is named once rather than
    /// twice a second for as long as it stands.
    private var lastCorrection: String?

    func start() async {
        guard socketServer == nil else { return }
        // One host per Mac.
        //
        // A KeepAlive LaunchAgent already runs one, and anything that opens the
        // bundle as well — the installer, the Dock, a double click — gets a
        // second. Binding unlinks the socket, so the newcomer silently takes
        // every request while the first keeps the overlay it had already
        // started: a lesson drawn by one process and answered by another, and
        // whichever of them lost the argument took the pointer with it. Stand
        // down instead of stealing.
        if Self.liveHostAnswers(at: Self.socketPath) {
            status = "Another TutorHost is already running"
            FileHandle.standardError.write(
                "[calla] another TutorHost already holds \(Self.socketPath); standing down\n".data(using: .utf8)!)
            NSApp.terminate(nil)
            return
        }
        do {
            let server = try UnixSocketServer(path: Self.socketPath) { [weak self] request in
                guard let self else {
                    return TutorResponse(requestID: request.requestID, ok: false, payload: nil, error: TutorError(code: "host_stopped", message: "TutorHost is unavailable"))
                }
                return await self.handle(request)
            }
            try server.start()
            socketServer = server
            status = "Local TutorHost ready (protocol v2)"
        } catch {
            status = "TutorHost failed: \(error.localizedDescription)"
        }
    }

    private func handle(_ request: TutorRequest) async -> TutorResponse {
        // Stamped around everything, including the refusals: "the Mac is not the
        // slow part" is only worth saying with a number behind it.
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let response = await route(request)
        // The code, not just the fact. A bare "refused" says a step failed and
        // takes the reason with it, which is the difference between reading this
        // log and guessing — the local-advance refusals have carried their reason
        // since the day that was the only way three separate causes were found.
        // A code is metadata by the same rule as everything else here: no payload,
        // no region, no title.
        let outcome = response.ok ? "ok" : "refused — \(response.error?.code ?? "unknown")"
        StepTiming.record(request.operation, started: startedAt, outcome: outcome)
        // Same fact, said where the learner is looking. The log is for afterwards;
        // the menu bar is for right now.
        if response.ok {
            // A drawing operation is Calla answering, so it clears the watchdog.
            if ["guide", "narrate", "point"].contains(request.operation) {
                BackendStatus.shared.noteSuccess()
            }
        } else {
            BackendStatus.shared.noteRefusal(operation: request.operation,
                                             code: response.error?.code ?? "unknown")
        }
        return response
    }

    private func route(_ request: TutorRequest) async -> TutorResponse {
        guard TutorProtocolVersion.accepts(request.protocolVersion) else {
            return failure(request, "unsupported_version", "Tutor protocol version must be in supported range 2...3")
        }
        // Recorded before any validation: the menu needs to show that Calla is
        // reaching this Mac even when what it sent was refused.
        BackendStatus.shared.noteRequest(operation: request.operation)
        guard request.sessionID.count >= 8 else { return failure(request, "invalid_session", "A valid teaching session is required") }
        // Bookkeeping and the course list are not looking at anything, so a
        // paused capture has no reason to refuse them.
        guard captureActive || ["session_start", "record_learning", "catalogue", "course_status", "course_runtime", "course_start", "course_start_again", "course_resume", "course_stop", "course_ask", "request_screen_recording", "request_accessibility"].contains(request.operation) else {
            return failure(request, "capture_paused", "Capture is paused locally")
        }
        do {
            try validateMacIngress(operation: request.operation, payload: request.payload)
            var payload: [String: JSONValue]
            // Anything that draws is refused after a stop. Observing is what
            // starts a lesson, so it is also what un-stops one.
            if ["guide", "narrate", "point", "plan", "await_change"].contains(request.operation), !lessonActive {
                return failure(request, "lesson_stopped",
                               "The learner stopped this lesson. Say so and wait to be asked again.")
            }
            // A stop is the learner's, and it holds for the lesson they stopped.
            // Observing used to un-stop a lesson here, which meant the next turn
            // to come back — and there is always one in flight — undid it.
            //
            // Every operation is refused, not only the ones that draw: once a
            // newer lesson is running, a late `guide` from the stopped one would
            // otherwise be perfectly valid and would put the old lesson's step on
            // the new lesson's screen. `record_learning` is exempt because it is
            // bookkeeping about work already done, and losing it teaches Calla
            // nothing about a learner who did finish the step.
            if request.sessionID == stoppedSession, request.operation != "record_learning" {
                return failure(request, "lesson_stopped",
                               "The learner stopped this lesson. Say so and wait to be asked again.")
            }
            // Observing is otherwise what starts a lesson. On the transition
            // specifically — not on every observe, which happens several times
            // per lesson — the previous lesson's route is dropped, so a stale
            // plan cannot advance a lesson it was not written for.
            if request.operation == "observe", !lessonActive {
                beginLesson()
            }
            if lessonActive, request.operation != "record_learning" {
                currentSession = request.sessionID
            }
            switch request.operation {
            case "session_start":
                guard let range = request.payload["supported_protocol_range"]?.objectValue,
                      let minimum = range["min"]?.numberValue,
                      let maximum = range["max"]?.numberValue,
                      minimum.rounded() == minimum, maximum.rounded() == maximum,
                      Int(minimum) <= Int(maximum),
                      request.payload["engine_build"]?.stringValue?.isEmpty == false,
                      request.payload["node_contract_hash"]?.stringValue?.isEmpty == false else {
                    return failure(request, "invalid_session_start", "A bounded internal capability handshake is required")
                }
                let compatible = TutorProtocolVersion.supported.contains(Int(minimum)) || TutorProtocolVersion.supported.contains(Int(maximum))
                guard compatible else {
                    return failure(request, "unsupported_version", "Node and engine do not share a Tutor protocol version")
                }
                CallaRuntime.recordCapabilityHandshake(
                    engineBuild: request.payload["engine_build"]?.stringValue ?? "unknown",
                    nodeContractHash: request.payload["node_contract_hash"]?.stringValue ?? "unknown"
                )
                payload = ["protocol_version": .number(Double(TutorProtocolVersion.current)),
                           "supported_protocol_min": .number(Double(TutorProtocolVersion.supported.lowerBound)),
                           "supported_protocol_max": .number(Double(TutorProtocolVersion.supported.upperBound))]
            case "observe":
                payload = try await engine.observe(request.payload)
                if let completion = pendingCompletion {
                    payload["completion_pending"] = .bool(true)
                    payload["completion_id"] = .string(completion.id)
                    payload["step_index"] = .number(Double(engine.currentPlanIndex))
                    pendingCompletion = nil
                }
                if let bundleID = payload["app_bundle_id"]?.stringValue,
                   let lessonID = LearningStore.shared.dueReview(bundleID: bundleID) {
                    payload["learning"] = .object(["due_review": .bool(true), "lesson_id": .string(lessonID)])
                }
            case "guide":
                payload = try await engine.guide(request.payload)
                publishProgress()
            case "await_change": payload = try await engine.awaitChange(request.payload)
            case "plan":
                payload = try engine.plan(request.payload)
                publishProgress()
            case "narrate": payload = engine.narrate(request.payload)
            case "point": payload = try await engine.point(request.payload)
            case "propose_action": payload = try await proposeAction(request.payload)
            case "verify": payload = try await engine.verify(request.payload)
            case "record_learning":
                guard let lessonID = request.payload["lesson_id"]?.stringValue,
                      let bundleID = request.payload["bundle_id"]?.stringValue,
                      let succeeded = request.payload["succeeded"]?.boolValue else {
                    return failure(request, "invalid_learning_record", "A bounded internal learning record is required")
                }
                let delayedReview = request.payload["delayed_review"]?.boolValue ?? false
                LearningStore.shared.record(lessonID: lessonID, bundleID: bundleID, succeeded: succeeded,
                                            delayedReview: delayedReview)
                payload = ["status": .string("recorded")]
                // The Gateway verifies one step at a time and reports each
                // verdict here, so this is not "the lesson passed" — it is "a
                // step passed". The lesson is over when the step that passed was
                // the last one on the route the Mac is holding. A lesson taught
                // without a plan has no knowable end and waits for the learner.
                if succeeded, !delayedReview, engine.isOnFinalPlannedStep {
                    completeLesson()
                }
            case "catalogue":
                // What the Gateway is willing to teach, so the menu bar can
                // offer it. Names and counts only; the steps, targets and
                // detectors stay on the Gateway until a lesson starts.
                guard case .array(let raw)? = request.payload["courses"] else {
                    return failure(request, "invalid_catalogue", "A catalogue requires a courses array")
                }
                let courses = raw.compactMap(Self.course(from:))
                CourseCatalogue.shared.replace(with: courses)
                payload = ["status": .string("stored"), "courses": .number(Double(courses.count))]
            case "course_status":
                guard case .array(let raw)? = request.payload["courses"] else {
                    return failure(request, "invalid_course_status", "Course status requires a courses array")
                }
                let courses = raw.compactMap(Self.courseStatus(from:))
                CourseLifecycleStore.shared.replace(with: courses)
                payload = ["status": .string("stored"), "courses": .number(Double(courses.count))]
            case "course_runtime":
                guard let raw = request.payload["runtime"], let data = try? JSONEncoder().encode(raw),
                      let runtime = try? JSONDecoder().decode(CourseRuntimeStore.Manifest.self, from: data) else {
                    return failure(request, "invalid_course_runtime", "A valid course runtime manifest is required")
                }
                try CourseRuntimeStore.shared.replace(runtime)
                payload = ["status": .string("stored"), "courses": .number(Double(runtime.courses.count))]
            // Boring XPC owns these local-only operations. They are never
            // registered as OpenClaw/model tools; owner-only socket permission
            // and the engine process are their capability boundary.
            case "course_start":
                guard let courseID = request.payload["course_id"]?.stringValue,
                      let course = CourseCatalogue.shared.courses.first(where: { $0.id == courseID }) else {
                    return failure(request, "missing_course", "This course is not in the current Gateway catalogue.")
                }
                let selectedLesson = request.payload["lesson_id"]?.stringValue.flatMap { requested in
                    course.lessons.first { $0.id == requested }
                }
                if request.payload["lesson_id"] != nil && selectedLesson == nil {
                    return failure(request, "missing_lesson", "This lesson is not in the selected course.")
                }
                let reason: String?
                if let selectedLesson {
                    reason = await CourseResume.start(course, lesson: selectedLesson, note: "Lesson started")
                } else {
                    reason = await CourseResume.resume(course, allowed: TutorSettings.shared.allowedBundleIDs)
                }
                if let reason {
                    return failure(request, "course_start_refused", reason)
                }
                payload = ["status": .string("started"), "course_id": .string(courseID)]
            case "course_start_again":
                guard let courseID = request.payload["course_id"]?.stringValue,
                      let course = CourseCatalogue.shared.courses.first(where: { $0.id == courseID }),
                      let bundleID = CourseCatalogue.shared.bundleID(for: course, allowed: TutorSettings.shared.allowedBundleIDs),
                      let first = course.lessons.first else {
                    return failure(request, "missing_course", "This course cannot start again yet.")
                }
                LearningStore.shared.clear(lessonIDs: course.lessons.map(\.id), bundleID: bundleID)
                CourseRunStore.shared.restart(courseID: course.id)
                if let reason = await CourseResume.start(course, lesson: first, note: "Course restarted") {
                    return failure(request, "course_restart_refused", reason)
                }
                payload = ["status": .string("restarted"), "course_id": .string(courseID)]
            case "course_resume":
                guard let courseID = CourseRunStore.shared.mostRecentCourseID,
                      let course = CourseCatalogue.shared.courses.first(where: { $0.id == courseID }) else {
                    return failure(request, "missing_course", "No course is ready to resume.")
                }
                if let reason = await CourseResume.resume(course, allowed: TutorSettings.shared.allowedBundleIDs) {
                    return failure(request, "course_resume_refused", reason)
                }
                payload = ["status": .string("resumed"), "course_id": .string(courseID)]
            case "course_stop":
                stopLesson()
                payload = ["status": .string("stopped")]
            case "course_ask":
                guard let text = request.payload["text"]?.stringValue,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.count <= 800 else {
                    return failure(request, "invalid_question", "Ask needs one short question.")
                }
                LessonRelay.shared.handle(event: "ask", text: text)
                payload = ["status": .string("asking")]
            case "request_screen_recording":
                // Boring engine is sole caller. This stays outside model tools;
                // direct request gives TCC the exact capture executable.
                TutorSettings.shared.requestScreenRecordingApproval()
                payload = ["status": .string("Screen Recording request shown")]
            case "request_accessibility":
                // Same reason as above. Asking from the XPC service prompted
                // for the service's own bundle, but this host is what calls
                // AXUIElement, so the grant landed on the wrong executable.
                TutorSettings.shared.requestAccessibilityApproval()
                payload = ["status": .string("Accessibility request shown")]
            default: return failure(request, "unsupported_operation", "This TutorHost accepts only documented Tutor operations")
            }
            if ["guide", "narrate"].contains(request.operation), let started = feedbackStartedAt {
                let elapsed = DispatchTime.now().uptimeNanoseconds &- started
                payload["feedback_latency_ms"] = .number(Double(elapsed / 1_000_000))
                feedbackStartedAt = nil
            }
            return TutorResponse(requestID: request.requestID, ok: true, payload: payload, error: nil)
        } catch let hostFailure as TutorHostFailure {
            return failure(request, hostFailure.code, hostFailure.message)
        } catch let descriptorFailure as DescriptorValidationError {
            return failure(request, "invalid_descriptor", descriptorFailure.message)
        } catch {
            return failure(request, "host_error", error.localizedDescription)
        }
    }

    private func proposeAction(_ payload: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard payload["target_hint"] == nil else {
            throw TutorHostFailure(code: "target_hint_forbidden", message: "A visual hint can never contribute action authority")
        }
        guard case .string(let action)? = payload["action"], action == "click" else {
            throw TutorHostFailure(code: "unsupported_action", message: "This TutorHost supports only a locally approved semantic click")
        }
        guard AXIsProcessTrusted() else {
            TutorSettings.shared.requestAccessibilityApproval()
            throw TutorHostFailure(code: "accessibility_not_permitted",
                                   message: "Accessibility is required for this approved action. Approve Calla TutorHost in System Settings, then try again.")
        }
        let target = try await engine.resolveFreshTarget(payload, authority: .action, allowHint: false)
        let detector = try engine.detector(from: payload, key: "expected_state")
        let approved = await withCheckedContinuation { continuation in
            pendingApproval = PendingApproval(
                id: UUID(),
                summary: "Click \(target.descriptor.title) in the focused allowlisted window.",
                continuation: continuation)
        }
        guard approved else {
            return ["status": .string("denied"), "reason": .string("The local user denied the action")]
        }
        try engine.press(target)
        return try engine.evaluate(detector: detector, target: target)
    }

    /// The learner says they finished a step. Prepare the question for the model.
    ///
    /// Returns what the Mac can see locally, phrased for the message that goes
    /// out — telling the model the window changed, or did not, saves it working
    /// that out and gives it a prior before it looks. Nothing here decides
    /// whether the step worked; that is the model's job now, and the whole
    /// reason the step is being sent at all.
    func checkStep() async -> String {
        guard lessonActive, captureActive else { return "the lesson is not running" }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let signal = await engine.progressSignal()
        StepTiming.record("progress_signal", started: startedAt, outcome: signal)
        // The verdict the Gateway verifies against on the next observation.
        let completion = (id: UUID().uuidString, startedAt: DispatchTime.now().uptimeNanoseconds)
        pendingCompletion = completion
        feedbackStartedAt = completion.startedAt
        return signal
    }

    /// Put the learner back on the step the lesson is already on.
    ///
    /// Costs no model turn: the Mac holds the region and the words. This is what
    /// makes leaving a lesson to ask something, and coming back, free.
    func resumeLesson() {
        guard lessonActive else { return }
        finishAsideForVerification()
        Task { @MainActor in
            if !(await engine.redrawCurrentStep()) {
                PointerOverlay.shared.narrate(step: "Calla", text: "Back to the lesson.",
                                              status: "Calla — \(engine.stepLabel)", thinking: false)
            }
        }
    }

    /// End an aside without redrawing its held instruction.
    ///
    /// Used by "Did it" after a tooltip question. The next operation must be
    /// verification, not a return animation that makes the learner press Done
    /// twice. `resumeLesson()` deliberately calls this first, then redraws.
    func finishAsideForVerification() {
        guard lessonActive, inAside else { return }
        inAside = false
        engine.heldForAside = false
        PointerOverlay.shared.setAside(false)
    }

    // MARK: - Lesson lifecycle
    //
    // Every transition goes through one of the three below. "Is a lesson running"
    // used to be answerable from two places set at different moments — this flag,
    // and the session id over in LessonRelay — which could disagree about whether
    // a lesson existed. The session is minted and retired here now, so they
    // cannot.

    /// One catalogue course, or nil when the entry is not one.
    ///
    /// Parsed strictly and dropped quietly rather than failing the whole push: a
    /// pack written for a newer Calla should cost the learner the course it did
    /// not understand, not every course on the list.
    private static func course(from value: JSONValue) -> CourseCatalogue.Course? {
        guard case .object(let object) = value,
              let id = object["id"]?.stringValue, !id.isEmpty,
              let title = object["title"]?.stringValue, !title.isEmpty,
              case .array(let rawLessons)? = object["lessons"] else { return nil }
        let lessons = rawLessons.compactMap { entry -> CourseCatalogue.Lesson? in
            guard case .object(let lesson) = entry,
                  let lessonID = lesson["id"]?.stringValue, !lessonID.isEmpty,
                  let lessonTitle = lesson["title"]?.stringValue else { return nil }
            return CourseCatalogue.Lesson(id: lessonID, title: lessonTitle)
        }
        guard !lessons.isEmpty else { return nil }
        let bundleIDs: [String]
        if case .array(let raw)? = object["bundle_ids"] {
            bundleIDs = raw.compactMap(\.stringValue)
        } else {
            bundleIDs = []
        }
        return CourseCatalogue.Course(
            id: id, title: title,
            summary: object["summary"]?.stringValue ?? "",
            icon: object["icon"]?.stringValue ?? "",
            packID: object["pack_id"]?.stringValue ?? "",
            bundleIDs: bundleIDs, lessons: lessons)
    }

    private static func courseStatus(from value: JSONValue) -> CourseLifecycleStore.Course? {
        guard case .object(let object) = value,
              let id = object["id"]?.stringValue, !id.isEmpty,
              let title = object["title"]?.stringValue, !title.isEmpty,
              let phase = object["phase"]?.stringValue,
              ["queued", "compiling", "validating", "waiting_for_blender", "preflighting", "publishing", "published", "failed", "cancelled", "archived"].contains(phase)
        else { return nil }
        let error = object["error"]?.stringValue.map { String($0.prefix(240)) }
        let warnings: [String]
        if case .array(let values)? = object["warnings"] {
            warnings = values.compactMap(\.stringValue).map { String($0.prefix(240)) }.prefix(8).map { $0 }
        } else { warnings = [] }
        let revision = Int(object["revision"]?.numberValue ?? 1)
        let lessonCount = Int(object["lesson_count"]?.numberValue ?? 0)
        let elapsed = Int(object["elapsed_ms"]?.numberValue ?? 0)
        let nextAction = object["next_action"]?.stringValue.map { String($0.prefix(240)) }
        return CourseLifecycleStore.Course(id: id, revision: revision, phase: phase, title: title,
                                            targetApp: object["target_app"]?.stringValue,
                                            targetVersion: object["target_version"]?.stringValue,
                                            lessonCount: lessonCount, warnings: warnings, error: error,
                                            elapsedMS: elapsed, nextAction: nextAction)
    }

    /// Mirror what the tooltip is saying, for the menu bar.
    func noteStep(_ step: String, text: String) {
        currentStep = step
        currentStepText = text
    }

    /// Mirror where the lesson has got to, for the menu bar.
    ///
    /// The engine owns the plan; this is the only place its position becomes
    /// something SwiftUI can watch.
    func publishProgress() {
        stepCount = engine.plannedStepCount
        stepIndex = engine.plannedStepCount == 0 ? 0 : engine.currentPlanIndex + 1
    }

    /// The learner has stepped out of the lesson to ask something.
    func beginAside() {
        guard lessonActive else { return }
        inAside = true
        engine.heldForAside = true
        PointerOverlay.shared.setAside(true)
    }

    /// Begin a lesson, whoever asked for it.
    func beginLesson() {
        stoppedSession = nil
        lessonActive = true
        inAside = false
        engine.heldForAside = false
        stepIndex = 0
        stepCount = 0
        // A fresh route and a fresh window: a plan measured against the last
        // lesson's screen cannot advance this one.
        engine.forgetPlan()
        WindowCapture.forgetCachedWindow()
        LessonRelay.shared.adoptNewSession()
    }

    /// The learner is finished. Nothing from this lesson draws again.
    func stopLesson() {
        stoppedSession = currentSession
        endLesson()
    }

    /// Teach one authored lesson, chosen from the menu rather than asked for.
    ///
    /// Returns the reason it could not start, or nil. The lesson id is named in
    /// the message, which is the only thing that reaches the Gateway daemon
    /// where the prompt is built — this Mac runs the CLI over ssh, and the
    /// daemon is a different process whose environment it cannot set. The
    /// Gateway puts the whole authored lesson in front of the model before its
    /// first tool call, so there is nothing left to retrieve or improvise.
    @discardableResult
    func startCourse(courseID: String, lessonID: String, courseTitle: String, lessonTitle: String) async -> String? {
        let allowed = TutorSettings.shared.effectiveAllowlist(requested: nil)
        guard !allowed.isEmpty else {
            return "Allow an application in Settings before starting a course."
        }
        let declaredBundleID = CourseRuntimeStore.shared.declaredBundleID(courseID: courseID, allowed: allowed)
        let subject: NSRunningApplication
        if let declaredBundleID {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == declaredBundleID && !$0.isTerminated
            }) else { return "Open the application this course teaches, then start it again." }
            subject = app
        } else {
            guard let app = LessonSubject.shared.mostRecent(in: allowed) else {
                return "Open the application this course teaches, then start it again."
            }
            subject = app
        }
        // Bring it forward before anything is asked of it.
        //
        // Starting from the menu bar necessarily makes the menu frontmost, so
        // by the time the first observe reached the Mac the application being
        // taught was behind it and the lesson died on `no_focused_window`
        // — every single time, with an error that told the learner to do what
        // the Mac could simply do itself. The overlay only draws while the
        // subject is in front, so this is also what makes the first step
        // visible at all.
        subject.activate()
        if lessonActive { stopLesson() }
        beginLesson()
        self.lessonTitle = lessonTitle
        CallaRuntime.recordActiveLesson(courseID: courseID, lessonID: lessonID, lessonTitle: lessonTitle)
        let version = subject.bundleURL.flatMap {
            Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        } ?? "unknown"
        if let run = CourseRuntimeStore.shared.run(courseID: courseID, lessonID: lessonID,
                                                    bundleID: subject.bundleIdentifier ?? "", version: version) {
            // Say what is wrong *before* the lesson opens, not at every step
            // afterwards. The prerequisites have been authored since the first
            // pack and enforced nowhere, so a learner with a light selected
            // started a lesson about meshes and was told "Not yet" until they
            // gave up. Refusing here costs one bridge read and answers the
            // question the old refusal never did: which one, and what is true
            // instead.
            if let unmet = unmetPrerequisite(of: run) {
                fastRun = nil
                endLesson()
                return unmet
            }
            fastRun = run
            do {
                try await showFastStep()
                return nil
            } catch {
                fastRun = nil
                endLesson()
                // Say which check refused. The old single sentence sent every
                // learner to "open its declared app window" even when the app
                // was already in front and the real cause was a missing grant
                // or an unresolved descriptor — advice that could not work.
                if let failure = error as? TutorHostFailure {
                    return "\(failure.message) (\(failure.code))"
                }
                return "Could not start this course step locally: \(error.localizedDescription)"
            }
        }
        if declaredBundleID != nil {
            endLesson()
            return "This course is pinned to a different version of its declared application."
        }
        // Cache miss remains a private control-plane refresh boundary. Existing
        // model path is retained only for that miss, never normal course steps.
        CourseControlRelay.shared.send("refresh-runtime", payload: [:], accepted: "Refreshing course cache…")
        LessonRelay.shared.startLesson("Teach \(courseTitle) — \(lessonTitle). [lesson:\(lessonID)]")
        return nil
    }

    /// The first authored prerequisite this lesson does not have, said plainly.
    private func unmetPrerequisite(of run: FastLessonRun) -> String? {
        let prerequisites = run.lesson.prerequisites ?? []
        guard !prerequisites.isEmpty, let state = engine.bridgeState() else { return nil }
        for prerequisite in prerequisites {
            guard let detector = try? DetectorDescriptor(raw: prerequisite.when) else { continue }
            if !engine.satisfies(detector, in: state) { return prerequisite.say }
        }
        return nil
    }

    /// Why the step is not done, in the learner's terms.
    ///
    /// Three sources, in descending order of how much they know. An authored
    /// diagnosis names a mistake the lesson anticipated; the state diff names one
    /// nobody anticipated but the application can still prove; and failing both,
    /// the instruction is repeated, which is where every failure used to end.
    private func heldStepMessage(_ run: FastLessonRun, _ step: CourseRuntimeStore.Step) -> (step: String, text: String) {
        let state = engine.bridgeState()
        if let state {
            for diagnosis in step.diagnose ?? [] {
                guard let detector = try? DetectorDescriptor(raw: diagnosis.when) else { continue }
                if engine.satisfies(detector, in: state) { return ("Not quite", diagnosis.say) }
            }
        }
        if let sentence = StepDiagnosis.sentence(from: run.stateAtStep, to: state.flatMap(BlenderStateDigest.init)) {
            return ("Not yet", "\(sentence) \(step.text)")
        }
        return ("Not yet", step.text)
    }

    /// Handles Did it for a warm course cache. Returns false only when this is
    /// an ordinary model-led lesson.
    func advanceFastLesson() async -> Bool {
        guard let run = fastRun else { return false }
        guard !fastAdvanceInFlight else { return true }
        fastAdvanceInFlight = true
        defer { fastAdvanceInFlight = false }
        guard let step = run.current else { completeLesson(); return true }
        guard let detector = step.detectorDescriptor else {
            PointerOverlay.shared.narrate(step: "Check", text: "This step needs visual confirmation. Try again after checking it.",
                                          status: "Calla — waiting", thinking: false)
            return true
        }
        do {
            let result = try await engine.fastVerify(target: step.targetDescriptor, detector: detector, bundleID: run.bundleID)
            guard result["outcome"]?.stringValue == "satisfied" else {
                run.noteAttempt()
                let held = heldStepMessage(run, step)
                PointerOverlay.shared.narrate(step: held.step, text: held.text,
                                              status: "Calla — step held", thinking: false)
                // The ladder the lesson authored, walked one rung per failure.
                // Saying the same words louder is not help; showing the learner
                // the panel the step lives in is.
                if run.assistance != "explain" { try? await showFastStep(assistance: run.assistance) }
                return true
            }
            CourseRunStore.shared.record(courseID: run.courseID, kind: "checkpoint", text: step.phase, checkpoint: run.lesson.id)
            if run.isFinalTransfer {
                LearningStore.shared.record(lessonID: run.lesson.id, bundleID: run.bundleID, succeeded: true, delayedReview: false)
                completeLesson()
                return true
            }
            run.advance()
            try await showFastStep()
        } catch {
            PointerOverlay.shared.narrate(step: "Check", text: "Calla could not verify that yet. Keep this step and try again.",
                                          status: "Calla — check again", thinking: false)
        }
        return true
    }

    private func showFastStep(assistance: String = "explain") async throws {
        guard let run = fastRun, let step = run.current else { throw TutorHostFailure(code: "course_finished", message: "Course route is finished") }
        try await engine.fastPoint(target: step.targetDescriptor, bundleID: run.bundleID,
                             step: "\(run.index + 1) of \(run.lesson.steps.count)", text: step.text,
                             status: "Calla — \(step.phase)", highlight: assistance != "explain")
        // What the application looked like when the step was put on screen. Two
        // readings are what let the next check say what the learner did rather
        // than only that it was not this.
        if run.stateAtStep == nil { run.stateAtStep = engine.stateDigest() }
        publishProgress()
        currentStep = "\(run.index + 1) of \(run.lesson.steps.count)"
        currentStepText = step.text
        lastCorrection = nil
        startLiveStepWatch()
    }

    /// The lesson reached the end of its route.
    ///
    /// Said out loud before the overlay goes, because a pointer that simply
    /// vanishes reads as a crash rather than an ending.
    ///
    /// `lessonActive` drops first so nothing new can draw during the closing
    /// beat — a turn already in flight would otherwise land a further step on top
    /// of "that is the lesson". The teardown then waits long enough for the words
    /// to be read, and checks on the way back that the learner has not started
    /// something new in the meantime.
    func completeLesson() {
        guard lessonActive else { return }
        lessonActive = false
        LessonRelay.shared.abort()
        PointerOverlay.shared.narrate(step: "Done", text: "That is the lesson — nicely done.",
                                      status: "Calla — finished", thinking: false)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard !lessonActive else { return }
            endLesson()
        }
    }

    /// Tear down whatever a lesson was holding. Not called directly — go through
    /// `stopLesson` or `completeLesson`, so the reason is always recorded.
    private func endLesson() {
        lessonActive = false
        currentSession = nil
        currentStep = ""
        currentStepText = ""
        lessonTitle = ""
        CallaRuntime.clearActiveLesson()
        stepIndex = 0
        stepCount = 0
        inAside = false
        engine.heldForAside = false
        PointerOverlay.shared.hide()
        LessonRelay.shared.abort()
        // The session goes with it. Keeping it would mean the next lesson
        // re-sent this one on every step, which is the cost this whole change
        // exists to remove.
        LessonRelay.shared.endLesson()
        engine.forgetPlan()
        WindowCapture.forgetCachedWindow()
        pendingCompletion = nil
        feedbackStartedAt = nil
        fastRun = nil
        fastAdvanceInFlight = false
        stopLiveStepWatch()
    }

    // MARK: - Watching the step happen

    /// Notice what the learner does, while they are doing it.
    ///
    /// The tutor used to find out how a step went only when the learner pressed
    /// "Did it" — so a learner who dropped into Edit Mode, or added the wrong
    /// modifier, worked on inside a mistake until they thought to ask. That is
    /// backwards: the moment to say "that is a Subdivision Surface, not a Bevel"
    /// is the moment it appears.
    ///
    /// Cheap enough to be allowed to run: the read is a loopback request to a
    /// process already on this Mac, single-digit milliseconds, no capture, no
    /// GPU, no network. Half a second rather than anything faster because the
    /// bridge answers on Blender's own main thread, and a tutor is not worth a
    /// frame of the thing it is teaching. It stops the moment the learner looks
    /// somewhere else, and dies with the lesson.
    private func startLiveStepWatch() {
        stopLiveStepWatch()
        guard fastRun != nil else { return }
        liveWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                await self.observeStepProgress()
            }
        }
    }

    private func stopLiveStepWatch() {
        liveWatch?.cancel()
        liveWatch = nil
        lastCorrection = nil
    }

    private func observeStepProgress() async {
        guard lessonActive, !inAside, let run = fastRun, let step = run.current else { return }
        guard !fastAdvanceInFlight else { return }
        // Not while the learner is somewhere else. Their attention is the only
        // thing that makes any of this worth saying.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == run.bundleID else { return }
        guard let state = engine.bridgeState() else { return }

        // Finished, and proved finished by the step's own authored check — the
        // same check "Did it" runs. Pressing a button to confirm what the
        // application has already confirmed is a step the learner should not
        // have to take.
        if let detector = step.detectorDescriptor,
           let checked = try? await engine.fastVerify(target: step.targetDescriptor, detector: detector, bundleID: run.bundleID),
           checked["outcome"]?.stringValue == "satisfied" {
            _ = await advanceFastLesson()
            return
        }

        // Not finished. If the application can say what went differently, say it
        // now rather than at the end.
        var correction: String?
        for diagnosis in step.diagnose ?? [] {
            guard let detector = try? DetectorDescriptor(raw: diagnosis.when) else { continue }
            if engine.satisfies(detector, in: state) { correction = diagnosis.say; break }
        }
        if correction == nil, let digest = BlenderStateDigest(state), let before = run.stateAtStep, before != digest {
            correction = StepDiagnosis.sentence(from: before, to: digest)
        }
        // "Nothing has changed yet" is true for most of every step and is not
        // worth interrupting anybody with; it belongs to the moment they say
        // they are done, not to the silence before it.
        guard let correction, !correction.hasPrefix("Nothing has changed"), correction != lastCorrection else { return }
        lastCorrection = correction
        PointerOverlay.shared.narrate(step: "Careful", text: "\(correction) \(step.text)",
                                      status: "Calla — watching", thinking: false)
    }

    /// Open the menu-bar Ask surface only over the application Calla may teach.
    /// A menu click must never resurrect a stale cursor over whichever unrelated
    /// app happened to be used after the last lesson.
    /// Why Ask could not open, in words worth showing someone. `nil` means it did.
    ///
    /// It used to write a sentence into `status`, which nothing rendered, so the
    /// button appeared to do nothing at all. Returning the reason makes it the
    /// caller's job to say it, and every caller does.
    @discardableResult
    func openAsk() -> String? {
        let allowed = TutorSettings.shared.effectiveAllowlist(requested: nil)
        guard !allowed.isEmpty else {
            return "Allow an application in Settings before asking Calla."
        }
        // The learner asks from wherever they are — the menu bar, a shortcut,
        // another window entirely — so the subject is the allowlisted application
        // they were last working in, not whatever happens to be in front right
        // now. Requiring the subject to be frontmost is what made Calla
        // impossible to start from the Mac it runs on.
        guard let app = LessonSubject.shared.mostRecent(in: allowed),
              let bundleID = app.bundleIdentifier else {
            return "Open the application you want taught, then ask Calla again."
        }
        guard let window = Self.largestWindow(ofProcess: app.processIdentifier) else {
            let name = TutorSettings.shared.displayName(for: bundleID)
            return "\(name) has no window on screen for Calla to teach."
        }
        PointerOverlay.shared.openAsk(owner: bundleID, window: window)
        return nil
    }

    /// The biggest ordinary window belonging to a process, in screen coordinates.
    private static func largestWindow(ofProcess pid: pid_t) -> CGRect? {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        return infos.compactMap { info -> CGRect? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 1, frame.height > 1 else { return nil }
            return frame
        }.max(by: { $0.width * $0.height < $1.width * $1.height })
    }

    func resolveApproval(_ approved: Bool) {
        guard let pending = pendingApproval else { return }
        pendingApproval = nil
        pending.continuation.resume(returning: approved)
    }

    private func failure(_ request: TutorRequest, _ code: String, _ message: String) -> TutorResponse {
        TutorResponse(requestID: request.requestID, ok: false, payload: nil, error: TutorError(code: code, message: message))
    }

    static let socketPath = CallaRuntime.file("tutor-host.sock").path

    /// Whether some other host is already listening.
    ///
    /// Connecting is the whole test: a socket file left behind by a host that
    /// died refuses the connection, so a stale file does not keep a fresh host
    /// out. Nothing is sent — a probe that spoke the protocol would show up in
    /// the request log as a lesson that never happened.
    private static func liveHostAnswers(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let byteCount = path.utf8.count + 1
        guard byteCount <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        _ = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { strncpy($0, source, byteCount) }
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sa_family_t>.size + byteCount)) == 0
            }
        }
    }
}

private func validateMacIngress(operation: String, payload: [String: JSONValue]) throws {
    if operation == "propose_action", payload["target_hint"] != nil {
        throw TutorHostFailure(code: "target_hint_forbidden", message: "A visual hint can never contribute action authority")
    }
    if operation == "observe", payload["include_crop"] != nil {
        throw TutorHostFailure(code: "invalid_capture_request", message: "include_crop was replaced by include_capture in protocol v2")
    }
    // The normalized regions a model may send, and exactly where. Pointing takes
    // one under `target_hint`; guiding and cropping take one directly, having no
    // descriptor to hang it off; planning takes one per step, because the Mac
    // draws those later without asking again. Everywhere else a
    // coordinate-shaped key is a rejection, and no exemption here reaches an
    // operation that can act.
    let exempt: [[String]]
    switch operation {
    case "point": exempt = [["payload", "target_hint", "region"]]
    case "guide", "observe": exempt = [["payload", "region"]]
    case "plan": exempt = [["payload", "steps", "#", "region"]]
    default: exempt = []
    }
    if let path = macForbiddenCoordinatePath(.object(payload), path: ["payload"], exempt: exempt) {
        throw TutorHostFailure(code: "invalid_coordinates", message: "Raw coordinate field \(path) is forbidden")
    }
}

/// Whether one exact path is a place a normalized region may sit.
///
/// `"#"` matches an array index and nothing else, so a plan can exempt
/// `steps.0.region` through `steps.11.region` without exempting some other
/// object that happens to have a `steps` key. Everything else matches
/// literally, and the lengths must agree — an exemption names one location, and
/// is never a prefix.
private func matchesExemptPath(_ path: [String], _ exempt: [String]) -> Bool {
    guard path.count == exempt.count else { return false }
    return zip(path, exempt).allSatisfy { part, expected in
        expected == "#" ? !part.isEmpty && part.allSatisfy(\.isNumber) : part == expected
    }
}

private func macForbiddenCoordinatePath(_ value: JSONValue, path: [String], exempt: [[String]]) -> String? {
    switch value {
    case .object(let object):
        for (key, child) in object {
            let next = path + [key]
            if exempt.contains(where: { matchesExemptPath(next, $0) }) { continue }
            if forbiddenCoordinateKeys.contains(key.lowercased()) { return next.joined(separator: ".") }
            if let found = macForbiddenCoordinatePath(child, path: next, exempt: exempt) { return found }
        }
    case .array(let values):
        for (index, child) in values.enumerated() {
            if let found = macForbiddenCoordinatePath(child, path: path + [String(index)], exempt: exempt) { return found }
        }
    default: break
    }
    return nil
}

private enum ResolutionAuthority { case point, action }

// Every call site is on the @MainActor TutorHostController, and point() drives
// an AppKit overlay, so state the isolation the code already relies on.
@MainActor
private final class AccessibilityTutorEngine {
    private var snapshots: [String: Snapshot] = [:]
    private let maxSnapshotAge: TimeInterval = 4
    /// Guiding only draws, so it can wait out a vision round trip that acting
    /// never would.
    private let maxGuideSnapshotAge: TimeInterval = 180
    private let bridgeObserver = BlenderBridgeObserver()
    private lazy var blenderLayout = BlenderLayoutResolver(observer: bridgeObserver)

    /// How much of the window must differ before the learner counts as having
    /// done something. Shared by `awaitChange` and `progressSignal` so a step
    /// cannot be finished enough for one and not the other.
    static let changeThreshold = 0.012

    /// One step of the route, as the model laid it out.
    ///
    /// A step with a region and words can be pointed at without asking the
    /// model again; a step with only a title costs a turn when it comes around.
    struct PlannedStep {
        let title: String
        let region: NormalizedRegion?
        let text: String?

        var canAdvanceLocally: Bool { region != nil && text != nil }
    }

    private var plan: [PlannedStep] = []
    private var planIndex = 0
    /// Set while the learner is asking something outside the lesson.
    var heldForAside = false
    var currentPlanIndex: Int { planIndex }
    var plannedStepCount: Int { plan.count }
    /// "Step 2 of 4", composed here rather than by the model.
    ///
    /// The model used to send this string. It has to count to produce it, and a
    /// miscount puts the wrong number on the learner's screen for the rest of
    /// the lesson. The Mac holds the plan and the index, so it cannot be wrong.
    var stepLabel: String {
        plan.isEmpty ? "Calla" : "Step \(planIndex + 1) of \(plan.count)"
    }
    /// True when a route exists and the learner is standing on its last step.
    ///
    /// This is the only end-of-lesson signal available locally. The Gateway
    /// verifies one step at a time and `record_learning` reports each of those
    /// verdicts, so nothing arriving from outside says "the lesson is over" —
    /// but the Mac holds the route, so it can tell that the step just passed was
    /// the final one. A lesson taught without a plan has no knowable end and
    /// keeps running until the learner stops it.
    var isOnFinalPlannedStep: Bool { !plan.isEmpty && planIndex >= plan.count - 1 }
    /// The observation the plan's regions were measured against. Every planned
    /// region is a fraction of this picture, so this is what they map back from.
    private var planSnapshot: Snapshot?
    /// The window as it looked when the current step was drawn, so "did the
    /// learner do anything" is measured from the step rather than from the
    /// moment we happened to ask.
    private var guideThumbprint: [UInt8]?
    /// The most recent observation, for a plan that arrives without naming one.
    private var latestSnapshot: Snapshot?
    /// Whether each application lets Accessibility see inside its window.
    private var controlExposure: [pid_t: Bool] = [:]

    func observe(_ payload: [String: JSONValue]) async throws -> [String: JSONValue] {
        let focused = try focusedAllowlistedApplication(allowlist(from: payload))
        let snapshot = try await makeSnapshot(for: focused)
        snapshots[snapshot.id] = snapshot
        latestSnapshot = snapshot
        var result: [String: JSONValue] = [
            "status": .string("ok"),
            "snapshot_id": .string(snapshot.id),
            "app_bundle_id": .string(snapshot.appBundleID),
            "app_version": .string(snapshot.appVersion),
            // Who is being taught, so notes kept about them outlive the lesson.
            // It is minted here and nowhere else — a session id lasts one
            // lesson by design, so it cannot be what memory is filed under.
            // Says nothing about the person; it is an opaque local handle.
            "learner_id": .string(TutorSettings.shared.learnerID),
        ]
        // What the application says about its own layout, in names rather than
        // rectangles.
        //
        // Half of what a capture was being spent on is the question "which
        // editors are open, and which Properties tab is showing" — twenty-seven
        // thousand input tokens and thirteen seconds of the model reading a
        // picture to learn something Blender will state in five milliseconds.
        // Deliberately no geometry: a rectangle here would be a coordinate on
        // the wire, which the ingress guard refuses and should. The Mac keeps
        // the geometry; the model gets the vocabulary.
        if let layout = blenderLayout.mapping(for: snapshot)?.layout {
            var editors: [JSONValue] = []
            for area in layout.areas.prefix(24) {
                var described: [String: JSONValue] = ["editor": .string(area.type)]
                if let context = area.context { described["context"] = .string(context) }
                if !area.regions.isEmpty {
                    described["regions"] = .array(area.regions.prefix(12).map { .string($0.type) })
                }
                editors.append(.object(described))
            }
            result["layout"] = .object(["source": .string("read_only_application_bridge"),
                                        "editors": .array(editors)])
        }
        if let capture = payload["include_capture"] {
            guard let includeCapture = capture.boolValue else {
                throw TutorHostFailure(code: "invalid_capture_request", message: "include_capture must be a boolean")
            }
            if includeCapture {
                // Asking for one panel rather than the whole window. The region
                // narrows what is sent and nothing else — it cannot reach past
                // the window it is a fraction of.
                let crop = try normalizedRegion(payload["region"])
                let requestedEdge = payload["long_edge"]?.numberValue.map { Int($0) }
                let capture = try await captureFocusedWindow(snapshot, crop: crop, longEdge: requestedEdge)
                // Remember what the picture covered. Every region the model
                // sends back is a fraction of this rectangle, which for a
                // cropped capture is the crop, not the window.
                snapshots[snapshot.id]?.captureFrame = capture.windowFrame
                latestSnapshot = snapshots[snapshot.id]
                var describedCapture: [String: JSONValue] = [
                    "snapshot_id": .string(snapshot.id),
                    "mime_type": .string("image/jpeg"),
                    "base64": .string(capture.base64),
                ]
                // Said back, because a model that asked for a crop must read its
                // next region against the crop rather than the whole window.
                if crop != nil { describedCapture["cropped"] = .bool(true) }
                result["capture"] = .object(describedCapture)
            }
        }
        return result
    }

    /// Point at a region the model read off the window capture.
    ///
    /// This is the path that carries a lesson in an application nobody has
    /// authored a pack for. There is no descriptor to resolve and no
    /// Accessibility tree to consult — the model looked at the JPEG it asked
    /// for, and says where in that window the learner should look. The Mac
    /// still owns everything that matters: it re-finds the window itself, maps
    /// the region against the window's *current* geometry, and draws. Nothing
    /// here can click, and no screen coordinate goes back over the wire.
    func guide(_ payload: [String: JSONValue]) async throws -> [String: JSONValue] {
        var result = try await drawGuide(payload)
        // What the window looked like the moment this step went up. Whether the
        // learner has since done anything is measured from here, so a local
        // advance judges the step rather than the wait.
        if let snapshot = planSnapshot ?? latestSnapshot {
            guideThumbprint = try? await thumbprint(snapshot)
        }
        // The model pointing at a step by hand is also it telling us where the
        // lesson is; a local advance from a stale index would skip a step.
        if let index = payload["step_index"]?.numberValue.map({ Int($0) }), index < plan.count {
            planIndex = index
        }
        // Pointing and then waiting are one thought, and splitting them costs a
        // whole model round trip — about eight seconds here — to say nothing
        // more than "now wait". Doing both in one call is most of the
        // difference between a lesson that keeps up and one that does not.
        if payload["wait_for_change"]?.boolValue == true {
            let waited = try await awaitChange(payload)
            for (key, value) in waited where key != "status" && key != "snapshot_id" {
                result[key] = value
            }
            // And hand back what the screen looks like now.
            //
            // This is what makes a step cost one round trip instead of two. The
            // model always needs a fresh look before it can point at the next
            // thing, and after a wait we are already standing at the moment
            // worth looking at. Sending the observation back with the wait
            // saves the learner an entire model call — most of the visible
            // delay between finishing one step and being shown the next.
            // A post-guide full image is costly and would be replayed in the
            // model history. It is opt-in only for a deliberate recovery path;
            // normal planned advances remain entirely local.
            if payload["capture_after_change"]?.boolValue == true {
                var next = try await observe(["allowed_bundle_ids": payload["allowed_bundle_ids"] ?? .array([]),
                                              "include_capture": .bool(true)])
                next.removeValue(forKey: "status")
                result["next_observation"] = .object(next)
            }
        }
        return result
    }

    private func drawGuide(_ payload: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard let region = try normalizedRegion(payload["region"]) else {
            throw TutorHostFailure(code: "missing_region", message: "guide requires one normalized region of the observed window")
        }
        let window = try await liveWindow(for: payload)
        let picture = pictureFrame(observed: window.snapshot, live: window.frame)
        let requested = CGRect(x: picture.rect.minX + picture.rect.width * region.left,
                               y: picture.rect.minY + picture.rect.height * region.top,
                               width: max(picture.rect.width * region.width, 8),
                               height: max(picture.rect.height * region.height, 8))
        var evidence = ["model_region_on_live_window"]
        var frame = requested
        var presentation: TargetPresentation = .broadArea
        // A region read off a JPEG is an estimate; the thing under it is a fact.
        // Two kinds of fact are available, and the application's own layout is
        // the better one where it exists — Blender knows where it drew the
        // Properties editor, and Accessibility, which sees one opaque window,
        // does not. Either way this is the difference between landing on a
        // control and landing a centimetre above it.
        if let panel = bridgePanelUnder(requested, in: window.snapshot) {
            frame = panel
            evidence.append("snapped_to_local_application_bridge_region")
        } else if let control = controlUnder(requested, in: window.snapshot) {
            frame = control
            presentation = .exactControl
            evidence.append("snapped_to_local_accessibility_element")
        }
        if picture.resized { evidence.append("window_resized_since_observation") }
        let step = payload["step"]?.stringValue ?? "Calla"
        let text = payload["text"]?.stringValue ?? ""
        let status = payload["status"]?.stringValue ?? "Calla — \(step)"
        PointerOverlay.shared.point(at: frame, window: window.frame, owner: window.snapshot.appBundleID,
                                    step: step, text: String(text.prefix(240)), status: status,
                                    targetOutline: presentation.outlineFrame(for: frame))
        var result: [String: JSONValue] = [
            "status": .string("ok"),
            "guide_receipt": .object([
                "snapshot_id": .string(window.snapshot.id),
                "app_bundle_id": .string(window.snapshot.appBundleID),
                "evidence": .array(evidence.map { JSONValue.string($0) }),
                "valid_until": .string("next_window_mutation"),
            ]),
        ]
        // Said out loud rather than silently absorbed: a window that is no
        // longer the size the model saw cannot have regions mapped onto it
        // faithfully, however the arithmetic is done.
        if picture.resized { result["window_resized"] = .bool(true) }
        return result
    }

    /// The rectangle the picture the model read actually covered, where it is now.
    ///
    /// Regions are fractions of the capture, so they must be mapped back onto
    /// the capture's own rectangle. A window that has since moved carries that
    /// rectangle with it; a window that has been *resized* has reflowed its
    /// contents, and no mapping of an old region is truthful — the live frame is
    /// then the best remaining guess, and the caller says so in the receipt.
    private func pictureFrame(observed: Snapshot, live: CGRect) -> (rect: CGRect, resized: Bool) {
        let resized = abs(live.width - observed.windowFrame.width) > 2
            || abs(live.height - observed.windowFrame.height) > 2
        guard !resized, let captured = observed.captureFrame else { return (live, resized) }
        return (captured.offsetBy(dx: live.minX - observed.windowFrame.minX,
                                  dy: live.minY - observed.windowFrame.minY), false)
    }

    /// Roles that describe a region of a window rather than a control in it.
    /// Snapping to one of these would replace a tight guess with a loose fact.
    private static let containerRoles: Set<String> = [
        kAXWindowRole, kAXApplicationRole, kAXGroupRole, kAXScrollAreaRole, kAXSplitGroupRole,
        kAXTabGroupRole, kAXToolbarRole, kAXListRole, kAXTableRole, kAXOutlineRole,
        kAXSheetRole, kAXDrawerRole, kAXLayoutAreaRole, kAXUnknownRole, "AXWebArea",
    ]

    /// The smallest Accessibility control the model's rectangle is sitting on.
    ///
    /// Hit-tested rather than searched, so it costs one call per sample and no
    /// tree walk. Everything here is a local fact: the element must belong to
    /// the process being taught (which is also what stops Calla's own overlay
    /// from being picked up), must be a control rather than a container, and
    /// must be near the size the model asked for — a match three times wider
    /// than the region is a panel behind the button, not the button.
    /// The smallest editor or region the application itself says is under the
    /// model's rectangle.
    ///
    /// Bounded by the same rule the Accessibility snap uses: a panel three times
    /// wider than the guess is the thing behind the control rather than the
    /// control, and replacing a tight guess with a loose fact makes the pointer
    /// worse. So this tightens a guess and never widens one.
    private func bridgePanelUnder(_ region: CGRect, in snapshot: Snapshot) -> CGRect? {
        guard let mapping = blenderLayout.mapping(for: snapshot) else { return nil }
        let centre = CGPoint(x: region.midX, y: region.midY)
        var best: CGRect?
        for area in mapping.layout.areas {
            let candidates = [mapping.screenRect(area.rect)] + area.regions.map { mapping.screenRect($0.rect) }
            for candidate in candidates where candidate.contains(centre) {
                guard candidate.width <= max(region.width, 28) * 3,
                      candidate.height <= max(region.height, 28) * 3 else { continue }
                if best == nil || candidate.width * candidate.height < best!.width * best!.height { best = candidate }
            }
        }
        return best
    }

    private func controlUnder(_ region: CGRect, in snapshot: Snapshot) -> CGRect? {
        // An application that draws its own interface answers every hit test with
        // the window itself, and each of those answers costs the full messaging
        // timeout. Five of them is a second of the socket-serving actor spent
        // learning what one probe already established. Ask once, remember, and do
        // not come back.
        //
        // An application that answered a layout bridge is that case by
        // definition — it draws its own interface, which is why it has a bridge
        // at all — so it does not even pay for the probe.
        guard blenderLayout.mapping(for: snapshot) == nil, exposesControls(snapshot) else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        // Accessibility waits six seconds by default for an application that is
        // busy, and this runs on the thread that answers the socket. A hit test
        // that cannot be answered promptly is not worth having: give it a fifth
        // of a second and fall back to the model's own rectangle.
        AXUIElementSetMessagingTimeout(systemWide, 0.2)
        let samples = [
            CGPoint(x: region.midX, y: region.midY),
            CGPoint(x: region.minX + region.width * 0.3, y: region.minY + region.height * 0.3),
            CGPoint(x: region.minX + region.width * 0.7, y: region.minY + region.height * 0.3),
            CGPoint(x: region.minX + region.width * 0.3, y: region.minY + region.height * 0.7),
            CGPoint(x: region.minX + region.width * 0.7, y: region.minY + region.height * 0.7),
        ]
        var best: CGRect?
        for sample in samples {
            var element: AXUIElement?
            guard AXUIElementCopyElementAtPosition(systemWide, Float(sample.x), Float(sample.y), &element) == .success,
                  let element else { continue }
            AXUIElementSetMessagingTimeout(element, 0.2)
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == snapshot.processID else { continue }
            guard let role = stringAttribute(element, kAXRoleAttribute as CFString),
                  !Self.containerRoles.contains(role) else { continue }
            guard let frame = try? frameAttribute(element), frame.width > 1, frame.height > 1 else { continue }
            guard frame.width <= max(region.width, 28) * 3, frame.height <= max(region.height, 28) * 3 else { continue }
            if best == nil || frame.width * frame.height < best!.width * best!.height { best = frame }
        }
        return best
    }

    /// Whether this application names its controls to Accessibility at all.
    ///
    /// The distinction matters because a failed hit test means opposite things
    /// in the two cases. In an application with a real Accessibility tree,
    /// nothing under the planned region means the screen has moved on and the
    /// step must go back to the model. In one that renders its own interface,
    /// the hit test returns the window itself everywhere and would refuse every
    /// step forever, so the same result carries no information.
    ///
    /// Answered by hit-testing a coarse grid inside the window rather than by
    /// hard-coding bundle ids, so an application that gains an Accessibility
    /// tree in a later version starts being checked properly on its own.
    ///
    /// Deliberately the window and not the application: Blender publishes a
    /// perfectly ordinary menu bar while its entire interface below it is one
    /// opaque `AXWindow`, so asking the application would answer yes and refuse
    /// every step. What matters is whether AX can see *inside the window the
    /// lesson is about*.
    ///
    /// Cached per process for the lesson: a dozen hit tests is far too much to
    /// repeat on a path whose whole point is to take a tenth of a second, and
    /// the answer is a property of the application, not of the moment.
    private func exposesControls(_ snapshot: Snapshot) -> Bool {
        if let cached = controlExposure[snapshot.processID] { return cached }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.2)
        let window = snapshot.windowFrame
        var found = false
        for column in 1...3 where !found {
            for row in 1...3 where !found {
                let point = CGPoint(x: window.minX + window.width * (CGFloat(column) / 4),
                                    y: window.minY + window.height * (CGFloat(row) / 4))
                var element: AXUIElement?
                guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
                      let element else { continue }
                var owner: pid_t = 0
                guard AXUIElementGetPid(element, &owner) == .success, owner == snapshot.processID,
                      let role = stringAttribute(element, kAXRoleAttribute as CFString) else { continue }
                found = !Self.containerRoles.contains(role)
            }
        }
        controlExposure[snapshot.processID] = found
        return found
    }

    /// Wait until the learner does something, then say so.
    ///
    /// This is what turns a single instruction into a lesson. Without it the
    /// model points once and stops, because nothing tells it the step was
    /// finished — the learner clicks, and Calla is still talking about the
    /// previous thing. Polling a coarse greyscale fingerprint of the window
    /// keeps the judgement on this Mac; only "it changed" crosses the wire.
    ///
    /// Returns rather than blocks when the wait runs out, so the model can
    /// decide whether to keep waiting, re-word the step, or move on.
    func awaitChange(_ payload: [String: JSONValue]) async throws -> [String: JSONValue] {
        let window = try await liveWindow(for: payload)
        let requested = payload["timeout_seconds"]?.numberValue ?? 15
        let deadline = Date().addingTimeInterval(min(max(requested, 1), 25))
        let threshold = min(max(payload["sensitivity"]?.numberValue ?? Self.changeThreshold, 0.005), 0.5)

        let baseline = try await thumbprint(window.snapshot)
        var latest = baseline
        var difference = 0.0
        let started = Date()
        while Date() < deadline {
            // Tight while the learner is likely to act, loose once they clearly
            // are not.
            //
            // Every tick is a real GPU capture, so a flat 80ms for the full
            // twenty-five second wait is three hundred captures for one step —
            // and it is the *first* second that matters, because a learner who
            // has understood the instruction acts almost immediately and one who
            // has not is going to take a while. Eighty milliseconds keeps the
            // response instant where it is noticed; a quarter of a second after
            // that is imperceptible and costs a third as much battery.
            let elapsed = Date().timeIntervalSince(started)
            try await Task.sleep(nanoseconds: elapsed < 1 ? 80_000_000 : 250_000_000)
            // The learner switching away is not a change in the lesson's window,
            // and re-reading a window that is no longer there is meaningless.
            guard let focused = NSWorkspace.shared.frontmostApplication,
                  focused.bundleIdentifier == window.snapshot.appBundleID else { continue }
            latest = (try? await thumbprint(window.snapshot)) ?? latest
            difference = WindowCapture.difference(baseline, latest)
            if difference >= threshold { break }
        }
        let changed = difference >= threshold
        return [
            "status": .string("ok"),
            "changed": .bool(changed),
            "difference": .number((difference * 1000).rounded() / 1000),
            "snapshot_id": .string(window.snapshot.id),
            "next": .string(changed
                            ? "Observe again; the window is not what you last saw."
                            : "Nothing moved. The learner may be stuck, or the step may already have been done."),
        ]
    }

    private func thumbprint(_ snapshot: Snapshot) async throws -> [UInt8] {
        do {
            return try await WindowCapture.thumbprint(bundleID: snapshot.appBundleID,
                                                      processID: snapshot.processID,
                                                      windowID: snapshot.windowID)
        } catch WindowCapture.Failure.notPermitted {
            throw TutorHostFailure(code: "screen_recording_not_permitted",
                                   message: "Screen Recording permission is required to notice the window changing")
        } catch {
            throw TutorHostFailure(code: "capture_failed", message: "The focused allowlisted window could not be read")
        }
    }

    /// Take the route the model worked out before it starts pointing.
    ///
    /// Held on this Mac so the tooltip can show where the lesson is and what
    /// follows without the model spending a round trip repeating itself. It is
    /// provisional: the model re-issues it whenever the screen turns out
    /// differently from what it expected.
    ///
    /// A step that arrives with a region and words is also the thing that makes
    /// a lesson quick: `advanceLocally` can point at it the moment the learner
    /// finishes the step before, with no model in the loop at all.
    func plan(_ payload: [String: JSONValue]) throws -> [String: JSONValue] {
        // An aside must not be able to rewrite the lesson it interrupted. The
        // model is told this, but the learner's route is not left resting on the
        // model having read its instructions.
        if heldForAside {
            throw TutorHostFailure(code: "lesson_held",
                                   message: "The learner stepped out of the lesson to ask something. Answer with tutor_narrate; do not plan or guide.")
        }
        guard case .array(let raw)? = payload["steps"] else {
            return ["status": .string("ok"), "steps": .number(0)]
        }
        let parsed = try raw.compactMap(plannedStep).prefix(12)
        plan = Array(parsed)
        planIndex = min(Int(payload["index"]?.numberValue ?? 0), max(plan.count - 1, 0))
        // The plan's regions were measured against whatever the model last
        // observed, so that is the geometry they have to be mapped back from.
        planSnapshot = snapshots[payload["snapshot_id"]?.stringValue ?? ""] ?? latestSnapshot
        // Said back, because "how many of these can the Mac do by itself" is the
        // number that decides how fast the lesson will feel — and a plan full of
        // regions advances nothing without the Accessibility grant that finds
        // the control under them. Better the model learns that once, here, than
        // discovers it as a failed step at a time.
        let trusted = AXIsProcessTrusted()
        var result: [String: JSONValue] = [
            "status": .string("ok"),
            "steps": .number(Double(plan.count)),
            "locally_advanceable": .number(trusted ? Double(plan.filter(\.canAdvanceLocally).count) : 0),
        ]
        if !trusted {
            result["note"] = .string(
                "This Mac has not granted Calla Accessibility, so it cannot advance steps by itself. "
                + "Every step will come back to you. Mention once that allowing it in Calla's menu bar "
                + "makes lessons much faster, then carry on teaching.")
        }
        return result
    }

    private func plannedStep(_ raw: JSONValue) throws -> PlannedStep? {
        if case .string(let title) = raw {
            return title.isEmpty ? nil : PlannedStep(title: title, region: nil, text: nil)
        }
        guard case .object(let object) = raw, let title = object["title"]?.stringValue, !title.isEmpty else {
            return nil
        }
        let region = try normalizedRegion(object["region"])
        let text = object["text"]?.stringValue
        // Both or neither: words with nowhere to go cannot be pointed at, and a
        // region with nothing to say would move the cursor in silence.
        guard (region == nil) == (text == nil || text!.isEmpty) else {
            throw TutorHostFailure(code: "invalid_plan_step",
                                   message: "A planned step needs a region and text together, or neither")
        }
        return PlannedStep(title: title, region: region, text: text)
    }

    /// Drop the route. A lesson that has ended must not have its next step
    /// pointed at because something arrived late.
    func forgetPlan() {
        plan = []
        planIndex = 0
        planSnapshot = nil
        guideThumbprint = nil
        controlExposure = [:]
    }

    /// Why the model had to be asked, in the words it will be told.
    /// What the Mac can say about the window, in the words the model is told.
    ///
    /// Shorter than it was. The cases about finding the next control —
    /// `stepNotPlanned`, `controlMissing`, `accessibilityMissing` — existed
    /// because the Mac used to point at the next step itself and had to explain
    /// why it would not. It no longer decides, so a reason it can never produce
    /// would only mislead whoever read it next.
    enum LocalAdvanceRefusal: String, Error {
        case noPlan = "there is no plan yet"
        case windowChanged = "the window being taught changed"
        case nothingMoved = "nothing on screen changed"
        case captureFailed = "the window could not be read"
    }

    /// What the Mac can tell about the step the learner says they finished.
    ///
    /// This used to point at the next step itself whenever three local checks
    /// agreed, and only asked the model when it could not. That made a step
    /// cost a tenth of a second, but nothing ever checked that the step just
    /// finished had actually worked — the cursor simply moved on. Checking the
    /// learner's work is the one thing a tutor is for, so the decision belongs
    /// to the model now.
    ///
    /// What survives is the cheap part: whether the window is still the one the
    /// plan was written against, and whether anything on it moved. That costs a
    /// thumbprint and answers a question the model would otherwise spend a
    /// capture on, so it is sent along with the question rather than thrown
    /// away. It draws nothing and advances nothing.
    func progressSignal() async -> String {
        guard !plan.isEmpty, let planSnapshot else { return LocalAdvanceRefusal.noPlan.rawValue }

        guard let focused = try? focusedAllowlistedApplication(TutorSettings.shared.effectiveAllowlist(requested: nil)),
              let fresh = try? await makeSnapshot(for: focused),
              fresh.processID == planSnapshot.processID, fresh.windowID == planSnapshot.windowID else {
            return LocalAdvanceRefusal.windowChanged.rawValue
        }

        guard let baseline = guideThumbprint, let now = try? await thumbprint(planSnapshot) else {
            return LocalAdvanceRefusal.captureFailed.rawValue
        }
        // Measured from the moment this step was drawn, not from now, so it
        // judges the step rather than the wait.
        return WindowCapture.difference(baseline, now) >= Self.changeThreshold
            ? "the window changed"
            : LocalAdvanceRefusal.nothingMoved.rawValue
    }

    /// Draw the step the lesson is already on, without asking anyone.
    ///
    /// Used to come back from an aside: the Mac still holds this step's region
    /// and words, so putting the learner back where they were is free.
    func redrawCurrentStep() async -> Bool {
        guard planIndex < plan.count, let region = plan[planIndex].region, let text = plan[planIndex].text,
              let focused = try? focusedAllowlistedApplication(TutorSettings.shared.effectiveAllowlist(requested: nil)),
              let fresh = try? await makeSnapshot(for: focused), let planSnapshot else { return false }
        let picture = pictureFrame(observed: planSnapshot, live: fresh.windowFrame)
        let frame = CGRect(x: picture.rect.minX + picture.rect.width * region.left,
                           y: picture.rect.minY + picture.rect.height * region.top,
                           width: max(picture.rect.width * region.width, 8),
                           height: max(picture.rect.height * region.height, 8))
        PointerOverlay.shared.point(at: frame, window: fresh.windowFrame, owner: fresh.appBundleID,
                                    step: stepLabel, text: String(text.prefix(240)),
                                    status: "Calla — \(plan[planIndex].title)",
                                    targetOutline: TargetPresentation.broadArea.outlineFrame(for: frame))
        return true
    }

    /// Re-word the tooltip without moving the cursor, so the model can keep
    /// talking about the control it already pointed at.
    func narrate(_ payload: [String: JSONValue]) -> [String: JSONValue] {
        let step = payload["step"]?.stringValue ?? "Calla"
        let text = payload["text"]?.stringValue ?? ""
        PointerOverlay.shared.narrate(step: step,
                                      text: String(text.prefix(240)),
                                      status: payload["status"]?.stringValue ?? "Calla — \(step)",
                                      thinking: payload["thinking"]?.boolValue ?? false,
                                      holding: payload["holding"]?.boolValue ?? false)
        return ["status": .string("ok")]
    }

    /// The window the observation named, located again right now.
    ///
    /// Guiding deliberately tolerates a much older observation than acting
    /// does: a vision round trip over the tailnet takes seconds, and drawing an
    /// arrow changes nothing. What it will not tolerate is a *different*
    /// window, so process and window identity must still match, and the region
    /// is mapped against the geometry read back in this call rather than the
    /// geometry captured earlier.
    private func liveWindow(for payload: [String: JSONValue]) async throws -> (snapshot: Snapshot, frame: CGRect) {
        guard case .string(let snapshotID)? = payload["snapshot_id"], let prior = snapshots[snapshotID] else {
            throw TutorHostFailure(code: "unknown_snapshot", message: "An observation receipt is required before guiding")
        }
        guard Date().timeIntervalSince(prior.createdAt) <= maxGuideSnapshotAge else {
            throw TutorHostFailure(code: "stale_snapshot", message: "The observation receipt is stale; observe again")
        }
        let focused = try focusedAllowlistedApplication(allowlist(from: payload))
        let fresh = try await makeSnapshot(for: focused)
        guard fresh.processID == prior.processID, fresh.windowID == prior.windowID else {
            throw TutorHostFailure(code: "changed_window", message: "The focused allowlisted window changed after observation")
        }
        return (prior, fresh.windowFrame)
    }

    func point(_ payload: [String: JSONValue]) async throws -> [String: JSONValue] {
        let target = try await resolveFreshTarget(payload, authority: .point, allowHint: true)
        var label: String?
        if case .string(let value)? = payload["label"] { label = value }
        var step = "Calla"
        if case .string(let value)? = payload["step"] { step = value }
        PointerOverlay.shared.point(at: target.frame,
                                    window: target.snapshot.windowFrame,
                                    owner: target.snapshot.appBundleID,
                                    step: step,
                                    text: label ?? target.descriptor.title,
                                    status: "Calla — \(target.descriptor.title)",
                                    targetOutline: target.presentation.outlineFrame(for: target.frame))
        return ["status": .string("ok"), "resolution_receipt": receipt(for: target)]
    }

    /// Fast-course pointing never consumes an observation or a model hint. It
    /// resolves current Accessibility facts against declared app bundle only.
    func fastPoint(target raw: JSONValue, bundleID: String, step: String, text: String, status: String,
                   highlight: Bool = false) async throws {
        let descriptor = try UITargetDescriptor(raw: raw)
        let focused = try focusedAllowlistedApplication(Set([bundleID]))
        let snapshot = try await makeSnapshot(for: focused)
        guard snapshot.appBundleID == bundleID else {
            throw TutorHostFailure(code: "course_app_changed", message: "Course target app is no longer focused")
        }
        let target = try await resolve(descriptor: descriptor, in: focused.element, snapshot: snapshot, hint: nil)
        guard target.confidence >= descriptor.pointMinimumConfidence else {
            throw TutorHostFailure(code: "unresolved", message: "Local descriptor evidence is below authored confidence")
        }
        PointerOverlay.shared.point(at: target.frame, window: snapshot.windowFrame, owner: bundleID,
                                    step: step, text: String(text.prefix(240)), status: status,
                                    targetOutline: target.presentation.outlineFrame(for: target.frame))
        // A rung up the lesson's own escalation ladder: outline the thing rather
        // than only point at it. Drawn around the same rectangle the pointer was
        // placed from, so the two cannot disagree about where the control is.
        if highlight { PointerOverlay.shared.highlight(target.frame) }
    }

    /// Fresh detector check for one fast-course step. No stale snapshot may
    /// advance a route, and unresolved state remains unknown/fail-closed.
    func fastVerify(target rawTarget: JSONValue, detector rawDetector: JSONValue, bundleID: String) async throws -> [String: JSONValue] {
        let descriptor = try UITargetDescriptor(raw: rawTarget)
        let detector = try DetectorDescriptor(raw: rawDetector)
        let focused = try focusedAllowlistedApplication(Set([bundleID]))
        let snapshot = try await makeSnapshot(for: focused)
        guard snapshot.appBundleID == bundleID else {
            throw TutorHostFailure(code: "course_app_changed", message: "Course target app changed")
        }
        let target = try await resolve(descriptor: descriptor, in: focused.element, snapshot: snapshot, hint: nil)
        guard target.confidence >= descriptor.pointMinimumConfidence else {
            throw TutorHostFailure(code: "unresolved", message: "Local descriptor evidence is below authored confidence")
        }
        return try evaluate(detector: detector, target: target)
    }

    func verify(_ payload: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard payload["target_hint"] == nil else {
            throw TutorHostFailure(code: "target_hint_forbidden", message: "Verification accepts only locally resolved descriptor evidence")
        }
        let target = try await resolveFreshTarget(payload, authority: .point, allowHint: false)
        let detector = try self.detector(from: payload, key: "detector_descriptor")
        return try evaluate(detector: detector, target: target)
    }

    func detector(from payload: [String: JSONValue], key: String) throws -> DetectorDescriptor {
        guard let raw = payload[key] else {
            throw TutorHostFailure(code: "missing_detector", message: "A canonical App-Pack detector descriptor is required")
        }
        return try DetectorDescriptor(raw: raw)
    }

    func resolveFreshTarget(_ payload: [String: JSONValue], authority: ResolutionAuthority, allowHint: Bool) async throws -> ResolvedTarget {
        guard let rawDescriptor = payload["target_descriptor"] else {
            throw TutorHostFailure(code: "missing_target", message: "A canonical App-Pack target descriptor is required")
        }
        let descriptor = try UITargetDescriptor(raw: rawDescriptor)
        guard case .string(let snapshotID)? = payload["snapshot_id"], let prior = snapshots[snapshotID] else {
            throw TutorHostFailure(code: "unknown_snapshot", message: "An observation receipt is required before target resolution")
        }
        guard Date().timeIntervalSince(prior.createdAt) <= maxSnapshotAge else {
            throw TutorHostFailure(code: "stale_snapshot", message: "The observation receipt is stale")
        }
        let hint: NormalizedRegion?
        if allowHint {
            hint = try normalizedHint(payload["target_hint"])
        } else {
            guard payload["target_hint"] == nil else {
                throw TutorHostFailure(code: "target_hint_forbidden", message: "A visual hint is permitted for pointing only")
            }
            hint = nil
        }
        let focused = try focusedAllowlistedApplication(allowlist(from: payload))
        let fresh = try await makeSnapshot(for: focused)
        guard fresh.processID == prior.processID, fresh.windowID == prior.windowID, fresh.windowFrame.equalTo(prior.windowFrame) else {
            throw TutorHostFailure(code: "changed_window", message: "The focused allowlisted window changed after observation")
        }
        let threshold = authority == .action ? descriptor.actionMinimumConfidence : descriptor.pointMinimumConfidence
        do {
            let target = try await resolve(descriptor: descriptor, in: focused.element, snapshot: fresh,
                                           hint: hint, authority: authority)
            // Pixels may point and may never press. The confidence ceiling in
            // `VisualLocator` already keeps a reading below every authored `act`
            // threshold; this refuses it by name as well, so a pack that authored
            // a low `act` could not quietly hand a reading the right to click.
            guard authority != .action || !target.evidence.contains("local_vision_text_match") else {
                throw TutorHostFailure(code: "unresolved",
                                       message: "A target read off the screen may be pointed at but never acted on")
            }
            guard target.confidence >= threshold else {
                throw TutorHostFailure(code: "unresolved", message: "Local descriptor evidence did not meet the authored confidence threshold")
            }
            return target
        } catch let failure as TutorHostFailure where failure.code == "unresolved" || failure.code == "ambiguous_target" {
            // Applications that render their own interface (Blender draws in
            // OpenGL) expose no Accessibility elements, so constraining an empty
            // candidate list by the hint can never resolve. Pointing changes
            // nothing, so the hint alone may place the cursor there. Acting never
            // may: `authority == .action` rethrows, and allowHint is false for it.
            guard authority == .point, let hint else { throw failure }
            let window = fresh.windowFrame
            let frame = CGRect(x: window.minX + window.width * hint.left,
                               y: window.minY + window.height * hint.top,
                               width: max(window.width * hint.width, 8),
                               height: max(window.height * hint.height, 8))
            return ResolvedTarget(element: focused.element,
                                  frame: frame,
                                  confidence: min(threshold, 0.75),
                                  snapshot: fresh,
                                  descriptor: descriptor,
                                  evidence: ["visual_hint_only"])
        }
    }

    func press(_ target: ResolvedTarget) throws {
        guard AXUIElementPerformAction(target.element, kAXPressAction as CFString) == .success else {
            throw TutorHostFailure(code: "action_failed", message: "macOS Accessibility rejected the locally approved action")
        }
    }

    func evaluate(detector: DetectorDescriptor, target: ResolvedTarget) throws -> [String: JSONValue] {
        switch detector.provider {
        case .accessibility:
            guard detector.query["target"]?.stringValue == target.descriptor.id else {
                throw TutorHostFailure(code: "detector_target_mismatch", message: "The detector does not apply to the locally resolved target")
            }
            guard let attribute = detector.query["attribute"]?.stringValue, let expected = detector.query["equals"]?.boolValue else {
                throw TutorHostFailure(code: "invalid_detector", message: "The accessibility detector is malformed")
            }
            let actual: Bool
            switch attribute {
            case "selected": actual = boolAttribute(target.element, kAXSelectedAttribute as CFString) ?? false
            case "enabled": actual = boolAttribute(target.element, kAXEnabledAttribute as CFString) ?? false
            case "visible": actual = !target.frame.isEmpty
            default: throw TutorHostFailure(code: "invalid_detector", message: "The detector requests an unsupported accessibility attribute")
            }
            return [
                "expectation_id": .string(detector.id),
                "outcome": .string(actual == expected ? "satisfied" : "unsatisfied"),
                "stable_samples": .number(1),
                "evidence": .array([.string("accessibility:\(attribute)")]),
                "resolution_receipt": receipt(for: target),
            ]
        case .blenderBridge:
            do {
                let state = try bridgeObserver.observeState()
                let satisfied = try Self.evaluateBridgeQuery(detector.query, state: state)
                return [
                    "expectation_id": .string(detector.id),
                    "outcome": .string(satisfied ? "satisfied" : "unsatisfied"),
                    "stable_samples": .number(1),
                    "evidence": .array([.string("read_only_blender_bridge")]),
                    "resolution_receipt": receipt(for: target),
                ]
            } catch {
                // A missing or failed bridge never falls back to model or pixel
                // interpretation. Accessibility-only detectors remain usable.
                return [
                    "expectation_id": .string(detector.id),
                    "outcome": .string("unknown"),
                    "stable_samples": .number(0),
                    "evidence": .array([.string("read_only_bridge_unavailable")]),
                    "reason": .string("No local read-only bridge observation was available"),
                    "resolution_receipt": receipt(for: target),
                ]
            }
        }
    }

    /// The application's own state, for the things that are about the state and
    /// not about any one control.
    ///
    /// A prerequisite ("this lesson needs a mesh selected") and a diagnosis
    /// ("that added a Subdivision Surface") are both questions about the
    /// application, not about a rectangle, so neither needs a resolved target and
    /// neither should have to invent one to ask.
    func bridgeState() -> JSONValue? { try? bridgeObserver.observeState() }

    func stateDigest() -> BlenderStateDigest? { bridgeState().flatMap { BlenderStateDigest($0) } }

    /// Whether a target-free detector holds right now.
    ///
    /// Only the bridge provider: an Accessibility detector asks about an element,
    /// so without a resolved target there is nothing for it to ask about, and
    /// answering "no" would be a claim rather than an answer. Unknown stays
    /// unknown — an explanation the Mac cannot verify is worse than none, because
    /// the learner believes it.
    func satisfies(_ detector: DetectorDescriptor, in state: JSONValue) -> Bool {
        guard detector.provider == .blenderBridge else { return false }
        return (try? Self.evaluateBridgeQuery(detector.query, state: state)) ?? false
    }

    private func receipt(for target: ResolvedTarget) -> JSONValue {
        // Written here because every path that produces a receipt also produces
        // a rectangle, and the rectangle is the one thing the receipt cannot
        // carry off this Mac.
        StepTiming.placement(target.descriptor.id, frame: target.frame,
                             confidence: target.confidence, evidence: target.evidence)
        return .object([
            "semantic_id": .string(target.descriptor.id),
            "snapshot_id": .string(target.snapshot.id),
            "confidence": .number(target.confidence),
            "evidence": .array(target.evidence.map(JSONValue.string)),
            "valid_until": .string("next_window_mutation"),
        ])
    }

    private func normalizedHint(_ value: JSONValue?) throws -> NormalizedRegion? {
        guard let value else { return nil }
        guard case .object(let hint) = value, Set(hint.keys) == Set(["region"]) else {
            throw TutorHostFailure(code: "invalid_target_hint", message: "target_hint must contain one normalized region only")
        }
        return try normalizedRegion(hint["region"])
    }

    /// A region of the observed window, in [0,1], and nothing else. Rejecting
    /// any extra key is what keeps a pixel rectangle from arriving dressed as a
    /// normalized one.
    private func normalizedRegion(_ value: JSONValue?) throws -> NormalizedRegion? {
        guard let value else { return nil }
        guard case .object(let region) = value, Set(region.keys) == Set(["left", "top", "width", "height"]),
              let left = region["left"]?.numberValue, let top = region["top"]?.numberValue,
              let width = region["width"]?.numberValue, let height = region["height"]?.numberValue else {
            throw TutorHostFailure(code: "invalid_region", message: "A region must contain left, top, width, and height only")
        }
        do { return try NormalizedRegion(left: left, top: top, width: width, height: height) }
        catch let error as DescriptorValidationError { throw TutorHostFailure(code: "invalid_region", message: error.message) }
    }

    /// The application this lesson is about.
    ///
    /// Normally that is whatever is in front. But asking Calla for a lesson
    /// means typing somewhere — a chat window, a terminal — and on this Mac that
    /// is the same screen, so by the time the request arrives the application
    /// the learner meant is behind the one they typed into. Requiring it to be
    /// frontmost made the product impossible to trigger from the machine it
    /// teaches on.
    ///
    /// So when the front application is not one Calla may observe, fall back to
    /// the most recent one that was. The allowlist is still the entire
    /// permission boundary: this can only ever land on an application the owner
    /// already allowed, and only one they were using themselves.
    private func focusedAllowlistedApplication(_ allowed: Set<String>) throws -> FocusedApplication {
        if let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier,
           allowed.contains(bundleID) {
            LessonSubject.shared.remember(app)
            return FocusedApplication(application: app, element: AXUIElementCreateApplication(app.processIdentifier))
        }
        if let recent = LessonSubject.shared.mostRecent(in: allowed) {
            return FocusedApplication(application: recent, element: AXUIElementCreateApplication(recent.processIdentifier))
        }
        throw TutorHostFailure(
            code: "app_not_allowed",
            message: "No application this Mac allows Calla to observe is open. Focus it once, then ask again.")
    }

    /// Builds the observation receipt without touching Accessibility.
    ///
    /// Applications that render their own interface expose no Accessibility
    /// tree, and AX is a separate TCC grant that silently returns nil when
    /// stale. The window geometry this host actually needs — id, bounds — comes
    /// from the window server, which only requires Screen Recording. AX is used
    /// afterwards, if at all, to resolve elements *within* the window.
    private func makeSnapshot(for focused: FocusedApplication) async throws -> Snapshot {
        let window = try await WindowCapture.identity(bundleID: focused.application.bundleIdentifier ?? "",
                                                       processID: focused.application.processIdentifier)
        let version = focused.application.bundleURL.flatMap {
            Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        } ?? "unknown"
        return Snapshot(processID: focused.application.processIdentifier,
                        windowID: window.id,
                        windowFrame: window.frame,
                        appBundleID: focused.application.bundleIdentifier ?? "unknown",
                        appVersion: version)
    }

    /// The largest on-screen, non-desktop window owned by the process.
    private func frontmostWindow(processID: pid_t) throws -> (id: CGWindowID, frame: CGRect) {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw TutorHostFailure(code: "window_lookup_failed", message: "The window server did not return a window list")
        }
        let owned = infos.compactMap { info -> (CGWindowID, CGRect)? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 1, frame.height > 1 else { return nil }
            return (CGWindowID(number.uint32Value), frame)
        }
        guard let best = owned.max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) else {
            throw TutorHostFailure(code: "no_focused_window", message: "The focused allowlisted application has no on-screen window")
        }
        return (best.0, best.1)
    }

    private func focusedWindowID(processID: pid_t, frame: CGRect) throws -> CGWindowID {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw TutorHostFailure(code: "window_lookup_failed", message: "Could not inspect the focused allowlisted window")
        }
        let candidate = infos.first { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let windowFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return windowFrame.intersects(frame) && windowFrame.width > 0 && windowFrame.height > 0
        }
        guard let number = candidate?[kCGWindowNumber as String] as? NSNumber else {
            throw TutorHostFailure(code: "window_lookup_failed", message: "Could not identify the focused allowlisted window")
        }
        return CGWindowID(number.uint32Value)
    }

    /// CGWindowListCreateImage is deprecated and returns nil on current macOS,
    /// so capture goes through ScreenCaptureKit. Still exactly one window,
    /// never a display, and never written to disk.
    private func captureFocusedWindow(_ snapshot: Snapshot,
                                      crop: NormalizedRegion? = nil,
                                      longEdge requested: Int? = nil) async throws -> WindowCapture.Capture {
        do {
            // The owner's setting is a ceiling, never a floor. The Gateway can
            // ask for something cheaper — a step check wants a small crop, not
            // a 1600-pixel window — but nothing off this Mac can ask for more
            // detail than the person sitting at it chose to send.
            let owned = TutorSettings.shared.captureLongEdge
            var longEdge = min(requested ?? owned, owned)
            // A big capture is only worth its price where the picture is what
            // carries the pointing.
            //
            // 1600 is the shipped default for a stated reason: in an application
            // that exposes no Accessibility controls there is nothing to correct
            // the model's estimate, so the pointer lands exactly where the
            // pixels let it guess, and detail is the only thing buying accuracy.
            // Where the application answers a layout bridge that reasoning no
            // longer holds — the geometry is measured, not read off the image —
            // so the capture is back to being something the model looks at
            // rather than something it aims with, and it can be cheap again.
            if blenderLayout.mapping(for: snapshot) != nil {
                longEdge = min(longEdge, 1024)
            }
            let capture = try await WindowCapture.capture(bundleID: snapshot.appBundleID,
                                                          processID: snapshot.processID,
                                                          windowID: snapshot.windowID,
                                                          longEdge: CGFloat(longEdge),
                                                          crop: crop)
            guard capture.data.count <= maxCaptureJPEGBytes else {
                throw TutorHostFailure(code: "capture_too_large", message: "The focused window JPEG exceeds the in-memory capture limit")
            }
            return capture
        } catch let failure as TutorHostFailure {
            throw failure
        } catch WindowCapture.Failure.notPermitted {
            throw TutorHostFailure(code: "screen_recording_not_permitted", message: "Screen Recording permission is required to capture the window")
        } catch {
            throw TutorHostFailure(code: "capture_failed", message: "The focused allowlisted window could not be captured")
        }
    }

    /// Which row of the Properties strip selects a given context.
    ///
    /// Reads the strip for the selected tab's highlight and files it under the
    /// context the bridge says is selected — so every visit teaches Calla one
    /// more row — then answers with the row asked for, if it has ever been seen.
    /// A tab nobody has ever opened returns nil and the caller points at the
    /// strip, which is honest: Calla genuinely does not know yet.
    private func propertyTab(_ tab: String, strip: CGRect, snapshot: Snapshot) async -> PropertyTabs.Band? {
        let state = bridgeState()
        let objectType = state?.objectValue?["active_object"]?.objectValue?["type"]?.stringValue ?? "none"
        var active: String?
        if case .array(let contexts)? = state?.objectValue?["properties_contexts"] {
            active = contexts.compactMap(\.stringValue).first
        }
        if let active, let band = await PropertyTabs.activeBand(in: strip, of: snapshot) {
            PropertyTabs.remember(active, band: band, for: snapshot, objectType: objectType, strip: strip)
            if active.caseInsensitiveCompare(tab) == .orderedSame { return band }
        }
        if let known = PropertyTabs.remembered(tab, for: snapshot, objectType: objectType, strip: strip) {
            return known
        }
        // Never seen this one. Walk the strip once, put the learner's tab back,
        // and answer from what that taught — so a lesson points at the right row
        // the first time rather than the second.
        await PropertyTabs.calibrate(strip: strip, snapshot: snapshot, objectType: objectType, bridge: bridgeObserver)
        return PropertyTabs.remembered(tab, for: snapshot, objectType: objectType, strip: strip)
    }

    /// Where a canonical pack entity is, from local facts, in order of authority.
    ///
    /// Three branches, tried in the order of how much they know:
    ///
    /// 1. **The application's own bridge.** Blender is asked where it drew the
    ///    Properties editor and it answers exactly, in its own pixels, which this
    ///    Mac converts. Measured geometry, so it may point and it may act.
    /// 2. **Accessibility.** Today's descriptor-constrained tree walk. The right
    ///    answer for an application that names its controls, and the reason this
    ///    branch is second rather than first is only that a bridge, where one
    ///    exists, is more specific about editors than AX is about panels.
    /// 3. **Reading the screen.** Text recognition inside the rectangle branch 1
    ///    or 2 produced — never inside a window, never inside a display. May
    ///    point, may never act; `VisualLocator.confidenceCeiling` and the
    ///    `authority == .action` refusal below say so twice.
    ///
    /// Before this, the method opened by throwing `unresolved` whenever no
    /// Accessibility candidate matched. In Blender that is every target, always:
    /// it draws its entire interface in OpenGL and macOS sees one opaque
    /// `AXWindow`. So no Blender course step could ever resolve, the fast local
    /// route died on its first step, and every lesson fell back to a model
    /// guessing at a JPEG. This chain is what makes the geometry knowable.
    private func resolve(descriptor: UITargetDescriptor, in app: AXUIElement, snapshot: Snapshot,
                         hint: NormalizedRegion?, authority: ResolutionAuthority = .point) async throws -> ResolvedTarget {
        // Branch 1: the application's own account of its layout.
        if let selector = descriptor.bridgeSelector,
           let mapping = blenderLayout.mapping(for: snapshot),
           let frame = mapping.screenRect(for: selector) {
            let bridged = ResolvedTarget(element: app, frame: frame, confidence: 0.95, snapshot: snapshot,
                                         descriptor: descriptor,
                                         evidence: ["local_application_bridge_layout",
                                                    "bridge-selector:\(selector.editorType ?? "?")"])
            // Branch 3, narrowed by branch 1: an editor is not a button. When the
            // entity names a label, the label's own rectangle inside that editor
            // is the better answer, and when it cannot be read the editor stands.
            if let matcher = descriptor.visual?.textMatcher, authority == .point,
               let match = await VisualLocator.text(matching: matcher, in: frame, of: snapshot) {
                return ResolvedTarget(element: app, frame: match.frame, confidence: match.confidence,
                                      snapshot: snapshot, descriptor: descriptor,
                                      evidence: bridged.evidence + ["local_vision_text_match"])
            }
            // A tab inside the Properties strip. The strip is measured; which
            // row is which is read from the highlight and remembered.
            if let tab = selector.tab, authority == .point,
               let band = await propertyTab(tab, strip: frame, snapshot: snapshot) {
                return ResolvedTarget(element: app, frame: band.rect(in: frame), confidence: 0.90,
                                      snapshot: snapshot, descriptor: descriptor,
                                      evidence: bridged.evidence + ["local_property_tab_highlight"])
            }
            if let icon = descriptor.visual?.icon, authority == .point,
               let match = await VisualLocator.icon(named: icon, in: frame, of: snapshot) {
                return ResolvedTarget(element: app, frame: match.frame, confidence: match.confidence,
                                      snapshot: snapshot, descriptor: descriptor,
                                      evidence: bridged.evidence + ["local_vision_icon_template_match"])
            }
            return bridged
        }

        guard !descriptor.accessibilityCandidates.isEmpty else {
            throw TutorHostFailure(code: "unresolved", message: "No safe local resolver branch answered for this target")
        }
        let crop = hint.map { normalizedRegion in
            CGRect(
                x: snapshot.windowFrame.minX + snapshot.windowFrame.width * normalizedRegion.left,
                y: snapshot.windowFrame.minY + snapshot.windowFrame.height * normalizedRegion.top,
                width: snapshot.windowFrame.width * normalizedRegion.width,
                height: snapshot.windowFrame.height * normalizedRegion.height)
        }
        let candidates = descendants(of: app, maxDepth: 12).compactMap { element -> ResolvedTarget? in
            guard let frame = try? frameAttribute(element), frame.width > 0, frame.height > 0,
                  crop.map({ $0.intersects(frame) }) ?? true else { return nil }
            guard let role = stringAttribute(element, kAXRoleAttribute as CFString) else { return nil }
            let title = stringAttribute(element, kAXTitleAttribute as CFString) ?? ""
            let description = stringAttribute(element, kAXDescriptionAttribute as CFString) ?? ""
            let help = stringAttribute(element, kAXHelpAttribute as CFString) ?? ""
            guard let match = descriptor.accessibilityCandidates.first(where: {
                matches(candidate: $0, role: role, title: title, description: description, help: help)
            }) else { return nil }
            let neighborsSatisfied = satisfiesNeighborConstraint(element, expected: descriptor.neighborConstraints)
            guard descriptor.neighborConstraints.isEmpty || neighborsSatisfied else { return nil }
            let matcherCount = [match.labelMatcher, match.descriptionMatcher, match.helpMatcher].compactMap { $0 }.count
            let aliasMatches = ([descriptor.title] + descriptor.aliases).contains {
                title.compare($0, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            let enabled = boolAttribute(element, kAXEnabledAttribute as CFString) == true
            // The score comes solely from independently observed local AX facts:
            // descriptor matcher(s), descriptor title/alias, and enabled state.
            // A model region is intentionally absent from this calculation.
            let confidence = min(1, 0.75 + 0.1 * Double(matcherCount) / 3 + (aliasMatches ? 0.1 : 0) + (enabled ? 0.1 : 0))
            var evidence = ["accessibility-role:\(role)", "descriptor-matcher"]
            if aliasMatches { evidence.append("descriptor-alias") }
            if enabled { evidence.append("accessibility-enabled") }
            if neighborsSatisfied { evidence.append("descriptor-neighbor") }
            if hint != nil { evidence.append("local-geometry-search-prior") }
            return ResolvedTarget(element: element, frame: frame, confidence: confidence, snapshot: snapshot, descriptor: descriptor, evidence: evidence)
        }
        guard candidates.count == 1, let target = candidates.first else {
            throw TutorHostFailure(code: candidates.isEmpty ? "unresolved" : "ambiguous_target", message: "The descriptor-constrained local result is not unique")
        }
        return target
    }

    private func matches(candidate: AccessibilityCandidate, role: String, title: String, description: String, help: String) -> Bool {
        guard role == candidate.role else { return false }
        if let matcher = candidate.labelMatcher, !matcher.matches(title) { return false }
        if let matcher = candidate.descriptionMatcher, !matcher.matches(description) { return false }
        if let matcher = candidate.helpMatcher, !matcher.matches(help) { return false }
        return true
    }

    private func satisfiesNeighborConstraint(_ element: AXUIElement, expected: [String]) -> Bool {
        guard !expected.isEmpty else { return true }
        guard let parent = copyElementAttribute(element, kAXParentAttribute as CFString) else { return false }
        let labels = descendants(of: parent, maxDepth: 2).map {
            [
                stringAttribute($0, kAXTitleAttribute as CFString),
                stringAttribute($0, kAXDescriptionAttribute as CFString),
                stringAttribute($0, kAXHelpAttribute as CFString),
            ].compactMap { $0 }.joined(separator: " ").lowercased()
        }
        return expected.contains { expectedLabel in
            let normalized = expectedLabel.replacingOccurrences(of: "_", with: " ").lowercased()
            return labels.contains { $0.contains(normalized) }
        }
    }

    private static func evaluateBridgeQuery(_ query: [String: JSONValue], state: JSONValue) throws -> Bool {
        guard let path = query["path"]?.stringValue else {
            throw TutorHostFailure(code: "invalid_detector", message: "The bridge detector has no bounded path")
        }
        let value = path.split(separator: ".").reduce(Optional(state)) { current, segment in
            current?.objectValue?[String(segment)]
        }
        guard let value else { return false }
        if let expected = query["equals"] { return value == expected }
        if let expected = query["contains"], case .array(let values) = value { return values.contains(expected) }
        if case .object(let expected)? = query["any"], case .array(let values) = value {
            return values.contains { candidate in
                guard case .object(let object) = candidate else { return false }
                return expected.allSatisfy { object[$0.key] == $0.value }
            }
        }
        if case .object(let ordered)? = query["ordered"],
           let before = ordered["before"]?.stringValue,
           let after = ordered["after"]?.stringValue,
           case .array(let values) = value {
            let types = values.compactMap { $0.objectValue?["type"]?.stringValue }
            guard let beforeIndex = types.firstIndex(of: before), let afterIndex = types.firstIndex(of: after) else { return false }
            return beforeIndex < afterIndex
        }
        throw TutorHostFailure(code: "invalid_detector", message: "The bridge detector has an unsupported query")
    }
}

struct BlenderBridgeDescriptor: Decodable {
    let protocolVersion: Int
    let bridge: String
    let host: String
    let port: UInt16
    let token: String
    let readOnly: Bool

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case bridge, host, port, token
        case readOnly = "read_only"
    }
}

final class BlenderBridgeObserver {
    /// Where a live Blender add-on announces its loopback endpoint.
    ///
    /// The add-on lives inside Blender's own scripts directory and knows
    /// nothing about Boring's runtime root, so it has always written to
    /// `~/Library/Caches/CallaTutor`. Moving Tutor into Boring moved only this
    /// reader to the runtime cache, and the two stopped meeting: no descriptor
    /// meant no layout, every Blender target resolved to nothing, and the
    /// pointer and tooltip never appeared for any lesson. Both are read, newest
    /// descriptor wins, so a future add-on may publish under the runtime root
    /// without breaking the installed one.
    private let directories = [
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/CallaTutor", isDirectory: true),
        CallaRuntime.cache("bridge"),
    ]

    func observeState() throws -> JSONValue { try observe("observe_state") }

    /// Every Properties tab Blender knows the name of.
    func propertyContexts() throws -> [String] {
        guard case .array(let values)? = try observe("property_contexts", timeout: 3).objectValue?["contexts"] else { return [] }
        return values.compactMap(\.stringValue)
    }

    /// Show one Properties tab. The only write this bridge has, bounded to one
    /// enum on one editor, and used only to learn where its button is.
    @discardableResult
    func setPropertyContext(_ context: String) throws -> String {
        let result = try observe("set_property_context", timeout: 3,
                                 payload: ["context": .string(context)])
        return result.objectValue?["context"]?.stringValue ?? ""
    }

    /// Where Blender has drawn its editors, in Blender's own window pixels.
    /// Converting that to the screen is `BlenderLayout`'s job, not this one's.
    ///
    /// Given a much shorter deadline than the state read, because this one is on
    /// the path that places the cursor. A live Blender on loopback answers in
    /// single-digit milliseconds; anything that has not answered in half a second
    /// is not going to, and waiting is a visible stall rather than a slow success.
    func observeLayout() throws -> JSONValue { try observe("observe_layout", timeout: 0.5) }

    private func observe(_ operation: String, timeout: TimeInterval = 5,
                         payload: [String: JSONValue] = [:]) throws -> JSONValue {
        let descriptor = try latestDescriptor()
        let requestID = UUID().uuidString
        let request: [String: JSONValue] = [
            "protocol_version": .number(1),
            "request_id": .string(requestID),
            "token": .string(descriptor.token),
            "operation": .string(operation),
            "payload": .object(payload),
        ]
        let response = try requestLoopback(descriptor: descriptor, request: request, timeout: timeout)
        guard let object = response.objectValue, object["request_id"]?.stringValue == requestID,
              object["ok"]?.boolValue == true, let result = object["result"] else {
            throw TutorHostFailure(code: "bridge_unavailable", message: "The local read-only bridge returned no valid observation")
        }
        return result
    }

    private func latestDescriptor() throws -> BlenderBridgeDescriptor {
        let manager = FileManager.default
        let files = directories
            .flatMap { directory in
                (try? manager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                    options: [.skipsHiddenFiles])) ?? []
            }
            .filter { $0.lastPathComponent.hasPrefix("blender-") && $0.pathExtension == "json" }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return left > right
            }
        guard let path = files.first else {
            throw TutorHostFailure(code: "bridge_unavailable", message: "No active local read-only bridge descriptor exists")
        }
        let attributes = try manager.attributesOfItem(atPath: path.path)
        guard let permission = (attributes[.posixPermissions] as? NSNumber)?.intValue, permission & 0o077 == 0,
              let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue, owner == Int(getuid()),
              let size = (attributes[.size] as? NSNumber)?.intValue, size > 0, size <= 8 * 1024 else {
            throw TutorHostFailure(code: "bridge_unavailable", message: "The local bridge descriptor is not owner-only and bounded")
        }
        let descriptor = try JSONDecoder().decode(BlenderBridgeDescriptor.self, from: Data(contentsOf: path, options: .mappedIfSafe))
        guard descriptor.protocolVersion == 1, descriptor.bridge == "blender-tutor-bridge-v1", descriptor.host == "127.0.0.1",
              descriptor.port > 0, descriptor.token.count >= 16, descriptor.readOnly else {
            throw TutorHostFailure(code: "bridge_unavailable", message: "The local bridge descriptor is not a read-only loopback endpoint")
        }
        return descriptor
    }

    private func requestLoopback(descriptor: BlenderBridgeDescriptor, request: [String: JSONValue],
                                 timeout seconds: TimeInterval) throws -> JSONValue {
        var encoded = try JSONEncoder().encode(request)
        encoded.append(10)
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw TutorHostFailure(code: "bridge_unavailable", message: "Could not open the local bridge socket") }
        defer { close(socketFD) }
        var timeout = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        _ = setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = descriptor.port.bigEndian
        guard inet_pton(AF_INET, descriptor.host, &address.sin_addr) == 1 else {
            throw TutorHostFailure(code: "bridge_unavailable", message: "The local bridge host is invalid")
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw TutorHostFailure(code: "bridge_unavailable", message: "The local read-only bridge is unavailable") }
        try encoded.withUnsafeBytes { bytes in
            var offset = 0
            while offset < encoded.count {
                let written = Darwin.write(socketFD, bytes.baseAddress!.advanced(by: offset), encoded.count - offset)
                if written < 0 { throw TutorHostFailure(code: "bridge_unavailable", message: "Could not write to the local read-only bridge") }
                offset += written
            }
        }
        var response = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count <= 64 * 1024 {
            let count = read(socketFD, &buffer, buffer.count)
            if count <= 0 { break }
            response.append(buffer, count: count)
            if response.last == 10 { break }
        }
        guard response.count > 0, response.count <= 64 * 1024, response.last == 10 else {
            throw TutorHostFailure(code: "bridge_unavailable", message: "The local read-only bridge returned an invalid response")
        }
        return try JSONDecoder().decode(JSONValue.self, from: response)
    }
}

private func copyElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute, &value) == .success ? value as? String : nil
}

private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute, &value) == .success ? (value as? NSNumber)?.boolValue : nil
}

// AXValue is a CoreFoundation type, so `as?` always succeeds and cannot test the
// payload. Check the CFTypeID, then the AXValue's own type tag.
private func axValueAttribute(_ element: AXUIElement, _ attribute: CFString, _ type: AXValueType) -> AXValue? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = (value as! AXValue)
    return AXValueGetType(axValue) == type ? axValue : nil
}

// There is no public kAXFrameAttribute; compose the frame from the documented
// position and size attributes instead of the undocumented "AXFrame".
private func frameAttribute(_ element: AXUIElement) throws -> CGRect {
    guard let positionValue = axValueAttribute(element, kAXPositionAttribute as CFString, .cgPoint),
          let sizeValue = axValueAttribute(element, kAXSizeAttribute as CFString, .cgSize) else {
        throw TutorHostFailure(code: "missing_frame", message: "The resolved Accessibility element has no usable frame")
    }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue, .cgPoint, &origin), AXValueGetValue(sizeValue, .cgSize, &size) else {
        throw TutorHostFailure(code: "missing_frame", message: "The resolved Accessibility element has no usable frame")
    }
    return CGRect(origin: origin, size: size)
}

private func firstWindow(of application: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return nil }
    return windows.first
}

private func descendants(of element: AXUIElement, maxDepth: Int) -> [AXUIElement] {
    guard maxDepth > 0 else { return [] }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
          let children = value as? [AXUIElement] else { return [] }
    return children + children.flatMap { descendants(of: $0, maxDepth: maxDepth - 1) }
}

/// Drives the overlay renderer, which runs as a separate process.
///
/// AppKit panels never composite from this SwiftUI MenuBarExtra host: they are
/// assigned a window number and report `isVisible`, but nothing reaches the
/// screen. The helper is a plain NSApplication that builds its panels during
/// launch, which is the only arrangement that renders.
@MainActor
final class PointerOverlay {
    static let shared = PointerOverlay()

    private var process: Process?
    private var input: FileHandle?

    /// The overlay renderer is a nested application inside the installed
    /// bundle, and a sibling binary in a build directory. Looking only where the
    /// installer puts it — or only where the build puts it — is why the cursor
    /// did not appear in one arrangement or the other.
    private static func helperURL() -> URL? {
        let bundle = Bundle.main.bundleURL
        let beside = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent()
        let candidates = [
            bundle.appendingPathComponent("Contents/Helpers/CallaOverlayHelper.app/Contents/MacOS/CallaOverlayHelper"),
            bundle.appendingPathComponent("Contents/MacOS/CallaOverlayHelper"),
            beside.appendingPathComponent("CallaOverlayHelper"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Start the renderer before any lesson exists.
    ///
    /// It used to be started lazily by the first thing a lesson sent, which was
    /// fine while everything it did belonged to a lesson. The Ask shortcut lives
    /// in that process and has to answer before the first lesson, so on a Mac
    /// that has not taught anything since booting there would otherwise be no
    /// process holding the key.
    func startRenderer() {
        ensureRunning()
    }

    private func ensureRunning() {
        guard process?.isRunning != true else { return }
        guard let helper = Self.helperURL() else { return }
        let task = Process()
        task.executableURL = helper
        let pipe = Pipe()
        task.standardInput = pipe
        // The tooltip carries the lesson's controls, so the renderer has to be
        // able to talk back. It writes one JSON object per line here.
        let events = Pipe()
        task.standardOutput = events
        guard (try? task.run()) != nil else { return }
        process = task
        input = pipe.fileHandleForWriting
        listen(to: events.fileHandleForReading)
    }

    private func listen(to handle: FileHandle) {
        handle.readabilityHandler = { pipe in
            let data = pipe.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                guard let payload = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let event = payload["event"] as? String else { continue }
                let detail = payload["text"] as? String ?? ""
                // Not a lesson event: the renderer is reporting the key
                // combinations another application already owns. It has sent
                // this since shortcuts existed and it was read straight past to
                // the relay, which has no idea what to do with it, so Settings
                // could only ever list the keys Calla *asked* for.
                guard event != "shortcuts_unavailable" else {
                    Task { @MainActor in ShortcutStatus.shared.note(unavailable: detail) }
                    continue
                }
                Task { @MainActor in LessonRelay.shared.handle(event: event, text: detail) }
            }
        }
    }

    private func send(_ command: [String: Any]) {
        ensureRunning()
        guard let input,
              var data = try? JSONSerialization.data(withJSONObject: command) else { return }
        data.append(10)
        // `FileHandle.write` raises an Objective-C exception when the renderer
        // has gone, and Swift cannot catch that — so the host would die of a
        // dead overlay, which is exactly backwards. Write the descriptor
        // directly, and treat a broken pipe as "the renderer needs restarting".
        guard !Self.writeAll(data, to: input.fileDescriptor) else { return }
        // One retry with a fresh renderer, so a step is not silently dropped.
        process?.terminate()
        process = nil
        self.input = nil
        ensureRunning()
        guard let restarted = self.input else { return }
        _ = Self.writeAll(data, to: restarted.fileDescriptor)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    /// `frame` and `window` are in screen coordinates with a top-left origin;
    /// the helper owns the conversion to Cocoa's bottom-left origin.
    ///
    /// The window rect and owner travel with every point so the overlay stays
    /// the taught application's overlay: the tooltip is kept inside that
    /// window's bounds, and the whole overlay hides whenever the learner is
    /// looking at something else.
    func point(at frame: CGRect, window: CGRect, owner: String, step: String, text: String,
               status: String, targetOutline: CGRect?) {
        // Every route that puts a step on screen comes through here — a guide from
        // the model and a local advance both — so this is the one place that can
        // mirror it for the menu bar without a second channel to keep in step.
        TutorHostController.shared.noteStep(step, text: text)
        let aim = Self.aim(frame)
        var command: [String: Any] = ["cmd": "point", "x": aim.x, "y": aim.y,
              "window": ["x": window.minX, "y": window.minY,
                         "width": window.width, "height": window.height],
              "owner": owner,
              "hide_on_hover": TutorSettings.shared.hideTooltipOnHover,
              "follow_focus": true,
              "tooltip_width": TutorSettings.shared.tooltipWidth,
              "cursor_size": TutorSettings.shared.cursorSize,
              "tooltip_opacity": TutorSettings.shared.tooltipOpacity,
              "show_hud": TutorSettings.shared.showStatusHUD,
              "step": step, "text": text, "status": status]
        if let targetOutline {
            command["target_rect"] = ["x": targetOutline.minX, "y": targetOutline.minY,
                                      "width": targetOutline.width, "height": targetOutline.height]
        }
        send(command)
    }

    /// Where in the target the arrow's apex should sit.
    ///
    /// Calla's arrow has its point at the top left and its body running down and
    /// to the right, so an apex placed dead centre lays the whole arrow over the
    /// thing it is indicating. On a twenty-six point icon that hides it
    /// completely — the lesson points at the wrench by covering the wrench.
    ///
    /// Putting the apex just inside the lower-right edge touches the target and
    /// throws the body clear of it, which is what an annotation arrow has always
    /// done. Large regions keep the centre: there is nothing to hide, and a
    /// corner would read as pointing at the corner.
    static func aim(_ frame: CGRect) -> CGPoint {
        let shortest = min(frame.width, frame.height)
        guard shortest <= 56 else { return CGPoint(x: frame.midX, y: frame.midY) }
        // Far enough in to be unambiguously on the target, never so far that a
        // very small control loses its own centre.
        let inset = min(max(shortest * 0.25, 3), 10)
        return CGPoint(x: frame.maxX - inset, y: frame.maxY - inset)
    }

    /// Outline a control, briefly.
    ///
    /// One rung above pointing on the lesson's escalation ladder, for a learner
    /// who has now missed the same step twice. It draws where the pointer was
    /// already placed from, and it takes itself away.
    func highlight(_ frame: CGRect) {
        send(["cmd": "highlight",
              "rect": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]])
    }

    /// Apply a preference to a renderer that is already on screen.
    ///
    /// `send` starts the helper if it is not running, which is right for a step
    /// and wrong for a preference: changing a colour must never be the thing
    /// that launches the overlay. Every value here also travels with the next
    /// `point`, so a renderer that is not up yet loses nothing by being skipped.
    private func sendPreference(_ command: [String: Any]) {
        guard process?.isRunning == true else { return }
        send(command)
    }

    /// Tell the tooltip the lesson is held, so it says so and offers the way
    /// back. Sent as a preference rather than folded into narrate: an aside is
    /// a state the tooltip is in, not a thing Calla just said.
    func setAside(_ value: Bool) {
        sendPreference(["cmd": "aside", "aside": value])
    }

    func setTooltipOpacity(_ opacity: Double) {
        sendPreference(["cmd": "preferences", "tooltip_opacity": opacity])
    }

    /// Same, for the pointer's size.
    ///
    /// Without this the size only reached the overlay inside the next `point`,
    /// so changing it while no lesson was running did nothing at all and
    /// changing it mid-lesson did nothing until the next step.
    func setTooltipWidth(_ width: Int) {
        sendPreference(["cmd": "preferences", "tooltip_width": width])
    }

    func setCursorSize(_ size: Int) {
        sendPreference(["cmd": "preferences", "cursor_size": size])
    }

    /// Re-word the tooltip in place. The cursor stays where the last step put
    /// it, so a lesson can narrate several beats about one control.
    ///
    /// `holding` says this is Calla reporting on itself — checking, thinking,
    /// asking — rather than the next thing for the learner to do. The renderer
    /// keeps the step and its words in that case, and only lights the working
    /// line, so waiting never wipes out the instruction being followed.
    func narrate(step: String, text: String, status: String, thinking: Bool, holding: Bool = false) {
        // A held narration is Calla talking about itself and deliberately leaves
        // the step alone, so it must not overwrite the mirror either.
        if !holding { TutorHostController.shared.noteStep(step, text: text) }
        send(["cmd": "narrate", "step": step, "text": text, "status": status,
              "thinking": thinking, "holding": holding])
    }

    // The route is not sent to the overlay. It used to be, so the tooltip could
    // say "Step 2 of 5" — a second copy of state the engine already holds, with
    // its own merge rules for a re-plan. The engine keeps the plan, because that
    // is what advances a step locally; the tooltip just says what this step is.

    /// Say one short thing on screen with no lesson behind it, for a request that
    /// could not be honoured yet.
    func notice(_ text: String) {
        send(["cmd": "notice", "text": text])
    }

    /// Pulse the pointer and tooltip where they already are, for a learner who
    /// has lost track of them on a large display.
    func locate() {
        send(["cmd": "locate"])
    }

    /// Show the question field over one current, allowed window.
    func openAsk(owner: String, window: CGRect) {
        send(["cmd": "ask", "owner": owner,
              "window": ["x": window.minX, "y": window.minY,
                         "width": window.width, "height": window.height]])
    }

    func hide() {
        send(["cmd": "hide"])
    }

    /// Take the renderer down with the host.
    ///
    /// Closing the pipe is normally enough — the helper terminates on stdin EOF
    /// — but that only holds when the host exits cleanly enough for its file
    /// descriptors to close. Asking first, and killing the process after, means
    /// a quit can never leave a pointer on screen with nothing behind it.
    /// Written straight to the descriptor rather than through `send`, whose
    /// broken-pipe retry starts a fresh renderer — the one thing a shutdown
    /// must not do.
    func shutdown() {
        guard let process, process.isRunning else { return }
        if let input, var data = try? JSONSerialization.data(withJSONObject: ["cmd": "quit"]) {
            data.append(10)
            _ = Self.writeAll(data, to: input.fileDescriptor)
        }
        input = nil
        process.terminate()
        self.process = nil
    }
}

// File-scope rather than a static method on UnixSocketServer: see acceptConnection.
private func serveConnection(client: Int32, handler: @Sendable (TutorRequest) async -> TutorResponse) async {
    defer { close(client) }
    do {
        let request = try UnixSocketServer.readRequest(client)
        let response = await handler(request)
        try UnixSocketServer.write(response, to: client)
    } catch {
        let response = TutorResponse(requestID: UUID().uuidString, ok: false, payload: nil,
                                     error: TutorError(code: "protocol_error", message: error.localizedDescription))
        try? UnixSocketServer.write(response, to: client)
    }
}

private final class UnixSocketServer {
    private let path: String
    private let handler: @Sendable (TutorRequest) async -> TutorResponse
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String, handler: @escaping @Sendable (TutorRequest) async -> TutorResponse) throws {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    func start() throws {
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TutorHostFailure(code: "socket_create_failed", message: String(cString: strerror(errno))) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let byteCount = path.utf8.count + 1
        guard byteCount <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            throw TutorHostFailure(code: "socket_path_too_long", message: "The TutorHost socket path is too long")
        }
        _ = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in strncpy(destination, source, byteCount) }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sa_family_t>.size + byteCount))
            }
        }
        guard bindResult == 0 else {
            let message = String(cString: strerror(errno)); close(descriptor)
            throw TutorHostFailure(code: "socket_bind_failed", message: message)
        }
        guard chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
            let message = String(cString: strerror(errno)); close(descriptor)
            throw TutorHostFailure(code: "socket_listen_failed", message: message)
        }
        fileDescriptor = descriptor
        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global(qos: .userInitiated))
        readSource.setEventHandler { [weak self] in self?.acceptConnection() }
        readSource.setCancelHandler { [descriptor] in close(descriptor) }
        readSource.resume()
        source = readSource
    }

    func stop() {
        source?.cancel(); source = nil; fileDescriptor = -1; _ = unlink(path)
    }

    private func acceptConnection() {
        let client = accept(fileDescriptor, nil, nil)
        guard client >= 0 else { return }
        // Per-socket as well as process-wide (see CallaTutorHostApp.init): a
        // caller that gave up waiting must come back as an error from write,
        // never as a signal that ends the teaching session.
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // serveConnection is a file-scope function, not a static member: calling a
        // static member of this non-Sendable class from inside a Task makes the
        // region-based isolation checker fail with "pattern that the region-based
        // isolation checker does not understand how to check. Please file a bug."
        let serve = handler
        Task.detached { await serveConnection(client: client, handler: serve) }
    }

    fileprivate static func readRequest(_ descriptor: Int32) throws -> TutorRequest {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= maxRequestFrameBytes {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 { throw TutorHostFailure(code: "socket_read_failed", message: String(cString: strerror(errno))) }
            if count == 0 { break }
            data.append(buffer, count: count)
            if data.last == 10 { break }
        }
        guard data.count > 0, data.count <= maxRequestFrameBytes, data.last == 10 else {
            throw TutorHostFailure(code: "frame_limit", message: "TutorHost requires one newline-delimited request under 64 KiB")
        }
        return try JSONDecoder().decode(TutorRequest.self, from: data)
    }

    fileprivate static func write(_ response: TutorResponse, to descriptor: Int32) throws {
        var data = try JSONEncoder().encode(response); data.append(10)
        guard data.count <= maxResponseFrameBytes else { throw TutorHostFailure(code: "frame_limit", message: "TutorHost response exceeds 1.5 MiB") }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 { throw TutorHostFailure(code: "socket_write_failed", message: String(cString: strerror(errno))) }
                offset += count
            }
        }
    }
}
