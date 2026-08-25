import SwiftUI

/// The live call, beside a closed notch.
///
/// A call is the one thing running here that the user is *inside* — they cannot
/// look away to check on it, and opening the notch mid-sentence to see whether the
/// copilot is still listening defeats the point of it. So the closed state carries
/// the two facts worth having at a glance: who is talking, and whether an answer is
/// waiting.
///
/// Takes the slot ahead of the Pomodoro and usage badges while a call runs: a
/// timer can wait, a conversation cannot.
struct CopilotNotchBadge: View {
    let notchWidth: CGFloat
    let height: CGFloat
    /// Called on hover — opens the notch on the copilot, mirroring the other badges.
    var onBadgeHover: (() -> Void)? = nil

    @ObservedObject private var engine = CallaEngineClient.shared

    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Both sides get the same width so the black spacer stays centred on the
    /// physical notch, the same reason the Pomodoro badge does it.
    private let sideWidth: CGFloat = 74

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    var body: some View {
        HStack(spacing: 0) {
            activity
                .frame(width: sideWidth, alignment: .trailing)
                .padding(.trailing, 10)

            Rectangle()
                .fill(.black)
                .frame(width: notchWidth)

            readout
                .frame(width: sideWidth, alignment: .leading)
                .padding(.leading, 10)
        }
        .fixedSize()
        .frame(height: height, alignment: .center)
        .onReceive(tick) { now = $0 }
        .onHover { hovering in
            if hovering { onBadgeHover?() }
        }
    }

    /// Left of the notch: who is speaking, or that the copilot is working.
    ///
    /// Glyph only. There is no room for a word here, and the colours are the same
    /// ones the open panel uses — blue for the other side, white for you, accent for
    /// the copilot — so the two surfaces teach the same code.
    private var activity: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect)
            .symbolEffect(.variableColor.iterative, isActive: copilot.thinking)
            .help(helpText)
    }

    /// Right of the notch: how long the call has run, and a dot when there is an
    /// answer on the table.
    private var readout: some View {
        HStack(spacing: 5) {
            Text(CallaCopilotPresentation.elapsed(since: copilot.startedAt, now: now) ?? "0:00")
                .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.85))
            if answerWaiting {
                // The one thing worth interrupting for: an answer exists and the
                // panel is closed.
                Circle()
                    .fill(Color.effectiveAccent)
                    .shadow(color: Color.effectiveAccent.opacity(0.9), radius: 4)
                    .frame(width: 5, height: 5)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.2), value: answerWaiting)
    }

    private var answerWaiting: Bool {
        copilot.answering && copilot.hasSuggestion
    }

    private var symbol: String {
        if copilot.working == "summary" { return "text.append" }
        if copilot.thinking { return "sparkles" }
        switch copilot.speaking {
        case "them": return "waveform"
        case "me": return "mic.fill"
        default: return "ear"
        }
    }

    private var tint: Color {
        // The panel's own vocabulary, so the closed badge and the open surface
        // teach the same code: accent is the copilot working, white is you, and
        // amber is the one state worth checking.
        if copilot.working == "summary" { return Color.effectiveAccent.opacity(0.65) }
        if copilot.thinking { return .effectiveAccent }
        switch copilot.speaking {
        case "them": return .effectiveAccent
        case "me": return NotchInk.primary.opacity(0.85)
        // Not grey: a call that is running but hearing nothing still needs to read
        // as running, or the badge becomes indistinguishable from a stopped one.
        default: return copilot.systemAudioActive ? NotchInk.secondary : NotchTint.attention
        }
    }

    private var helpText: String {
        if copilot.working == "summary" { return "Catching the summary up" }
        if copilot.thinking { return "Finding an answer" }
        switch copilot.speaking {
        case "them": return "They are speaking"
        case "me": return "You are speaking"
        default:
            return copilot.systemAudioActive
                ? "Listening to both sides"
                : "Only your microphone is being captured"
        }
    }
}
