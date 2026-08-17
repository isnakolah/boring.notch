import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

/// Calls that already happened.
///
/// Every call has been archived to disk since the copilot shipped and nothing
/// ever showed them. The app is sandboxed and cannot read the capture host's
/// files, so all of this arrives through the engine.
struct CopilotHistoryPane: View {
    @ObservedObject private var engine = CallaEngineClient.shared

    @State private var calls: [CallaCallSummary] = []
    @State private var selected: CallaCallSummary?
    @State private var turns: [CallaCallTurn] = []
    @State private var loading = false

    var body: some View {
        SettingsPane(eyebrow: "Call copilot", title: "History",
                     detail: "Transcripts stay on this Mac. Nothing here has been uploaded anywhere.") {
            if calls.isEmpty {
                SettingCard {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(loading ? "Reading the archive…" : "No calls yet")
                            .font(NotchType.rowTitle)
                        Text("A call appears here as soon as one finishes.")
                            .font(NotchType.rowDetail)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                SettingCard("Calls", detail: "Newest first.") {
                    VStack(spacing: 0) {
                        ForEach(calls) { call in
                            callRow(call)
                            if call.id != calls.last?.id {
                                Divider().padding(.vertical, 2)
                            }
                        }
                    }
                }
            }

            if let selected {
                transcriptCard(for: selected)
            }
        }
        .task { await load() }
    }

    private func callRow(_ call: CallaCallSummary) -> some View {
        HStack(spacing: 10) {
            SettingGlyph(symbol: "waveform", tint: NotchTint.active, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? call.id)
                    .font(NotchType.rowTitle)
                Text(subtitle(for: call))
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            SettingBadge(CallaCopilotPersona.title(call.persona))
            Button(selected?.id == call.id ? "Hide" : "Open") { toggle(call) }
                .controlSize(.small)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func transcriptCard(for call: CallaCallSummary) -> some View {
        SettingCard(call.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? call.id) {
            VStack(alignment: .leading, spacing: 10) {
                if turns.isEmpty {
                    Text("This call has no saved turns.")
                        .font(NotchType.rowDetail)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        // Same bubble treatment as the live panel, so a
                        // transcript read afterwards looks like the one read
                        // during the call.
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(turns) { turn in
                                HStack(spacing: 0) {
                                    if !turn.isRemote { Spacer(minLength: 48) }
                                    Text(turn.text)
                                        .font(.system(size: 11))
                                        .multilineTextAlignment(turn.isRemote ? .leading : .trailing)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(
                                            turn.isRemote ? Color.blue.opacity(0.14) : Color.primary.opacity(0.06),
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    if turn.isRemote { Spacer(minLength: 48) }
                                }
                            }
                        }
                        .padding(10)
                    }
                    .frame(maxHeight: 320)
                    .background(NotchSurface.sunken,
                                in: RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous))
                }

                HStack(spacing: 8) {
                    Button("Export…") { export(call) }
                        .controlSize(.small)
                        .disabled(turns.isEmpty)
                    if call.hasAudio {
                        Button("Re-transcribe with the large model") {
                            engine.retranscribe(callID: call.id)
                        }
                        .controlSize(.small)
                        .help("Runs the archive model over the saved audio. Slower, and more accurate.")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Data

    private func toggle(_ call: CallaCallSummary) {
        guard selected?.id != call.id else {
            selected = nil
            turns = []
            return
        }
        selected = call
        turns = []
        engine.fetchCallTranscript(callID: call.id) { turns = $0 }
    }

    private func load() async {
        loading = true
        engine.fetchCalls { fetched in
            calls = fetched
            loading = false
        }
    }

    private func subtitle(for call: CallaCallSummary) -> String {
        var parts: [String] = []
        if let duration = call.duration {
            let total = Int(duration)
            parts.append(String(format: "%d:%02d", total / 60, total % 60))
        }
        parts.append("\(call.turnCount) turn\(call.turnCount == 1 ? "" : "s")")
        if call.hasAudio { parts.append("audio kept") }
        return parts.joined(separator: " · ")
    }

    /// Writing to a location the user picked is the one file write the sandbox
    /// allows without an entitlement, which is why this is a save panel and not
    /// a Downloads folder drop.
    private func export(_ call: CallaCallSummary) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "call-\(call.startedAt.map { ISO8601DateFormatter().string(from: $0) } ?? call.id).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let body = turns.map { turn in
            let clock = Int(max(0, turn.t0))
            let who = turn.isRemote ? "THEM" : "ME"
            return String(format: "[%d:%02d] %@: %@", clock / 60, clock % 60, who, turn.text)
        }.joined(separator: "\n")

        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[Copilot] transcript export failed: %@", String(describing: error))
        }
    }
}
