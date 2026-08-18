//
//  CopilotCallDetailPane.swift
//  boringNotch
//

import SwiftUI

/// One archived call, on a page of its own.
///
/// This used to expand in place above the list: opening a call pushed the list
/// down the pane, and the thing you were reading and the thing you were choosing
/// from competed for the same scroll. A call has a transcript, a timeline and
/// whatever the copilot said — that is a page, not a disclosure.
///
/// The Timeline / Transcript / Copilot control stays a segmented picker rather
/// than becoming three more destinations. It re-filters one dataset; it does not
/// swap unrelated content. That is the line between a control and navigation in
/// disguise, and it is worth not blurring the next time someone tidies this.
struct CopilotCallDetailPane: View {
    let callID: String

    @ObservedObject private var engine = CallaEngineClient.shared
    @Environment(\.settingsRouter) private var router

    @State private var call: CallaCallSummary?
    @State private var turns: [CallaCallTurn] = []
    @State private var suggestions: [CallaCopilotArchivedSuggestion] = []
    @State private var view: DetailView = .timeline
    @State private var loading = true

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
        SettingsPane(SettingsPage.copilotCallDetail(id: callID), titleOverride: title) {
            if let call {
                overviewCard(for: call)
                detailCard(for: call)
            } else if loading {
                SettingCard {
                    HStack(spacing: NotchSpace.snug) {
                        ProgressView().controlSize(.small)
                        Text("Reading the call\u{2026}").font(NotchType.rowDetail).foregroundStyle(.secondary)
                    }
                }
            } else {
                SettingsEmptyState(
                    symbol: "waveform.slash",
                    title: "This call is no longer in the archive",
                    detail: "It may have been exported and removed, or the archive was cleared.",
                    actionTitle: "Back to History",
                    action: { router?.pop() })
            }
        }
        .task { await load() }
    }

    private var title: String {
        call?.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Call"
    }

    private func load() async {
        loading = true
        let summaries: [CallaCallSummary] = await withCheckedContinuation { continuation in
            engine.fetchCalls { continuation.resume(returning: $0) }
        }
        call = summaries.first { $0.id == callID }
        loading = false
        guard call != nil else { return }
        engine.fetchCallTranscript(callID: callID) { turns = $0 }
        engine.fetchCallSuggestions(callID) { suggestions = $0 }
    }

    private func overviewCard(for call: CallaCallSummary) -> some View {
        SettingCard(call.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? call.id) {
            VStack(alignment: .leading, spacing: 10) {
                SettingFact(title: "Persona", value: CallaCopilotPersona.title(call.persona))
                if let duration = call.duration {
                    SettingFact(title: "Length", value: callClock(duration))
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
