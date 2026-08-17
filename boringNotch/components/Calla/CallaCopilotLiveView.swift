import Defaults
import KeyboardShortcuts
import SwiftUI

/// The notch during a live call.
///
/// Replaces the standalone window this feature shipped with. That window was
/// readable but visible in every screen share, which for a call copilot is the
/// one failure that cannot be traded away — so the surface moved into the notch
/// panel, which already knows how to drop out of a recording.
///
/// Two columns, because the two halves are read at different moments: the
/// transcript is glanced at to catch what was just said, the pointer is read in
/// the second before answering.
struct CallaCopilotLiveView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var session = CopilotLiveSession.shared

    @State private var turns: [CallaCallTurn] = []
    @State private var now = Date()

    @Default(.callaCopilotShowAnswers) private var showAnswers
    @Default(.callaCopilotShowRollingSummary) private var showRollingSummary

    /// Answers as they arrive, newest last.
    ///
    /// The engine only ever carries the *latest* suggestion — it is a status poll,
    /// not a feed — so a call's earlier pointers were simply lost. Keeping them here
    /// is what makes the compact panel a stream rather than a single line that
    /// silently replaces itself.
    @State private var answers: [LiveAnswer] = []

    struct LiveAnswer: Identifiable, Equatable {
        let id: Int
        let headline: String
        let angles: [String]
    }

    /// Fast enough that a turn appears while it is still the thing being
    /// answered. The engine hands back only what is newer than `lastSeq`, so
    /// the cost of the shorter interval is a near-empty reply, not a re-read.
    private let transcriptTick = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()
    private let clockTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    private var mode: CallaCopilotPresentation.Mode {
        CallaCopilotPresentation.mode(
            available: copilot.available,
            running: copilot.running,
            systemAudioActive: copilot.systemAudioActive,
            hasSuggestion: copilot.hasSuggestion
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.layout == .full {
                HStack(alignment: .top, spacing: 14) {
                    transcript
                    Divider().overlay(Color.white.opacity(0.08))
                    pointer.frame(width: 232)
                }
            } else {
                compactStream
                Spacer(minLength: 0)
            }
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(clockTick) { value in now = value }
        .onChange(of: copilot.suggestionAfterSeq) { _, seq in
            guard let seq, let headline = copilot.headline?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !headline.isEmpty, answers.last?.id != seq
            else { return }
            answers.append(LiveAnswer(id: seq, headline: headline, angles: copilot.angles))
            // A long call would otherwise grow this without bound.
            if answers.count > 30 { answers.removeFirst(answers.count - 30) }
        }
        .onReceive(transcriptTick) { _ in refresh() }
        .onAppear { refresh() }
    }

    // MARK: - Transcript

    private var transcript: some View {
        Group {
            if turns.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(copilot.systemAudioActive ? "Listening…" : "Only your side is being heard")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white)
                    Text(copilot.systemAudioActive
                         ? "Turns appear here as they are transcribed on this Mac."
                         : "Grant Screen Recording so the other side is transcribed too.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.white.opacity(0.72))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(turns) { turn in
                                turnRow(turn, isNewest: turn.seq == turns.last?.seq)
                                    .id(turn.seq)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    // Old turns dissolve into the top edge instead of being
                    // sliced by it — the panel is translucent, and a hard cut
                    // against glass reads as a rendering bug.
                    .mask(
                        LinearGradient(
                            colors: [.clear, .black, .black],
                            startPoint: .top,
                            endPoint: .init(x: 0.5, y: 0.18))
                    )
                    // Pinned to the bottom as content grows. The explicit
                    // `scrollTo` below is still needed — it lands the animation
                    // — but on its own it fired before the new row had laid
                    // out, so the view stopped a turn short of the end and the
                    // newest line was the one you could not read.
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: turns.last?.seq) { _, seq in
                        guard let seq else { return }
                        Task { @MainActor in
                            // One runloop hop, so the row exists before we ask
                            // to scroll to it.
                            await Task.yield()
                            withAnimation(.easeOut(duration: 0.22)) {
                                proxy.scrollTo(seq, anchor: .bottom)
                            }
                        }
                    }
                    .onAppear {
                        if let seq = turns.last?.seq { proxy.scrollTo(seq, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func turnRow(_ turn: CallaCallTurn, isNewest: Bool) -> some View {
        // Them left, you right. The split is the whole reason the two capture
        // legs are never mixed, so it should be readable without a label.
        HStack(spacing: 0) {
            if !turn.isRemote { Spacer(minLength: 32) }
            Text(turn.text)
                .font(.system(size: 11.5, weight: isNewest ? .medium : .regular))
                // Explicit whites rather than .primary/.secondary. The panel is
                // translucent, so the semantic colours land on whatever happens
                // to be behind it and the older turns wash out completely.
                .foregroundStyle(Color.white.opacity(isNewest ? 1 : 0.82))
                .multilineTextAlignment(turn.isRemote ? .leading : .trailing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    turn.isRemote ? Color.blue.opacity(0.28) : Color.white.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if turn.isRemote { Spacer(minLength: 32) }
        }
        .transition(.opacity.combined(with: .offset(y: 6)))
    }

    // MARK: - Pointer

    private var pointer: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch mode {
            case .suggesting where showAnswers:
                suggestion
            case .halfDeaf:
                note("Mic only", detail: "Grant Screen Recording so the other side of the call is transcribed.", tint: .orange)
            case .suggesting, .listening, .ready, .unavailable:
                // No question on the table is not the same as nothing to say.
                // A rolling account of where the conversation has got to is
                // worth the space between questions — it is what you need when
                // you are asked "what do you think?" about the last two
                // minutes. A real pointer always outranks it.
                if showRollingSummary, let summary = copilot.summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        label("SO FAR")
                        Text(summary)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if !copilot.openQuestions.isEmpty {
                            label("OPEN")
                            ForEach(Array(copilot.openQuestions.prefix(3).enumerated()), id: \.offset) { _, item in
                                bullet(item, tint: .blue)
                            }
                        }
                    }
                } else {
                    note("Listening…",
                         detail: "A running summary appears here, and a pointer the moment there is a question worth answering.",
                         tint: .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The compact panel: answers as they come in, with the rolling summary above
    /// them when it is wanted.
    ///
    /// Compact used to show the same single pointer as the full panel, which meant
    /// the previous answer vanished the moment the next one arrived — unreadable on a
    /// call that is still moving.
    private var compactStream: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showRollingSummary, let summary = copilot.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.black.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
            }

            if !showAnswers, !showRollingSummary {
                note("Nothing selected",
                     detail: "Turn on Answers or Summary below to see the copilot again.",
                     tint: .orange)
            } else if !showAnswers {
                // Summary-only: the block above is the whole panel.
                EmptyView()
            } else if answers.isEmpty {
                note("Listening…",
                     detail: showRollingSummary
                        ? "Answers and a running summary appear here."
                        : "Answers appear here as they arrive.",
                     tint: .secondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(showAnswers ? answers : []) { answer in
                                answerRow(answer, isNewest: answer.id == answers.last?.id)
                                    .id(answer.id)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: answers.last?.id) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func pushDetailMode() {
        engine.setAnswersOnly(showAnswers && !showRollingSummary)
    }

    private func answerRow(_ answer: LiveAnswer, isNewest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(CallaCopilotPresentation.headlineLine(answer.headline, limit: 110) ?? answer.headline)
                .font(.system(size: 12.5, weight: isNewest ? .semibold : .medium))
                // Near-white even when it is not the newest. This panel is
                // translucent, so dimming text does not read as "older", it reads as
                // unreadable — whatever is behind the notch shows straight through it.
                .foregroundStyle(Color.white.opacity(isNewest ? 1 : 0.92))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            // Only the newest answer earns its alternatives; older ones are context.
            if isNewest, !answer.angles.isEmpty {
                ForEach(Array(CallaCopilotPresentation.angleLines(answer.angles, limit: 2, characters: 70).enumerated()), id: \.offset) { _, angle in
                    bullet(angle, tint: .white)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A backing plate, for the same reason the transcript rows have one: text
        // on bare glass is legible over a dark window and invisible over a bright
        // one, and a call panel cannot be a coin toss.
        .background(
            Color.black.opacity(isNewest ? 0.62 : 0.5),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(isNewest ? 0.22 : 0.12), lineWidth: 0.5)
        )
    }

    private var suggestion: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let headline = CallaCopilotPresentation.headlineLine(copilot.headline, limit: 120) {
                Text(headline)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !copilot.angles.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    label("ANSWER")
                    ForEach(Array(CallaCopilotPresentation.angleLines(copilot.angles, limit: 3, characters: 140).enumerated()), id: \.offset) { _, angle in
                        bullet(angle, tint: .blue)
                    }
                }
            }
            // Kept visually distinct on purpose: this is the part that stops a
            // confident wrong answer.
            if !copilot.confirm.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    label("CONFIRM")
                    ForEach(Array(copilot.confirm.prefix(3).enumerated()), id: \.offset) { _, item in
                        bullet(item, tint: .orange)
                    }
                }
            }
        }
    }

    private func note(_ title: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(tint == .secondary ? Color.white : tint)
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Color.white.opacity(0.55))
    }

    private func bullet(_ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(tint.opacity(0.8))
                .frame(width: 3.5, height: 3.5)
                .padding(.top, 5.5)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.97))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button("End call") { engine.endCall() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.red)
            // Two independent switches: either, both, or neither. Cheap to flip
            // because every suggestion already carries both fields — this chooses
            // what is worth the space, not what gets asked for. `.button` style so a
            // pressed-in button *is* the on state, rather than a label that has to
            // be read.
            Toggle(isOn: $showAnswers) {
                Label("Answers", systemImage: "bubble.left.fill")
                    .font(.system(size: 9))
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Show what to say next")
            // Answers without the summary means "answer when asked": the copilot
            // stops remarking on every statement, which is what an interview wants.
            .onChange(of: showAnswers) { _, _ in pushDetailMode() }

            Toggle(isOn: $showRollingSummary) {
                Label("Summary", systemImage: "text.alignleft")
                    .font(.system(size: 9))
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Show the running account of where the call has got to")
            .onChange(of: showRollingSummary) { _, _ in pushDetailMode() }

            if !copilot.gatewayConnected {
                Label("Gateway offline", systemImage: "wifi.slash")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            Text(CallaCopilotPresentation.subtitle(
                turnCount: copilot.turnCount,
                elapsed: nil,
                gatewayConnected: copilot.gatewayConnected))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func shortcutHint(for name: KeyboardShortcuts.Name) -> some View {
        if let shortcut = KeyboardShortcuts.getShortcut(for: name) {
            Text(shortcut.description)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .help("Switch between the full panel and the pointer alone")
        }
    }

    // MARK: - Data

    private func refresh() {
        guard copilot.running else { return }
        engine.fetchTranscript(since: turns.last?.seq) { fresh in
            guard !fresh.isEmpty else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                // The engine only returns turns newer than the cursor, but a
                // reconnect can replay one; `seq` is monotonic per call, so
                // filtering on it is enough to stay ordered and duplicate-free.
                let known = Set(turns.map(\.seq))
                turns.append(contentsOf: fresh.filter { !known.contains($0.seq) })
            }
        }
    }

    private var pill: CallaCopilotPresentation.Pill {
        CallaCopilotPresentation.pill(for: mode)
    }

    private func tint(for tone: CallaCopilotPresentation.Tone) -> Color {
        switch tone {
        case .active: return .green
        case .ready: return .blue
        case .warning: return .orange
        }
    }
}

/// A recording dot that breathes while both legs are being captured.
private struct LivePulse: View {
    let active: Bool
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(active ? Color.green : Color.orange)
            .frame(width: 6, height: 6)
            .scaleEffect(expanded ? 1.35 : 1)
            .opacity(expanded ? 0.55 : 1)
            .animation(active ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default,
                       value: expanded)
            .onAppear { expanded = active }
            .onChange(of: active) { _, value in expanded = value }
    }
}

/// The live call's status and controls, drawn either side of the camera housing.
///
/// Lives in the notch's own header band rather than inside the panel below it.
/// That band is dead space during a call — the panel is wider than the physical
/// cutout and the tab row is hidden — so putting the status on one side and the
/// controls on the other buys the transcript a full row of height it would
/// otherwise spend on a status line.
struct CallaCopilotLiveHeader: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var session = CopilotLiveSession.shared
    @EnvironmentObject private var vm: BoringViewModel

    @State private var now = Date()
    @Default(.hideFromScreenRecording) private var hiddenFromCapture
    @Default(.callaIntelligenceProvider) private var preferredProvider
    private let clockTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    private var pill: CallaCopilotPresentation.Pill {
        CallaCopilotPresentation.pill(for: CallaCopilotPresentation.mode(
            available: copilot.available,
            running: copilot.running,
            systemAudioActive: copilot.systemAudioActive,
            hasSuggestion: copilot.hasSuggestion))
    }

    var body: some View {
        HStack(spacing: 0) {
            // Every label here is `fixedSize`, because the row it sits in is
            // split into two halves around a rigid camera housing and each half
            // is narrower than it looks. Without it SwiftUI meets the shortfall
            // by wrapping the text — "Listening" breaks after "Listenin", and a
            // clock reading "0:" over "…" is worse than no clock at all. Better
            // to drop a whole item, which is what `full` below decides.
            HStack(spacing: 6) {
                LivePulse(active: copilot.running && copilot.systemAudioActive)
                Text(pill.text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint(for: pill.tone))
                    .lineLimit(1)
                    .fixedSize()
                if let elapsed = CallaCopilotPresentation.elapsed(since: copilot.startedAt, now: now) {
                    Text(elapsed)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.88))
                        .lineLimit(1)
                        .fixedSize()
                }
                // Shown only when the brain answering is not the one chosen in
                // Settings — an automatic handover to the gateway is otherwise
                // indistinguishable from a copilot that has quietly gone vague.
                // Ranks above the persona because it changes mid-call and the
                // persona cannot.
                if let badge = CallaCopilotPresentation.providerBadge(
                    active: copilot.activeProvider,
                    preferred: preferredProvider,
                    running: copilot.running
                ) {
                    CallaPill(text: badge.text, tint: tint(for: badge.tone))
                }
                // The persona is set before the call and does not change during
                // it, so it is the first thing to go when the row is halved.
                if session.layout == .full {
                    CallaPill(text: CallaCopilotPersona.title(copilot.persona), tint: .secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The camera housing. Nothing may be drawn here.
            Color.clear.frame(width: vm.closedNotchSize.width)

            HStack(spacing: 7) {
                Spacer(minLength: 0)
                // Two facts worth one glyph each: is it hearing both sides, and
                // is it out of the screen share.
                Image(systemName: copilot.micActive ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(copilot.micActive ? Color.white.opacity(0.7) : Color.orange)
                    .help(copilot.micActive ? "Your microphone is being captured" : "Your microphone is not being captured")
                // Reports the setting rather than asserting a guarantee. The
                // panel is hidden from captures when "Hide from screen
                // recording" is on and visible when it is off, call or no call,
                // and a crossed-out eye that means neither is the one glyph
                // here that could cost someone the thing this feature exists to
                // protect.
                Image(systemName: hiddenFromCapture ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(hiddenFromCapture ? Color.white.opacity(0.7) : Color.orange)
                    .help(hiddenFromCapture
                          ? "Hidden from screen recordings and shares"
                          : "Visible in screen recordings and shares — turn on Hide from screen recording in Settings")

                // Only while there is room. Compact is the state this shortcut
                // gets you *out* of, and the button beside it does the same job
                // — a badge that wraps to "⌥" over "⌘T" teaches nothing.
                if session.layout == .full,
                   let shortcut = KeyboardShortcuts.getShortcut(for: .copilotToggleLayout) {
                    Text(shortcut.description)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.white.opacity(0.07),
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                // Minimise to the pointer alone and back. The transcript is the
                // part worth surrendering first: it is the half you can
                // reconstruct by listening, where the pointer is not.
                Button { session.toggleLayout() } label: {
                    Image(systemName: session.layout == .full
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.7))
                .help(session.layout == .full ? "Minimise to the pointer" : "Show the transcript again")

                // Closes the notch. The call keeps running — ending it is the
                // red button at the bottom, which is a different decision.
                Button { session.dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.7))
                .help("Close the notch — the call keeps running")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .onReceive(clockTick) { now = $0 }
    }

    private func tint(for tone: CallaCopilotPresentation.Tone) -> Color {
        switch tone {
        case .active: return .green
        case .ready: return .blue
        case .warning: return .orange
        }
    }
}
