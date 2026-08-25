//
//  TutorBehaviorPane.swift
//  boringNotch
//

import AppKit
import Defaults
import SwiftUI

/// What the tutor watches, how it points, and what it is allowed to look at.
///
/// Access used to be its own page. It was half of one question: "watch screen"
/// is meaningless without an application on the allow-list, and an empty
/// allow-list was reported on a page you had to already suspect to open. Merged,
/// the pane says what it sees and what it may see in one place.
///
/// The three on-screen values were segmented pickers of five, three and three —
/// but tooltip width, pointer size and opacity are *scales*, and a picker of
/// arbitrary stops on a scale is a slider with the in-between values deleted.
/// They are sliders now, over a preview that redraws as they move, because none
/// of these numbers means anything until you see the tooltip it makes.
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
    @Default(.callaAllowedBundleIDs) private var allowedBundleIDs

    var body: some View {
        SettingsPane(SettingsPage.tutorBehavior) {
            SettingsColumns {
                watchingCard
                accessCard
            } trailing: {
                onScreenCard
                calendarCard
            }
        }
        .onChange(of: captureEnabled) { _, _ in engine.applyCurrentPreferences() }
        .onChange(of: captureLongEdge) { _, _ in engine.applyCurrentPreferences() }
        .onChange(of: tooltipWidth) { _, _ in engine.applyCurrentPreferences() }
        .onChange(of: hideTooltipOnHover) { _, _ in engine.applyCurrentPreferences() }
        .onChange(of: cursorSize) { _, _ in engine.applyCurrentPreferences() }
        .onChange(of: tooltipOpacity) { _, _ in engine.applyCurrentPreferences() }
        .onChange(of: showStatusHUD) { _, _ in engine.applyCurrentPreferences() }
        .onChange(of: allowedBundleIDs) { _, _ in engine.applyCurrentPreferences() }
    }

    // MARK: - Watching

    private var watchingCard: some View {
        SettingCard("Watching") {
            SettingRow("Enable Tutor",
                       detail: "Off stops the engine and hides the Calla tab in the notch.") {
                Toggle("", isOn: $tutorEnabled).labelsHidden().toggleStyle(.switch)
            }
            Divider().opacity(0.35)
            SettingRow("Watch screen",
                       detail: "Off pauses every capture. Calla refuses to teach until it is back on.") {
                Toggle("", isOn: $captureEnabled).labelsHidden().toggleStyle(.switch)
            }
            Divider().opacity(0.35)
            // The cost belongs under the stop, not in a sentence beside the
            // control. This is the number that decides whether a lesson feels
            // instant or takes a quarter of a minute per step, and the old
            // segmented picker put the price in a footnote.
            NotchStopSlider(
                selection: $captureLongEdge,
                stops: [
                    .init(value: 1024, title: "1024", caption: "14k tok · 7s"),
                    .init(value: 1600, title: "1600", caption: "27k tok · 13s"),
                    .init(value: 2048, title: "2048", caption: "44k tok · 21s"),
                ],
                label: "Capture detail",
                detail: "The cost of one look. A lesson takes six to twelve of them.")
            .disabled(!captureEnabled)
        }
    }

    // MARK: - On screen

    private var onScreenCard: some View {
        SettingCard("On screen", detail: "Every value below is drawn above as you move it.") {
            TooltipPreview(width: CGFloat(tooltipWidth),
                           cursor: CGFloat(cursorSize),
                           opacity: tooltipOpacity)

            NotchSlider(value: Binding(get: { Double(tooltipWidth) },
                                       set: { tooltipWidth = Int($0.rounded()) }),
                        range: 280...560, step: 10,
                        label: "Tooltip width",
                        format: { "\(Int($0)) pt" },
                        ends: ("Narrow", "Wide"))
            NotchSlider(value: Binding(get: { Double(cursorSize) },
                                       set: { cursorSize = Int($0.rounded()) }),
                        range: 20...44, step: 2,
                        label: "Pointer size",
                        format: { "\(Int($0)) pt" },
                        ends: ("20", "44"))
            NotchSlider(value: $tooltipOpacity,
                        range: 0.7...1.0,
                        label: "Tooltip opacity",
                        format: { "\(Int(($0 * 100).rounded()))%" },
                        ends: ("See-through", "Solid"),
                        style: .glass)

            Divider().opacity(0.35)

            SettingRow("Move out of the way on hover",
                       detail: "Steps the tooltip aside when your own pointer is over it.") {
                Toggle("", isOn: $hideTooltipOnHover).labelsHidden().toggleStyle(.switch)
            }
            SettingRow("Show the status capsule",
                       detail: "The small capsule naming what Calla is doing.") {
                Toggle("", isOn: $showStatusHUD).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    // MARK: - Access

    private var accessCard: some View {
        SettingCard("What it may look at",
                    detail: allowedBundleIDs.isEmpty
                        ? "Calla cannot teach anything until at least one application is allowed."
                        : "Calla can only see an application on this list, and only while a lesson is running.",
                    tint: accessTint) {
            if allowedBundleIDs.isEmpty {
                SettingsEmptyState(
                    symbol: "app.dashed",
                    title: "No applications allowed",
                    detail: "Bring the app you want a lesson in to the front, then add it.",
                    actionTitle: "Add frontmost application",
                    action: addFrontmostApplication)
            } else {
                ForEach(Array(allowedBundleIDs.enumerated()), id: \.element) { index, id in
                    if index > 0 { Divider().opacity(0.35).padding(.leading, 36) }
                    AllowedAppRow(bundleID: id) {
                        allowedBundleIDs.removeAll { $0 == id }
                    }
                }
                HStack {
                    Button("Add frontmost application", action: addFrontmostApplication)
                        .controlSize(.small)
                    Spacer()
                }
            }

            Divider().opacity(0.35)

            permissionRow("Screen Recording",
                          granted: engine.status.screenRecordingGranted,
                          note: "Calla cannot see the app without it.",
                          action: { engine.requestScreenRecording() })
            permissionRow("Accessibility",
                          granted: engine.status.accessibilityGranted,
                          note: "Only needed when a lesson reaches an action you have approved.",
                          action: { engine.requestAccessibility() })
        }
    }

    private var accessTint: Color? {
        if allowedBundleIDs.isEmpty { return NotchTint.attention }
        return engine.status.screenRecordingGranted ? nil : NotchTint.attention
    }

    private func permissionRow(_ title: String, granted: Bool, note: String,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: NotchSpace.snug) {
            SettingStatusIcon(ok: granted)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(NotchType.rowTitle)
                Text(granted ? "Allowed" : note)
                    .font(NotchType.rowDetail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - Calendar

    private var calendarCard: some View {
        SettingCard("Calendar") {
            SettingRow("Calendar starts lessons",
                       detail: "An event bound to a course starts it, with a Pomodoro bounded by the event.") {
                Toggle("", isOn: $calendarEnabled).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}

/// An allowed application, named the way a person would name it.
///
/// The bundle identifier is the truth and stays visible, but `com.figma.Desktop`
/// is not what anyone calls Figma — and the icon is the fastest way to see that
/// the list contains the app you meant.
private struct AllowedAppRow: View {
    let bundleID: String
    let remove: () -> Void

    private var url: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private var displayName: String {
        guard let url else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }

    var body: some View {
        HStack(spacing: NotchSpace.snug) {
            Group {
                if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable().interpolation(.high)
                } else {
                    Image(systemName: "questionmark.app.dashed")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: NotchSpace.hair) {
                Text(url == nil ? bundleID : displayName).font(NotchType.rowTitle)
                Text(url == nil ? "Not installed on this Mac" : bundleID)
                    .font(NotchType.mono)
                    .foregroundStyle(url == nil ? AnyShapeStyle(NotchTint.attention)
                                                : AnyShapeStyle(.secondary))
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Remove", role: .destructive, action: remove).controlSize(.small)
        }
        .padding(.vertical, 3)
    }
}

/// The tooltip and pointer at the sizes currently chosen.
///
/// Not decoration: "380 pt" is not a width anyone can picture, and the previous
/// control offered five of them with no way to tell which one held a sentence
/// without wrapping. The grid behind it stands in for an application window so
/// the tooltip has something to be a size relative to.
private struct TooltipPreview: View {
    let width: CGFloat
    let cursor: CGFloat
    let opacity: Double

    /// The preview is drawn at about a third scale, so a 380pt tooltip is 127pt
    /// here. The pointer uses the same factor, which is what makes the two
    /// comparable — a pointer drawn at full size beside a shrunken tooltip would
    /// be a lie about the relationship being set.
    private static let scale: CGFloat = 0.34

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                .fill(LinearGradient(colors: [Color.primary.opacity(0.06), Color.primary.opacity(0.02)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                        .strokeBorder(NotchSurface.hairline, lineWidth: 1))

            // Stand-in window furniture, so the tooltip has a scene.
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07))
                    .frame(width: 96, height: 20)
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07))
                    .frame(width: 58, height: 20)
            }
            .padding(14)

            VStack(alignment: .leading, spacing: 3) {
                SettingsMicroLabel(text: "Step 4 of 9", tint: NotchTint.active)
                Text("Select both rows, then press ⇧A to wrap them in an Auto Layout frame.")
                    .font(.system(size: 10))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(width: max(60, width * Self.scale), alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(NotchSurface.raised.opacity(opacity))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 7, y: 3))
            .offset(x: 128, y: 16)

            PointerGlyph()
                .frame(width: cursor * Self.scale * 2.4, height: cursor * Self.scale * 2.4)
                .offset(x: 104, y: 42)
        }
        .frame(height: 98)
        .clipped()
        .animation(NotchMotion.settle, value: width)
        .animation(NotchMotion.settle, value: cursor)
        .animation(NotchMotion.settle, value: opacity)
        .accessibilityHidden(true)
    }
}

/// Calla's pointer, drawn rather than imaged so it scales with the value.
private struct PointerGlyph: View {
    var body: some View {
        GeometryReader { geometry in
            let s = min(geometry.size.width, geometry.size.height) / 30
            Path { path in
                path.move(to: CGPoint(x: 6 * s, y: 3 * s))
                path.addLine(to: CGPoint(x: 6 * s, y: 23 * s))
                path.addLine(to: CGPoint(x: 11.5 * s, y: 18.2 * s))
                path.addLine(to: CGPoint(x: 15 * s, y: 26 * s))
                path.addLine(to: CGPoint(x: 18.6 * s, y: 24.3 * s))
                path.addLine(to: CGPoint(x: 15.2 * s, y: 16.8 * s))
                path.addLine(to: CGPoint(x: 22.5 * s, y: 16.4 * s))
                path.closeSubpath()
            }
            .fill(.white)
            .overlay(
                Path { path in
                    path.move(to: CGPoint(x: 6 * s, y: 3 * s))
                    path.addLine(to: CGPoint(x: 6 * s, y: 23 * s))
                    path.addLine(to: CGPoint(x: 11.5 * s, y: 18.2 * s))
                    path.addLine(to: CGPoint(x: 15 * s, y: 26 * s))
                    path.addLine(to: CGPoint(x: 18.6 * s, y: 24.3 * s))
                    path.addLine(to: CGPoint(x: 15.2 * s, y: 16.8 * s))
                    path.addLine(to: CGPoint(x: 22.5 * s, y: 16.4 * s))
                    path.closeSubpath()
                }
                .stroke(Color.black.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
        }
    }
}
