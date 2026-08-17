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
    @ObservedObject private var engine = CallaEngineClient.shared

    @State private var calls: [CallaCallSummary] = []
    @State private var selected: CallaCallSummary?
    @State private var turns: [CallaCallTurn] = []
    @State private var suggestions: [CallaCopilotArchivedSuggestion] = []
    @State private var view: DetailView = .timeline
    @State private var loading = false
    /// Calls waiting their turn for the large model.
    @State private var queued: [String] = []

    /// The three ways a finished call is worth reading.
    private enum DetailView: String, CaseIterable, Identifiable {
        case timeline, transcript, advice
        var id: String { rawValue }

        var title: String {
            switch self {
            case .timeline: "Timeline"
            case .transcript: "Transcript"
            case .advice: "Copilot"
            }
        }
    }

    var body: some View {
        SettingsPane(
            eyebrow: "Call copilot",
            title: "History",
            detail: "Transcripts and advice stay on this Mac. Nothing here has been uploaded anywhere."
        ) {
            if let selected {
                overviewCard(for: selected)
                detailCard(for: selected)
            }
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
            Button(selected?.id == call.id ? "Hide" : "Open") { toggle(call) }
                .controlSize(.small)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    // MARK: - Overview

    private func overviewCard(for call: CallaCallSummary) -> some View {
        SettingCard(call.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? call.id) {
            VStack(alignment: .leading, spacing: 10) {
                SettingFact(title: "Persona", value: CallaCopilotPersona.title(call.persona))
                if let duration = call.duration {
                    SettingFact(title: "Length", value: clock(duration))
                }
                SettingFact(title: "Turns transcribed", value: "\(call.turnCount)")
                // The two numbers side by side are the point: a re-transcribed pass
                // that found more turns is visibly better than the live one.
                SettingFact(
                    title: "Re-transcribed",
                    value: call.retranscribed
                        ? "yes — \(call.archivedTurnCount) turns with the large model"
                        : "not yet",
                    tint: call.retranscribed ? NotchTint.healthy : nil
                )
                SettingFact(
                    title: "Copilot suggestions",
                    value: "\(call.suggestionCount)",
                    tint: call.suggestionCount == 0 ? NotchTint.attention : nil
                )
                SettingFact(title: "Audio", value: call.hasAudio ? "kept on disk" : "discarded")

                HStack(spacing: 8) {
                    Button("Export…") { export(call) }
                        .controlSize(.small)
                        .disabled(turns.isEmpty)
                    if call.hasAudio {
                        Button(call.retranscribed
                               ? "Re-transcribe again"
                               : "Re-transcribe with the large model") {
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

    // MARK: - Detail

    private func detailCard(for call: CallaCallSummary) -> some View {
        SettingCard(detailTitle, detail: detailSubtitle(for: call)) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $view) {
                    ForEach(DetailView.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        switch view {
                        case .timeline: timelineRows
                        case .transcript: transcriptRows
                        case .advice: adviceRows
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 340)
                .background(NotchSurface.sunken,
                            in: RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous))
            }
        }
    }

    private var detailTitle: String {
        switch view {
        case .timeline: "What happened"
        case .transcript: "Transcript"
        case .advice: "What the copilot said"
        }
    }

    private func detailSubtitle(for call: CallaCallSummary) -> String {
        switch view {
        case .timeline: "Turns and the copilot's advice, in the order they happened."
        case .transcript: "\(turns.count) turn\(turns.count == 1 ? "" : "s"), as transcribed on this Mac."
        case .advice:
            call.suggestionCount == 0
                ? "Nothing was returned during this call."
                : "\(call.suggestionCount) suggestion\(call.suggestionCount == 1 ? "" : "s")."
        }
    }

    /// Turns and advice interleaved.
    ///
    /// A suggestion answers a particular turn — that is what `after_seq` records —
    /// so showing them apart loses the only thing that makes the advice
    /// interpretable afterwards: what it was responding to.
    @ViewBuilder
    private var timelineRows: some View {
        if turns.isEmpty {
            emptyNote("This call has no saved turns.")
        } else {
            ForEach(turns) { turn in
                turnBubble(turn)
                ForEach(suggestions.filter { $0.afterSeq == turn.seq }) { suggestion in
                    adviceBlock(suggestion, showSeq: false)
                }
            }
            // Advice that answers a turn no longer in the transcript still belongs
            // somewhere, rather than being silently dropped.
            let orphans = suggestions.filter { suggestion in
                !turns.contains { $0.seq == suggestion.afterSeq }
            }
            ForEach(orphans) { adviceBlock($0, showSeq: true) }
        }
    }

    @ViewBuilder
    private var transcriptRows: some View {
        if turns.isEmpty {
            emptyNote("This call has no saved turns.")
        } else {
            ForEach(turns) { turnBubble($0) }
        }
    }

    @ViewBuilder
    private var adviceRows: some View {
        if suggestions.isEmpty {
            emptyNote("The copilot produced no advice — either it was not asked, or it could not answer.")
        } else {
            ForEach(suggestions) { adviceBlock($0, showSeq: true) }
        }
    }

    /// Them left, you right — the same split the live panel uses, so a transcript
    /// read afterwards looks like the one read during the call.
    private func turnBubble(_ turn: CallaCallTurn) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if !turn.isRemote { Spacer(minLength: 36) }
            // Named, not just positioned. Left-versus-right is learnable during a
            // call and ambiguous a week later, and this is the only speaker
            // attribution that is actually known: the two capture legs are never
            // mixed, so "me" and "them" are recorded rather than guessed.
            if turn.isRemote { speakerTag("Them", tint: .blue) }
            Text(turn.text)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    turn.isRemote ? Color.blue.opacity(0.16) : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if !turn.isRemote { speakerTag("You", tint: .secondary) }
            if turn.isRemote { Spacer(minLength: 36) }
        }
    }

    private func speakerTag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.top, 5)
            .frame(width: 32, alignment: turn_alignment(text))
    }

    private func turn_alignment(_ text: String) -> Alignment {
        text == "Them" ? .trailing : .leading
    }

    private func adviceBlock(_ suggestion: CallaCopilotArchivedSuggestion, showSeq: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(NotchTint.active)
                Text(showSeq ? "copilot · after turn \(suggestion.afterSeq)" : "copilot")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            if !suggestion.headline.isEmpty {
                Text(suggestion.headline)
                    .font(.system(size: 11, weight: .medium))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(suggestion.angles.enumerated()), id: \.offset) { _, angle in
                Text("• \(angle)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(suggestion.confirm.enumerated()), id: \.offset) { _, item in
                Text("check: \(item)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(NotchTint.attention)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NotchTint.active.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(NotchType.rowDetail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Data

    private func toggle(_ call: CallaCallSummary) {
        guard selected?.id != call.id else {
            selected = nil
            turns = []
            suggestions = []
            return
        }
        selected = call
        turns = []
        suggestions = []
        engine.fetchCallTranscript(callID: call.id) { turns = $0 }
        engine.fetchCallSuggestions(call.id) { suggestions = $0 }
    }

    private func load() async {
        loading = true
        engine.fetchCalls { fetched in
            calls = fetched
            loading = false
        }
    }

    private func clock(_ duration: TimeInterval) -> String {
        let total = Int(duration)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func subtitle(for call: CallaCallSummary) -> String {
        var parts: [String] = []
        if let duration = call.duration { parts.append(clock(duration)) }
        parts.append("\(call.turnCount) turn\(call.turnCount == 1 ? "" : "s")")
        if call.suggestionCount > 0 { parts.append("\(call.suggestionCount) suggested") }
        if call.hasAudio { parts.append("audio kept") }
        return parts.joined(separator: " · ")
    }

    /// Writing to a location the user picked is the one file write the sandbox
    /// allows without an entitlement, which is why this is a save panel and not a
    /// Downloads folder drop.
    ///
    /// Exports the timeline rather than the transcript alone: the advice is half of
    /// what happened, and it is only interpretable next to the turn it answered.
    private func export(_ call: CallaCallSummary) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "call-\(call.startedAt.map { ISO8601DateFormatter().string(from: $0) } ?? call.id).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var lines: [String] = []
        for turn in turns {
            let stamp = Int(max(0, turn.t0))
            let who = turn.isRemote ? "THEM" : "ME"
            lines.append(String(format: "[%d:%02d] %@: %@", stamp / 60, stamp % 60, who, turn.text))
            for suggestion in suggestions where suggestion.afterSeq == turn.seq {
                if !suggestion.headline.isEmpty { lines.append("         COPILOT: \(suggestion.headline)") }
                for angle in suggestion.angles { lines.append("                  • \(angle)") }
                for item in suggestion.confirm { lines.append("                  check: \(item)") }
            }
        }

        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSSound.beep()
        }
    }
}
