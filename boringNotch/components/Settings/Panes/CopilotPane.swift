import Defaults
import SwiftUI

/// The live-call copilot: what it listens to, who it answers as, and whether it
/// is running right now.
///
/// The call itself is driven from the notch. This pane is for the decisions you
/// make before one starts — persona, transcription model — plus an honest
/// account of the two capture legs, because "is it hearing them or only me" is
/// the question that decides whether any of it is useful.
struct CopilotPane: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @Default(.callaCopilotEnabled) private var copilotEnabled
    @Default(.callaCopilotPersona) private var persona
    @Default(.callaCopilotLiveModel) private var model
    @Default(.callaCopilotAutoReveal) private var autoReveal
    @Default(.callaCopilotArchiveRetranscribe) private var archiveRetranscribe

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    var body: some View {
        SettingsPane(eyebrow: "Tools", title: "Call copilot",
                     detail: "Listens to a call and suggests where to take it next.") {
            if !copilot.available {
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

            SettingCard("Call", tint: copilot.running ? NotchTint.active : nil) {
                VStack(spacing: 10) {
                    SettingFact(title: "State", value: copilot.running ? "In a call" : "Idle",
                                tint: copilot.running ? NotchTint.active : NotchTint.paused)
                    if copilot.running {
                        // Two separate legs, reported separately on purpose. Only
                        // your own side being captured is the failure that looks
                        // like success: suggestions keep arriving, about half a
                        // conversation.
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
                            SettingFact(title: "Started", value: startedAt.formatted(date: .omitted, time: .shortened))
                        }
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

            SettingCard("Persona",
                        detail: "How the copilot frames a suggestion. Fixed for the length of a call — changing it applies to the next one.") {
                Picker("", selection: $persona) {
                    Text("General").tag("generic")
                    Text("Interview").tag("interview")
                    Text("Sales").tag("sales")
                    Text("Support").tag("support")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            SettingCard("Transcription") {
                VStack(spacing: 12) {
                    SettingRow("Live model",
                               detail: "Runs on this Mac. Small hears more accurately; base keeps up on a busy machine.") {
                        Picker("", selection: $model) {
                            Text("Small").tag("whisper-small-en")
                            Text("Base").tag("whisper-base-en")
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 180)
                    }
                    SettingRow("Re-transcribe after the call",
                               detail: "Runs the large model over the saved audio once the call ends. Slower, and more accurate.") {
                        Toggle("", isOn: $archiveRetranscribe).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

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
                }
            }

            if let result = copilot.lastResult {
                SettingCard("Last result") {
                    Text(result).font(NotchType.rowDetail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { engine.refresh() }
        // Persona is sent to the engine so a call started from the notch uses
        // the same one this pane shows.
        .onChange(of: persona) { _, value in engine.setCallPersona(value) }
    }
}
