//
//  TutorPane.swift
//  boringNotch
//

import Defaults
import SwiftUI

/// Tutor's front page.
///
/// It was a switch in a card and five drill rows. What someone opens Tutor for
/// is almost always "where was I" — and that answer lived two clicks away, at
/// the bottom of Courses, behind a menu. So the landing pane leads with the
/// engine's actual state and then with the courses themselves; the destinations
/// come after, as four tiles rather than five rows.
struct TutorPane: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @Environment(\.settingsRouter) private var router

    @Default(.callaTutorEnabled) private var enabled
    @Default(.callaHiddenCourseIDs) private var hiddenCourseIDs
    @Default(.callaAllowedBundleIDs) private var allowedBundleIDs
    @Default(.callaCaptureLongEdge) private var captureLongEdge

    private var status: CallaEngineStatus { engine.status }
    private var courses: [CallaCourseSnapshot] {
        status.courses.filter { !hiddenCourseIDs.contains($0.id) }
    }

    var body: some View {
        SettingsPane(.tutor) {
            band
            if !courses.isEmpty { rail }
            if let router { tiles(router) }
        }
        .task { engine.refresh() }
    }

    // MARK: - Band

    private var band: some View {
        SettingsStateBand(
            symbol: "graduationcap.fill",
            title: status.running ? "Engine running" : "Engine stopped",
            detail: bandDetail,
            tint: bandTint,
            isOn: $enabled
        ) {
            HStack(spacing: NotchSpace.row) {
                SettingsHealthDot(label: "Host",
                                  tint: status.hostReady ? NotchTint.healthy : NotchTint.attention)
                SettingsHealthDot(label: "Gateway",
                                  tint: status.gatewayReachable ? NotchTint.healthy : NotchTint.attention)
                SettingsHealthDot(label: "Node",
                                  tint: status.nodeConnected ? NotchTint.healthy : NotchTint.attention)
            }
            .padding(.trailing, NotchSpace.tight)
        }
    }

    /// The course a lesson is running in, if one is.
    private var activeCourseID: String? {
        guard let lesson = status.activeLesson, lesson.active else { return nil }
        return lesson.courseID
    }

    private var bandDetail: String {
        guard status.running else {
            return "Watches the screen during a lesson and points at the next step."
        }
        var parts: [String] = []
        parts.append("^[\(status.courses.count) course](inflect: true) installed")
        parts.append(allowedBundleIDs.isEmpty
                     ? "no applications allowed yet"
                     : "^[\(allowedBundleIDs.count) application](inflect: true) allowed")
        parts.append("\(captureLongEdge) px looks")
        return parts.joined(separator: " · ")
    }

    private var bandTint: Color? {
        guard enabled else { return nil }
        if !status.running { return NotchTint.stuck }
        // A tutor that cannot see anything is stopped in every way that matters.
        if allowedBundleIDs.isEmpty || !status.hostReady { return NotchTint.attention }
        return NotchTint.active
    }

    // MARK: - Course rail

    /// Where you left off, on the front page.
    ///
    /// This is a rail rather than a list: three courses across is the whole
    /// library for most people, and the point is to be able to press Resume
    /// without navigating. Everything else about a course stays in Courses.
    private var rail: some View {
        VStack(alignment: .leading, spacing: NotchSpace.row) {
            SettingsDivider("Where you left off")
            HStack(alignment: .top, spacing: NotchSpace.stack) {
                ForEach(courses.prefix(3)) { course in
                    CourseCard(course: course,
                               isActive: course.id == activeCourseID,
                               resume: { engine.resumeCourse() },
                               start: { engine.startAgain(courseID: course.id) })
                }
                if courses.count < 3 {
                    // Keeps two courses from stretching to half the pane each.
                    ForEach(0..<(3 - courses.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    // MARK: - Tiles

    private func tiles(_ router: SettingsRouter) -> some View {
        SettingsTileGrid(columns: 4) {
            SettingsTile(symbol: SettingsPage.tutorCourses.symbol,
                         title: String(localized: SettingsPage.tutorCourses.title),
                         value: coursesValue) { router.push(.tutorCourses) }
            SettingsTile(symbol: SettingsPage.tutorCreate.symbol,
                         title: String(localized: SettingsPage.tutorCreate.title),
                         value: "Build a new course, or revise one") { router.push(.tutorCreate) }
            SettingsTile(symbol: SettingsPage.tutorBehavior.symbol,
                         title: String(localized: SettingsPage.tutorBehavior.title),
                         value: behaviourValue,
                         tint: allowedBundleIDs.isEmpty ? NotchTint.attention : NotchTint.active) {
                router.push(.tutorBehavior)
            }
            SettingsTile(symbol: SettingsPage.tutorEngine.symbol,
                         title: String(localized: SettingsPage.tutorEngine.title),
                         value: engineValue,
                         valueIsLive: status.running) { router.push(.tutorEngine) }
        }
    }

    private var coursesValue: String {
        guard !status.courses.isEmpty else { return "Nothing installed yet" }
        let hidden = status.courses.count - courses.count
        guard hidden > 0 else { return "^[\(status.courses.count) course](inflect: true) installed" }
        return "^[\(status.courses.count) course](inflect: true) · \(hidden) hidden"
    }

    private var behaviourValue: String {
        guard !allowedBundleIDs.isEmpty else { return "No applications allowed yet" }
        return "\(captureLongEdge) px · ^[\(allowedBundleIDs.count) app](inflect: true) allowed"
    }

    private var engineValue: String {
        guard status.running else { return "Stopped" }
        guard let build = status.engineBuild else { return "Running" }
        return "Running · \(build)"
    }
}

/// One course on the rail: how far through it you are, and the one button that
/// matters for it.
private struct CourseCard: View {
    let course: CallaCourseSnapshot
    let isActive: Bool
    let resume: () -> Void
    let start: () -> Void

    private var fraction: Double {
        course.lessonCount == 0 ? 0 : Double(course.completedCount) / Double(course.lessonCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchSpace.snug) {
            HStack(spacing: NotchSpace.snug) {
                ProgressRing(fraction: fraction,
                             tint: isActive ? NotchTint.active : Color.secondary)
                VStack(alignment: .leading, spacing: NotchSpace.hair) {
                    Text(course.title)
                        .font(NotchType.rowTitle)
                        .lineLimit(1)
                    Text(lessonLine)
                        .font(NotchType.rowDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: NotchSpace.tight) {
                if course.dueForReview { SettingBadge("Review due", tint: NotchTint.attention) }
                Spacer(minLength: 0)
                if isActive {
                    Button("Resume", action: resume)
                        .buttonStyle(.borderedProminent).controlSize(.small)
                } else {
                    Button(course.completedCount == 0 ? "Start" : "Continue", action: start)
                        .controlSize(.small)
                }
            }
        }
        .padding(NotchSpace.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isActive ? AnyShapeStyle(NotchTint.active.opacity(0.08))
                             : AnyShapeStyle(NotchSurface.raised),
                    in: RoundedRectangle(cornerRadius: NotchRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NotchRadius.card, style: .continuous)
                .strokeBorder(isActive ? NotchTint.active.opacity(0.30) : NotchSurface.hairline,
                              lineWidth: 1))
    }

    private var lessonLine: String {
        if course.completedCount >= course.lessonCount, course.lessonCount > 0 {
            return "Finished · ^[\(course.lessonCount) lesson](inflect: true)"
        }
        return "Lesson \(course.completedCount + 1) of \(course.lessonCount)"
    }
}

/// How far through, as a shape rather than a bar.
///
/// A rail of three cards each carrying a horizontal bar reads as a chart; a ring
/// beside the title reads as a course. `SettingProgressBar` stays for the places
/// where the count itself is the subject.
private struct ProgressRing: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.001, min(fraction, 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((fraction * 100).rounded()))")
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .frame(width: 38, height: 38)
        .animation(NotchMotion.settle, value: fraction)
        .accessibilityHidden(true)
    }
}
