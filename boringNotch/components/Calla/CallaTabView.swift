import SwiftUI

/// Notch tab for Tutor. The open notch gives roughly 488x130pt and cannot be
/// scrolled upward, so this surface never scrolls: it shows only what matters
/// at the current moment and defers the catalogue, lifecycle, and diagnostics
/// to Tutor Settings. `CallaNotchPresentation` owns the "what matters" call.
struct CallaTabView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @State private var selectedCourseID = ""
    @State private var question = ""

    private var courses: [CallaCourseSnapshot] { engine.status.courses.filter { !$0.hidden } }
    private var activeLesson: CallaActiveLesson? {
        guard let lesson = engine.status.activeLesson, lesson.active else { return nil }
        return lesson
    }

    private var selectedCourse: CallaCourseSnapshot? {
        courses.first { $0.id == selectedCourseID } ?? courses.first
    }

    private var mode: CallaNotchPresentation.Mode {
        CallaNotchPresentation.mode(
            running: engine.status.running,
            hostReady: engine.status.hostReady,
            gatewayReachable: engine.status.gatewayReachable,
            hasCourses: !courses.isEmpty,
            lessonActive: activeLesson != nil
        )
    }

    var body: some View {
        // Spacing and the bottom inset are load-bearing: the notch's lower
        // corners curve inward, so a control row flush with the frame is drawn
        // half outside the shape. Keep the last row above that curve.
        VStack(alignment: .leading, spacing: 6) {
            switch mode {
            case .teaching:
                teaching
            // Degraded still teaches: courses are cached locally and the fast
            // lesson path needs no Gateway, so it gets the same controls as
            // idle. The pill is what says the Gateway is missing.
            case .idle, .degraded:
                if let course = selectedCourse { idle(course) } else { placeholder }
            case .offline, .empty:
                placeholder
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            engine.start()
            engine.startMonitoring()
        }
        .onChange(of: courses.map(\.id)) { _, ids in syncSelection(ids) }
        .onChange(of: activeLesson?.courseID) { _, _ in syncSelection(courses.map(\.id)) }
        .onAppear { syncSelection(courses.map(\.id)) }
        .animation(.smooth(duration: 0.25), value: mode)
    }

    private func syncSelection(_ ids: [String]) {
        selectedCourseID = CallaNotchPresentation.resolveSelection(
            current: selectedCourseID,
            availableIDs: ids,
            activeCourseID: activeLesson?.courseID
        )
    }

    // MARK: - Teaching

    /// A running lesson owns the slab: which step is live, one line of what the
    /// tutor last said, and the two controls a learner reaches for mid-lesson.
    @ViewBuilder private var teaching: some View {
        let lesson = engine.status.activeLesson
        let course = courses.first { $0.id == lesson?.courseID }
        let snapshot = course?.lessons.first { $0.id == lesson?.lessonID }

        HStack(spacing: 8) {
            statusPill
            Text(lesson?.lessonTitle ?? "Lesson")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            settingsButton
        }

        Text(CallaNotchPresentation.teachingSubtitle(
            courseTitle: course?.title ?? "Course",
            completed: course?.completedCount ?? 0,
            total: course?.lessonCount ?? 0,
            stepCount: snapshot?.stepCount ?? 0
        ))
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .lineLimit(1)

        CallaProgress(done: course?.completedCount ?? 0, total: course?.lessonCount ?? 0)

        // The course thread had a line here and cost the row below it: the
        // slab is 168pt tall and the last row was drawn through the notch's
        // bottom curve. Stop and Ask are what a learner reaches for mid-lesson;
        // the thread is one click away in Tutor Settings.
        Spacer(minLength: 0)

        HStack(spacing: 7) {
            Button("Stop") { engine.stopLesson() }
                .controlSize(.small)
            askField(placeholder: "Ask about this step")
        }
    }

    // MARK: - Idle

    /// No lesson running: one course, its progress, and the single next thing
    /// to start. The lesson list lives behind the "Next" menu instead of a
    /// column that would need the scrolling this surface does not have.
    @ViewBuilder private func idle(_ course: CallaCourseSnapshot) -> some View {
        HStack(spacing: 8) {
            courseMenu(course)
            Spacer(minLength: 4)
            Text("\(course.completedCount)/\(course.lessonCount)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            statusPill
            lessonMenu(course)
            settingsButton
        }

        CallaProgress(done: course.completedCount, total: course.lessonCount)

        nextLine(course)

        if course.runtimeBlocked {
            Label("Runtime targets a different app build", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .lineLimit(1)
        }

        Spacer(minLength: 0)

        HStack(spacing: 7) {
            Button(CallaNotchPresentation.primaryActionTitle(completedCount: course.completedCount)) {
                engine.resumeCourse()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!engine.status.running || course.runtimeBlocked)

            Button("Again") { engine.startAgain(courseID: course.id) }
                .controlSize(.small)
                .disabled(!engine.status.running || course.runtimeBlocked)

            askField(placeholder: "Ask about this course")
        }
    }

    private func courseMenu(_ course: CallaCourseSnapshot) -> some View {
        Menu {
            ForEach(courses) { option in
                Button {
                    selectedCourseID = option.id
                } label: {
                    Text(verbatim: "\(option.id == course.id ? "● " : "")\(option.title)  \(option.completedCount)/\(option.lessonCount)")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: course.icon.isEmpty ? "books.vertical.fill" : course.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.blue)
                Text(course.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(courses.count < 2)
    }

    /// What Resume will start, said in words rather than hidden in a control.
    private func nextLine(_ course: CallaCourseSnapshot) -> some View {
        HStack(spacing: 5) {
            Text("NEXT")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.45)
                .foregroundStyle(.white.opacity(0.4))
            Text(course.nextLesson?.title ?? "Nothing queued")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            if course.dueForReview {
                Circle().fill(.orange).frame(width: 5, height: 5)
            }
        }
    }

    /// The whole lesson roster, one icon wide. A menu carries it because a
    /// visible list would need the vertical scrolling this surface refuses.
    private func lessonMenu(_ course: CallaCourseSnapshot) -> some View {
        Menu {
            ForEach(course.lessons) { lesson in
                Button {
                    engine.startLesson(courseID: course.id, lessonID: lesson.id)
                } label: {
                    Label(lesson.title, systemImage: lesson.dueForReview ? "arrow.clockwise.circle.fill"
                          : lesson.completed ? "checkmark.circle.fill" : "circle")
                }
                .disabled(!engine.status.running || course.runtimeBlocked)
            }
        } label: {
            Image(systemName: "list.bullet").font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Lessons")
        .disabled(course.lessons.isEmpty)
    }

    // MARK: - Shared pieces

    private func askField(placeholder: String) -> some View {
        HStack(spacing: 5) {
            TextField(placeholder, text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onSubmit(submitQuestion)
            Button {
                submitQuestion()
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .disabled(!CallaNotchPresentation.canAsk(question: question, running: engine.status.running))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.white.opacity(0.08), in: Capsule())
    }

    private func submitQuestion() {
        guard CallaNotchPresentation.canAsk(question: question, running: engine.status.running) else { return }
        engine.ask(question)
        question = ""
    }

    private var statusPill: some View {
        let pill = CallaNotchPresentation.pill(for: mode)
        return CallaPill(text: pill.text, tint: tint(pill.tone))
    }

    private func tint(_ tone: CallaNotchPresentation.Tone) -> Color {
        switch tone {
        case .active: return .blue
        case .ready: return .green
        case .warning: return .orange
        }
    }

    private var settingsButton: some View {
        Button { SettingsWindowController.shared.showTutorWindow() } label: {
            Image(systemName: "slider.horizontal.3").font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Tutor Settings")
    }

    /// Offline and empty share a frame: one sentence and the one button that
    /// resolves it. Everything diagnostic stays in Tutor Settings' System tab.
    @ViewBuilder private var placeholder: some View {
        HStack(spacing: 8) {
            statusPill
            Spacer(minLength: 4)
            settingsButton
        }

        Spacer(minLength: 0)

        VStack(alignment: .leading, spacing: 4) {
            Text(mode == .offline ? "Tutor engine is not reachable" : "No published courses")
                .font(.system(size: 13, weight: .semibold))
            Text(mode == .offline
                 ? "Start the engine or check the Gateway in Tutor Settings."
                 : "Create or restore a course in Tutor Settings.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Button(mode == .offline ? "Start engine" : "Open Tutor Settings") {
                if mode == .offline { engine.start() } else { SettingsWindowController.shared.showTutorWindow() }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Spacer(minLength: 0)
    }
}

struct CallaPill: View {
    let text: String; let tint: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.22), in: Capsule())
            .foregroundStyle(tint)
            .fixedSize()
    }
}

struct CallaProgress: View {
    let done: Int; let total: Int
    var body: some View {
        ProgressView(value: total == 0 ? 0 : Double(min(done, total)), total: Double(max(1, total)))
            .tint(.blue)
            .progressViewStyle(.linear)
            .scaleEffect(x: 1, y: 0.7, anchor: .center)
    }
}
