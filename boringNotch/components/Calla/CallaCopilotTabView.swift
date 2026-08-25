//
//  CallaCopilotTabView.swift
//  boringNotch
//
//  The copilot at rest, in the notch.
//
//  A pre-flight check rather than a settings page, because that is the question
//  people bring to it thirty seconds before a call: *will this work?* A copilot
//  that starts and then silently hears only one side is worse than one that
//  refuses to start, so the panel shows what is armed before it offers to begin,
//  and the primary control names whatever is missing instead of always saying
//  "start".
//
//  One card, two columns: the verdict on the left, the four facts behind it on
//  the right. An earlier pass put those facts in a grid *under* the verdict and
//  the whole second row fell through the notch's lower curve — 168pt does not
//  hold three stacked bands, which is why the tab-naming row is gone too.
//

import Defaults
import KeyboardShortcuts
import SwiftUI

struct CallaCopilotTabView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var session = CopilotLiveSession.shared
    @Environment(\.openURL) private var openURL
    @Default(.callaCopilotPersona) private var persona
    @Default(.callaCopilotLiveModel) private var liveModel
    @Default(.callaIntelligenceProvider) private var provider
    @Default(.callaCopilotCustomPersonas) private var customPersonas

    /// Drives only the elapsed-time label; the rest arrives on the engine poll.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    var body: some View {
        HStack(spacing: 0) {
            verdictColumn
                .frame(maxWidth: .infinity)
            NotchColumnDivider()
            readinessColumn
                .frame(width: 190)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .notchCard()
        .notchTabInsets()
        .task {
            engine.start()
            engine.startMonitoring()
            // Debounced, because this tab is one arrow key away from the others
            // and arming spawns a host process plus a language server. Someone
            // passing through should not pay for that; someone who has settled
            // here for a moment is probably about to start a call.
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            engine.prewarmForImminentCall()
        }
        .onDisappear { engine.cancelSpeculativePrewarm() }
        .onReceive(tick) { value in
            if copilot.running || isPreroll { now = value }
        }
    }

    // MARK: - Verdict

    private var verdictColumn: some View {
        VStack(alignment: .leading, spacing: NotchGlassSpace.snug) {
            NotchCardHeader(state: stateLine,
                            live: copilot.running || isPreroll,
                            tint: copilot.running ? NotchTint.healthy : .effectiveAccent,
                            figure: copilot.running
                             ? CallaCopilotPresentation.elapsed(since: copilot.startedAt, now: now)
                             : nil) {
                personaMenu
                NotchGlyphButton(symbol: "clock.arrow.circlepath",
                                 help: "Past calls, their transcripts, and what the copilot said") {
                    SettingsWindowController.shared.showCopilotWindow(tab: "CopilotHistory")
                }
            }

            Text(headline)
                .font(NotchGlassType.title)
                .foregroundStyle(NotchInk.primary)
                .lineLimit(1)

            // One line, never two. The four facts are in the column beside
            // this one; a second line here is the band that pushed the control
            // row through the notch's lower curve.
            Text(detail)
                .font(NotchGlassType.caption)
                .foregroundStyle(NotchInk.tertiary)
                .lineLimit(1)

            controls
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 12)
    }

    /// Which kind of call this is. A glyph menu, because the choice is made
    /// rarely and the current value is already in the state line.
    private var personaMenu: some View {
        Menu {
            ForEach(CallaCopilotPersona.all(including: Array(customPersonas.keys)), id: \.self) { value in
                Button(CallaCopilotPersona.title(value)) {
                    persona = value
                    engine.setCallPersona(value)
                }
            }
        } label: {
            Image(systemName: "person.crop.circle")
                .font(NotchGlassType.glyphSmall)
                .foregroundStyle(NotchInk.tertiary)
                .padding(4)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("What kind of call this is")
    }

    // MARK: - Readiness

    /// The four things a call needs, and nothing more.
    ///
    /// Ready is deliberately quiet; the one thing missing is the only thing in
    /// colour. A column of green ticks is equally loud whether everything is
    /// fine or nothing is, which is how the old segmented strip managed to be
    /// both noisy and uninformative.
    private var readinessColumn: some View {
        VStack(alignment: .leading, spacing: 7) {
            check("Microphone", state: micState, ready: "allowed", problem: "not allowed")
            check("Other side", state: screenState, ready: "captured", problem: "not captured")
            check(brainLabel, state: brainState, ready: brainReadyNote, problem: brainProblemNote)
            check("Speech model", state: modelState, ready: shortModelName, problem: modelShortProblem)
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 12)
    }

    private enum CheckState {
        /// Armed and known good.
        case ready
        /// The thing standing between you and a working call.
        case blocking
        /// Working on it.
        case progress(Double)
        /// Nobody has asked yet, which is not the same as denied.
        case unknown

        var symbol: String {
            switch self {
            case .ready: "checkmark"
            case .blocking: "exclamationmark.triangle.fill"
            case .progress: "arrow.down.circle"
            case .unknown: "questionmark"
            }
        }

        var tint: Color {
            switch self {
            case .ready: NotchTint.healthy
            case .blocking: NotchTint.attention
            case .progress: NotchTint.active
            case .unknown: NotchInk.tertiary
            }
        }

        var settled: Bool {
            switch self {
            case .ready, .unknown: true
            case .blocking, .progress: false
            }
        }
    }

    private func check(_ label: String, state: CheckState,
                       ready: String, problem: String) -> some View {
        HStack(spacing: NotchGlassSpace.tight) {
            Image(systemName: state.symbol)
                .font(NotchGlassType.glyphSmall)
                .foregroundStyle(state.tint)
                .frame(width: 12)
            Text(label)
                .font(NotchGlassType.detail)
                .foregroundStyle(state.settled ? NotchInk.secondary : NotchInk.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(state.settled ? ready : problem)
                .font(NotchGlassType.caption)
                .foregroundStyle(state.settled ? NotchInk.tertiary : state.tint)
                .lineLimit(1)
        }
    }

    // MARK: - Copy

    /// State, then which kind of call it is set up for. Never the tab's name.
    private var stateLine: String {
        let kind = CallaCopilotPersona.title(persona)
        if isPreroll { return "Warming up · \(kind)" }
        if copilot.running { return "In a call · \(kind)" }
        return "Ready · \(kind)"
    }


    /// The pre-roll owns the panel, but never over a blocker.
    ///
    /// A missing microphone still outranks it: arming early is worthless if the
    /// call it is arming for cannot hear anything, and the permission is exactly
    /// the thing two minutes of warning is *for*.
    private var isPreroll: Bool {
        session.prerollActive && blocker == .none
    }

    private var prerollCountdown: String {
        guard let startsAt = session.prerollStartsAt else { return "starting soon" }
        let remaining = startsAt.timeIntervalSince(now)
        guard remaining > 0 else { return "starting now" }
        let minutes = Int((remaining / 60).rounded(.up))
        return minutes <= 1 ? "in under a minute" : "in \(minutes) min"
    }

    private var headline: String {
        guard copilot.available else { return "Call host is not installed" }
        if isPreroll {
            return session.prerollTitle ?? "Your meeting is about to start"
        }
        if copilot.running {
            return copilot.systemAudioActive ? "Listening to both sides" : "Hearing only you"
        }
        switch blocker {
        case .microphone: return "Nothing would be heard"
        case .screen: return "Only your side would be heard"
        case .signIn: return "Sign in to use this Mac's copilot"
        case .model: return "Fetching the transcription model"
        case .none: return "Ready to listen"
        }
    }

    private var detail: String {
        guard copilot.available else {
            return copilot.lastResult ?? "Reinstall Boring to restore the copilot."
        }
        if isPreroll {
            // Says the countdown and says nothing is being recorded, in that
            // order. The second half is the promise the whole pre-roll rests on.
            return "Starts \(prerollCountdown) · nothing is being recorded yet"
        }
        if copilot.running {
            return "\(copilot.turnCount) turn\(copilot.turnCount == 1 ? "" : "s") · \(brainLabel) answers"
        }
        switch blocker {
        case .microphone: return "Your own voice is half the conversation."
        case .screen: return "Screen recording is how the other side gets transcribed."
        case .signIn: return "One sign-in, then answers come from this Mac."
        case .model: return modelDetail
        case .none: return "Audio stays on this Mac. \(brainLabel) answers."
        }
    }

    private var modelDetail: String {
        guard let download = copilot.modelDownload else { return "Downloading in the background." }
        if download.state == "failed" { return download.message ?? "The download did not finish." }
        return "\(Int(download.fraction * 100))% of \(download.model)"
    }

    /// The readiness column has room for a value, not a sentence — the long
    /// form is already in `detail` under the headline.
    private var modelShortProblem: String {
        guard let download = copilot.modelDownload else { return "downloading" }
        if download.state == "failed" { return "failed" }
        return "\(Int(download.fraction * 100))%"
    }

    private var shortModelName: String {
        liveModel.replacingOccurrences(of: "whisper-", with: "").replacingOccurrences(of: "-en", with: "")
    }

    private var brainLabel: String {
        provider == "local" ? "This Mac" : "Gateway"
    }

    private var brainReadyNote: String {
        provider == "local" ? "signed in" : "reachable"
    }

    private var brainProblemNote: String {
        provider == "local"
            ? (copilot.agyAvailable ? "Not signed in on this Mac" : "Local intelligence unavailable")
            : "Gateway unreachable"
    }

    // MARK: - Readiness state

    private var micState: CheckState {
        guard copilot.hostPermissionsKnown else { return .unknown }
        return copilot.hostMicGranted ? .ready : .blocking
    }

    private var screenState: CheckState {
        guard copilot.hostPermissionsKnown else { return .unknown }
        return copilot.hostScreenGranted ? .ready : .blocking
    }

    private var brainState: CheckState {
        guard provider == "local" else {
            return engine.status.gatewayReachable ? .ready : .blocking
        }
        guard copilot.agyAvailable else { return .blocking }
        return copilot.agyLoggedIn ? .ready : .blocking
    }

    private var modelState: CheckState {
        guard let download = copilot.modelDownload else { return .ready }
        if download.state == "failed" { return .blocking }
        if download.isActive { return .progress(download.fraction) }
        return .ready
    }

    // MARK: - Controls

    /// The blocking step, if there is one.
    ///
    /// Ordered by what a call cannot proceed without at all, then by what makes it
    /// useful: no microphone means no call, no screen recording means half a call.
    private enum Blocker { case microphone, screen, signIn, model, none }

    private var blocker: Blocker {
        if copilot.hostPermissionsKnown, !copilot.hostMicGranted { return .microphone }
        if copilot.hostPermissionsKnown, !copilot.hostScreenGranted { return .screen }
        if provider == "local", copilot.agyAvailable, !copilot.agyLoggedIn { return .signIn }
        if let download = copilot.modelDownload, download.isActive { return .model }
        return .none
    }

    /// One primary button, and it says what pressing it does.
    ///
    /// A panel that offers "Start call" while the microphone is denied is lying by
    /// omission: the call starts and hears nothing. The button becomes the fix
    /// instead, so the next step is always the obvious one.
    private var controls: some View {
        HStack(spacing: NotchGlassSpace.tight) {
            if isPreroll {
                prerollControls
            } else {
                callControls
            }
            Spacer(minLength: 0)
        }
    }

    /// Join, start, or not this one.
    ///
    /// Three buttons rather than two because opening the meeting and beginning to
    /// record are genuinely different intentions: people join early and sit muted,
    /// and people record calls they joined from their phone. Collapsing them would
    /// force one of those to be wrong.
    @ViewBuilder
    private var prerollControls: some View {
        primaryButton("Join", symbol: "video.fill", tint: .effectiveAccent) {
            if let url = MeetingPreroll.shared.joinURL { open(url) }
            MeetingPreroll.shared.release()
        }
        .disabled(MeetingPreroll.shared.joinURL == nil)

        NotchChip(action: { MeetingPreroll.shared.release() }) {
            Text("Start listening")
        }

        NotchGlyphButton(symbol: "xmark", help: "Not this one") {
            MeetingPreroll.shared.cancel()
            CopilotLiveSession.shared.endPreroll()
        }
    }

    @ViewBuilder
    private var callControls: some View {
        // `isRecording`, not `running`. A host can be up and deliberately not
        // recording — the pre-roll, and now the speculative warm-up armed when
        // this tab opens — and in that state the useful button is still the one
        // that begins the call, not "End call" for a call nobody started.
        switch (copilot.isRecording, blocker) {
        case (true, _):
            primaryButton("End call", symbol: "stop.fill", tint: NotchTint.stuck) { engine.endCall() }
        case (false, .microphone), (false, .screen):
            primaryButton("Allow recording", symbol: "checkmark.shield.fill", tint: NotchTint.attention) {
                engine.requestCopilotPermissions()
            }
            NotchChip(action: { engine.startCall(persona: persona, model: liveModel) }) {
                Text("Start anyway")
            }
        case (false, .signIn):
            primaryButton("Sign in", symbol: "person.badge.key.fill", tint: NotchTint.attention) {
                engine.loginAgy()
            }
        case (false, .model):
            primaryButton("Fetching model…", symbol: "arrow.down.circle", tint: NotchTint.active) {}
                .disabled(true)
        case (false, .none):
            primaryButton("Start listening", symbol: "waveform", tint: .effectiveAccent) {
                engine.startCall(persona: persona, model: liveModel)
            }
            .disabled(!copilot.available)
        }
    }

    /// Opens the meeting the way the calendar row does, so a Zoom link lands in
    /// Zoom rather than a browser tab that immediately hands off to Zoom.
    private func open(_ url: URL) {
        if Defaults[.openMeetingsInApp],
           let native = MeetingLinkResolver.nativeURL(for: url),
           NSWorkspace.shared.open(native) {
            return
        }
        openURL(url)
    }

    private func primaryButton(
        _ title: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(NotchGlassType.glyph)
                Text(title).font(NotchGlassType.action)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(height: NotchGlassSpace.control)
            .background(tint, in: RoundedRectangle(cornerRadius: NotchGlassRadius.chip, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The personas the gateway flow ships, and their display names.
enum CallaCopilotPersona {
    /// Seeded by the gateway. Their guidance text can be edited in settings;
    /// their ids cannot, because the gateway's own allowlist knows them.
    static let builtIn = ["generic", "interview", "sales", "support"]

    static let all = builtIn

    /// The built-ins plus whatever the user added, in a stable order.
    static func all(including custom: [String]) -> [String] {
        builtIn + custom.filter { !builtIn.contains($0) }.sorted()
    }

    static func title(_ value: String) -> String {
        switch value {
        case "generic": return "General"
        case "interview": return "Interview"
        case "sales": return "Sales"
        case "support": return "Support"
        default:
            // A user-defined id like `board-review` reads as "Board review".
            return value
                .replacingOccurrences(of: "-", with: " ")
                .prefix(1).uppercased()
                + value.replacingOccurrences(of: "-", with: " ").dropFirst()
        }
    }

    /// Ids the user may create. Kept allowlist-shaped even though the guidance
    /// body is free text: an id can end up naming things, a paragraph cannot.
    static func isValidCustomID(_ value: String) -> Bool {
        !builtIn.contains(value)
            && value.range(of: "^[a-z0-9-]{1,24}$", options: .regularExpression) != nil
    }
}
