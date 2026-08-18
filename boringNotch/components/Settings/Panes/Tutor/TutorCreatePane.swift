//
//  TutorCreatePane.swift
//  boringNotch
//
//  Split out of TutorPane.swift, which held a router and four sibling panes in
//  one 564-line file.
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

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
        SettingsPane(SettingsPage.tutorCreate) {
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
