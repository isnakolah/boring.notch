//
//  TutorCoursesPane.swift
//  boringNotch
//
//  Split out of TutorPane.swift, which held a router and four sibling panes in
//  one 564-line file.
//

import Defaults
import SwiftUI

struct TutorCoursesPane: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @Default(.callaHiddenCourseIDs) private var hiddenCourseIDs
    @State private var selectedCourseID = ""
    @State private var publishCandidate: CallaCourseSnapshot?

    private var courses: [CallaCourseSnapshot] { engine.status.courses }
    private var selectedCourse: CallaCourseSnapshot? {
        courses.first { $0.id == selectedCourseID } ?? courses.first
    }

    var body: some View {
        SettingsPane(SettingsPage.tutorCourses) {
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
        .alert("Publish course revision?", isPresented: Binding(
            get: { publishCandidate != nil }, set: { if !$0 { publishCandidate = nil } }
        ), presenting: publishCandidate) { course in
            Button("Publish", role: .destructive) {
                engine.courseControl(.init(action: "publish", courseID: course.id))
                publishCandidate = nil
            }
            Button("Cancel", role: .cancel) { publishCandidate = nil }
        } message: { course in
            Text("Publish \(course.title)? New learners will receive this exact revision. Active runs stay pinned to their current revision.")
        }
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
        let published = course.isLearnerVisible
        return VStack(spacing: 16) {
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
                    if course.lifecyclePhase == "ready_for_review" {
                        Label(course.lifecycleNote ?? "Review bounded validation, preflight, and lesson-order facts before publishing.",
                              systemImage: "checkmark.seal.fill")
                            .font(NotchType.rowDetail).foregroundStyle(NotchTint.healthy)
                            .fixedSize(horizontal: false, vertical: true)
                        if let revision = course.revision { SettingFact(title: "Revision", value: revision) }
                        if let targetVersion = course.targetVersion { SettingFact(title: "Target version", value: targetVersion) }
                        if let count = course.authoredLessonCount { SettingFact(title: "Authored lessons", value: "\(count)") }
                        if let compiler = course.compilerVersion { SettingFact(title: "Compiler", value: compiler) }
                        if let contract = course.packContractVersion { SettingFact(title: "Pack contract", value: "v\(contract)") }
                        if let digest = course.artifactDigest { SettingFact(title: "Artifact digest", value: digest) }
                        if let validation = course.validationReceipt { SettingFact(title: "Validation", value: validation) }
                        if let preflight = course.preflightReceipt { SettingFact(title: "Preflight", value: preflight) }
                        ForEach(course.reviewWarnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(NotchType.rowDetail).foregroundStyle(NotchTint.attention)
                        }
                    }
                    HStack {
                        Button("Resume") { engine.resumeCourse() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!published || course.runtimeBlocked)
                        Button("Start again") { engine.startAgain(courseID: course.id) }
                            .disabled(!published || course.runtimeBlocked)
                        if course.lifecyclePhase == "ready_for_review" {
                            Button("Publish") { publishCandidate = course }
                                .buttonStyle(.borderedProminent)
                        }
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
                    if course.lessons.isEmpty, let count = course.authoredLessonCount, count > 0 {
                        Text("Lesson ordering will appear with the reviewed runtime (\(count) lesson\(count == 1 ? "" : "s")).")
                            .font(NotchType.rowDetail).foregroundStyle(.secondary)
                    }
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
                            .disabled(!published || course.runtimeBlocked)
                        }
                    }
                }
            }
        }
    }

}
