import Defaults
import KeyboardShortcuts
import SwiftUI

/// The copilot at rest, in the notch.
///
/// Designed as a pre-flight check rather than a settings page, because that is the
/// question people actually bring to it thirty seconds before a call: *will this
/// work?* A copilot that starts and then silently hears only one side is worse than
/// one that refuses to start, so the panel shows what is armed before it offers to
/// begin — and the primary button names whatever is missing instead of always
/// saying "start".
struct CallaCopilotTabView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var session = CopilotLiveSession.shared
    @Environment(\.openURL) private var openURL
    @Default(.callaCopilotPersona) private var persona
    @Default(.callaCopilotLiveModel) private var liveModel
    @Default(.callaIntelligenceProvider) private var provider

    /// Drives only the elapsed-time label; the rest arrives on the engine poll.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    var body: some View {
        // The notch's lower corners curve inward, so the control row has to stay
        // above that curve or it draws half outside the shape.
        VStack(alignment: .leading, spacing: 0) {
            eyebrow
            Spacer(minLength: 6)
            stateLine
            Spacer(minLength: 8)
            readinessRow
            Spacer(minLength: 8)
            controls
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            engine.start()
            engine.startMonitoring()
        }
        .onReceive(tick) { value in
            if copilot.running || isPreroll { now = value }
        }
    }

    // MARK: - Eyebrow

    /// The legend of an instrument, not a title bar: what this is, what it is set
    /// to, and the way out to past calls.
    private var eyebrow: some View {
        HStack(spacing: 8) {
            LivePulse(active: copilot.running)
            Text("CALL COPILOT")
                .font(.system(size: 8.5, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Color.white.opacity(0.55))

            Spacer(minLength: 0)

            if copilot.running {
                Text(CallaCopilotPresentation.elapsed(since: copilot.startedAt, now: now) ?? "")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.8))
            } else {
                Picker("", selection: $persona) {
                    ForEach(CallaCopilotPersona.all, id: \.self) { value in
                        Text(CallaCopilotPersona.title(value)).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 104)
                .onChange(of: persona) { _, value in engine.setCallPersona(value) }
            }

            Button {
                SettingsWindowController.shared.showCopilotWindow(tab: "CopilotHistory")
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white.opacity(0.5))
            .help("Past calls, their transcripts, and what the copilot said")
        }
    }

    // MARK: - State line

    /// One sentence of truth, and one of consequence. Sized to be the thing you
    /// read first from across the desk.
    private var stateLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(headline)
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.white.opacity(0.6))
                .lineLimit(1)
        }
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
        case .microphone: return "Microphone not allowed yet"
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
            // order. The second half is the promise the whole pre-roll rests on,
            // and it is repeated on the readiness row below in its own words.
            return "Ready \(prerollCountdown) · not recording yet"
        }
        if copilot.running {
            return "\(copilot.turnCount) turn\(copilot.turnCount == 1 ? "" : "s") · \(brainLabel)"
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
        return "\(Int(download.fraction * 100))% of \(download.model)."
    }

    private var brainLabel: String {
        provider == "local" ? "This Mac" : "Gateway"
    }

    // MARK: - Readiness

    /// The four things a call needs, and nothing more.
    ///
    /// This was a row of segmented bars, which was wrong twice over: a gauge implies
    /// a quantity, and these are yes-or-no facts with nothing to measure — and it
    /// was equally loud whether everything was fine or nothing was, so sixteen green
    /// dashes ended up reading as decoration.
    ///
    /// So it inverts. When everything is ready this is a quiet grey line you can
    /// ignore, which is the correct amount of attention for "no problems". When
    /// something is missing, that one item goes amber and legible and the rest stay
    /// quiet, so the eye lands on the thing that needs fixing.
    private var readinessRow: some View {
        HStack(spacing: 12) {
            if isPreroll {
                // The one moment a process booted without the user asking, so the
                // panel states what it is not doing rather than only what it is.
                // Said in words, not a dot: "not recording" is the claim, and a
                // grey dot is not a claim.
                Text("MIC OFF · SYSTEM AUDIO OFF")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Color.white.opacity(0.45))
                check("MODEL", state: modelState)
                check(brainLabel.uppercased(), state: brainState)
                Spacer(minLength: 0)
            } else {
                callReadiness
            }
        }
    }

    @ViewBuilder
    private var callReadiness: some View {
        check("MIC", state: micState)
        check("SCREEN", state: screenState)
        check("MODEL", state: modelState)
        check(brainLabel.uppercased(), state: brainState)
        Spacer(minLength: 0)
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

        /// Ready is deliberately dim. Green on everything is how the old strip
        /// managed to be both loud and uninformative.
        var tint: Color {
            switch self {
            case .ready: Color.white.opacity(0.4)
            case .blocking: NotchTint.attention
            case .progress: NotchTint.active
            case .unknown: Color.white.opacity(0.3)
            }
        }

        var emphasised: Bool {
            switch self {
            case .blocking, .progress: true
            case .ready, .unknown: false
            }
        }
    }

    private func check(_ label: String, state: CheckState) -> some View {
        HStack(spacing: 4) {
            Image(systemName: state.symbol)
                .font(.system(size: 8.5, weight: .bold))
            Text(label)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.8)
            if case let .progress(fraction) = state {
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 8.5, weight: .bold).monospacedDigit())
            }
        }
        .foregroundStyle(state.tint)
    }

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

    /// One button, and it says what pressing it does.
    ///
    /// A panel that offers "Start call" while the microphone is denied is lying by
    /// omission: the call starts and hears nothing. The button becomes the fix
    /// instead, so the next step is always the obvious one.
    private var controls: some View {
        HStack(spacing: 10) {
            if isPreroll {
                prerollControls
            } else {
                callControls
            }

            if let shortcut = KeyboardShortcuts.getShortcut(for: .copilotToggleCall) {
                Text(shortcut.description)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08), in: Capsule())
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
        actionButton("Join", symbol: "video.fill", tint: .accentColor) {
            if let url = MeetingPreroll.shared.joinURL { open(url) }
            MeetingPreroll.shared.release()
        }
        .disabled(MeetingPreroll.shared.joinURL == nil)

        actionButton("Start", symbol: "waveform", tint: NotchTint.active) {
            MeetingPreroll.shared.release()
        }

        actionButton("Not now", symbol: "xmark", tint: Color.white.opacity(0.35)) {
            MeetingPreroll.shared.cancel()
            CopilotLiveSession.shared.endPreroll()
        }
    }

    @ViewBuilder
    private var callControls: some View {
        switch (copilot.running, blocker) {
        case (true, _):
            actionButton("End call", symbol: "stop.fill", tint: .red) { engine.endCall() }
        case (false, .microphone), (false, .screen):
            actionButton("Allow recording", symbol: "checkmark.shield.fill", tint: NotchTint.attention) {
                engine.requestCopilotPermissions()
            }
        case (false, .signIn):
            actionButton("Sign in", symbol: "person.badge.key.fill", tint: NotchTint.attention) {
                engine.loginAgy()
            }
        case (false, .model):
            actionButton("Fetching model…", symbol: "arrow.down.circle", tint: NotchTint.active) {}
                .disabled(true)
        case (false, .none):
            actionButton("Start listening", symbol: "waveform", tint: .accentColor) {
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

    private func actionButton(
        _ title: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(tint.opacity(0.9), in: Capsule())
            .contentShape(Capsule())
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
