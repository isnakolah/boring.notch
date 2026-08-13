import AppKit
import Defaults
import SwiftUI

struct CallaTutorSettingsView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @Default(.callaTutorEnabled) private var tutorEnabled
    @Default(.callaCaptureEnabled) private var captureEnabled
    @Default(.callaAllowedBundleIDs) private var allowedBundleIDs
    @Default(.callaCaptureLongEdge) private var captureLongEdge
    @Default(.callaTooltipWidth) private var tooltipWidth
    @Default(.callaHideTooltipOnHover) private var hideTooltipOnHover
    @Default(.callaCursorSize) private var cursorSize
    @Default(.callaTooltipOpacity) private var tooltipOpacity
    @Default(.callaShowStatusHUD) private var showStatusHUD
    @Default(.callaHiddenCourseIDs) private var hiddenCourseIDs
    @Default(.callaCalendarEnabled) private var calendarEnabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                statusSection
                teachingSection
                permissionsSection
                coursesSection
                calendarSection
                diagnosticsSection
            }
            .padding(20)
        }
        .navigationTitle("Tutor")
        .onAppear {
            if tutorEnabled { engine.start() }
            pushPreferences()
        }
        .onChange(of: preferenceSignature) { _, _ in pushPreferences() }
        .onChange(of: tutorEnabled) { _, enabled in
            enabled ? engine.start() : engine.stop()
        }
    }

    private var statusSection: some View {
        SectionBox("Tutor status", icon: "waveform.path.ecg") {
            Toggle("Enable Calla tab", isOn: $tutorEnabled)
            LabeledContent("Engine", value: engine.status.running ? "Running" : "Stopped")
            LabeledContent("Gateway", value: engine.status.gatewayReachable ? "Reachable" : "Unavailable")
            LabeledContent("Node", value: engine.status.nodeConnected ? "Connected" : "Disconnected")
            LabeledContent("Gateway release", value: engine.status.releaseVersion ?? "Unknown")
            LabeledContent("Engine build", value: engine.status.engineBuild ?? "No capability handshake")
            LabeledContent("Last result", value: engine.status.lastResult)
        }
    }

    private var teachingSection: some View {
        SectionBox("Teaching", icon: "hand.point.up.left") {
            Toggle("Watch screen", isOn: $captureEnabled)
            VStack(alignment: .leading, spacing: 6) {
                Text("Allowed applications")
                ForEach(allowedBundleIDs, id: \.self) { bundleID in
                    HStack {
                        Text(bundleID).font(.caption.monospaced())
                        Spacer()
                        Button("Remove", role: .destructive) {
                            allowedBundleIDs.removeAll { $0 == bundleID }
                        }
                    }
                }
                Button("Add frontmost application") { addFrontmostApplication() }
            }
            Picker("Capture detail", selection: $captureLongEdge) {
                Text("1024").tag(1024)
                Text("1600").tag(1600)
                Text("2048").tag(2048)
            }
            Picker("Tooltip width", selection: $tooltipWidth) {
                ForEach([300, 340, 380, 440, 520], id: \.self) { Text("\($0) pt").tag($0) }
            }
            Picker("Pointer size", selection: $cursorSize) {
                ForEach([24, 30, 38], id: \.self) { Text("\($0) pt").tag($0) }
            }
            Picker("Tooltip opacity", selection: $tooltipOpacity) {
                Text("85%").tag(0.85)
                Text("92%").tag(0.92)
                Text("100%").tag(1.0)
            }
            Toggle("Hide tooltip on hover", isOn: $hideTooltipOnHover)
            Toggle("Show status capsule", isOn: $showStatusHUD)
            Button("Reset teaching appearance") {
                captureLongEdge = 1600
                tooltipWidth = 340
                hideTooltipOnHover = true
                cursorSize = 30
                tooltipOpacity = 0.92
                showStatusHUD = true
            }
        }
    }

    private var permissionsSection: some View {
        SectionBox("Permissions", icon: "lock.shield") {
            LabeledContent("Screen Recording", value: engine.status.screenRecordingGranted ? "Allowed" : "Required")
            Button("Open Screen Recording Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            LabeledContent("Accessibility", value: engine.status.accessibilityGranted ? "Allowed" : "Not granted")
            Button("Request Accessibility for approved action") { engine.requestAccessibility() }
            Text("Observing and pointing work without Accessibility. Calla asks only when an approved semantic action needs it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var coursesSection: some View {
        SectionBox("Courses", icon: "books.vertical") {
            Text("Gateway owns authored packs, descriptors, lifecycle, and course build work.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Refresh course library") { engine.refresh() }
                .disabled(!engine.status.gatewayReachable)
            if engine.status.courses.isEmpty {
                Text("No published courses received yet").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(engine.status.courses) { course in
                    Toggle(course.title, isOn: Binding(
                        get: { !hiddenCourseIDs.contains(course.id) },
                        set: { visible in
                            if visible { hiddenCourseIDs.removeAll { $0 == course.id } }
                            else if !hiddenCourseIDs.contains(course.id) { hiddenCourseIDs.append(course.id) }
                        }
                    ))
                    .help(course.summary)
                }
            }
        }
    }

    private var calendarSection: some View {
        SectionBox("Calendar and Pomodoro", icon: "calendar.badge.clock") {
            Toggle("Enable Calendar Start lesson action", isOn: $calendarEnabled)
            Text("Bind eligible event to course. Bound event resumes next runnable lesson and starts event-bounded Pomodoro. Direct Calla start never starts Pomodoro.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if CallaCalendarBindings.all.isEmpty {
                Text("No event bindings").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(CallaCalendarBindings.all) { binding in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(engine.status.courses.first(where: { $0.id == binding.courseID })?.title ?? binding.courseID)
                            Text(binding.eventID).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { CallaCalendarBindings.remove(eventID: binding.eventID) }
                    }
                }
            }
        }
    }

    private var diagnosticsSection: some View {
        SectionBox("Gateway and diagnostics", icon: "stethoscope") {
            LabeledContent("Private Gateway", value: engine.status.gatewayReachable ? "Reachable" : "Unavailable")
            LabeledContent("Current release", value: engine.status.releaseVersion ?? "Unknown")
            LabeledContent("Previous release", value: engine.status.previousGatewayRelease ?? "None")
            LabeledContent("Last update receipt", value: engine.status.lastGatewayUpdate ?? "No update receipt")
            LabeledContent("Socket", value: engine.status.socketPath.isEmpty ? "Not created" : engine.status.socketPath)
            Button("Retry update") { engine.requestGatewayUpdate() }
            Button("Reveal logs") {
                let path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("boringNotch/Calla/logs", isDirectory: true)
                NSWorkspace.shared.activateFileViewerSelecting([path])
            }
        }
    }

    private var preferenceSignature: String {
        "\(captureEnabled)|\(allowedBundleIDs.joined(separator: ","))|\(captureLongEdge)|\(tooltipWidth)|\(hideTooltipOnHover)|\(cursorSize)|\(tooltipOpacity)|\(showStatusHUD)|\(hiddenCourseIDs.joined(separator: ","))"
    }

    private func pushPreferences() { engine.applyCurrentPreferences() }

    private func addFrontmostApplication() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              !allowedBundleIDs.contains(bundleID) else { return }
        allowedBundleIDs.append(bundleID)
    }
}

private struct SectionBox<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
