import AppKit
import Foundation

/// Carries what the learner pressed in the tooltip back to Calla.
///
/// The host holds no model and no credentials — deliberately, since the
/// Gateway is where the thinking belongs — so it does not answer these itself.
/// It hands them to `scripts/calla-ask.sh`, the one place that knows where a
/// question goes, which is the same path the Raycast commands take.
@MainActor
final class LessonRelay: ObservableObject {
    static let shared = LessonRelay()

    private var inFlight: Process?
    private var checking = false
    /// The session this lesson's turns share, and nothing else does.
    ///
    /// A fixed id here is what let one transcript run from the first lesson ever
    /// given to the last: every step re-sent every step before it, and the
    /// context climbed to 240k tokens against a 258k window — most of the wait
    /// the learner sits through. Minted where a lesson begins, retired where it
    /// ends, so step eight costs what step two costs.
    private var lessonID: String?
    /// The one-time Tailscale approval link, when reaching Calla needs one.
    /// Detected here because the sender is the only thing that sees it, and it
    /// is useless in a log nobody is tailing.
    @Published private(set) var authorisationURL: URL?

    func handle(event: String, text: String) {
        switch event {
        case "next":
            // Every step is checked. The Mac used to answer this itself whenever
            // three local facts agreed — fast, but nothing ever looked at whether
            // the step had actually worked, which is the one thing a tutor is
            // for. What the Mac can still see cheaply goes along with the
            // question, so the model has a prior before it looks.
            Task { @MainActor in
                let host = TutorHostController.shared
                guard host.lessonActive else { return }
                // "Did it" after an aside is not "Back to lesson". Clear the
                // hold without redrawing, then run normal proof for the held
                // step. Fast courses use their detector; model-led courses take
                // a fresh visual check before Calla guides the next step.
                host.finishAsideForVerification()
                // Warm published courses never wait on Gateway or a model. The
                // host re-resolves and verifies canonical App-Pack data locally.
                if await host.advanceFastLesson() { return }
                let signal = await host.checkStep()
                checking = true
                send("Step \(host.stepIndex) done. Check it. (\(signal))")
            }
        case "resume":
            // Free: the Mac still holds this step's region and words, so coming
            // back from an aside costs no turn at all.
            TutorHostController.shared.resumeLesson()
        case "ask":
            guard TutorHostController.shared.lessonActive, !text.isEmpty else {
                PointerOverlay.shared.notice("Choose a published course in Courses to begin.")
                return
            }
            // A question asked with no lesson running starts one. The tooltip's
            // Ask button is a perfectly ordinary way to begin, and a question
            // that continued the last lesson's transcript would carry a
            // conversation the learner has finished with.
            //
            // Starting goes through the controller, which owns the transition.
            // Doing it here as well is how the session id and `lessonActive` used
            // to end up disagreeing about whether a lesson existed.
            // A question during a lesson is an aside, not a new lesson. The
            // route is held exactly where it is and marked so the model answers
            // rather than teaches; the learner comes back with one press.
            TutorHostController.shared.beginAside()
            send("[aside] \(text)")
        case "ask_open":
            PointerOverlay.shared.notice("Choose a published course in Courses to begin.")
        case "stop":
            // No message to the model, and no waiting for one back. Stopping is
            // something the learner does, not something they request.
            TutorHostController.shared.stopLesson()
        default:
            break
        }
    }

    /// Compatibility entry for older callers. Course authoring now uses the
    /// durable Gateway control socket, never a fire-and-forget calla-prep turn.
    func importCourse(outline: String) {
        guard let bundleID = TutorSettings.shared.allowedBundleIDs.first,
              let app = TutorSettings.shared.runningAllowedApplication(bundleID: bundleID) else {
            return
        }
        CourseControlRelay.shared.send("import", payload: ["outline": outline,
                                                            "target_app": app.bundleID,
                                                            "target_version": app.version],
                                      accepted: "Course queued. Calla will show review details here.")
    }

    /// Start a lesson the learner picked rather than typed.
    ///
    /// The controller has already made the lesson exist and minted its session;
    /// this only carries the request. Kept here rather than exposing `send`,
    /// because everything that reaches Calla should go through one door.
    func startLesson(_ message: String) {
        send(message)
    }

    /// The one way in, for the menu bar and the shortcut alike.
    ///
    /// An invitation to ask, not an instruction to start teaching blindly: the
    /// lesson and its session begin only once the learner submits a question. If
    /// Ask cannot open, the reason is put on screen rather than into a status
    /// string nobody displays.
    func openAsk() {
        PointerOverlay.shared.notice("Choose a published course in Courses to begin.")
    }

    /// Mint the session this lesson's turns will share.
    ///
    /// Driven by `TutorHostController`, which owns whether a lesson exists. This
    /// only holds the id, because it is the thing that has to put it in the
    /// sender's environment.
    func adoptNewSession() {
        lessonID = TutorSettings.mintIdentifier(prefix: "lesson")
    }

    /// Let the lesson's session go. The next question mints a new one, so
    /// nothing after this point continues a conversation the learner ended.
    func endLesson() {
        lessonID = nil
    }

    /// Drop whatever was in flight. A question already travelling would
    /// otherwise come back and put a step on a screen the learner has finished
    /// with.
    func clearAuthorisation() { authorisationURL = nil }

    func abort() {
        inFlight?.terminate()
        inFlight = nil
        checking = false
    }

    private func send(_ message: String) {
        guard let sender = Self.senderURL() else {
            PointerOverlay.shared.narrate(
                step: "Calla",
                text: "I could not find calla-ask.sh, so that did not reach Calla.",
                status: "Calla — not sent",
                thinking: false)
            return
        }
        // One at a time: a second question while the first is still travelling
        // would interleave two turns in the same lesson.
        if inFlight?.isRunning == true { return }

        // Say which of the two it is. "Checking" and "asking" feel different to
        // someone who has just finished a step and is waiting to hear. Held, so
        // the step they just finished stays on screen while they wait for the
        // verdict on it.
        PointerOverlay.shared.narrate(step: "Calla",
                                      text: checking ? "Checking your work…" : "Asking Calla…",
                                      status: checking ? "Calla — checking" : "Calla — thinking",
                                      thinking: true, holding: true)
        checking = false
        let task = Process()
        task.executableURL = sender
        task.arguments = [message]
        // The sender says "Thinking…" for the surfaces that have nothing else to
        // say it — Raycast, a shell. Here the tooltip has already said something
        // truer, and letting the generic line land a moment later replaced it.
        var environment = ProcessInfo.processInfo.environment
        environment["CALLA_QUIET"] = "1"
        // A lesson that somehow reached here without one still gets its own
        // session rather than falling back to a shared transcript.
        if lessonID == nil { adoptNewSession() }
        environment["CALLA_SESSION"] = lessonID
        environment["CALLA_LEARNER"] = TutorSettings.shared.learnerID
        task.environment = environment
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            guard let range = text.range(of: "https://login.tailscale.com/[^ \n]+", options: .regularExpression),
                  let url = URL(string: String(text[range])) else { return }
            Task { @MainActor in
                LessonRelay.shared.authorisationURL = url
                PointerOverlay.shared.narrate(
                    step: "Calla",
                    text: "Calla needs one Tailscale approval. Open it from the menu bar.",
                    status: "Calla — needs authorisation", thinking: false)
            }
        }
        do {
            try task.run()
            inFlight = task
            // The sender backgrounds the remote command and reports only that it
            // started, so a turn that fails or answers with nothing is invisible
            // from here. Watch for an answer instead of assuming one.
            BackendStatus.shared.expectReply()
        } catch {
            PointerOverlay.shared.narrate(step: "Calla", text: "That did not reach Calla.",
                                          status: "Calla — not sent", thinking: false)
        }
    }

    /// Beside the installed bundle, or in the checkout that built it.
    private static func senderURL() -> URL? {
        var candidates = [URL]()
        if let resource = Bundle.main.url(forResource: "calla-ask", withExtension: "sh") {
            candidates.append(resource)
        }
        // A development build runs straight out of the package directory.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(directory.appendingPathComponent("scripts/calla-ask.sh"))
            directory = directory.deletingLastPathComponent()
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
