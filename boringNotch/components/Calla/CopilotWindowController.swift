import AppKit
import SwiftUI

/// Standalone window for the live call: full transcript on the left, the
/// current pointer on the right.
///
/// Separate from Settings because it is read *during* a call — it wants to sit
/// beside the meeting window and stay out of the way, which a settings sheet
/// cannot do.
@MainActor
final class CopilotWindowController: NSWindowController, NSWindowDelegate {
    static let shared = CopilotWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Call Copilot"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 420)
        window.center()
        // Floats above the meeting app without stealing its keyboard focus, so
        // it can be read mid-sentence without interrupting the call.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: CopilotWindowView())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct CopilotWindowView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @State private var turns: [CallaCallTurn] = []

    /// Polls only while the window is open — the transcript is deliberately off
    /// the engine's status poll.
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    var body: some View {
        HSplitView {
            transcript
                .frame(minWidth: 320)
            pointer
                .frame(minWidth: 260, idealWidth: 300)
        }
        .frame(minWidth: 620, minHeight: 420)
        .onReceive(tick) { _ in refresh() }
        .onAppear { refresh() }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Transcript", trailing: copilot.running ? "live" : nil)
            if turns.isEmpty {
                emptyState(
                    copilot.running ? "Listening…" : "No call running",
                    detail: copilot.running
                        ? "Turns appear here as they are transcribed on this Mac."
                        : "Start a call from the notch to see the transcript here.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(turns) { turn in
                                turnRow(turn).id(turn.seq)
                            }
                        }
                        .padding(14)
                    }
                    .onChange(of: turns.last?.seq) { _, seq in
                        guard let seq else { return }
                        withAnimation { proxy.scrollTo(seq, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func turnRow(_ turn: CallaCallTurn) -> some View {
        // Them on the left, you on the right. The split is the whole point of
        // capturing the two legs separately, so it should be visible at a glance.
        HStack {
            if !turn.isRemote { Spacer(minLength: 40) }
            VStack(alignment: turn.isRemote ? .leading : .trailing, spacing: 2) {
                Text(turn.isRemote ? "Them" : "You")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(turn.isRemote ? Color.blue : Color.secondary)
                Text(turn.text)
                    .font(.system(size: 12))
                    .multilineTextAlignment(turn.isRemote ? .leading : .trailing)
                    .textSelection(.enabled)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        (turn.isRemote ? Color.blue.opacity(0.13) : Color.secondary.opacity(0.10)),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(timestamp(turn.t0))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if turn.isRemote { Spacer(minLength: 40) }
        }
    }

    private var pointer: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("How to answer", trailing: nil)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if copilot.hasSuggestion {
                        if let headline = copilot.headline {
                            Text(headline)
                                .font(.system(size: 14, weight: .semibold))
                                .textSelection(.enabled)
                        }
                        if !copilot.angles.isEmpty {
                            section("Ways to answer") {
                                ForEach(Array(copilot.angles.enumerated()), id: \.offset) { _, angle in
                                    bullet(angle, tint: .blue)
                                }
                            }
                        }
                        // Facts the model wants checked before they are asserted.
                        // Kept visually distinct: this is the part that stops a
                        // confident wrong answer.
                        if !copilot.confirm.isEmpty {
                            section("Confirm before you say it") {
                                ForEach(Array(copilot.confirm.enumerated()), id: \.offset) { _, item in
                                    bullet(item, tint: .orange)
                                }
                            }
                        }
                    } else {
                        Text(copilot.running
                             ? "Nothing worth interrupting for yet."
                             : "Pointers appear here during a call.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Divider().padding(.vertical, 4)
                    footer
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                copilot.systemAudioActive ? "Both sides captured" : "Microphone only",
                systemImage: copilot.systemAudioActive ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(copilot.systemAudioActive ? Color.secondary : Color.orange)
            Label(
                copilot.gatewayConnected ? "Gateway connected" : "Gateway offline",
                systemImage: copilot.gatewayConnected ? "antenna.radiowaves.left.and.right" : "wifi.slash")
                .font(.system(size: 10))
                .foregroundStyle(copilot.gatewayConnected ? Color.secondary : Color.orange)
            Text("Audio never leaves this Mac. Only transcribed text reaches the gateway.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }

    private func header(_ title: String, trailing: String?) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let trailing {
                CallaPill(text: trailing, tint: .green)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.25))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func bullet(_ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(tint.opacity(0.7))
                .frame(width: 4, height: 4)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(spacing: 5) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func timestamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func refresh() {
        engine.fetchTranscript { turns = $0 }
    }
}
