import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

/// Calls that already happened.
///
/// Every call has been archived to disk since the copilot shipped and nothing ever
/// showed them. The app is sandboxed and cannot read the capture host's files, so
/// all of this arrives through the engine.
///
/// Structured around one selected call, because that is the question people bring
/// here: what happened on *that* call — what was said, what the copilot said back,
/// and whether the better model has been over it since.
struct CopilotHistoryPane: View {
    @Environment(\.settingsRouter) private var router

    @ObservedObject private var engine = CallaEngineClient.shared

    @State private var calls: [CallaCallSummary] = []
    @State private var loading = false
    /// Calls waiting their turn for the large model.
    @State private var queued: [String] = []


    var body: some View {
        SettingsPane(SettingsPage.copilotHistory) {
            pendingRetranscribeCard
            callsCard
        }
        .task { await load() }
        // The badge and the counts only change when a run finishes, so the list is
        // re-read then rather than left stale until the pane is reopened.
        .onChange(of: retranscribingID) { previous, current in
            guard previous != nil, current == nil else { return }
            Task { await load() }
            startNextRetranscribe()
        }
    }

    // MARK: - Re-transcribing

    /// Calls with audio still on disk that the large model has not been over.
    private var pending: [CallaCallSummary] {
        calls.filter { $0.hasAudio && !$0.retranscribed }
    }

    private var retranscribingID: String? { engine.status.copilot.retranscribingCallID }

    @ViewBuilder
    private var pendingRetranscribeCard: some View {
        if !pending.isEmpty || retranscribingID != nil {
            SettingCard(
                "Better transcripts",
                detail: "The large model is slower and more accurate. It runs on the saved audio, after the fact.",
                tint: retranscribingID != nil ? NotchTint.active : nil
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    if let active = retranscribingID {
                        SettingRow(
                            "Re-transcribing now",
                            detail: "\(active) — this takes a few minutes per call."
                        ) {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if !pending.isEmpty {
                        SettingRow(
                            "\(pending.count) call\(pending.count == 1 ? "" : "s") not re-transcribed",
                            detail: "Runs one at a time; the next starts when the current one finishes."
                        ) {
                            Button(pending.count == 1 ? "Re-transcribe" : "Re-transcribe all") {
                                queued = pending.map(\.id)
                                startNextRetranscribe()
                            }
                            .controlSize(.small)
                            .disabled(retranscribingID != nil)
                        }
                    }
                    if let result = engine.status.copilot.lastResult,
                       result.lowercased().contains("transcrib") {
                        Text(result)
                            .font(NotchType.rowDetail)
                            .foregroundStyle(result.lowercased().contains("fail") ? NotchTint.attention : .secondary)
                    }
                }
            }
        }
    }

    /// Sequential, because the engine refuses a second concurrent run — and because
    /// two large-model passes at once would fight over the same cores.
    private func startNextRetranscribe() {
        guard retranscribingID == nil, let next = queued.first else { return }
        queued.removeFirst()
        engine.retranscribe(callID: next)
    }

    // MARK: - Calls

    @ViewBuilder
    private var callsCard: some View {
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
            // Whether the large model has been over this call. Previously
            // indistinguishable from a call that was never re-transcribed.
            if call.retranscribed {
                SettingBadge("Re-transcribed", tint: NotchTint.healthy)
            }
            // Zero advice against a full transcript is the case worth surfacing: the
            // copilot was running and never answered.
            if call.suggestionCount == 0, call.turnCount > 0 {
                SettingBadge("No advice", tint: NotchTint.attention)
            }
            SettingBadge(CallaCopilotPersona.title(call.persona))
            Image(systemName: "chevron.forward")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        // A call opens on its own page. It used to expand in place, which pushed
        // the list you were choosing from off the screen with the thing you had
        // chosen.
        .onTapGesture { router?.push(.copilotCallDetail(id: call.id)) }
    }

    // MARK: - Overview


    // MARK: - Detail












    // MARK: - Data


    private func load() async {
        loading = true
        engine.fetchCalls { fetched in
            calls = fetched
            loading = false
        }
    }


    private func subtitle(for call: CallaCallSummary) -> String {
        var parts: [String] = []
        if let duration = call.duration { parts.append(callClock(duration)) }
        parts.append("\(call.turnCount) turn\(call.turnCount == 1 ? "" : "s")")
        if call.suggestionCount > 0 { parts.append("\(call.suggestionCount) suggested") }
        if call.hasAudio { parts.append("audio kept") }
        return parts.joined(separator: " · ")
    }

}
