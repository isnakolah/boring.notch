//
//  CallaTabView.swift
//  boringNotch
//
//  Tutor's notch tab.
//
//  One card, two columns — the lesson on the left, how far through the course
//  you are on the right — split the way the Usage tab splits its providers. The
//  surface never scrolls: the open notch gives 512x168pt and cannot be pushed
//  upward, so this shows what matters now and defers the catalogue, lifecycle
//  and diagnostics to Tutor Settings. `CallaNotchPresentation` still owns the
//  "what matters" call.
//
//  There is no row naming the tab. The reader clicked Tutor to get here; the
//  header line inside the card says only what state it is in, and carries the
//  two controls that belong to it.
//

import SwiftUI

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
        HStack(spacing: 0) {
            main
                .frame(maxWidth: .infinity)
            if let course = selectedCourse, mode != .offline, mode != .empty {
                NotchColumnDivider()
                progressColumn(course)
                    .frame(width: 116)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .notchCard()
        .notchTabInsets()
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

    @ViewBuilder private var main: some View {
        switch mode {
        case .teaching:
            teaching
        // Degraded still teaches: courses are cached locally and the fast lesson
        // path needs no Gateway, so it gets the same controls as idle. The state
        // caps are what say the Gateway is missing.
        case .idle, .degraded:
            if let course = selectedCourse { idle(course) } else { placeholder }
        case .offline, .empty:
            placeholder
        }
    }

    // MARK: - Teaching

    /// A running lesson owns the card: which step is live, what it belongs to,
    /// and the two controls a learner reaches for mid-lesson.
    @ViewBuilder private var teaching: some View {
        let lesson = engine.status.activeLesson
        let course = courses.first { $0.id == lesson?.courseID }
        let snapshot = course?.lessons.first { $0.id == lesson?.lessonID }

        VStack(alignment: .leading, spacing: NotchGlassSpace.snug) {
            NotchCardHeader(state: CallaNotchPresentation.pill(for: mode).text,
                            live: true,
                            tint: tint(CallaNotchPresentation.pill(for: mode).tone),
                            figure: snapshot.map { "\($0.stepCount) steps" }) {
                NotchGlyphButton(symbol: "stop.fill", help: "Stop the lesson") { engine.stopLesson() }
                settingsButton
            }

            Text(lesson?.lessonTitle ?? "Lesson")
                .font(NotchGlassType.title)
                .foregroundStyle(NotchInk.primary)
                .lineLimit(1)

            Text(course?.title ?? "Course")
                .font(NotchGlassType.caption)
                .foregroundStyle(NotchInk.tertiary)
                .lineLimit(1)

            askField(placeholder: "Ask about this step")
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 12)
    }

    // MARK: - Idle

    /// No lesson running: what Resume would start, and the progress behind it.
    /// The lesson roster stays behind a menu — a visible list would need the
    /// vertical scrolling this surface refuses.
    @ViewBuilder private func idle(_ course: CallaCourseSnapshot) -> some View {
        VStack(alignment: .leading, spacing: NotchGlassSpace.snug) {
            NotchCardHeader(state: CallaNotchPresentation.pill(for: mode).text,
                            live: false,
                            tint: tint(CallaNotchPresentation.pill(for: mode).tone)) {
                courseMenu(course)
                lessonMenu(course)
                NotchGlyphButton(symbol: "play.fill",
                                 help: CallaNotchPresentation.primaryActionTitle(completedCount: course.completedCount)) {
                    engine.resumeCourse()
                }
                settingsButton
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(course.nextLesson?.title ?? "Nothing queued")
                    .font(NotchGlassType.title)
                    .foregroundStyle(NotchInk.primary)
                    .lineLimit(1)
                if course.dueForReview {
                    Circle().fill(NotchTint.attention).frame(width: 5, height: 5)
                }
                Spacer(minLength: 0)
            }

            Text(idleSubtitle(course))
                .font(NotchGlassType.caption)
                .foregroundStyle(NotchInk.tertiary)
                .lineLimit(1)

            // The blocked state is a caption rather than a banner that would
            // cost the card a line it does not have.
            if course.runtimeBlocked {
                NotchCaps("Runtime targets another build", tint: NotchTint.attention)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 12)
    }

    private func idleSubtitle(_ course: CallaCourseSnapshot) -> String {
        var parts = [course.title]
        if let steps = course.nextLesson?.stepCount, steps > 0 {
            parts.append("\(steps) steps")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Progress column

    private func progressColumn(_ course: CallaCourseSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            NotchCaps("Course")
            Text("\(course.completedCount)/\(course.lessonCount)")
                .font(NotchGlassType.figure)
                .foregroundStyle(course.completedCount > 0 ? NotchInk.primary : NotchInk.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            NotchBar(fraction: course.lessonCount == 0 ? 0
                     : Double(min(course.completedCount, course.lessonCount)) / Double(course.lessonCount),
                     tint: mode == .teaching ? NotchTint.healthy : NotchInk.tertiary)
            Text("lessons done")
                .font(NotchGlassType.caption)
                .foregroundStyle(NotchInk.tertiary)
                .lineLimit(1)
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 12)
    }

    // MARK: - Controls

    private var settingsButton: some View {
        NotchGlyphButton(symbol: "slider.horizontal.3", help: "Tutor Settings") {
            SettingsWindowController.shared.showTutorWindow()
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
            Image(systemName: "books.vertical.fill")
                .font(NotchGlassType.glyphSmall)
                .foregroundStyle(NotchInk.tertiary)
                .padding(4)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch course")
        .disabled(courses.count < 2)
    }

    /// The whole lesson roster, one glyph wide.
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
            Image(systemName: "list.bullet")
                .font(NotchGlassType.glyphSmall)
                .foregroundStyle(NotchInk.tertiary)
                .padding(4)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Lessons")
        .disabled(course.lessons.isEmpty)
    }

    private func askField(placeholder: String) -> some View {
        HStack(spacing: NotchGlassSpace.tight) {
            Image(systemName: "text.bubble")
                .font(NotchGlassType.glyphSmall)
                .foregroundStyle(NotchInk.tertiary)
            TextField(placeholder, text: $question)
                .textFieldStyle(.plain)
                .font(NotchGlassType.detail)
                .foregroundStyle(NotchInk.secondary)
                .onSubmit(submitQuestion)
            Button {
                submitQuestion()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(NotchGlassType.glyph)
                    .foregroundStyle(Color.effectiveAccent)
            }
            .buttonStyle(.plain)
            .disabled(!CallaNotchPresentation.canAsk(question: question, running: engine.status.running))
        }
        .padding(.horizontal, 10)
        .frame(height: NotchGlassSpace.control)
        .frame(maxWidth: .infinity)
        .background(NotchPlane.chip,
                    in: RoundedRectangle(cornerRadius: NotchGlassRadius.chip, style: .continuous))
    }

    private func submitQuestion() {
        guard CallaNotchPresentation.canAsk(question: question, running: engine.status.running) else { return }
        engine.ask(question)
        question = ""
    }

    private func tint(_ tone: CallaNotchPresentation.Tone) -> Color {
        switch tone {
        case .active: return .effectiveAccent
        case .ready: return NotchTint.healthy
        case .warning: return NotchTint.attention
        }
    }

    /// Offline and empty share a frame: one sentence and the one control that
    /// resolves it.
    @ViewBuilder private var placeholder: some View {
        VStack(alignment: .leading, spacing: NotchGlassSpace.snug) {
            NotchCardHeader(state: CallaNotchPresentation.pill(for: mode).text,
                            live: false,
                            tint: NotchTint.attention) {
                settingsButton
            }
            Text(mode == .offline ? "Tutor engine is not reachable" : "No published courses")
                .font(NotchGlassType.title)
                .foregroundStyle(NotchInk.primary)
            Text(mode == .offline
                 ? "Start the engine, or check the Gateway in Tutor Settings."
                 : "Create or restore a course in Tutor Settings.")
                .font(NotchGlassType.caption)
                .foregroundStyle(NotchInk.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            NotchChip(action: {
                if mode == .offline { engine.start() } else { SettingsWindowController.shared.showTutorWindow() }
            }) {
                Text(mode == .offline ? "Start engine" : "Open Tutor Settings")
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 12)
    }
}
