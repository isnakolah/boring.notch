import Defaults
import SwiftUI

/// Which brain answers a call.
///
/// Until now there was exactly one: a websocket to a Gateway on a Tailscale host,
/// with no picker and no repair path, so an unreachable host meant no suggestions
/// at all. The local option runs Google's Antigravity CLI (`agy`) on this Mac
/// against a resident language server, which answers in about the same time as the
/// remote one — roughly 2.5-3.5s — and needs no host to be up.
struct CopilotIntelligencePane: View {
    @ObservedObject private var engine = CallaEngineClient.shared

    @State private var authToken: String = ""
    @Default(.callaIntelligenceProvider) private var provider
    @Default(.callaIntelligenceLiveTier) private var liveTier
    @Default(.callaIntelligenceSummaryModel) private var summaryModel
    @Default(.callaIntelligenceFallback) private var fallback
    @Default(.callaGatewayStandby) private var gatewayStandby

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    private func submitCode() {
        let code = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        engine.submitAgyToken(code)
        authToken = ""
    }

    var body: some View {
        SettingsPane(.copilotIntelligence) {
            providerCard
            localCard
            summaryCard
            fallbackCard
        }
        .task { engine.refresh() }
    }

    private var providerCard: some View {
        SettingCard(
            "Answers from",
            detail: "Local runs on this Mac and does not need the gateway host to be reachable."
        ) {
            VStack(spacing: 12) {
                Picker("", selection: $provider) {
                    Text("This Mac").tag("local")
                    Text("Gateway").tag("gateway")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: provider) { _, new in
                    engine.setIntelligence(
                        provider: new,
                        tier: liveTier,
                        summaryModel: summaryModel,
                        fallback: fallback
                    )
                }

                SettingRow(
                    "Antigravity CLI",
                    detail: copilot.agyAvailable
                        ? (copilot.agyVersion.map { "agy \($0)" } ?? "Installed")
                        : "Not installed — install agy, or leave this set to Gateway."
                ) {
                    SettingBadge(
                        copilot.agyAvailable ? "Ready" : "Missing",
                        tint: copilot.agyAvailable ? NotchTint.healthy : NotchTint.attention
                    )
                }

                if copilot.agyAvailable {
                    SettingRow(
                        "Google account",
                        detail: copilot.agyLoggedIn
                            ? (copilot.agyAccount ?? "Authenticated")
                            : "Not signed in — sign in so agy can reach Gemini."
                    ) {
                        if copilot.agyLoggedIn {
                            // Forces a fresh sign-in. Without `force` this does
                            // nothing when credentials exist, which is useless in
                            // exactly the case people press it: signed in on
                            // paper, failing in practice.
                            HStack(spacing: 8) {
                                Button("Sign in again") { engine.loginAgy(force: true) }
                                    .controlSize(.small)
                                Button("Sign out") { engine.signOutAgy() }
                                    .controlSize(.small)
                            }
                        } else {
                            Button("Sign in") { engine.loginAgy() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                    }

                    // Only offered when there is something to undo: a sign-out
                    // keeps the old credential rather than destroying it, so a
                    // sign-out pressed by mistake is not a dead end.
                    if copilot.agyBackupAvailable, !copilot.agyLoggedIn {
                        SettingRow(
                            "Previous sign-in",
                            detail: "Kept aside when you signed out. Put it back without going through Google again."
                        ) {
                            Button("Restore") { engine.restoreSignIn() }
                                .controlSize(.small)
                        }
                    }

                    SettingRow(
                        "Rehearse the sign-in",
                        detail: "Runs the whole flow against a throwaway home directory, so the steps can be watched without signing out."
                    ) {
                        Button("Test") { engine.testSignInFlow() }
                            .controlSize(.small)
                    }

                    // Shown from the sign-in URL agy printed, not from a guess
                    // about whether a browser opened. If it did not, this is the
                    // way in.
                    if let url = copilot.agyLoginURL {
                        SettingRow(
                            "Sign-in link",
                            detail: "Open this if your browser did not."
                        ) {
                            HStack(spacing: 8) {
                                Button("Open") {
                                    if let target = URL(string: url) {
                                        NSWorkspace.shared.open(target)
                                    }
                                }
                                .controlSize(.small)
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url, forType: .string)
                                }
                                .controlSize(.small)
                            }
                        }
                    }

                    // Driven by agy actually sitting at its paste prompt, rather
                    // than by matching words in the last status message — which
                    // any other action could overwrite mid-sign-in.
                    if copilot.canAcceptCode {
                        SettingRow(
                            "Authorization code",
                            detail: "Paste the code the sign-in page gave you. It expires quickly."
                        ) {
                            HStack(spacing: 8) {
                                TextField("Code", text: $authToken)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(minWidth: 160)
                                    .onSubmit { submitCode() }
                                Button("Submit", action: submitCode)
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(authToken.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                    }

                    if let result = copilot.lastResult, !result.isEmpty {
                        SettingRow("Last sign-in step", detail: result) { EmptyView() }
                    }
                }

                // Which brain is *actually* answering, which is not always the one
                // chosen above: a local failure hands the call to the gateway
                // mid-flight, and that has to be visible.
                if copilot.running {
                    SettingRow(
                        "Answering now",
                        detail: copilot.providerDetail ?? "—"
                    ) {
                        SettingBadge(
                            copilot.activeProvider == "local" ? "This Mac" : "Gateway",
                            tint: copilot.activeProvider == "local" ? NotchTint.active : nil
                        )
                    }
                }
            }
        }
    }

    private var localCard: some View {
        SettingCard(
            "Live model",
            detail: """
            Tiers, not model names: the only transport quick enough for a live call \
            picks a tier. Balanced is Gemini Flash.
            """
        ) {
            VStack(spacing: 12) {
                Picker("", selection: $liveTier) {
                    Text("Fast").tag("fast")
                    Text("Balanced").tag("balanced")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(provider != "local")
                .onChange(of: liveTier) { _, new in
                    engine.setIntelligence(provider: provider, tier: new)
                }

                SettingRow(
                    "Applies from the next call",
                    detail: "A call binds its brain when it starts, so changes wait for the next one."
                ) { EmptyView() }
            }
        }
    }

    private var summaryCard: some View {
        SettingCard(
            "End-of-call summary",
            detail: """
            One deeper pass once the call is over, where a slower, better model costs \
            nothing that matters.
            """
        ) {
            Picker("", selection: $summaryModel) {
                Text("Gemini 3.1 Pro").tag("gemini-3.1-pro-high")
                Text("Claude Sonnet 4.6").tag("claude-sonnet-4-6")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(provider != "local")
            .onChange(of: summaryModel) { _, new in
                engine.setIntelligence(provider: provider, summaryModel: new)
            }
        }
    }

    /// One control for two questions that were previously answered separately and
    /// inconsistently: may the gateway answer, and when does its socket open.
    ///
    /// They were never independent. The socket connected on every call and
    /// received every turn whether or not the gateway was allowed to answer — so
    /// "fall back: off" still shipped the transcript to `nomonhomelab`, and every
    /// call paid ~1s of handshake before its microphone opened. Collapsing them
    /// makes the honest combinations the only reachable ones.
    private var fallbackCard: some View {
        SettingCard(
            "If this Mac cannot answer",
            detail: """
            A warm gateway is connected from the start and hears the call as it \
            happens, so a handover is instant. None of these delay recording.
            """
        ) {
            VStack(spacing: 12) {
                Picker("", selection: standbyBinding) {
                    Text("Never").tag("off")
                    Text("On failure").tag("on-failure")
                    Text("Keep warm").tag("warm")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(provider != "local")

                SettingRow(standbyTitle, detail: standbyDetail) { EmptyView() }
            }
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
                engine.setIntelligence(
                    provider: provider,
                    fallback: allowed,
                    gatewayStandby: allowed ? mode : "off")
            })
    }

    private var standbyTitle: String {
        switch standbyBinding.wrappedValue {
        case "off": return "Nothing leaves this Mac"
        case "on-failure": return "Connects only if the local brain gives up"
        default: return "Connected for the whole call"
        }
    }

    private var standbyDetail: String {
        switch standbyBinding.wrappedValue {
        case "off":
            return """
            The gateway is never opened, so no part of the transcript is sent to it. \
            A local brain that fails simply says so — there is nowhere to hand over to.
            """
        case "on-failure":
            return """
            The call stays on this Mac while it is going well. On a failure the socket \
            opens and the recent transcript is sent so the handover is not blind, which \
            costs a moment at exactly the wrong time.
            """
        default:
            return """
            Every turn is sent to the gateway as it is transcribed, so it can take over \
            mid-sentence. Its suggestions stay hidden unless the local brain gives up.
            """
        }
    }
}
