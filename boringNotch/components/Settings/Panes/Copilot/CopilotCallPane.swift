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
    @ObservedObject private var detector = MeetingDetector.shared

    @Default(.callaCopilotEnabled) private var copilotEnabled
    @Default(.callaCopilotPersona) private var persona
    @Default(.callaCopilotLiveModel) private var model
    @Default(.callaCopilotAutoReveal) private var autoReveal
    @Default(.callaCopilotAutoStartOnMeeting) private var autoStart
    @Default(.callaCopilotPrerollEnabled) private var preroll
    @Default(.callaCopilotPrerollLead) private var prerollLead
    @Default(.callaCopilotGlassLevel) private var glassLevel
    @Default(.callaCopilotCustomPersonas) private var customPersonas

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    var body: some View {
        SettingsPane(SettingsPage.copilotCall) {
            if !copilot.available { notInstalled }
            liveCard
            permissionsCard
            autoStartCard
            personaCard
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
                            // Ending by hand outranks the detector, or it starts
                            // the call again four seconds later.
                            MeetingDetector.shared.suppressUntilMicIdle()
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

    private var autoStartCard: some View {
        SettingCard("Start on its own",
                    detail: "A copilot you have to remember to start is one that is off during the question worth answering.") {
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
                Divider()
                SettingRow("Start when a meeting starts",
                           detail: "Begins when your microphone goes live and something corroborates it — a conferencing app running, or the speakers live at the same time, which is what a two-way conversation looks like. Ends when the mic goes quiet. Ending a call by hand keeps it off until then.") {
                    Toggle("", isOn: $autoStart).labelsHidden().toggleStyle(.switch)
                }
                // The two raw signals, so the detector can be understood rather
                // than guessed at when it does something surprising.
                SettingFact(title: "Microphone in use",
                            value: detector.microphoneInUse ? "Yes" : "No",
                            tint: detector.microphoneInUse ? NotchTint.active : NotchTint.paused)
                SettingFact(title: "Conferencing app running",
                            value: detector.meetingAppRunning ? "Yes" : "No",
                            tint: detector.meetingAppRunning ? NotchTint.active : NotchTint.paused)
                SettingFact(title: "Speakers live",
                            value: detector.speakerActive ? "Yes" : "No",
                            tint: detector.speakerActive ? NotchTint.active : NotchTint.paused)
                SettingFact(title: "Reads as a meeting",
                            value: detector.inMeeting ? "Yes" : "No",
                            tint: detector.inMeeting ? NotchTint.healthy : NotchTint.paused)
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

    // The three copilot recorders moved to Settings › Shortcuts, which is now
    // the only place any of them live. Three panes used to own recorders, so
    // "what is bound to ⌥⌘C" could not be answered from one screen and nothing
    // stopped two features claiming the same chord.

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}
