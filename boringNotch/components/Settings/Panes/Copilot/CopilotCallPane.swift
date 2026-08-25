//
//  CopilotCallPane.swift
//  boringNotch
//

import Defaults
import KeyboardShortcuts
import SwiftUI

/// The live call: what is being captured right now, what starts it, and what
/// the panel looks like while it runs.
///
/// The two capture legs are reported separately on purpose. Only your own side
/// being heard is the failure that looks like success — suggestions keep
/// arriving, built from half a conversation.
///
/// Laid out in two columns because it was seven cards in one scroll: the state
/// of the call and the permissions it needs on the left, the shape of the panel
/// and the pre-roll on the right. Nothing here is below the fold at the window's
/// default size, which is the whole point.
struct CopilotCallPane: View {
    @ObservedObject private var engine = CallaEngineClient.shared

    @Default(.callaCopilotEnabled) private var copilotEnabled
    @Default(.callaCopilotPersona) private var persona
    @Default(.callaCopilotLiveModel) private var model
    @Default(.callaCopilotAutoReveal) private var autoReveal
    @Default(.callaCopilotPrerollEnabled) private var preroll
    @Default(.callaCopilotPrerollLead) private var prerollLead
    @Default(.callaCopilotGlassLevel) private var glassLevel
    @Default(.callaCopilotCustomPersonas) private var customPersonas
    @Default(.callaPanelWidth) private var panelWidth
    @Default(.callaPanelHeight) private var panelHeight
    @Default(.callaCompactPanelWidth) private var compactPanelWidth
    @Default(.callaCompactPanelHeight) private var compactPanelHeight

    /// Which layout the size controls are driving. One set of controls for two
    /// layouts rather than two stacked sets, which is what pushed this card past
    /// a screen; the silhouette draws both either way, so the one you are not
    /// editing is still visible as an outline.
    @State private var editingCompact = false

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    var body: some View {
        SettingsPane(SettingsPage.copilotCall, nav: [.copilotModels, .copilotHistory]) {
            if !copilot.available { notInstalled }
            SettingsColumns {
                liveCard
                permissionsCard
            } trailing: {
                panelSizeCard
                warmUpCard
            }
            notchCard
            if let result = copilot.lastResult {
                SettingCard("Last result") {
                    Text(result)
                        .font(NotchType.rowDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { engine.refresh() }
        .onChange(of: persona) { _, value in engine.setCallPersona(value) }
    }

    // MARK: - Cards

    private var notInstalled: some View {
        SettingCard(tint: NotchTint.attention) {
            HStack(spacing: NotchSpace.snug) {
                SettingStatusIcon(ok: false)
                VStack(alignment: .leading, spacing: NotchSpace.hair) {
                    Text("Call host is not installed").font(NotchType.rowTitle)
                    Text("The copilot ships with Boring's Calla runtime. Redeploy to install it.")
                        .font(NotchType.rowDetail).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var liveCard: some View {
        SettingCard("Right now", tint: copilot.running ? NotchTint.active : nil) {
            VStack(spacing: NotchSpace.snug) {
                SettingFact(title: "State", value: stateValue,
                            tint: copilot.running ? NotchTint.active : NotchTint.paused)
                if copilot.running {
                    SettingFact(title: "Your microphone",
                                value: copilot.micActive ? "Capturing" : "Silent",
                                tint: copilot.micActive ? NotchTint.healthy : NotchTint.attention)
                    SettingFact(title: "The other party",
                                value: copilot.systemAudioActive ? "Capturing" : "Not captured",
                                tint: copilot.systemAudioActive ? NotchTint.healthy : NotchTint.attention)
                    SettingFact(title: "Gateway",
                                value: copilot.gatewayConnected ? "Connected" : "Disconnected",
                                tint: copilot.gatewayConnected ? NotchTint.healthy : NotchTint.attention)
                    SettingFact(title: "Turns heard", value: "\(copilot.turnCount)")
                }
                HStack {
                    if copilot.running {
                        Button("End call", role: .destructive) { engine.endCall() }
                    } else {
                        Button("Start call") { engine.startCall(persona: persona, model: model) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!copilot.available)
                    }
                    Spacer()
                }
                .controlSize(.small)
            }
        }
    }

    private var stateValue: String {
        if copilot.isRecording {
            guard let startedAt = copilot.startedAt else { return "In a call" }
            let elapsed = Int(Date().timeIntervalSince(startedAt))
            return String(format: "In a call · %d:%02d", elapsed / 60, elapsed % 60)
        }
        if copilot.prewarming { return "Warm, not recording" }
        if copilot.starting { return "Starting" }
        return "Idle"
    }

    /// Grants belong to the capture host, not to Boring and not to the engine.
    ///
    /// TCC keys a grant to the signature of the process that asks, so a prompt
    /// raised anywhere else grants nothing the host can use — which is why this
    /// pane used to be able to report the problem but never fix it. Unknown is
    /// drawn as unknown: until the host has reported once there is nothing to
    /// say, and saying "not granted" would be the same wrong answer the engine
    /// used to give by preflighting on its own behalf.
    private var permissionsResolved: Bool { copilot.hostPermissionsKnown }
    private var permissionsSatisfied: Bool {
        permissionsResolved && copilot.hostMicGranted && copilot.hostScreenGranted
    }

    private var permissionsCard: some View {
        SettingCard("Permissions",
                    detail: "Held by the capture host, which is the process that actually records.",
                    tint: permissionsResolved && !permissionsSatisfied ? NotchTint.attention : nil) {
            VStack(spacing: NotchSpace.snug) {
                permissionRow("Microphone",
                              detail: "Your own side of the call.",
                              granted: copilot.hostMicGranted)
                permissionRow("Screen recording",
                              detail: "The other party's audio. Without it the copilot only hears you, and its pointers are built almost entirely from what they said.",
                              granted: copilot.hostScreenGranted)
                if !permissionsResolved {
                    Text("Checking what the capture host holds…")
                        .font(NotchType.rowDetail)
                        .foregroundStyle(.secondary)
                } else if !permissionsSatisfied {
                    HStack {
                        Text("Already denied once? macOS will not ask again — turn it on by hand.")
                            .font(NotchType.rowDetail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Open System Settings") { openPrivacySettings() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func permissionRow(_ title: String, detail: String, granted: Bool) -> some View {
        SettingRow(title, detail: detail) {
            HStack(spacing: 8) {
                if !permissionsResolved {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                } else {
                    SettingStatusIcon(ok: granted)
                    if !granted {
                        Button("Grant") { engine.requestCopilotPermissions() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var warmUpCard: some View {
        SettingCard("Before a scheduled meeting",
                    detail: "Loads the model early so the first suggestion is not ten seconds late. Nothing is recorded: the notch shows Join, Start and Not now, and both microphones stay off until you press one.") {
            SettingRow("Warm up ahead of an event") {
                Toggle("", isOn: $preroll).labelsHidden().toggleStyle(.switch)
            }
            if preroll {
                // A scale, so a slider rather than a picker: the positions are
                // ordered and the reader is trading slack against a warm model
                // sitting idle. A cold start takes about ten seconds; the rest
                // is slack for a meeting that begins on time.
                NotchStopSlider(
                    selection: Binding(get: { prerollLead }, set: { prerollLead = $0 }),
                    stops: [
                        .init(value: 60.0, title: "1 min"),
                        .init(value: 120.0, title: "2 min"),
                        .init(value: 300.0, title: "5 min"),
                        .init(value: 600.0, title: "10 min"),
                    ],
                    label: "How early")
                if let armed = MeetingPreroll.shared.armed {
                    SettingFact(title: "Armed for", value: armed.title, tint: NotchTint.active)
                }
            }
        }
    }

    // MARK: - Panel size

    /// How big the live panel is, in each layout.
    ///
    /// The card shows the thing it controls. Four numbers on four sliders say
    /// nothing about the shape they make, and the panel is a shape — so the
    /// silhouette is drawn to scale, hanging from the top edge the way the notch
    /// does, and its own right and bottom edges are draggable. The sliders below
    /// are the fine adjustment, not the only way in.
    ///
    /// The ranges are not decoration. The window behind the notch is created once
    /// at a fixed ceiling, so a size outside them would draw a panel the window
    /// cannot contain.
    private var panelSizeCard: some View {
        SettingCard("Panel size",
                    detail: "Drag the panel's own edges, or use the sliders. Changes apply straight away.") {
            HStack {
                Picker("", selection: $editingCompact) {
                    Text("Expanded").tag(false)
                    Text("Collapsed").tag(true)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 190)
                Spacer(minLength: 8)
                // One read-out for the pair. "600 × 340" is the size; two numbers
                // parked beside two sliders are just slider state.
                Text("\(Int(activeWidth.wrappedValue)) × \(Int(activeHeight.wrappedValue))")
                    .font(NotchType.figure).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            HStack(alignment: .top, spacing: NotchSpace.card) {
                PanelSilhouette(width: activeWidth,
                                height: activeHeight,
                                heightRange: activeHeightRange,
                                ghost: ghostSize)

                VStack(alignment: .leading, spacing: NotchSpace.snug) {
                    NotchSlider(value: activeWidth,
                                range: widthRange,
                                step: 2,
                                label: "Width",
                                format: { "\(Int($0)) pt" },
                                ends: ("\(Int(CallaPanelBounds.width.lowerBound))",
                                       "\(Int(CallaPanelBounds.width.upperBound))"))
                    NotchSlider(value: activeHeight,
                                range: heightRange,
                                step: 2,
                                label: "Height",
                                format: { "\(Int($0)) pt" },
                                ends: ("\(Int(activeHeightRange.lowerBound))",
                                       "\(Int(activeHeightRange.upperBound))"))
                }
            }

            if !CallaPanelSize.isDefault {
                HStack {
                    Spacer(minLength: 0)
                    Button("Reset to defaults") { CallaPanelSize.reset() }
                        .controlSize(.small)
                }
            }
        }
    }

    private var widthRange: ClosedRange<Double> {
        Double(CallaPanelBounds.width.lowerBound)...Double(CallaPanelBounds.width.upperBound)
    }

    private var heightRange: ClosedRange<Double> {
        Double(activeHeightRange.lowerBound)...Double(activeHeightRange.upperBound)
    }

    private var activeWidth: Binding<Double> {
        editingCompact ? $compactPanelWidth : $panelWidth
    }

    private var activeHeight: Binding<Double> {
        editingCompact ? $compactPanelHeight : $panelHeight
    }

    private var activeHeightRange: ClosedRange<CGFloat> {
        editingCompact ? CallaPanelBounds.compactHeight : CallaPanelBounds.fullHeight
    }

    /// The layout not currently being edited, drawn as an outline so the two are
    /// visibly one panel in two states rather than two unrelated rectangles.
    private var ghostSize: CGSize {
        editingCompact
            ? CGSize(width: panelWidth, height: panelHeight)
            : CGSize(width: compactPanelWidth, height: compactPanelHeight)
    }

    private var notchCard: some View {
        SettingCard("In the notch") {
            HStack(alignment: .top, spacing: NotchSpace.group) {
                VStack(spacing: NotchSpace.row) {
                    SettingRow("Enable call copilot",
                               detail: "Off hides the copilot tab and stops it starting with a call.") {
                        Toggle("", isOn: $copilotEnabled).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Reveal new suggestions",
                               detail: "Peeks the newest pointer as it arrives instead of waiting to be opened.") {
                        Toggle("", isOn: $autoReveal).labelsHidden().toggleStyle(.switch)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: NotchSpace.tight) {
                    // The glass style rather than the amount style: the rail is
                    // the transparency it is setting, so the control shows the
                    // answer instead of describing it.
                    NotchSlider(value: $glassLevel,
                                range: 0...0.8,
                                label: "Panel transparency",
                                format: { "\(Int($0 / 0.8 * 100))%" },
                                ends: ("Opaque", "See-through"),
                                style: .glass)
                    Text("How much of the desktop shows through the live panel. It is hidden from screen recordings and shares for the whole call regardless.")
                        .font(NotchType.rowDetail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // The three copilot recorders moved to Settings › Shortcuts, which is now
    // the only place any of them live. Three panes used to own recorders, so
    // "what is bound to ⌥⌘C" could not be answered from one screen and nothing
    // stopped two features claiming the same chord.

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// A scale drawing of the call panel, hanging from the top edge the way the
/// notch does — and the primary control for its size.
///
/// Four numbers do not describe a shape, so the shape is what you grab. The two
/// handles are the panel's own right and bottom edges, which is the gesture
/// anyone already has for resizing a rectangle; the sliders underneath exist for
/// the pixel and for the keyboard.
///
/// Both layouts are drawn against the same maximum, so the collapsed panel is
/// visibly a smaller thing than the expanded one rather than a second diagram of
/// the same size.
private struct PanelSilhouette: View {
    @Binding var width: Double
    @Binding var height: Double
    /// The height range this layout is drawn against; the width range is shared.
    let heightRange: ClosedRange<CGFloat>
    /// The other layout, as an outline.
    let ghost: CGSize

    /// The frame the silhouette is drawn inside. Fixed, so the drawing does not
    /// resize as the value changes — only the shape within it does.
    private static let box = CGSize(width: 118, height: 80)
    private static let inset: CGFloat = 6

    @State private var dragStart: CGSize?

    private func drawn(_ size: CGSize) -> CGSize {
        let w = Self.box.width * (size.width / CallaPanelBounds.width.upperBound)
        let h = (Self.box.height - Self.inset)
            * (size.height / CallaPanelBounds.fullHeight.upperBound)
        return CGSize(width: max(12, w), height: max(8, h))
    }

    private var current: CGSize {
        drawn(CGSize(width: width, height: height))
    }

    var body: some View {
        ZStack(alignment: .top) {
            // The screen the notch hangs from.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(NotchSurface.sunken)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(NotchSurface.hairline, lineWidth: 1))

            // The notch itself, so the panel is seen hanging from something.
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 2,
                                   bottomTrailingRadius: 2, topTrailingRadius: 0,
                                   style: .continuous)
                .fill(Color.black)
                .frame(width: 26, height: Self.inset)

            let ghostDrawn = drawn(ghost)
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 6,
                                   bottomTrailingRadius: 6, topTrailingRadius: 0,
                                   style: .continuous)
                .strokeBorder(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .frame(width: ghostDrawn.width, height: ghostDrawn.height)
                .offset(y: Self.inset)

            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 7,
                                   bottomTrailingRadius: 7, topTrailingRadius: 0,
                                   style: .continuous)
                .fill(Color.effectiveAccent.opacity(0.75))
                .frame(width: current.width, height: current.height)
                .offset(y: Self.inset)
                .overlay(alignment: .top) {
                    handles
                }
        }
        .frame(width: Self.box.width, height: Self.box.height)
        .animation(.easeOut(duration: 0.12), value: current)
    }

    private var handles: some View {
        ZStack(alignment: .top) {
            Color.clear.frame(width: current.width, height: current.height)
            // Right edge: width.
            Capsule()
                .fill(.white)
                .frame(width: 5, height: 14)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .offset(x: current.width / 2, y: current.height / 2 - 7)
                .gesture(edgeDrag(horizontal: true))
            // Bottom edge: height.
            Capsule()
                .fill(.white)
                .frame(width: 14, height: 5)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .offset(y: current.height - 2.5)
                .gesture(edgeDrag(horizontal: false))
        }
        .offset(y: Self.inset)
        .accessibilityHidden(true)
    }

    /// Drag in drawing points, applied in panel points. The scale factors are
    /// the same ones the drawing uses, so a handle moved an inch moves the panel
    /// the amount the drawing says it does.
    private func edgeDrag(horizontal: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { drag in
                let start = dragStart ?? CGSize(width: width, height: height)
                if dragStart == nil { dragStart = start }
                if horizontal {
                    let perPoint = CallaPanelBounds.width.upperBound / Self.box.width
                    width = clamp(start.width + drag.translation.width * perPoint,
                                  CallaPanelBounds.width)
                } else {
                    let perPoint = CallaPanelBounds.fullHeight.upperBound
                        / (Self.box.height - Self.inset)
                    height = clamp(start.height + drag.translation.height * perPoint, heightRange)
                }
            }
            .onEnded { _ in dragStart = nil }
    }

    private func clamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>) -> Double {
        Double(min(max(value, range.lowerBound), range.upperBound))
    }
}
