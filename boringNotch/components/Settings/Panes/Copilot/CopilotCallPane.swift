import Defaults
import KeyboardShortcuts
import SwiftUI

/// The live call: what is being captured right now, what starts it, and what
/// to press.
///
/// The two capture legs are reported separately on purpose. Only your own side
/// being heard is the failure that looks like success — suggestions keep
/// arriving, built from half a conversation.
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

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    var body: some View {
        SettingsPane(SettingsPage.copilotCall) {
            if !copilot.available { notInstalled }
            liveCard
            permissionsCard
                warmUpCard
            personaCard
            notchCard
            panelSizeCard
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
            HStack(spacing: 10) {
                SettingStatusIcon(ok: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Call host is not installed").font(NotchType.rowTitle)
                    Text("The copilot ships with Boring's Calla runtime. Redeploy to install it.")
                        .font(NotchType.rowDetail).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var liveCard: some View {
        SettingCard("Live", tint: copilot.running ? NotchTint.active : nil) {
            VStack(spacing: 10) {
                SettingFact(title: "State", value: copilot.running ? "In a call" : "Idle",
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
                    if let startedAt = copilot.startedAt {
                        SettingFact(title: "Started",
                                    value: startedAt.formatted(date: .omitted, time: .shortened))
                    }
                }
                HStack {
                    if copilot.running {
                        Button("End call", role: .destructive) {
                            engine.endCall()
                        }
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

    /// Grants belong to the capture host, not to Boring and not to the engine.
    ///
    /// TCC keys a grant to the signature of the process that asks, so a prompt
    /// raised anywhere else grants nothing the host can use — which is why this
    /// pane used to be able to report the problem but never fix it.
    /// Unknown is drawn as unknown.
    ///
    /// Until the host has reported once there is nothing to say, and saying
    /// "not granted" would be the same wrong answer the engine used to give by
    /// preflighting on its own behalf.
    private var permissionsResolved: Bool { copilot.hostPermissionsKnown }
    private var permissionsSatisfied: Bool {
        permissionsResolved && copilot.hostMicGranted && copilot.hostScreenGranted
    }

    private var permissionsCard: some View {
        SettingCard("Permissions",
                    detail: "Granted to the capture host, which is the process that actually records.",
                    tint: permissionsResolved && !permissionsSatisfied ? NotchTint.attention : nil) {
            VStack(spacing: 10) {
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
                    detail: "Warms the model before a meeting. Recording always needs your Start or Join button.") {
            VStack(spacing: 12) {
                SettingRow("Warm up before a scheduled meeting",
                           detail: "Two minutes before an event with a call link, the copilot loads its model and opens its connections so the first suggestion is not ten seconds late. Nothing is recorded: the notch shows Join, Start and Not now, and both microphones stay off until you press one.") {
                    Toggle("", isOn: $preroll).labelsHidden().toggleStyle(.switch)
                }
                if preroll {
                    SettingRow("How early",
                               detail: "A cold start takes about ten seconds. The rest is slack for a meeting that begins on time.") {
                        Picker("", selection: $prerollLead) {
                            Text("1 min").tag(60.0)
                            Text("2 min").tag(120.0)
                            Text("5 min").tag(300.0)
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                    if let armed = MeetingPreroll.shared.armed {
                        SettingFact(title: "Armed for", value: armed.title, tint: NotchTint.active)
                    }
                }
            }
        }
    }

    private var personaCard: some View {
        SettingCard("Persona",
                    detail: "How a suggestion is framed. Fixed for the length of a call — changing it applies to the next one. Edit what each one actually says under Prompts.") {
            Picker("", selection: $persona) {
                ForEach(CallaCopilotPersona.all(including: Array(customPersonas.keys)), id: \.self) { value in
                    Text(CallaCopilotPersona.title(value)).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var notchCard: some View {
        SettingCard("In the notch") {
            VStack(spacing: 12) {
                SettingRow("Enable call copilot",
                           detail: "Off hides the copilot tab and stops it starting with a call.") {
                    Toggle("", isOn: $copilotEnabled).labelsHidden().toggleStyle(.switch)
                }
                SettingRow("Reveal new suggestions",
                           detail: "Peeks the newest pointer as it arrives instead of waiting to be opened.") {
                    Toggle("", isOn: $autoReveal).labelsHidden().toggleStyle(.switch)
                }
                SettingRow("Panel transparency",
                           detail: "How much of the desktop shows through the live panel. The panel is hidden from screen recordings and shares for the whole call regardless.") {
                    Slider(value: $glassLevel, in: 0...0.8).frame(width: 160)
                }
            }
        }
    }

    /// How big the live panel is, in both layouts.
    ///
    /// Two layouts rather than one size: expanded carries the transcript beside
    /// the answer and wants room, collapsed is read at a glance and wants to be
    /// out of the way. How much of a call belongs on screen is a matter of
    /// screen size and taste, so it is a setting rather than a constant.
    ///
    /// The ranges are not decoration. The window behind the notch is created
    /// once at a fixed ceiling, so a size outside them would draw a panel the
    /// window cannot contain — the sliders are bounded to what can actually be
    /// shown, and the stored value is clamped again on read.
    /// How big the live panel is, in each layout.
    ///
    /// The card shows the thing it controls. Four numbers on four sliders say
    /// nothing about the shape they make, and the panel is a shape — so each
    /// layout gets a silhouette drawn to scale, hanging from the top edge the
    /// way the notch does, resizing as the sliders move. The two are drawn
    /// against the same maximum, so the collapsed panel is visibly a smaller
    /// thing than the expanded one rather than a second diagram of the same size.
    private var panelSizeCard: some View {
        SettingCard(
            "Panel size",
            detail: "The live call panel, in each layout. Changes apply straight away."
        ) {
            VStack(spacing: 16) {
                panelSizeSection(
                    "Expanded",
                    caption: "Answer and transcript, side by side.",
                    width: $panelWidth,
                    height: $panelHeight,
                    heightRange: CallaPanelBounds.fullHeight)

                Divider()

                panelSizeSection(
                    "Collapsed",
                    caption: "The answer and the caption strip alone.",
                    width: $compactPanelWidth,
                    height: $compactPanelHeight,
                    heightRange: CallaPanelBounds.compactHeight)

                if !CallaPanelSize.isDefault {
                    HStack {
                        Spacer(minLength: 0)
                        Button("Reset to defaults") { CallaPanelSize.reset() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func panelSizeSection(
        _ title: String,
        caption: String,
        width: Binding<Double>,
        height: Binding<Double>,
        heightRange: ClosedRange<CGFloat>
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            PanelSilhouette(width: CGFloat(width.wrappedValue),
                            height: CGFloat(height.wrappedValue),
                            heightRange: heightRange)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(NotchType.rowTitle)
                    Spacer(minLength: 0)
                    // One read-out for the pair. "600 × 340" is the size; two
                    // numbers parked beside two sliders are just slider state.
                    Text("\(Int(width.wrappedValue)) × \(Int(height.wrappedValue))")
                        .font(NotchType.figure)
                        .foregroundStyle(.secondary)
                }
                Text(caption)
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                dimensionSlider("W", value: width, range: CallaPanelBounds.width)
                dimensionSlider("H", value: height, range: heightRange)
            }
        }
    }

    private func dimensionSlider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<CGFloat>
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(NotchType.figure)
                .foregroundStyle(.tertiary)
                .frame(width: 12, alignment: .leading)
            // Continuous, and rounded in the binding. Passing `step:` draws a
            // row of tick marks under the track — a dotted ruler that says
            // nothing here, because the value is already shown as a number.
            Slider(
                value: Binding(
                    get: { value.wrappedValue },
                    set: { value.wrappedValue = (($0 / 2).rounded() * 2) }),
                in: Double(range.lowerBound)...Double(range.upperBound))
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
/// notch does.
///
/// The point is that four numbers do not describe a shape. Drawn against the
/// same maximum in both layouts, the two silhouettes are directly comparable —
/// you can see that the collapsed panel is a smaller thing, not a second
/// diagram of the same size, and you can see the proportion you are choosing
/// before opening a call to find out.
private struct PanelSilhouette: View {
    let width: CGFloat
    let height: CGFloat
    /// The height range this layout is drawn against; the width range is shared.
    let heightRange: ClosedRange<CGFloat>

    /// The frame the silhouette is drawn inside. Fixed, so both sections line
    /// up and the drawing does not resize as the value changes — only the shape
    /// within it does.
    private static let box = CGSize(width: 108, height: 74)

    private var drawn: CGSize {
        // Against the shared maximum, so the two layouts are comparable. The
        // height uses the larger of the two ranges for the same reason.
        let widthFraction = width / CallaPanelBounds.width.upperBound
        let heightFraction = height / CallaPanelBounds.fullHeight.upperBound
        return CGSize(width: max(12, Self.box.width * widthFraction),
                      height: max(8, Self.box.height * heightFraction))
    }

    var body: some View {
        ZStack(alignment: .top) {
            // The screen the notch hangs from.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(NotchSurface.sunken)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(NotchSurface.hairline, lineWidth: 1))

            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 7,
                bottomTrailingRadius: 7, topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Color.effectiveAccent.opacity(0.75))
            .frame(width: drawn.width, height: drawn.height)
        }
        .frame(width: Self.box.width, height: Self.box.height)
        .animation(.easeOut(duration: 0.12), value: drawn)
        .accessibilityHidden(true)
    }
}
