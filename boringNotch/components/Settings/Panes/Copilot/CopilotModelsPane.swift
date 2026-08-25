//
//  CopilotModelsPane.swift
//  boringNotch
//

import AppKit
import Defaults
import SwiftUI

/// Which model hears the call, and which one answers.
///
/// Intelligence and Transcription were two pages asking one question. The split
/// was not neutral: the speech model and the reasoning model share a budget and
/// a machine — choosing Small whisper and a local brain on the same Mac is a
/// decision about one machine's next four seconds — and a menu between them made
/// that impossible to see. They also both reported a download and both reported
/// a health, in two different vocabularies.
///
/// Merged, the page reads left to right the way a call does: what it hears, what
/// it answers with, and where the audio goes if this Mac cannot.
struct CopilotModelsPane: View {
    @ObservedObject private var engine = CallaEngineClient.shared

    @State private var authToken: String = ""
    @Default(.callaIntelligenceProvider) private var provider
    @Default(.callaIntelligenceLiveTier) private var liveTier
    @Default(.callaIntelligenceSummaryModel) private var summaryModel
    @Default(.callaIntelligenceFallback) private var fallback
    @Default(.callaGatewayStandby) private var gatewayStandby
    @Default(.callaCopilotLiveModel) private var speechModel
    @Default(.callaCopilotArchiveRetranscribe) private var archiveRetranscribe

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    var body: some View {
        SettingsPane(SettingsPage.copilotModels) {
            SettingsColumns {
                SettingsDivider("What it hears")
                hearsCard
            } trailing: {
                SettingsDivider("What it answers with")
                answersCard
            }
            fallbackCard
        }
        .task { engine.refresh() }
    }

    // MARK: - Hears

    private var hearsCard: some View {
        SettingCard("Speech model",
                    detail: "Runs during the call. Small hears more accurately; Base keeps up on a busy machine.") {
            Picker("", selection: $speechModel) {
                Text("Base").tag("whisper-base-en")
                Text("Small").tag("whisper-small-en")
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if let download = copilot.modelDownload {
                VStack(alignment: .leading, spacing: NotchSpace.tight) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(download.model).font(NotchType.rowTitle)
                        Spacer(minLength: 8)
                        Text(downloadFigure(download))
                            .font(NotchType.figure).foregroundStyle(.secondary)
                    }
                    SettingProgressBar(done: megabytes(download.receivedBytes),
                                       total: megabytes(download.totalBytes),
                                       active: download.isActive)
                    if let message = download.message {
                        Text(message)
                            .font(NotchType.rowDetail).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                SettingRow("Fetch it now",
                           detail: "Downloads ahead of a call instead of at the start of one.") {
                    Button("Download") { engine.prefetchModel(speechModel) }
                        .controlSize(.small)
                        .disabled(!copilot.available)
                }
            }

            Divider().opacity(0.35)

            SettingRow("Re-transcribe after the call",
                       detail: "The large model over the saved audio once nothing is waiting on it. Slower, and more accurate.") {
                Toggle("", isOn: $archiveRetranscribe).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private func downloadFigure(_ download: CallaModelDownload) -> String {
        guard download.totalBytes > 0 else { return stateLabel(download.state) }
        return "\(megabytes(download.receivedBytes)) of \(megabytes(download.totalBytes)) MB"
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "downloading": return "Downloading"
        case "verifying": return "Verifying"
        case "ready": return "On this Mac"
        case "failed": return "Failed"
        default: return state
        }
    }

    private func megabytes(_ bytes: Int64) -> Int { Int(bytes / 1_048_576) }

    // MARK: - Answers

    private var answersCard: some View {
        SettingCard("Answers from",
                    detail: "Local runs on this Mac and does not need the gateway host to be reachable.") {
            Picker("", selection: $provider) {
                Text("This Mac").tag("local")
                Text("Gateway").tag("gateway")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: provider) { _, new in
                engine.setIntelligence(provider: new, tier: liveTier,
                                       summaryModel: summaryModel, fallback: fallback)
            }

            SettingRow("Antigravity CLI",
                       detail: copilot.agyAvailable
                        ? (copilot.agyVersion.map { "agy \($0)" } ?? "Installed")
                        : "Not installed — install agy, or leave this set to Gateway.") {
                SettingBadge(copilot.agyAvailable ? "Ready" : "Missing",
                             tint: copilot.agyAvailable ? NotchTint.healthy : NotchTint.attention)
            }

            if copilot.agyAvailable { signIn }

            Divider().opacity(0.35)

            SettingRow("Live tier", detail: "Balanced is Gemini Flash. Applies from the next call.") {
                Picker("", selection: $liveTier) {
                    Text("Fast").tag("fast")
                    Text("Balanced").tag("balanced")
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 170)
                .disabled(provider != "local")
                .onChange(of: liveTier) { _, new in
                    engine.setIntelligence(provider: provider, tier: new)
                }
            }

            SettingRow("End-of-call summary",
                       detail: "One deeper pass once the call is over, where a slower model costs nothing that matters.") {
                Picker("", selection: $summaryModel) {
                    Text("Gemini 3.1 Pro").tag("gemini-3.1-pro-high")
                    Text("Sonnet 4.6").tag("claude-sonnet-4-6")
                }
                .labelsHidden().frame(width: 170)
                .disabled(provider != "local")
                .onChange(of: summaryModel) { _, new in
                    engine.setIntelligence(provider: provider, summaryModel: new)
                }
            }

            // Which brain is *actually* answering, which is not always the one
            // chosen above: a local failure hands the call to the gateway
            // mid-flight, and that has to be visible.
            if copilot.running {
                Divider().opacity(0.35)
                SettingRow("Answering now", detail: copilot.providerDetail ?? "—") {
                    SettingBadge(copilot.activeProvider == "local" ? "This Mac" : "Gateway",
                                 tint: copilot.activeProvider == "local" ? NotchTint.active : nil)
                }
            }
        }
    }

    @ViewBuilder private var signIn: some View {
        SettingRow("Google account",
                   detail: copilot.agyLoggedIn
                    ? (copilot.agyAccount ?? "Authenticated")
                    : "Not signed in — sign in so agy can reach Gemini.") {
            if copilot.agyLoggedIn {
                HStack(spacing: 8) {
                    // Forces a fresh sign-in. Without `force` this does nothing
                    // when credentials exist, which is useless in exactly the
                    // case people press it: signed in on paper, failing in
                    // practice.
                    Button("Sign in again") { engine.loginAgy(force: true) }.controlSize(.small)
                    Button("Sign out") { engine.signOutAgy() }.controlSize(.small)
                }
            } else {
                Button("Sign in") { engine.loginAgy() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }

        if copilot.agyBackupAvailable, !copilot.agyLoggedIn {
            SettingRow("Previous sign-in",
                       detail: "Kept aside when you signed out. Put it back without going through Google again.") {
                Button("Restore") { engine.restoreSignIn() }.controlSize(.small)
            }
        }

        if let url = copilot.agyLoginURL {
            SettingRow("Sign-in link", detail: "Open this if your browser did not.") {
                HStack(spacing: 8) {
                    Button("Open") {
                        if let target = URL(string: url) { NSWorkspace.shared.open(target) }
                    }.controlSize(.small)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }.controlSize(.small)
                }
            }
        }

        // Driven by agy actually sitting at its paste prompt, rather than by
        // matching words in the last status message.
        if copilot.canAcceptCode {
            SettingRow("Authorization code",
                       detail: "Paste the code the sign-in page gave you. It expires quickly.") {
                HStack(spacing: 8) {
                    TextField("Code", text: $authToken)
                        .textFieldStyle(.roundedBorder).frame(minWidth: 140)
                        .onSubmit { submitCode() }
                    Button("Submit", action: submitCode)
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(authToken.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func submitCode() {
        let code = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        engine.submitAgyToken(code)
        authToken = ""
    }

    // MARK: - Fallback

    /// One control for two questions that were previously answered separately
    /// and inconsistently: may the gateway answer, and when does its socket open.
    ///
    /// They were never independent. The socket connected on every call and
    /// received every turn whether or not the gateway was allowed to answer — so
    /// "fall back: off" still shipped the transcript, and every call paid ~1s of
    /// handshake before its microphone opened.
    ///
    /// A stop slider rather than a segmented picker because the three positions
    /// are ordered: they are increasing amounts of this call leaving the machine,
    /// and that ordering is the whole point of the control.
    private var fallbackCard: some View {
        SettingCard("If this Mac cannot answer",
                    detail: "A warm gateway hears the call as it happens, so a handover is instant. None of these delay recording.") {
            NotchStopSlider(
                selection: standbyBinding,
                stops: [
                    .init(value: "off", title: "Never", caption: "nothing sent"),
                    .init(value: "on-failure", title: "On failure", caption: "sends on handover"),
                    .init(value: "warm", title: "Keep warm", caption: "sends throughout"),
                ],
                detail: standbyDetail)
            .disabled(provider != "local")

            GatewayFlow(mode: standbyBinding.wrappedValue,
                        host: engine.status.gatewayReachable ? "Reachable" : "Unavailable")
        }
    }

    /// `fallback` stays the flag the engine and the advisor already understand —
    /// "may the gateway answer" — and is derived rather than picked, because
    /// "never connect" and "may answer" is not a state that means anything.
    private var standbyBinding: Binding<String> {
        Binding(
            get: { fallback ? gatewayStandby : "off" },
            set: { mode in
                let allowed = mode != "off"
                fallback = allowed
                if allowed { gatewayStandby = mode }
                engine.setIntelligence(provider: provider, fallback: allowed,
                                       gatewayStandby: allowed ? mode : "off")
            })
    }

    private var standbyDetail: String {
        switch standbyBinding.wrappedValue {
        case "off":
            return "The gateway is never opened, so no part of the transcript is sent to it. A local brain that fails simply says so — there is nowhere to hand over to."
        case "on-failure":
            return "The call stays on this Mac while it is going well. On a failure the socket opens and the recent transcript is sent so the handover is not blind, which costs a moment at exactly the wrong time."
        default:
            return "Every turn is sent to the gateway as it is transcribed, so it can take over mid-sentence. Its suggestions stay hidden unless the local brain gives up."
        }
    }
}

/// Where the transcript actually goes, for the mode chosen above.
///
/// "Nothing leaves this Mac" and "every turn is sent to the gateway" is a fact
/// about data flow, and a sentence under a picker is the wrong place to keep it —
/// it is the sentence people skip, and it is the one that matters most.
private struct GatewayFlow: View {
    let mode: String
    let host: String

    private var label: String {
        switch mode {
        case "off": return "nothing sent"
        case "on-failure": return "only on failure"
        default: return "every turn, live"
        }
    }

    private var tint: Color {
        switch mode {
        case "off": return NotchTint.paused
        case "on-failure": return NotchTint.attention
        default: return NotchTint.active
        }
    }

    var body: some View {
        HStack(spacing: NotchSpace.snug) {
            node(symbol: "laptopcomputer", title: "This Mac", detail: "agy", tint: NotchTint.active)

            VStack(spacing: 2) {
                SettingsMicroLabel(text: label, tint: tint)
                ZStack(alignment: .trailing) {
                    Rectangle()
                        .fill(LinearGradient(colors: [tint, tint.opacity(0.25)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(height: 2)
                        .opacity(mode == "off" ? 0.25 : 1)
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(tint)
                        .opacity(mode == "off" ? 0.25 : 1)
                }
            }
            .frame(maxWidth: .infinity)

            node(symbol: "network", title: "Gateway", detail: host, tint: NotchTint.paused)
        }
        .animation(NotchMotion.settle, value: mode)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Transcript sent to the gateway: \(label)")
    }

    private func node(symbol: String, title: String, detail: String, tint: Color) -> some View {
        HStack(spacing: NotchSpace.tight) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(NotchType.rowDetail)
                Text(detail).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, NotchSpace.snug)
        .padding(.vertical, NotchSpace.tight)
        .background(tint.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1))
    }
}
