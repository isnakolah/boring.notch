import SwiftUI

struct CallaTabView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @State private var selectedCourseID = ""
    @State private var question = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Calla", systemImage: "graduationcap.fill")
                    .font(.title3.weight(.semibold))
                Spacer()
                statusCapsule
            }

            VStack(alignment: .leading, spacing: 5) {
                Label(engine.status.gatewayReachable ? "Gateway reachable" : "Gateway unavailable", systemImage: "network")
                Label(engine.status.nodeConnected ? "Calla Mac connected" : "Calla Mac disconnected", systemImage: "desktopcomputer")
                if let releaseVersion = engine.status.releaseVersion {
                    Text("Gateway release \(releaseVersion)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            if engine.status.courses.isEmpty {
                Text("No published courses")
                    .font(.headline)
                Text("Gateway publishes the course library to Calla Mac. Refresh after it reconnects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Course", selection: $selectedCourseID) {
                    Text("Choose course").tag("")
                    ForEach(engine.status.courses) { course in
                        Text("\(course.title) · \(course.lessonCount) lessons").tag(course.id)
                    }
                }
                .labelsHidden()
                Text(engine.status.courses.first(where: { $0.id == selectedCourseID })?.summary ?? "Choose a course to start its next unfinished lesson.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Start course") { engine.startCourse(selectedCourseID) }
                    .disabled(selectedCourseID.isEmpty || !engine.status.running)
                Button("Resume course") { engine.resumeCourse() }
                    .disabled(!engine.status.running)
                Button("Stop lesson") { engine.stopLesson() }
                    .disabled(!engine.status.running)
                Spacer()
                Button("Tutor Settings") { SettingsWindowController.shared.showTutorWindow() }
            }

            HStack {
                TextField("Ask Calla", text: $question)
                    .textFieldStyle(.roundedBorder)
                Button("Ask") {
                    engine.ask(question)
                    question = ""
                }
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !engine.status.running)
            }
        }
        .padding(16)
        .task {
            engine.start()
            engine.applyCurrentPreferences()
            while !Task.isCancelled {
                engine.refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .onChange(of: engine.status.courses) { _, courses in
            if selectedCourseID.isEmpty || !courses.contains(where: { $0.id == selectedCourseID }) {
                selectedCourseID = courses.first?.id ?? ""
            }
        }
    }

    private var statusCapsule: some View {
        Text(engine.status.running ? "Engine running" : "Engine stopped")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(engine.status.running ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15), in: Capsule())
    }
}
