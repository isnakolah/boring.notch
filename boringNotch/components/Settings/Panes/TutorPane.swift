import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

/// Tutor, as five sidebar destinations rather than one pane with its own tab bar.
///
/// The old pane carried a segmented `Picker` over Library / Create / Teaching /
/// Access / System, so the window had two navigation models stacked on each
/// other. It also mixed `Form`-based and hand-built sub-panes, which is why it
/// agreed visually with none of the other thirteen.
struct TutorPane: View {
    let tab: SettingsTab

    @ObservedObject private var engine = CallaEngineClient.shared

    var body: some View {
        Group {
            switch tab {
            case .tutorCreate: TutorCreatePane()
            case .tutorBehavior: TutorBehaviorPane()
            case .tutorAccess: TutorAccessPane()
            case .tutorEngine: TutorEnginePane()
            default: TutorCoursesPane()
            }
        }
        .task { engine.refresh() }
    }
}

// MARK: - Courses

struct TutorCoursesPane: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @Default(.callaHiddenCourseIDs) private var hiddenCourseIDs
    @State private var selectedCourseID = ""

    private var courses: [CallaCourseSnapshot] { engine.status.courses }
    private var selectedCourse: CallaCourseSnapshot? {
        courses.first { $0.id == selectedCourseID } ?? courses.first
    }

    var body: some View {
        SettingsPane(eyebrow: "Tutor", title: "Courses",
                     detail: "Calla teaches by pointing at the app you are learning.") {
            if courses.isEmpty {
                SettingCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No courses yet").font(NotchType.cardTitle)
                        Text("Build one in Create, or start the engine if it is stopped.")
                            .font(NotchType.rowDetail).foregroundStyle(.secondary)
                    }
                }
            } else {
                courseList
                if let course = selectedCourse { courseDetail(course) }
            }
        }
        .onChange(of: courses.map(\.id)) { _, ids in
            if !ids.contains(selectedCourseID) { selectedCourseID = ids.first ?? "" }
        }
        .onChange(of: hiddenCourseIDs) { _, _ in engine.applyCurrentPreferences() }
    }

    private var courseList: some View {
        SettingCard("Library", detail: "Hidden courses stay installed; they just leave the notch.") {
            VStack(spacing: 8) {
                ForEach(courses) { course in
                    courseRow(course)
                }
            }
        }
    }

    private func courseRow(_ course: CallaCourseSnapshot) -> some View {
        let isHidden = hiddenCourseIDs.contains(course.id)
        return HStack(spacing: 10) {
            Image(systemName: course.icon.isEmpty ? "books.vertical.fill" : course.icon)
                .font(.system(size: 13))
                .foregroundStyle(isHidden ? Color.secondary : NotchTint.active)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(course.title).font(NotchType.rowTitle)
                    if course.dueForReview { SettingBadge("Review due", tint: NotchTint.attention) }
                }
                SettingProgressBar(done: course.completedCount, total: course.lessonCount,
                                   active: course.id == selectedCourseID)
                    .frame(maxWidth: 220)
            }
            Spacer(minLength: 8)
            // Course visibility lives here because docs/calla-migration.md says
            // Tutor Settings owns it. It had no control anywhere until now: the
            // preference was bound, observed, and pushed over XPC by a pane that
            // never drew it.
            Toggle("", isOn: Binding(
                get: { !isHidden },
                set: { visible in
                    if visible { hiddenCourseIDs.removeAll { $0 == course.id } }
                    else if !hiddenCourseIDs.contains(course.id) { hiddenCourseIDs.append(course.id) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(isHidden ? "Show in the notch" : "Hide from the notch")
        }
        .padding(8)
        .background(course.id == selectedCourseID ? NotchTint.active.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { selectedCourseID = course.id }
    }

    private func courseDetail(_ course: CallaCourseSnapshot) -> some View {
        VStack(spacing: 16) {
            SettingCard(course.title, detail: course.summary.isEmpty ? nil : course.summary,
                        tint: course.lifecyclePhase == "failed" ? NotchTint.stuck : nil) {
                VStack(alignment: .leading, spacing: 10) {
                    SettingFact(title: "Teaches", value: course.targetApp ?? "No target app")
                    if let checkpoint = course.checkpointLessonID {
                        SettingFact(title: "Checkpoint", value: checkpoint)
                    }
                    if course.runtimeBlocked {
                        Label("The running app is not the version this course targets.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(NotchType.rowDetail)
                            .foregroundStyle(NotchTint.attention)
                    }
                    HStack {
                        Button("Resume") { engine.resumeCourse() }.buttonStyle(.borderedProminent)
                        Button("Start again") { engine.startAgain(courseID: course.id) }
                        if course.lifecyclePhase == "published" {
                            Button("Archive") { engine.courseControl(.init(action: "archive", courseID: course.id)) }
                        }
                        if course.lifecyclePhase == "archived" {
                            Button("Restore") { engine.courseControl(.init(action: "restore", courseID: course.id)) }
                        }
                    }
                    .controlSize(.small)
                }
            }
            SettingCard("Lessons") {
                VStack(spacing: 6) {
                    ForEach(course.lessons) { lesson in
                        HStack(spacing: 10) {
                            Image(systemName: lesson.completed ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(lesson.dueForReview ? NotchTint.attention
                                                 : lesson.completed ? NotchTint.healthy : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(lesson.title).font(NotchType.rowTitle)
                                // Two separate Text values rather than one
                                // interpolated string: a hand-built
                                // "1 step"/"n steps" cannot be translated,
                                // and `inflect:` needs the count in the key.
                                HStack(spacing: 4) {
                                    Text("^[\(lesson.stepCount) step](inflect: true)")
                                    if lesson.dueForReview { Text("· review due") }
                                }
                                .font(NotchType.rowDetail).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button(lesson.completed ? "Again" : "Start") {
                                engine.startLesson(courseID: course.id, lessonID: lesson.id)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

}

// MARK: - Create

struct TutorCreatePane: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @Default(.callaAllowedBundleIDs) private var allowedBundleIDs
    @State private var outline = ""
    @State private var assetBundle: URL?
    @State private var targetApp = ""
    @State private var reviseCourseID = ""
    @State private var problem: String?

    private var courses: [CallaCourseSnapshot] { engine.status.courses }

    private var transitional: [CallaCourseSnapshot] {
        let phases = ["queued", "compiling", "validating", "waiting_for_blender",
                      "preflighting", "publishing", "failed", "cancelled", "archived"]
        return courses.filter { phases.contains($0.lifecyclePhase ?? "") }
    }

    var body: some View {
        SettingsPane(eyebrow: "Tutor", title: "Create",
                     detail: "Paste a reviewed outline. Boring checks the app, the size, and the scene ZIP before anything leaves this Mac.") {
            SettingCard("New course") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingRow("Target app", detail: "Only apps you have allowed, and it has to be running.") {
                        Picker("", selection: $targetApp) {
                            Text("Choose app").tag("")
                            ForEach(allowedBundleIDs, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Outline").font(NotchType.rowTitle)
                        TextEditor(text: $outline)
                            .font(NotchType.mono)
                            .frame(minHeight: 150)
                            .overlay(RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                                .stroke(NotchSurface.hairline))
                    }
                    SettingRow("Scene ZIP", detail: assetBundle?.lastPathComponent ?? "No file chosen") {
                        Button("Choose…") { chooseZip() }.controlSize(.small)
                    }
                    SettingRow("Revise", detail: "Build on an existing course instead of starting fresh.") {
                        Picker("", selection: $reviseCourseID) {
                            Text("New course").tag("")
                            ForEach(courses) { Text($0.title).tag($0.id) }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(NotchType.rowDetail)
                            .foregroundStyle(NotchTint.attention)
                    }
                    HStack {
                        Button(reviseCourseID.isEmpty ? "Build course" : "Build revision") { submitCourse() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!isComplete)
                        Spacer()
                        Button("Copy research prompt") { copyResearchPrompt() }.controlSize(.small)
                    }
                }
            }
            if !transitional.isEmpty {
                SettingCard("In progress") {
                    VStack(spacing: 8) {
                        ForEach(transitional) { course in lifecycleRow(course) }
                    }
                }
            }
        }
        .onAppear { if targetApp.isEmpty { targetApp = allowedBundleIDs.first ?? "" } }
    }

    private var isComplete: Bool {
        !outline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && assetBundle != nil && !targetApp.isEmpty
    }

    private func lifecycleRow(_ course: CallaCourseSnapshot) -> some View {
        let phase = course.lifecyclePhase ?? ""
        let busy = ["queued", "compiling", "validating", "waiting_for_blender",
                    "preflighting", "publishing"].contains(phase)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(course.title).font(NotchType.rowTitle)
                Text(course.lifecycleNote ?? phase.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(NotchType.rowDetail).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if busy { Button("Cancel") { engine.courseControl(.init(action: "cancel", courseID: course.id)) } }
            if ["failed", "cancelled", "waiting_for_blender"].contains(phase) {
                Button("Retry") { engine.courseControl(.init(action: "retry", courseID: course.id)) }
            }
            if phase == "archived" {
                Button("Restore") { engine.courseControl(.init(action: "restore", courseID: course.id)) }
            }
        }
        .controlSize(.small)
    }

    private func submitCourse() {
        guard let zip = assetBundle else { return }
        // This used to `return` silently when the target app was not running, so
        // the button appeared to do nothing at all. Say which of the two things
        // is missing instead.
        guard let app = NSWorkspace.shared.runningApplications.first(
            where: { $0.bundleIdentifier == targetApp && !$0.isTerminated }
        ) else {
            problem = "Open \(targetApp) first. A course is compiled against the running app's version."
            return
        }
        problem = nil
        let version = app.bundleURL
            .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
            ?? "unknown"
        engine.courseControl(.init(
            action: reviseCourseID.isEmpty ? "import" : "revise",
            courseID: reviseCourseID.isEmpty ? nil : reviseCourseID,
            outline: outline, assetBundlePath: zip.path,
            targetApp: targetApp, targetVersion: version
        ))
        outline = ""
        assetBundle = nil
    }

    private func chooseZip() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { assetBundle = panel.url }
    }

    private func copyResearchPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "Research this course as a concise, ordered outline with learner outcomes and scene checkpoints.",
            forType: .string)
    }
}

// MARK: - Behavior

struct TutorBehaviorPane: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @Default(.callaTutorEnabled) private var tutorEnabled
    @Default(.callaCaptureEnabled) private var captureEnabled
    @Default(.callaCaptureLongEdge) private var captureLongEdge
    @Default(.callaTooltipWidth) private var tooltipWidth
    @Default(.callaHideTooltipOnHover) private var hideTooltipOnHover
    @Default(.callaCursorSize) private var cursorSize
    @Default(.callaTooltipOpacity) private var tooltipOpacity
    @Default(.callaShowStatusHUD) private var showStatusHUD
    @Default(.callaCalendarEnabled) private var calendarEnabled

    var body: some View {
        SettingsPane(eyebrow: "Tutor", title: "Behavior",
                     detail: "What Calla may look at, and how it draws on top of it.") {
            SettingCard("Tutor") {
                // There was no way to turn Tutor off anywhere in the app, even
                // though this preference gates engine startup and the notch tab.
                SettingRow("Enable Tutor",
                           detail: "Off stops the engine and hides the Calla tab in the notch.") {
                    Toggle("", isOn: $tutorEnabled).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingCard("Watching") {
                VStack(spacing: 12) {
                    SettingRow("Watch screen",
                               detail: "Off pauses every capture. Calla refuses to teach until it is back on.") {
                        Toggle("", isOn: $captureEnabled).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Capture detail",
                               detail: "1600 px costs roughly 27,000 tokens and 13 seconds a look; 2048 about 44,000.") {
                        Picker("", selection: $captureLongEdge) {
                            Text("1024").tag(1024)
                            Text("1600").tag(1600)
                            Text("2048").tag(2048)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 200)
                    }
                }
            }
            SettingCard("On screen") {
                VStack(spacing: 12) {
                    SettingRow("Tooltip width",
                               detail: "How much of a line the lesson text gets.") {
                        Picker("", selection: $tooltipWidth) {
                            ForEach([300, 340, 380, 440, 520], id: \.self) { Text("\($0) pt").tag($0) }
                        }
                        .labelsHidden().frame(width: 120)
                    }
                    SettingRow("Pointer size", detail: nil) {
                        Picker("", selection: $cursorSize) {
                            ForEach([24, 30, 38], id: \.self) { Text("\($0) pt").tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 200)
                    }
                    SettingRow("Tooltip opacity", detail: nil) {
                        Picker("", selection: $tooltipOpacity) {
                            Text("85%").tag(0.85)
                            Text("92%").tag(0.92)
                            Text("100%").tag(1.0)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 200)
                    }
                    SettingRow("Hide tooltip on hover",
                               detail: "Moves the tooltip out of the way when your own pointer is over it.") {
                        Toggle("", isOn: $hideTooltipOnHover).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Show status HUD",
                               detail: "The small capsule naming what Calla is doing.") {
                        Toggle("", isOn: $showStatusHUD).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
            SettingCard("Calendar") {
                SettingRow("Calendar starts lessons",
                           detail: "An event bound to a course starts it, with a Pomodoro bounded by the event.") {
                    Toggle("", isOn: $calendarEnabled).labelsHidden().toggleStyle(.switch)
                }
            }
        }
        .onChange(of: captureEnabled) { _, _ in engine.applyCurrentPreferences() }
        .onChange(of: captureLongEdge) { _, _ in engine.applyCurrentPreferences() }
        .onChange(of: tooltipWidth) { _, _ in engine.applyCurrentPreferences() }
        .onChange(of: hideTooltipOnHover) { _, _ in engine.applyCurrentPreferences() }
        .onChange(of: cursorSize) { _, _ in engine.applyCurrentPreferences() }
        .onChange(of: tooltipOpacity) { _, _ in engine.applyCurrentPreferences() }
        .onChange(of: showStatusHUD) { _, _ in engine.applyCurrentPreferences() }
    }
}

// MARK: - Access

struct TutorAccessPane: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @Default(.callaAllowedBundleIDs) private var allowedBundleIDs

    var body: some View {
        SettingsPane(eyebrow: "Tutor", title: "Access",
                     detail: "Naming an app here is what lets Calla look at it. A lesson can narrow this, never widen it.") {
            SettingCard("Allowed applications", detail: allowedBundleIDs.isEmpty
                        ? "Calla cannot teach anything until at least one app is allowed."
                        : nil) {
                VStack(spacing: 6) {
                    ForEach(allowedBundleIDs, id: \.self) { id in
                        HStack {
                            Text(id).font(NotchType.mono)
                            Spacer(minLength: 8)
                            Button("Remove", role: .destructive) {
                                allowedBundleIDs.removeAll { $0 == id }
                            }
                            .controlSize(.small)
                        }
                    }
                    HStack {
                        Button("Add frontmost application") { addFrontmostApplication() }
                            .controlSize(.small)
                        Spacer()
                    }
                }
            }
            SettingCard("Permissions",
                        detail: "Requests are always explicit. Opening this pane changes nothing.",
                        tint: permissionsTint) {
                VStack(spacing: 10) {
                    permissionRow(
                        "Screen Recording",
                        granted: engine.status.screenRecordingGranted,
                        note: "Calla cannot see the app without it.",
                        action: { engine.requestScreenRecording() })
                    permissionRow(
                        "Accessibility",
                        granted: engine.status.accessibilityGranted,
                        note: "Only needed when a lesson reaches an action you have approved.",
                        action: { engine.requestAccessibility() })
                }
            }
        }
        .onChange(of: allowedBundleIDs) { _, _ in engine.applyCurrentPreferences() }
    }

    private var permissionsTint: Color? {
        engine.status.screenRecordingGranted ? nil : NotchTint.attention
    }

    private func permissionRow(_ title: String, granted: Bool, note: String,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            SettingStatusIcon(ok: granted)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(NotchType.rowTitle)
                Text(granted ? "Allowed" : note)
                    .font(NotchType.rowDetail).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !granted {
                Button("Request") { action() }.controlSize(.small)
            }
        }
    }

    private func addFrontmostApplication() {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              id != Bundle.main.bundleIdentifier,
              !allowedBundleIDs.contains(id) else { return }
        allowedBundleIDs.append(id)
    }
}

// MARK: - Engine

struct TutorEnginePane: View {
    @ObservedObject private var engine = CallaEngineClient.shared

    private var status: CallaEngineStatus { engine.status }

    var body: some View {
        SettingsPane(eyebrow: "Tutor", title: "Engine",
                     detail: "Where the teaching runtime is, and what it is talking to.") {
            SettingCard("Runtime", tint: engineTint) {
                VStack(spacing: 10) {
                    SettingFact(title: "Engine", value: status.running ? "Running" : "Stopped",
                                tint: status.running ? NotchTint.healthy : NotchTint.paused)
                    // Host and Gateway are separate facts. Folding them together
                    // reported a healthy Mac as Offline whenever the tailnet
                    // route was down, even though cached courses teach fine.
                    SettingFact(title: "Tutor host",
                                value: status.hostReady ? "Listening" : "Not listening",
                                tint: status.hostReady ? NotchTint.healthy : NotchTint.attention)
                    SettingFact(title: "Gateway",
                                value: status.gatewayReachable ? "Reachable" : "Unavailable",
                                tint: status.gatewayReachable ? NotchTint.healthy : NotchTint.attention)
                    SettingFact(title: "Calla Mac node",
                                value: status.nodeConnected ? "Connected" : "Disconnected",
                                tint: status.nodeConnected ? NotchTint.healthy : NotchTint.attention)
                    SettingFact(title: "Build", value: status.engineBuild ?? "Waiting for capability receipt")
                    HStack {
                        Button(status.running ? "Stop engine" : "Start engine") {
                            status.running ? engine.stop() : engine.start()
                        }
                        Button("Refresh runtime") {
                            engine.courseControl(.init(action: "refresh_runtime"))
                        }
                        Spacer()
                    }
                    .controlSize(.small)
                }
            }
            SettingCard("Gateway release") {
                VStack(spacing: 10) {
                    SettingFact(title: "Current", value: status.releaseVersion ?? "Unknown")
                    SettingFact(title: "Last update", value: status.lastGatewayUpdate ?? "None")
                    HStack {
                        Button("Retry Gateway update") { engine.requestGatewayUpdate() }
                        Spacer()
                    }
                    .controlSize(.small)
                }
            }
            SettingCard("Last result") {
                Text(status.lastResult).font(NotchType.rowDetail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !status.diagnostics.isEmpty {
                // Competing-install warnings arrive here: the engine reports a
                // legacy host holding the socket, or a second Calla Mac node.
                SettingCard("Diagnostics", detail: "The last few bounded notes from the engine.") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(status.diagnostics, id: \.self) { line in
                            Text(line).font(NotchType.mono).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var engineTint: Color? {
        if !status.running { return NotchTint.stuck }
        if !status.hostReady { return NotchTint.attention }
        return nil
    }
}
