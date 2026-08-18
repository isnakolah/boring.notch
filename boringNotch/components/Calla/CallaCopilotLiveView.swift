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

    /// Controls appear under the pointer. See the overlay in `body`.
    @State private var showsControls = false

    @Default(.callaCopilotPanelSurface) private var surface

    /// Answers as they arrive, newest last.
    ///
    /// The engine only ever carries the *latest* suggestion — it is a status poll,
    /// not a feed — so a call's earlier pointers were simply lost. Keeping them here
    /// is what makes the compact panel a stream rather than a single line that
    /// silently replaces itself.
    @State private var answers: [LiveAnswer] = []
    /// When the newest answer arrived, which decides whether it still earns the
    /// space or the rolling account should have it back.
    @State private var lastAnswerAt: Date?

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
        .padding(.bottom, 8)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { showsControls = hovering }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(clockTick) { value in now = value }
        .onChange(of: copilot.suggestionAfterSeq) { _, seq in
            guard let seq, let headline = copilot.headline?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !headline.isEmpty, answers.last?.id != seq
            else { return }
            answers.append(LiveAnswer(id: seq, headline: headline, angles: copilot.angles))
            lastAnswerAt = Date()
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
                    .defaultScrollAnchor(.top)
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
            // Both layouts carry it. In the two-column view it sits over the pointer
            // column, where the eye already goes to read the answer.
            activityChip
            switch mode {
            case .suggesting:
                suggestion
            case .halfDeaf:
                note("Mic only", detail: "Grant Screen Recording so the other side of the call is transcribed.", tint: .orange)
            case .listening, .ready, .unavailable:
                // No question on the table is not the same as nothing to say.
                // A rolling account of where the conversation has got to is
                // worth the space between questions — it is what you need when
                // you are asked "what do you think?" about the last two
                // minutes. A real pointer always outranks it.
                // The account holds this column between questions, which is most of
                // a call.
                if let summary = copilot.summary, !summary.isEmpty {
                    let account = splitSummary(summary)
                    VStack(alignment: .leading, spacing: 6) {
                        tintedLabel("SO FAR", tint: Surface.summary.tint)
                        // The standing paragraph is the earlier part of the call,
                        // folded once it stopped being what anyone is discussing. It
                        // sits above the points as background, not as a headline.
                        if !account.standing.isEmpty {
                            Text(account.standing)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // Appended at the bottom, and the last line reads loudest:
                        // it is what is being discussed now, the ones above are
                        // what led there. Only the tail fits this column, which
                        // has no room to scroll beside the transcript.
                        let recent = Array(account.points.suffix(5))
                        ForEach(Array(recent.enumerated()), id: \.offset) { index, point in
                            bullet(point, tint: index == recent.count - 1 ? .white : .secondary)
                        }
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
    /// What the copilot is doing, right now.
    ///
    /// Three states that look identical without it: hearing you, hearing them, and
    /// working on an answer. Colour carries the distinction at a glance — blue is
    /// the other side, white is you, accent is the copilot itself — and the icon
    /// carries it for anyone who cannot rely on colour.
    private var activityChip: some View {
        HStack(spacing: 5) {
            Image(systemName: activity.symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(activity.tint)
                .symbolEffect(.variableColor.iterative, isActive: activity.animates)
            Text(activity.label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(activity.tint)
                .fixedSize()
            Spacer(minLength: 0)
        }
    }

    private enum Activity {
        case them, you, answering, summarising, idle

        var label: String {
            switch self {
            case .them: "THEM SPEAKING"
            case .you: "YOU SPEAKING"
            case .answering: "FINDING AN ANSWER"
            // Named differently because it takes longer: four seconds labelled
            // "finding an answer" reads as a stall; the same wait labelled "catching
            // up" reads as work.
            case .summarising: "CATCHING UP"
            case .idle: "LISTENING"
            }
        }

        var symbol: String {
            switch self {
            case .them: "waveform"
            case .you: "mic.fill"
            case .answering: "sparkles"
            case .summarising: "text.append"
            case .idle: "ear"
            }
        }

        var tint: Color {
            switch self {
            case .them: .blue
            case .you: Color.white.opacity(0.8)
            // The copilot's own colour, used nowhere else in the panel.
            case .answering: .accentColor
            // Quieter than answering: background work, not the thing being waited on
            // mid-sentence.
            case .summarising: Color.accentColor.opacity(0.65)
            case .idle: Color.white.opacity(0.4)
            }
        }

        /// Only the working states animate. A panel where everything moves tells you
        /// nothing about which thing is moving.
        var animates: Bool { self == .answering || self == .summarising }
    }

    private var activity: Activity {
        switch copilot.working {
        case "answer": return .answering
        case "summary": return .summarising
        default: break
        }
        switch copilot.speaking {
        case "them": return .them
        case "me": return .you
        default: return .idle
        }
    }

    /// Whether an answer is what the panel should be showing.
    ///
    /// A pointer is worth the space while it is still about the question on the
    /// table. After that the rolling account is the more useful thing, and going
    /// back to it is how the panel stops showing a stale answer to a question that
    /// was settled two minutes ago.
    private var answerIsCurrent: Bool {
        guard copilot.answering, !answers.isEmpty else { return false }
        guard let arrived = lastAnswerAt else { return false }
        return Date().timeIntervalSince(arrived) < 45
    }

    /// The two things the panel can be showing, and the colour that says which.
    ///
    /// An answer takes the panel on its own whenever a question is live, so the
    /// switcher is not a reliable read of what is currently on screen — you can
    /// have Summary selected and be looking at an answer. One colour per kind,
    /// carried by the rail, the heading and the bullets, answers the question
    /// "which am I reading" without anything having to be read.
    private enum Surface {
        case answers, summary

        /// Green speaks, blue records. Neither collides with the orange this panel
        /// already uses for things that need checking.
        var tint: Color {
            switch self {
            case .answers: Color(red: 0.36, green: 0.86, blue: 0.62)
            case .summary: Color(red: 0.42, green: 0.68, blue: 1)
            }
        }

        var heading: String {
            switch self {
            case .answers: "SAY THIS"
            case .summary: "SO FAR"
            }
        }
    }

    /// What the compact panel is actually showing. Mirrors the fallthrough in
    /// `compactStream`, and is the single place either can be changed.
    private var shownSurface: Surface {
        if answerIsCurrent, !answers.isEmpty { return .answers }
        if surface == "answers", !answers.isEmpty { return .answers }
        return .summary
    }

    /// The small panel: everything the big one has, minus the transcript column.
    ///
    /// Its rule is that it is never blank. A call panel showing nothing is
    /// indistinguishable from a broken one, and the earlier version managed exactly
    /// that — before the first brief was compiled and before anything had been
    /// asked, both surfaces were empty and the panel showed an empty box for the
    /// first minute of every call.
    ///
    /// So it falls through, most useful first: an answer while a question is live,
    /// the compiled account once there is one, and what was just said until then.
    private var compactStream: some View {
        let showing = shownSurface
        return VStack(alignment: .leading, spacing: 6) {
            activityChip

            HStack(alignment: .top, spacing: 8) {
                // A rail down the side, in the surface's colour. Cheaper to read
                // than a heading — it is in peripheral vision before the eye has
                // landed on any word.
                Capsule()
                    .fill(showing.tint.opacity(0.55))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 5) {
                    // An answer takes the panel while it is still about the question
                    // on the table, whichever surface is selected — that is the whole
                    // point of the thing. After that, the selection decides, and the
                    // account gives way to plain speech only until it exists.
                    let hasAccount = !(copilot.summary ?? "").isEmpty
                    Text(showing == .summary && !hasAccount ? "JUST SAID" : showing.heading)
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(showing.tint.opacity(0.9))

                    if showing == .answers {
                        answerScroller
                    } else if let summary = copilot.summary, !summary.isEmpty {
                        summaryBlock(summary)
                    } else {
                        recentSpeech
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .animation(.easeOut(duration: 0.18), value: showing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The compiled account, given the whole panel because between questions it is
    /// the whole point.
    private func summaryBlock(_ summary: String) -> some View {
        let account = splitSummary(summary)
        // A log that follows its own bottom, like the transcript beside it. New
        // points are appended below; what is already on screen never moves, so a
        // glance costs one line of reading rather than re-finding your place.
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    if !account.standing.isEmpty {
                        Text(account.standing)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(.bottom, 2)
                    }
                    ForEach(Array(account.points.enumerated()), id: \.offset) { index, point in
                        let isNewest = index == account.points.count - 1
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(isNewest
                                      ? Surface.summary.tint.opacity(0.9)
                                      : Color.white.opacity(0.35))
                                .frame(width: 3.5, height: 3.5)
                                .padding(.top, isNewest ? 6 : 5)
                            Text(point)
                                .font(.system(size: isNewest ? 12 : 11, weight: isNewest ? .medium : .regular))
                                .foregroundStyle(Color.white.opacity(isNewest ? 0.97 : 0.72))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .id(index)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                    if !copilot.openQuestions.isEmpty {
                        label("STILL OPEN")
                        ForEach(Array(copilot.openQuestions.prefix(2).enumerated()), id: \.offset) { _, item in
                            bullet(item, tint: .blue)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            // Same reasoning as the transcript: the anchor keeps the view pinned as
            // content grows, and the explicit scroll lands the animation once the
            // new row has actually laid out.
            .defaultScrollAnchor(.bottom)
            .onChange(of: account.points.count) { _, count in
                Task { @MainActor in
                    await Task.yield()
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
            .onAppear { proxy.scrollTo(account.points.count - 1, anchor: .bottom) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The resting state: what was actually just said.
    ///
    /// Available from the first turn, which is what makes the blank minute
    /// impossible — and it is genuinely useful, because the thing you most want
    /// after glancing away is the sentence you missed.
    @ViewBuilder
    private var recentSpeech: some View {
        if turns.isEmpty {
            note("Listening…",
                 detail: "What is said appears here, then a running account, then answers when you are asked something.",
                 tint: .secondary)
        } else {
            // No heading of its own: the surface rail above already names it, and
            // two labels in a panel this small is one too many.
            VStack(alignment: .leading, spacing: 5) {
                ForEach(turns.suffix(2)) { turn in
                    HStack(alignment: .top, spacing: 6) {
                        Text(turn.isRemote ? "THEM" : "YOU")
                            .font(.system(size: 8.5, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(turn.isRemote ? Color.blue : Color.white.opacity(0.5))
                            .frame(width: 34, alignment: .leading)
                            .padding(.top, 2)
                        Text(turn.text)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.white.opacity(turn.seq == turns.last?.seq ? 0.95 : 0.6))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var answerScroller: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(answers) { answer in
                        answerRow(answer, isNewest: answer.id == answers.last?.id)
                            .id(answer.id)
                    }
                }
                .padding(.vertical, 1)
            }
            .defaultScrollAnchor(.top)
            .onChange(of: answers.last?.id) { _, id in
                guard let id else { return }
                // `.top`, so a wrapped headline starts at its first line instead of
                // being clipped by the panel's edge.
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    /// One point per line, as the brief writes them.
    ///
    /// Strips any bullet character a model added despite being asked not to, because
    /// the alternative is a stray "-" sitting in the panel.
    private func summaryPoints(_ summary: String) -> [String] {
        summary
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-•*·")) }
            .filter { !$0.isEmpty }
    }

    /// The account arrives as one string: the standing paragraph, a blank line,
    /// then the points. One field rather than two because the gateway writes this
    /// same frame and knows nothing about a fold — with no blank line, everything
    /// is points, which is exactly what it used to be.
    private func splitSummary(_ summary: String) -> (standing: String, points: [String]) {
        guard let gap = summary.range(of: "\n\n") else {
            return ("", summaryPoints(summary))
        }
        return (
            String(summary[summary.startIndex ..< gap.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines),
            summaryPoints(String(summary[gap.upperBound...]))
        )
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
                    bullet(angle, tint: Surface.answers.tint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    tintedLabel("SAY THIS", tint: Surface.answers.tint)
                    ForEach(Array(CallaCopilotPresentation.angleLines(copilot.angles, limit: 3, characters: 140).enumerated()), id: \.offset) { _, angle in
                        bullet(angle, tint: Surface.answers.tint)
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

    /// The same heading in a surface's colour, for the two-column layout where
    /// both surfaces are on screen at once and only the colour tells them apart.
    private func tintedLabel(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(tint.opacity(0.9))
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

    /// One slim row, and only while the pointer is in the panel.
    ///
    /// Between glances there is nothing here worth a line of a panel this small —
    /// the account should have it. Note what this is *not*: an overlay that appears
    /// on hover. That was tried, and it covered the text and swallowed the first
    /// click, because hit testing only switched on once the pointer was already over
    /// a button. This keeps the row in the layout and collapses it, and hover is the
    /// whole panel rather than the row, so the controls are already up and hittable
    /// long before the pointer arrives at them.
    private var footer: some View {
        HStack(spacing: 6) {
            controlButton(
                "xmark.circle.fill",
                label: "End call",
                tint: .red,
                help: "End the call"
            ) { engine.endCall() }

            // Two independent switches: either, both, or neither. Cheap to flip
            // because every suggestion already carries both fields — this chooses
            // what is worth the space, not what gets asked for.
            // A choice, not two switches: both jobs run either way.
            // The selected button carries its surface's own colour, so the switcher
            // and the thing on screen say the same thing in the same hue.
            controlButton(
                "bubble.left.fill",
                label: "Answers",
                tint: surface == "answers" ? Surface.answers.tint : Color.white.opacity(0.45),
                help: "Show what to say next. Questions are answered either way."
            ) { surface = "answers" }

            controlButton(
                "text.alignleft",
                label: "Summary",
                tint: surface == "summary" ? Surface.summary.tint : Color.white.opacity(0.45),
                help: "Show the running account. It keeps building either way."
            ) { surface = "summary" }

            if !copilot.gatewayConnected {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help("The gateway is unreachable")
            }
            Spacer(minLength: 0)
            Text(CallaCopilotPresentation.subtitle(
                turnCount: copilot.turnCount,
                elapsed: nil,
                gatewayConnected: copilot.gatewayConnected))
                .font(.system(size: 9))
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .frame(height: showsControls ? 18 : 0, alignment: .top)
        .opacity(showsControls ? 1 : 0)
        .allowsHitTesting(showsControls)
        .clipped()
    }

    private func controlButton(
        _ symbol: String,
        label: String,
        tint: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                if showsControls {
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .fixedSize()
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
/// Shared with the idle panel, which shows the same armed/idle dot.
struct LivePulse: View {
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
