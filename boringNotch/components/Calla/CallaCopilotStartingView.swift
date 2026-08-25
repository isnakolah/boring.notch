import SwiftUI

/// The seconds between pressing Start and the microphone being open.
///
/// There was nothing here before. The engine reports a call as running only once
/// the host has finished its whole `start()`, and the notch polled for that every
/// four seconds — so a press was followed by up to six seconds of a tab that still
/// said "Start listening", which reads as a button that did not work. People
/// pressed it again.
///
/// What this draws is the host's own progress, published as it happens: the
/// stages are a closed enum on the wire (`CallStartupStage`) so a row can never
/// come out blank, and each one is a real cost being paid rather than a fake
/// progress bar. The two rows below the line — the brain and the gateway — are
/// deliberately *not* steps: neither blocks recording, and both routinely land
/// after the call is already live.
struct CallaCopilotStartingView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var session = CopilotLiveSession.shared

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    /// The ordered spine of the startup. Anything the host has passed is done,
    /// the current one is in flight, the rest are waiting.
    private enum Step: String, CaseIterable {
        case launching, permissions, model, capture

        var label: String {
            switch self {
            case .launching: "Starting the capture host"
            case .permissions: "Checking microphone access"
            case .model: "Loading the speech model"
            case .capture: "Opening the microphone"
            }
        }

        var done: String {
            switch self {
            case .launching: "running"
            case .permissions: "allowed"
            case .model: "loaded"
            case .capture: "listening"
            }
        }
    }

    /// Where the host says it is. Nil until the first status file lands, which is
    /// the window where the launch is still only this app's own claim.
    private var stage: Step? {
        guard let raw = copilot.startupStage else { return nil }
        // `listening` is past the last step rather than one of them.
        if raw == "listening" { return nil }
        return Step(rawValue: raw)
    }

    private var reachedListening: Bool { copilot.startupStage == "listening" }

    private func state(of step: Step) -> StepState {
        guard let stage else {
            // No host report yet, so only the first step can honestly be claimed
            // as in flight — this app asked for it, and that is all it knows.
            return step == .launching ? .active : .waiting
        }
        if reachedListening { return .done }
        guard let current = Step.allCases.firstIndex(of: stage),
              let mine = Step.allCases.firstIndex(of: step) else { return .waiting }
        if mine < current { return .done }
        return mine == current ? .active : .waiting
    }

    private enum StepState {
        case done, active, waiting

        var symbol: String {
            switch self {
            case .done: "checkmark"
            case .active: "circle.dotted"
            case .waiting: "circle"
            }
        }

        var tint: Color {
            switch self {
            case .done: NotchTint.healthy
            case .active: NotchTint.active
            case .waiting: NotchInk.tertiary
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchGlassSpace.snug) {
            NotchCardHeader(state: "Starting the call",
                            live: true,
                            tint: NotchTint.active,
                            figure: nil) {
                NotchGlyphButton(symbol: "stop.fill", help: "Cancel") {
                    engine.endCall()
                }
            }

            Text(headline)
                .font(NotchGlassType.title)
                .foregroundStyle(NotchInk.primary)
                .lineLimit(1)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(Step.allCases, id: \.self) { step in
                    row(symbol: state(of: step).symbol,
                        tint: state(of: step).tint,
                        label: step.label,
                        note: state(of: step) == .done ? step.done : "",
                        emphasised: state(of: step) == .active)
                }
            }
            .padding(.top, 2)

            // Below the line: things that are still arriving and never hold up
            // the recording. Drawn plainly so a cold brain reads as "not yet"
            // rather than as a fault.
            VStack(alignment: .leading, spacing: 7) {
                row(symbol: copilot.brainWarm ? "checkmark" : "circle.dotted",
                    tint: copilot.brainWarm ? NotchTint.healthy : NotchInk.tertiary,
                    label: brainLabel,
                    note: copilot.brainWarm ? "ready" : "warming",
                    emphasised: false)
                if let gatewayWarm = copilot.gatewayWarm {
                    row(symbol: gatewayWarm ? "checkmark" : "circle.dotted",
                        tint: gatewayWarm ? NotchTint.healthy : NotchInk.tertiary,
                        label: "Gateway standby",
                        note: gatewayWarm ? "connected" : "connecting",
                        emphasised: false)
                }
            }
            .padding(.top, 2)

            Text(footnote)
                .font(NotchGlassType.caption)
                .foregroundStyle(NotchInk.tertiary)
                .lineLimit(2)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .animation(.smooth(duration: 0.2), value: copilot.startupStage)
        .animation(.smooth(duration: 0.2), value: copilot.brainWarm)
    }

    private func row(symbol: String, tint: Color, label: String,
                     note: String, emphasised: Bool) -> some View {
        HStack(spacing: NotchGlassSpace.tight) {
            Image(systemName: symbol)
                .font(NotchGlassType.glyphSmall)
                .foregroundStyle(tint)
                .frame(width: 12)
            Text(label)
                .font(NotchGlassType.detail)
                .foregroundStyle(emphasised ? NotchInk.primary : NotchInk.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(note)
                .font(NotchGlassType.caption)
                .foregroundStyle(NotchInk.tertiary)
                .lineLimit(1)
        }
    }

    private var brainLabel: String {
        copilot.activeProvider == "gateway" ? "Gateway brain" : "Local brain"
    }

    private var headline: String {
        if reachedListening { return "Listening" }
        guard let stage else { return "Waking the capture host" }
        return stage.label
    }

    /// Says the one thing a person waiting actually wants to know: whether
    /// anything is being missed yet.
    private var footnote: String {
        if reachedListening || state(of: .capture) == .done {
            return copilot.brainWarm
                ? "Recording. Everything said from here is captured."
                : "Recording. The first answer may take a few seconds while the brain warms up."
        }
        return "Nothing is being recorded yet."
    }
}
