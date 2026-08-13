import AppKit
import SwiftUI

/// The menu bar panel.
///
/// It answers one question first — can Calla teach right now, and what — and
/// only then offers the controls. The earlier version showed six equal sections
/// with a paragraph under each, so the state that mattered was buried in
/// explanation. Everything that is working stays quiet; only what is broken
/// speaks up, and it comes with the button that fixes it.
struct CallaMenu: View {
    @ObservedObject var host: TutorHostController
    @ObservedObject var settings: TutorSettings
    @ObservedObject var backend: BackendStatus
    @ObservedObject var subject: LessonSubject
    @ObservedObject var relay = LessonRelay.shared
    @ObservedObject var catalogue = CourseCatalogue.shared

    /// Why the last attempt to start could not open Ask. Shown until it works.
    @State private var startFailure: String?

    /// Everything that has to be true before a lesson can start, in the order
    /// the owner should fix them.
    private enum Readiness {
        case paused
        case needsScreenRecording
        case disconnected(String)
        case noApplications
        case ready(String)
    }

    private var readiness: Readiness {
        if !host.captureActive { return .paused }
        if !settings.screenRecordingGranted { return .needsScreenRecording }
        if case .connected = backend.link {} else {
            return .disconnected(CallaMenu.linkSummary(backend.link, stuck: backend.isStuck))
        }
        if settings.allowedBundleIDs.isEmpty { return .noApplications }
        return .ready(subject.lastSubjectName ?? settings.displayName(for: settings.allowedBundleIDs[0]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // Sized by its content rather than scrolled: a MenuBarExtra window
            // gives its content no height to resolve against, so a flexible
            // ScrollView collapses to nothing and the panel becomes a header
            // and a footer with a gap between them.
            VStack(alignment: .leading, spacing: 14) {
                if let url = relay.authorisationURL {
                    card(icon: "link.badge.plus",
                         title: "Calla needs one Tailscale approval",
                         detail: "Reaching the Gateway asks for a browser check when the session expires.",
                         action: ("Open", {
                             NSWorkspace.shared.open(url)
                             relay.clearAuthorisation()
                         }))
                }
                if let approval = host.pendingApproval { approvalCard(approval) }
                wentWrongCard
                lesson
                courses
                problemCard
            }
            .padding(14)
            Divider()
            footer
        }
        .frame(width: 340)
        .task {
            await host.start()
            await settings.refreshPermissionStatus()
            backend.startWatching()
        }
        // The panel is the reason the link is polled at all. Closed, and with no
        // lesson running, the poll has nobody to answer to and stops.
        .onAppear { backend.observers += 1; backend.refresh() }
        .onDisappear { backend.observers = max(0, backend.observers - 1) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: CallaMark.image(edge: 22))
                .renderingMode(.template)
                .foregroundStyle(statusTint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Calla").font(.system(size: 13, weight: .semibold))
                Text(statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // Identity and state only.
            //
            // This carried the one action for a while — "Teach me…", then
            // "Resume" — and both had the same flaw: a button up here has to
            // guess which course it means, which is fine with one course and a
            // lie with three. Start, Resume and Stop belong on the course they
            // act on, so that is where they went.
            Circle().fill(statusTint).frame(width: 7, height: 7)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// Pick up a course where it was left, and say why if it cannot.
    private func resume(_ course: CourseCatalogue.Course) {
        Task { startFailure = await CourseResume.resume(course, allowed: settings.allowedBundleIDs) }
    }

    private var statusLine: String {
        // A green "Ready" directly above an orange "Calla could not see the
        // window" is the panel disagreeing with itself, and the learner believes
        // the header.
        if backend.problem != nil, case .ready = readiness { return "Needs a hand — see below" }
        switch readiness {
        case .paused: return "Paused"
        case .needsScreenRecording: return "Needs permission to see the screen"
        case .disconnected(let why): return why
        case .noApplications: return "No application allowed yet"
        case .ready(let app): return "Ready · teaching \(app)"
        }
    }

    private var statusTint: Color {
        if backend.problem != nil, case .ready = readiness { return CallaTint.attention }
        switch readiness {
        case .ready: return CallaTint.healthy
        case .paused: return CallaTint.paused
        // Red is reserved for stuck. Orange means Calla is working on it or
        // needs a permission; red means it has stopped getting anywhere.
        case .disconnected: return backend.isStuck ? CallaTint.stuck : CallaTint.attention
        default: return CallaTint.attention
        }
    }

    private static func linkSummary(_ link: BackendStatus.Link, stuck: Bool) -> String {
        switch link {
        case .connected: return "Connected"
        case .agentNotRunning: return "Calla's node agent is not running"
        case .disconnected: return stuck ? "Can't reach Calla" : "Reconnecting to Calla…"
        case .unknown: return stuck ? "Can't reach Calla" : "Connecting to Calla…"
        }
    }

    // MARK: - Courses

    /// What Calla could teach, when nobody is mid-lesson.
    ///
    /// Until now the only way in was to think of a question. A learner who does
    /// not yet know what an application can do has no question to ask, which is
    /// exactly the person a tutor is for. The list is pushed from the Gateway,
    /// which is where the packs live; the Mac only ever holds names and counts.
    @ViewBuilder private var courses: some View {
        let available = catalogue.courses(forAllowed: settings.allowedBundleIDs)
        if host.lessonActive {
            // Only the course being taught. The whole list vanished the moment a
            // lesson began, which took course-level progress with it exactly
            // when a learner has most reason to wonder how much is left.
            if let active = available.first(where: { course in
                course.lessons.contains { $0.title == host.lessonTitle }
            }) {
                VStack(alignment: .leading, spacing: 6) {
                    CallaEyebrow("Course")
                    courseCard(active)
                }
            }
        } else if !available.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                CallaEyebrow("Courses")
                ForEach(available) { course in
                    courseCard(course)
                }
            }
        }
    }

    /// One course, with the one thing you would do to it.
    ///
    /// The action lives here rather than in the header. A header button has to
    /// guess which course it means — fine with one, a lie with three — and it
    /// separated "Resume" from the thing being resumed. Start, Resume and Stop
    /// are the same control in three states, so they sit in the same place.
    private func courseCard(_ course: CourseCatalogue.Course) -> some View {
        let bundleID = catalogue.bundleID(for: course, allowed: settings.allowedBundleIDs)
        let progress = bundleID.map {
            LearningStore.shared.progress(lessonIDs: course.lessons.map(\.id), bundleID: $0)
        }
        let isActive = host.lessonActive && course.lessons.contains { $0.title == host.lessonTitle }
        let started = (progress?.done ?? 0) > 0 || CourseRunStore.shared.checkpoint(for: course.id) != nil

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 9) {
                CourseIcon(symbol: course.icon, bundleID: bundleID, size: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(course.title).font(.system(size: 12.5, weight: .semibold))
                        // A mark, not a word: something here is due for review.
                        if progress?.dueForReview == true {
                            Circle().fill(CallaTint.teaching).frame(width: 5, height: 5)
                        }
                    }
                    if !course.summary.isEmpty, !isActive {
                        Text(course.summary)
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if isActive {
                    Button("Stop") { host.stopLesson() }
                        .controlSize(.small)
                        .help("End the lesson now")
                } else {
                    Button(started ? "Resume" : "Start") { resume(course) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .help(started ? "Continue where you left off" : "Begin the first lesson")
                }
            }
            if let progress, progress.total > 0 {
                CourseProgressBar(done: progress.done, total: progress.total, active: isActive)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.primary.opacity(isActive ? 0.075 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(isActive ? 0.45 : 0), lineWidth: 1))
    }

    // MARK: - What just went wrong

    /// The most recent failure, in the menu bar rather than only in a log file.
    ///
    /// Without this, a refused step and a silent Gateway turn both look exactly
    /// like Calla thinking, and the only way to tell was to go and read
    /// `step-timing.log`. The code is shown too, small — it is the thing worth
    /// searching for once the sentence is not enough.
    /// What went wrong, and the one thing that fixes it.
    ///
    /// This used to put the raw host code — `observe refused: no_focused_win…` —
    /// under the sentence in monospace, where it was too narrow to read, cut off
    /// mid-word, and meaningless to the person being taught. It also stacked
    /// "Logs" and "Dismiss" beside the text, which squeezed the sentence into a
    /// column and made the card taller than the lesson it was interrupting. The
    /// code belongs in the log; what belongs here is the fix.
    @ViewBuilder private var wentWrongCard: some View {
        if let problem = backend.problem {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.system(size: 13))
                    Text(problem.summary)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    // The action that actually resolves it, when there is one.
                    if let subject = frontableSubject {
                        Button("Open \(subject.localizedName ?? "the app")") {
                            subject.activate()
                            backend.clearProblem()
                        }
                        .controlSize(.small)
                    }
                    Button("Dismiss") { backend.clearProblem() }.controlSize(.small)
                    Spacer(minLength: 0)
                    Button("Logs") { openSettings() }
                        .controlSize(.small).buttonStyle(.plain)
                        .foregroundStyle(.secondary).font(.system(size: 11))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12)))
        }
    }

    /// The application a lesson would teach, when bringing it forward is the fix.
    private var frontableSubject: NSRunningApplication? {
        guard let problem = backend.problem, problem.detail.contains("no_focused_window") else { return nil }
        return LessonSubject.shared.mostRecent(in: Set(settings.allowedBundleIDs))
    }

    // MARK: - The lesson, while there is one

    /// What Calla is saying right now, in the menu bar as well as on the window.
    ///
    /// The tooltip is the primary place for this and stays so. This exists for
    /// when the tooltip is behind something, on a display the learner is not
    /// looking at, or hidden because their own pointer is over it — the three
    /// cases where "what was I meant to be doing" had no answer short of moving
    /// windows around.
    @ViewBuilder private var lesson: some View {
        if host.lessonActive {
            VStack(alignment: .leading, spacing: 6) {
                CallaEyebrow(host.inAside ? "Aside" : "Now")
                // How far in the learner is. The panel could say what the
                // current step was and never where it sat in the lesson, which
                // is the thing someone mid-course actually wants to know.
                if !host.lessonTitle.isEmpty || host.stepCount > 0 {
                    HStack(spacing: 6) {
                        if !host.lessonTitle.isEmpty {
                            Text(host.lessonTitle)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if host.stepCount > 0 {
                            Text("Step \(host.stepIndex) of \(host.stepCount)")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    if host.stepCount > 0 {
                        ProgressView(value: Double(host.stepIndex), total: Double(host.stepCount))
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    }
                }
                if host.inAside {
                    Text("You stepped out of the lesson to ask something. It is held where it was.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if host.currentStep.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(backend.problem == nil ? "Reading the window and working out the route…"
                                                    : "Waiting — see the note above.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } else {
                    Text(host.currentStep).font(.system(size: 12, weight: .medium))
                    if !host.currentStepText.isEmpty {
                        Text(host.currentStepText)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Nothing to have done yet, so nothing to press. "Did it"
                // offered against an empty step sends Calla off to check work on
                // a step it never drew — a whole model turn to be told the
                // lesson has not started.
                if host.inAside || !host.currentStep.isEmpty {
                    HStack(spacing: 8) {
                        if host.inAside {
                            Button("Back to lesson") { relay.handle(event: "resume", text: "") }
                                .controlSize(.small)
                                .help("Return to the step you were on · ⌥⌘L")
                        } else {
                            Button("Did it") { relay.handle(event: "next", text: "") }
                                .controlSize(.small)
                                .help("Tell Calla you finished this step · ⌥⌘↩")
                        }
                        // Moved out of the header: it is about the lesson, so it
                        // belongs with the lesson rather than beside the status.
                        Button("Find it") { PointerOverlay.shared.locate() }
                            .controlSize(.small)
                            .help("Flash Calla's pointer and tooltip where they are")
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)
                }
            }
        } else if let notice = startFailure {
            card(icon: "questionmark.circle",
                 title: "Calla cannot start a lesson yet",
                 detail: notice,
                 action: ("Settings…", { openSettings() }))
        }
    }

    // MARK: - The one thing that is wrong

    @ViewBuilder private var problemCard: some View {
        if case .needsScreenRecording = readiness {
            card(icon: "eye.trianglebadge.exclamationmark",
                 title: "Let Calla see the screen",
                 detail: "It reads one window at a time, only the app you allow.",
                 action: ("Open Settings", { settings.requestScreenRecordingApproval() }))
        }
        if settings.accessibilityApprovalNeeded && !settings.accessibilityGranted {
            card(icon: "hand.raised.fill",
                 title: "Allow Accessibility for approved clicks",
                 detail: "Calla asks only when an action needs it. It cannot click without your separate approval.",
                 action: ("Open Settings", { settings.requestAccessibilityApproval() }))
        }
        // There used to be an offer here selling Accessibility on speed: that
        // the Mac would find the next control itself and land a step in a tenth
        // of a second. It does not any more — every step is checked by the model
        // now, deliberately — so the claim was retired rather than reworded.
        switch readiness {
        case .disconnected(let why):
            card(icon: "antenna.radiowaves.left.and.right.slash",
                 title: why,
                 detail: backend.isStuck
                     ? "It has been retrying for a while, so something is in the way — the tailnet, the Gateway being down, or an approval it is waiting on."
                     : "Calla retries on its own.",
                 action: ("Logs", { settings.openLogs() }))
        case .noApplications:
            card(icon: "square.dashed",
                 title: "Allow an application",
                 detail: "Calla can only look at applications you list below.",
                 action: nil)
        case .needsScreenRecording, .paused, .ready:
            EmptyView()
        }
    }

    private func card(icon: String, title: String, detail: String,
                      action: (String, () -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.orange).font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let action {
                Button(action.0, action: action.1).controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.orange.opacity(0.10)))
    }

    private func approvalCard(_ approval: PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allow one action?").font(.system(size: 12, weight: .semibold))
            Text(approval.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Deny") { host.resolveApproval(false) }.controlSize(.small)
                Button("Allow once") { host.resolveApproval(true) }
                    .controlSize(.small).keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.accentColor.opacity(0.12)))
    }

    // The allowlist and every preference live in the Settings window now. They
    // were here, which made this panel answer two unrelated questions at once —
    // "can Calla teach right now" and "how should it behave" — and left it with
    // room to answer neither well. What stays here is what gets acted on.

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            // This controls capture, not the lesson. It used to read "Teaching
            // on" / "Paused", which is the one wording guaranteed to be mistaken
            // for starting and stopping a lesson — and turning it off while a
            // lesson ran looked like a way to end that lesson. Stop does that.
            Toggle(isOn: $host.captureActive) {
                Text("Watch the screen").font(.system(size: 11)).lineLimit(1)
            }
            .fixedSize()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("When off, no capture is taken and nothing reaches the Gateway")
            Spacer(minLength: 4)
            Button("Settings…") { openSettings() }
                .controlSize(.small)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Open settings.
    ///
    /// Sending `showSettingsWindow:` was the first attempt and did nothing:
    /// Calla is an accessory application, so there is no Application menu for
    /// that action to route through and SwiftUI never builds the `Settings`
    /// scene. `SettingsPresenter` owns the window instead.
    private func openSettings() {
        SettingsPresenter.shared.show(host: host, settings: settings)
    }
}
