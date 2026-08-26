//
//  CallaCopilotStartingView.swift
//  boringNotch
//

import Defaults
import SwiftUI

/// The seconds between pressing Start and the microphone being open — and, when
/// the microphone never opens, the same panel saying why.
///
/// There was nothing here before. The engine reports a call as running only once
/// the host has finished its whole `start()`, and the notch polled for that every
/// four seconds — so a press was followed by up to six seconds of a tab that still
/// said "Start listening", which reads as a button that did not work. People
/// pressed it again.
///
/// Two things this deliberately does *not* do any more.
///
/// It does not open the notch at the live call's size. Startup has four short
/// lines to show and the live panel has a transcript beside an answer; using the
/// big slab for both meant the notch opened to a mostly empty rectangle and then
/// stayed that size whether or not a call ever appeared. It uses the compact
/// size and grows into the full one at the moment recording actually begins,
/// which is also the moment the extra room starts carrying something.
///
/// And it does not draw the four steps as four rows. In a compact panel that is
/// most of the height spent on the three steps that have not happened; the same
/// information fits in one segmented bar with the current step named above it.
/// On a failure the rows were worse than useless — three empty circles under a
/// red cross, with two green ticks below them for a brain and a gateway that
/// have nothing to do with why it failed.
struct CallaCopilotStartingView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var session = CopilotLiveSession.shared

    @Default(.callaCopilotPersona) private var persona
    @Default(.callaCopilotLiveModel) private var model

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    private var failed: Bool { session.startupFailed }
    private var failure: CopilotStartFailure {
        .classify(reason: session.startupFailure, copilot: copilot)
    }

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

    /// How many steps are behind us. The bar is drawn from this rather than from
    /// a spinner, because every one of these is a real cost being paid.
    private var completedSteps: Int {
        if reachedListening { return Step.allCases.count }
        guard let stage, let index = Step.allCases.firstIndex(of: stage) else { return 0 }
        return index
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchGlassSpace.snug) {
            NotchCardHeader(state: failed ? "Call did not start" : "Starting the call",
                            live: !failed,
                            tint: failed ? NotchTint.stuck : NotchTint.active,
                            figure: nil) {
                NotchGlyphButton(symbol: failed ? "xmark" : "stop.fill",
                                 help: failed ? "Dismiss" : "Cancel") {
                    if failed {
                        session.dismissStartupFailure()
                    } else {
                        engine.endCall()
                    }
                }
            }

            if failed { failureBody } else { progressBody }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .animation(.smooth(duration: 0.2), value: copilot.startupStage)
        .animation(.smooth(duration: 0.2), value: copilot.brainWarm)
        .animation(.smooth(duration: 0.2), value: failed)
    }

    // MARK: - Coming up

    @ViewBuilder private var progressBody: some View {
        Text(headline)
            .font(NotchGlassType.title)
            .foregroundStyle(NotchInk.primary)
            .lineLimit(1)

        CallaStepBar(total: Step.allCases.count, completed: completedSteps, tint: NotchTint.active)

        Text(footnote)
            .font(NotchGlassType.caption)
            .foregroundStyle(NotchInk.tertiary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

        // Below the line: things that are still arriving and never hold up the
        // recording. One line rather than two rows — neither blocks the call, so
        // neither has earned a row of its own in a panel this size.
        Text(supporting)
            .font(NotchGlassType.caption)
            .foregroundStyle(NotchInk.tertiary)
            .lineLimit(1)
    }

    private var headline: String {
        if reachedListening { return "Listening" }
        guard let stage else { return "Waking the capture host" }
        return stage.label
    }

    /// Says the one thing a person waiting actually wants to know: whether
    /// anything is being missed yet.
    private var footnote: String {
        if reachedListening || completedSteps == Step.allCases.count {
            return copilot.brainWarm
                ? "Recording. Everything said from here is captured."
                : "Recording. The first answer may take a few seconds while the brain warms up."
        }
        return "Nothing is being recorded yet."
    }

    private var supporting: String {
        var parts = [copilot.brainWarm
                     ? "\(brainLabel) ready"
                     : "\(brainLabel) warming"]
        if let gatewayWarm = copilot.gatewayWarm {
            parts.append(gatewayWarm ? "gateway connected" : "gateway connecting")
        }
        return parts.joined(separator: " · ")
    }

    private var brainLabel: String {
        copilot.activeProvider == "gateway" ? "Gateway brain" : "Local brain"
    }

    // MARK: - Did not start

    @ViewBuilder private var failureBody: some View {
        Text(failure.headline)
            .font(NotchGlassType.title)
            .foregroundStyle(NotchInk.primary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

        Text(failure.detail(copilot: copilot))
            .font(NotchGlassType.detail)
            .foregroundStyle(NotchInk.secondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)

        Spacer(minLength: 0)

        HStack(spacing: NotchGlassSpace.tight) {
            if let remedy = failure.remedy {
                Button(remedy.title) { perform(remedy) }
                    .buttonStyle(.borderedProminent)
            }
            Button(failure.remedy == nil ? "Dismiss" : "Not now") {
                session.dismissStartupFailure()
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private func perform(_ remedy: CopilotStartFailure.Remedy) {
        switch remedy {
        case .retry:
            session.clearStartupFailure()
            engine.startCall(persona: persona, model: model)
        case .endAndRetry:
            // Bring the invisible host down first, then start clean. The engine
            // refuses a second host outright, so starting without ending would
            // fail identically — which is what made the first version's Try
            // again button a dead end.
            session.clearStartupFailure()
            engine.endCall()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                engine.startCall(persona: persona, model: model)
            }
        case let .openSettings(page, _):
            session.dismissStartupFailure()
            SettingsWindowController.shared.show(route: .init(page.section, [page]))
        }
    }
}
