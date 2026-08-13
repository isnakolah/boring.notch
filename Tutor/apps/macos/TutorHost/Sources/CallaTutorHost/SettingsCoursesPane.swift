import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Courses, for the two people who open this pane.
///
/// It used to be one scrolling column that answered three unrelated questions in
/// an order that served neither reader: a build queue, then a review step, then
/// the learner's own library, then the archive, and finally — at the very bottom,
/// past all of it — the box you type a new course into. Somebody wanting to
/// learn something scrolled past a compiler; somebody making a course scrolled
/// past a library to reach the only control they came for.
///
/// So it is two modes. Library is what this Mac can teach and how far through it
/// you are. Authoring is what the Gateway is building and how to give it more.
/// They share a data source and nothing else.
struct CoursesPane: View {
    @ObservedObject var host: TutorHostController
    @ObservedObject var settings: TutorSettings

    enum Mode: String, CaseIterable, Identifiable {
        case library = "Library"
        case authoring = "Authoring"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .library

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                Spacer(minLength: 8)
                if mode == .authoring {
                    CourseAuthoringCounts()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            switch mode {
            case .library:
                CourseLibraryView(host: host, settings: settings)
            case .authoring:
                CourseAuthoringView(settings: settings)
            }
        }
    }
}

// MARK: - Library

/// One list, one course open beside it.
///
/// Every course used to be a card in a column, with its lessons and its thread
/// folded into disclosure triangles and its progress reduced to "3/7" — all
/// inside a 760pt column in a window that opens 1400pt wide. A list and a detail
/// spends that width on the thing being read.
private struct CourseLibraryView: View {
    @ObservedObject var host: TutorHostController
    @ObservedObject var settings: TutorSettings
    @ObservedObject var catalogue = CourseCatalogue.shared
    @ObservedObject var lifecycle = CourseLifecycleStore.shared
    @ObservedObject var runs = CourseRunStore.shared
    @ObservedObject var runtime = CourseRuntimeStore.shared

    @State private var selectedCourseID: String?
    @State private var note: String?
    @State private var restarting: CourseCatalogue.Course?

    var body: some View {
        Group {
            if catalogue.courses.isEmpty {
                emptyLibrary
            } else {
                HStack(spacing: 0) {
                    courseList
                        .frame(width: 236)
                    Divider()
                    detail
                }
            }
        }
        .onAppear(perform: selectDefault)
        .onChange(of: catalogue.courses) { _, _ in selectDefault() }
        .confirmationDialog("Start this course again from the beginning?",
                            isPresented: Binding(get: { restarting != nil },
                                                 set: { if !$0 { restarting = nil } })) {
            Button("Start again", role: .destructive) {
                if let course = restarting { restart(course) }
                restarting = nil
            }
            Button("Cancel", role: .cancel) { restarting = nil }
        } message: {
            Text("This clears what you have passed in this course, and its checkpoint. The course itself, its archive state, and its thread are untouched.")
        }
    }

    // MARK: List

    private var courseList: some View {
        List(catalogue.courses, selection: $selectedCourseID) { course in
            listRow(course)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private func listRow(_ course: CourseCatalogue.Course) -> some View {
        let bundleID = catalogue.bundleID(for: course, allowed: settings.allowedBundleIDs)
        let progress = progress(for: course, bundleID: bundleID)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                CourseIcon(symbol: course.icon, bundleID: bundleID, size: 15)
                Text(course.title).font(CallaFont.rowTitle).lineLimit(1)
                // A mark, not a word: something in here is due again.
                if progress?.dueForReview == true {
                    Circle().fill(CallaTint.teaching).frame(width: 5, height: 5)
                }
                Spacer(minLength: 0)
                if !catalogue.isVisible(course) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                        .help("Hidden from the menu bar")
                }
            }
            if let progress, progress.total > 0 {
                CourseProgressBar(done: progress.done, total: progress.total,
                                  active: isTeaching(course))
            }
        }
        .padding(.vertical, 3)
        // Not hidden, dimmed. A course whose application is not allowed used to
        // be listed here exactly like the others while the menu bar quietly left
        // it out, so the two surfaces disagreed and neither said why.
        .opacity(isRunnable(course) ? 1 : 0.5)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let course = selectedCourse {
            ScrollView {
                courseDetail(course)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            VStack {
                Spacer()
                Text("Select a course.").font(CallaFont.detail).foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func courseDetail(_ course: CourseCatalogue.Course) -> some View {
        let bundleID = catalogue.bundleID(for: course, allowed: settings.allowedBundleIDs)
        let progress = progress(for: course, bundleID: bundleID)
        let next = bundleID.flatMap { CourseResume.nextLesson(in: course, bundleID: $0) }
        let teaching = isTeaching(course)

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                CallaGlyph(symbol: course.icon.isEmpty ? "books.vertical.fill" : course.icon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(course.title).font(CallaFont.cardTitle)
                    Text(subtitle(course, bundleID: bundleID))
                        .font(CallaFont.detail).foregroundStyle(.secondary)
                    if !course.summary.isEmpty {
                        Text(course.summary)
                            .font(CallaFont.detail).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }

            if let progress, progress.total > 0 {
                CourseProgressBar(done: progress.done, total: progress.total, active: teaching)
            }

            ForEach(blockers(course, bundleID: bundleID), id: \.self) { blocker in
                Label(blocker, systemImage: "exclamationmark.triangle")
                    .font(CallaFont.detail).foregroundStyle(CallaTint.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions(course, bundleID: bundleID, next: next, teaching: teaching)

            if let note {
                Text(note).font(CallaFont.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                CallaSectionHeader("Lessons", count: course.lessons.count)
                ForEach(course.lessons) { lesson in
                    lessonRow(course, lesson, bundleID: bundleID, next: next?.id)
                }
            }

            let entries = runs.entries(for: course.id)
            if !entries.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    CallaSectionHeader("Thread", detail: "The last few things that happened in this course.")
                    ForEach(Array(entries.reversed().prefix(8))) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.text).font(CallaFont.detail).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Text(CallaTime.ago(entry.at))
                                .font(CallaFont.caption).foregroundStyle(.tertiary)
                                .monospacedDigit().fixedSize()
                        }
                    }
                }
            }
        }
    }

    private func actions(_ course: CourseCatalogue.Course, bundleID: String?,
                         next: CourseCatalogue.Lesson?, teaching: Bool) -> some View {
        let started = (progress(for: course, bundleID: bundleID)?.done ?? 0) > 0
            || runs.checkpoint(for: course.id) != nil
        let published = lifecycle.courses.first { $0.id == course.id && $0.isPublished }

        return HStack(spacing: 8) {
            if teaching {
                // Stopping the lesson was only ever possible from the menu bar,
                // while this pane showed a card headed "In progress" that meant
                // a course being *compiled*. Two meanings of active, in two
                // windows, and neither offered the button for the other.
                Button("Stop lesson") { host.stopLesson() }
            } else {
                Button(started ? "Resume" : "Start") { resume(course) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isRunnable(course) || next == nil)
            }
            Button("Start again") { restarting = course }
                .disabled(!isRunnable(course) || !started)
            if let published {
                Button("Archive") { command("archive", published) }
            }
            Spacer(minLength: 8)
            Toggle("Show in menu", isOn: Binding(
                get: { catalogue.isVisible(course) },
                set: { catalogue.setVisible($0, for: course) }))
                .toggleStyle(.checkbox)
                .font(CallaFont.detail)
        }
        .controlSize(.small)
    }

    private func lessonRow(_ course: CourseCatalogue.Course, _ lesson: CourseCatalogue.Lesson,
                           bundleID: String?, next: String?) -> some View {
        let done = bundleID.map { LearningStore.shared.isCompleted(lessonID: lesson.id, bundleID: $0) } ?? false
        let due = bundleID.map { LearningStore.shared.isDue(lessonID: lesson.id, bundleID: $0) } ?? false
        let isNext = lesson.id == next
        let steps = runtime.lesson(courseID: course.id, lessonID: lesson.id)?.steps.count

        return HStack(spacing: 9) {
            Image(systemName: glyph(done: done, due: due, next: isNext))
                .font(.system(size: 12))
                .foregroundStyle(tint(done: done, due: due, next: isNext))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(lesson.title).font(CallaFont.body)
                if let subtitle = lessonSubtitle(steps: steps, done: done, due: due, next: isNext) {
                    Text(subtitle).font(CallaFont.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            // The one lesson a resume would land on gets the prominent button,
            // so the row and the Resume above it are visibly the same action.
            if isNext {
                Button("Start") { start(course, lesson: lesson) }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                    .disabled(!isRunnable(course))
            } else {
                Button(done ? "Again" : "Start") { start(course, lesson: lesson) }
                    .controlSize(.small)
                    .disabled(!isRunnable(course))
            }
        }
        .padding(.vertical, 2)
    }

    private var emptyLibrary: some View {
        VStack(spacing: 10) {
            Spacer()
            CallaGlyph(symbol: "books.vertical", tint: CallaTint.paused, size: 40)
            Text("Nothing to teach yet").font(CallaFont.rowTitle)
            Text("Courses appear here once the Gateway has built one. Authoring is where you give it an outline to build from.")
                .font(CallaFont.detail).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Reading

    private var selectedCourse: CourseCatalogue.Course? {
        catalogue.courses.first { $0.id == selectedCourseID }
    }

    /// Open on whatever was last being worked on, which `CourseRunStore` has
    /// always known and nothing has ever asked it.
    private func selectDefault() {
        if let selectedCourseID, catalogue.courses.contains(where: { $0.id == selectedCourseID }) { return }
        let recent = runs.mostRecentCourseID
        selectedCourseID = catalogue.courses.first { $0.id == recent }?.id ?? catalogue.courses.first?.id
    }

    private func progress(for course: CourseCatalogue.Course,
                          bundleID: String?) -> (done: Int, total: Int, dueForReview: Bool)? {
        bundleID.map { LearningStore.shared.progress(lessonIDs: course.lessons.map(\.id), bundleID: $0) }
    }

    private func isTeaching(_ course: CourseCatalogue.Course) -> Bool {
        host.lessonActive && course.lessons.contains { $0.title == host.lessonTitle }
    }

    private func isRunnable(_ course: CourseCatalogue.Course) -> Bool {
        guard let bundleID = catalogue.bundleID(for: course, allowed: settings.allowedBundleIDs) else { return false }
        return settings.allowedBundleIDs.contains(bundleID)
    }

    private func subtitle(_ course: CourseCatalogue.Course, bundleID: String?) -> String {
        let app = bundleID.map { settings.displayName(for: $0) } ?? "No application"
        let count = course.lessons.count
        return "\(app) · \(count) \(count == 1 ? "lesson" : "lessons")"
    }

    /// Everything standing between this course and a lesson starting, said here
    /// rather than as a runtime error after the learner presses Start.
    private func blockers(_ course: CourseCatalogue.Course, bundleID: String?) -> [String] {
        var result: [String] = []
        if let bundleID, !settings.allowedBundleIDs.contains(bundleID) {
            result.append("\(settings.displayName(for: bundleID)) is not one of your allowed applications, so this course cannot run. Add it in Applications.")
        } else if bundleID == nil {
            result.append("This course names no application, so nothing can teach it.")
        }
        if let cached = runtime.course(id: course.id),
           let running = settings.runningAllowedApplication(bundleID: cached.appBundleID),
           !versionMatches(running.version, cached.appVersion) {
            result.append("Built for \(settings.displayName(for: cached.appBundleID)) \(cached.appVersion). You are running \(running.version).")
        }
        return result
    }

    private func glyph(done: Bool, due: Bool, next: Bool) -> String {
        if done && due { return "arrow.clockwise.circle.fill" }
        if done { return "checkmark.circle.fill" }
        if next { return "circle.inset.filled" }
        return "circle"
    }

    private func tint(done: Bool, due: Bool, next: Bool) -> Color {
        if done && due { return CallaTint.attention }
        if done { return CallaTint.healthy }
        if next { return CallaTint.teaching }
        return Color(nsColor: .tertiaryLabelColor)
    }

    private func lessonSubtitle(steps: Int?, done: Bool, due: Bool, next: Bool) -> String? {
        var parts: [String] = []
        if let steps { parts.append("\(steps) \(steps == 1 ? "step" : "steps")") }
        if done && due { parts.append("due again") }
        else if done { parts.append("passed") }
        else if next { parts.append("next") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Acting

    private func start(_ course: CourseCatalogue.Course, lesson: CourseCatalogue.Lesson) {
        Task { note = await CourseResume.start(course, lesson: lesson, note: "Lesson started") }
    }

    private func resume(_ course: CourseCatalogue.Course) {
        Task { note = await CourseResume.resume(course, allowed: settings.allowedBundleIDs) }
    }

    private func restart(_ course: CourseCatalogue.Course) {
        guard let bundleID = catalogue.bundleID(for: course, allowed: settings.allowedBundleIDs),
              let first = course.lessons.first else { return }
        LearningStore.shared.clear(lessonIDs: course.lessons.map(\.id), bundleID: bundleID)
        runs.restart(courseID: course.id)
        Task { note = await CourseResume.start(course, lesson: first, note: "Course restarted") }
    }

    private func command(_ command: String, _ course: CourseLifecycleStore.Course) {
        CourseControlRelay.shared.send(command, payload: ["course_id": course.id],
                                       accepted: "Course updated.")
    }
}

// MARK: - Authoring

/// The counts, beside the switch that reveals them.
private struct CourseAuthoringCounts: View {
    @ObservedObject var lifecycle = CourseLifecycleStore.shared

    var body: some View {
        HStack(spacing: 12) {
            count("Building", lifecycle.courses.filter(\.isActive).count, tint: CallaTint.attention)
            count("Stalled", lifecycle.courses.filter(\.needsAttention).count, tint: CallaTint.stuck)
            count("Published", lifecycle.courses.filter(\.isPublished).count, tint: CallaTint.healthy)
        }
    }

    private func count(_ label: String, _ value: Int, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(value)").font(CallaFont.figure).monospacedDigit()
                .foregroundStyle(value == 0 ? Color.secondary : tint)
            Text(label).font(CallaFont.caption).foregroundStyle(.secondary)
        }
    }
}

/// Giving the Gateway something to build, and watching it build it.
///
/// The composer is at the top because it is the reason to be here: on an
/// ordinary day every section below it is empty, and it used to sit underneath
/// all of them. There is no review step in this pane any more, because there is
/// none on the Gateway — it publishes as soon as its preflight passes, and its
/// `publish` command has always refused to be called.
private struct CourseAuthoringView: View {
    @ObservedObject var settings: TutorSettings
    @ObservedObject var lifecycle = CourseLifecycleStore.shared
    @ObservedObject var control = CourseControlRelay.shared

    @State private var outline = ""
    @State private var assetBundle: URL?
    @State private var targetBundleID = ""
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                composer

                section("Building", lifecycle.courses.filter(\.isActive),
                        detail: "Calla keeps working after this window closes.") { buildingCard($0) }

                section("Needs you", lifecycle.courses.filter(\.needsAttention),
                        detail: "Stopped, and waiting on something only you can do.") { attentionCard($0) }

                section("Archived", lifecycle.courses.filter(\.isArchived),
                        detail: "Hidden from the menu. Their source and your progress are kept.") { archivedCard($0) }
            }
            .padding(20)
            .frame(maxWidth: 780, alignment: .leading)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, _ courses: [CourseLifecycleStore.Course],
                                        detail: String,
                                        @ViewBuilder row: @escaping (CourseLifecycleStore.Course) -> Content) -> some View {
        if !courses.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                CallaSectionHeader(title, detail: detail, count: courses.count)
                ForEach(courses) { row($0) }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create a course").font(CallaFont.cardTitle)
                    Text("Research the course in whatever model you like, paste the outline here, and Calla turns it into lessons it can teach.")
                        .font(CallaFont.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Copy research prompt") { copyResearchPrompt() }
                    .controlSize(.small)
            }

            if settings.allowedBundleIDs.isEmpty {
                Label("Allow an application in Applications before creating a course.",
                      systemImage: "exclamationmark.triangle")
                    .font(CallaFont.detail).foregroundStyle(CallaTint.attention)
            } else {
                // The label is drawn rather than given to the Picker: a labelled
                // Picker right-aligns its label inside whatever width it is
                // given, which put "Teaches" adrift in the middle of the card.
                HStack(spacing: 8) {
                    Text("Teaches").font(CallaFont.body)
                    Picker("", selection: $targetBundleID) {
                        ForEach(settings.allowedBundleIDs, id: \.self) { bundleID in
                            Text(settings.displayName(for: bundleID)).tag(bundleID)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                    .onAppear(perform: selectDefaultTarget)
                    .onChange(of: settings.allowedBundleIDs) { _, _ in selectDefaultTarget() }
                    Spacer(minLength: 0)
                }
                Text("\(settings.displayName(for: targetBundleID)) has to be running so Calla can read its version. This window may stay in front.")
                    .font(CallaFont.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $outline)
                .font(CallaFont.mono)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 180)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: CallaRadius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: CallaRadius.control, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.24), lineWidth: 1))

            assetBundleRow

            HStack(spacing: 8) {
                if let line = note ?? control.note {
                    Text(line).font(CallaFont.detail).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("You will be told when it is ready, or when it needs you.")
                        .font(CallaFont.detail).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if control.busy { ProgressView().controlSize(.small) }
                Button("Build course") { importOutline() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!canImport)
            }
        }
        .callaCard()
    }

    /// The starter scenes, chosen as a file rather than typed as a path.
    ///
    /// The Gateway has always required this and the Mac has never sent it, so
    /// every import ever made from this window was refused before it started.
    /// The bundle is megabytes of `.blend`, far past what the control socket
    /// will accept in a request, so it travels beside the request over the same
    /// SSH connection — which is why this asks for a file on *this* Mac and not
    /// a path on the Gateway.
    private var assetBundleRow: some View {
        HStack(spacing: 10) {
            Image(systemName: assetBundle == nil ? "shippingbox" : "shippingbox.fill")
                .foregroundStyle(assetBundle == nil ? Color.secondary : CallaTint.healthy)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(assetBundle?.lastPathComponent ?? "No scenes chosen")
                    .font(CallaFont.body)
                    .lineLimit(1).truncationMode(.middle)
                Text("A .zip of the Blender scenes the lessons start from and check against.")
                    .font(CallaFont.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if assetBundle != nil {
                Button("Remove") { assetBundle = nil }.controlSize(.small)
            }
            Button(assetBundle == nil ? "Choose…" : "Change…") { chooseAssetBundle() }
                .controlSize(.small)
        }
    }

    // MARK: Cards

    private func buildingCard(_ course: CourseLifecycleStore.Course) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView().controlSize(.small).tint(CallaTint.attention)
            VStack(alignment: .leading, spacing: 3) {
                Text(course.title).font(CallaFont.rowTitle)
                HStack(spacing: 6) {
                    Text(course.phaseLabel).font(CallaFont.detail).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(course.elapsedLabel)
                        .font(CallaFont.detail).foregroundStyle(.secondary).monospacedDigit()
                }
                ForEach(course.warnings, id: \.self) {
                    Text($0).font(CallaFont.detail).foregroundStyle(CallaTint.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button("Cancel") { command("cancel", course) }.controlSize(.small)
        }
        .callaCard()
    }

    private func attentionCard(_ course: CourseLifecycleStore.Course) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(CallaTint.attention)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(course.title).font(CallaFont.rowTitle)
                Text(course.phaseLabel).font(CallaFont.detail).foregroundStyle(.secondary)
                if let reason = course.error {
                    Text(reason).font(CallaFont.detail).foregroundStyle(CallaTint.stuck)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The Gateway says what would unstick it. It has always said so
                // and this window has always thrown the sentence away.
                if let action = course.nextAction {
                    Text(action).font(CallaFont.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            VStack(spacing: 6) {
                Button("Try again") { command("retry", course) }
                    .controlSize(.small).disabled(control.busy)
                if course.phase == "waiting_for_blender" {
                    Button("Cancel") { command("cancel", course) }.controlSize(.small)
                }
            }
        }
        .callaCard(tint: CallaTint.attention)
    }

    private func archivedCard(_ course: CourseLifecycleStore.Course) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "archivebox").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(course.title).font(CallaFont.rowTitle)
                Text("\(course.lessonCount) \(course.lessonCount == 1 ? "lesson" : "lessons")")
                    .font(CallaFont.detail).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Restore") { command("restore", course) }.controlSize(.small)
        }
        .callaCard()
    }

    // MARK: Acting

    private var canImport: Bool {
        !control.busy && !targetBundleID.isEmpty && assetBundle != nil
            && !outline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func selectDefaultTarget() {
        if !settings.allowedBundleIDs.contains(targetBundleID) {
            targetBundleID = settings.allowedBundleIDs.first ?? ""
        }
    }

    private func chooseAssetBundle() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        panel.message = "The Blender scenes this course's lessons start from."
        if panel.runModal() == .OK { assetBundle = panel.url }
    }

    private func importOutline() {
        let text = outline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let bundle = assetBundle else {
            note = "Choose the .zip of Blender scenes this course starts from."
            return
        }
        guard let app = settings.runningAllowedApplication(bundleID: targetBundleID) else {
            note = "Open \(settings.displayName(for: targetBundleID)) before building a course, so Calla can read its version."
            return
        }
        note = nil
        control.send("import",
                     payload: ["outline": text, "target_app": app.bundleID, "target_version": app.version,
                               "target_frontmost": true, "target_allowlisted": true,
                               "asset_bundle_local": bundle.path],
                     accepted: "Sent. Calla is writing the lessons — this pane follows along.")
        outline = ""
    }

    private func command(_ command: String, _ course: CourseLifecycleStore.Course) {
        control.send(command, payload: ["course_id": course.id], accepted: "Course updated.")
    }

    /// Put the prompt on the clipboard, from the installed bundle or the
    /// checkout that built it — the same two places the sender is looked for.
    private func copyResearchPrompt() {
        guard let text = Self.researchPrompt() else {
            note = "Could not find course-research-prompt.md beside Calla."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        note = "Prompt copied. Paste it into a model, then paste its answer above."
    }

    private static func researchPrompt() -> String? {
        var candidates: [URL] = []
        if let resource = Bundle.main.url(forResource: "course-research-prompt", withExtension: "md") {
            candidates.append(resource)
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<8 {
            candidates.append(directory.appendingPathComponent("docs/course-research-prompt.md"))
            directory = directory.deletingLastPathComponent()
        }
        return candidates.lazy.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.first
    }
}
