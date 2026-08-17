import Defaults
import SwiftUI

/// Notch tab for the live call copilot.
///
/// Read mid-call, in the second before the user has to answer, so it shows one
/// question and at most two ways to answer it. Everything else — the full
/// transcript, the facts worth confirming, past calls — is in the window behind
/// the expand button. `CallaCopilotPresentation` owns what earns the space.
struct CallaCopilotTabView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @Default(.callaCopilotPersona) private var persona
    @Default(.callaCopilotLiveModel) private var liveModel

    /// Drives only the elapsed-time label; the rest arrives on the engine poll.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
        // The notch's lower corners curve inward, so the control row has to stay
        // above that curve or it draws half outside the shape.
        VStack(alignment: .leading, spacing: 6) {
            header
            content
            Spacer(minLength: 0)
            controls
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            engine.start()
            engine.startMonitoring()
        }
        .onReceive(tick) { value in
            // Only redraw the clock while a call is actually running.
            if copilot.running { now = value }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Call copilot")
                .font(.system(size: 12, weight: .semibold))
            CallaPill(text: pill.text, tint: tint(for: pill.tone))
            Spacer(minLength: 0)
            if copilot.running, copilot.micActive {
                Image(systemName: "mic.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Button {
                SettingsWindowController.shared.showCopilotWindow(tab: "CopilotHistory")
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Past calls and their transcripts")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .suggesting:
            suggestion
        case .listening:
            message("Listening…", detail: subtitle)
        case .halfDeaf:
            message(
                "Only your microphone is being captured",
                detail: "Grant Screen Recording so the other side of the call is transcribed.")
        case .ready:
            message(
                "Ready when the call is",
                detail: copilot.lastResult ?? "Audio stays on this Mac; only text reaches the gateway.")
        case .unavailable:
            message(
                "Call host is not installed",
                detail: copilot.lastResult ?? "Reinstall Boring to restore the copilot.")
        }
    }

    private var suggestion: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let headline = CallaCopilotPresentation.headlineLine(copilot.headline) {
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            ForEach(Array(CallaCopilotPresentation.angleLines(copilot.angles).enumerated()), id: \.offset) { _, angle in
                HStack(alignment: .top, spacing: 5) {
                    Circle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 3, height: 3)
                        .padding(.top, 5)
                    Text(angle)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
            }
            if !copilot.confirm.isEmpty {
                Label("\(copilot.confirm.count) to confirm", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.orange)
            }
            Text(subtitle)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(CallaCopilotPresentation.primaryActionTitle(running: copilot.running)) {
                if copilot.running {
                    engine.endCall()
                } else {
                    engine.startCall(persona: persona, model: liveModel)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(copilot.running ? .red : .blue)
            .disabled(!copilot.available)

            if !copilot.running {
                Picker("", selection: $persona) {
                    ForEach(CallaCopilotPersona.all, id: \.self) { value in
                        Text(CallaCopilotPersona.title(value)).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 110)
                .onChange(of: persona) { _, value in engine.setCallPersona(value) }
            }

            Spacer(minLength: 0)
        }
    }

    private var pill: CallaCopilotPresentation.Pill {
        CallaCopilotPresentation.pill(for: mode)
    }

    private var subtitle: String {
        CallaCopilotPresentation.subtitle(
            turnCount: copilot.turnCount,
            elapsed: CallaCopilotPresentation.elapsed(since: copilot.startedAt, now: now),
            gatewayConnected: copilot.gatewayConnected)
    }

    private func tint(for tone: CallaCopilotPresentation.Tone) -> Color {
        switch tone {
        case .active: return .green
        case .ready: return .blue
        case .warning: return .orange
        }
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
