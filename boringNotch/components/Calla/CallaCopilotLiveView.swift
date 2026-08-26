//
//  CallaCopilotLiveView.swift
//  boringNotch
//

import Defaults
import KeyboardShortcuts
import SwiftUI

/// The notch during a live call, drawn from `NotchGlass`.
///
/// Replaces the standalone window this feature shipped with. That window was
/// readable but visible in every screen share, which for a call copilot is the
/// one failure that cannot be traded away — so the surface moved into the notch
/// panel, which already knows how to drop out of a recording.
///
/// Two layouts, one slab. A call keeps `copilotNotchSize` in both: collapsing
/// drops the transcript, never the panel, because a notch that shrinks mid-call
/// reads as the call having ended.
///
/// **Collapsed** is the resting layout — one answer, the line that prompted it,
/// and nothing else. It is read in the half-second before you have to speak.
/// **Expanded** gives the answer the left column and lets the transcript earn
/// the rest: three turns, newest at full ink, the two before it at tertiary.
/// Nothing older, because reading further costs more time than it saves
/// mid-sentence — the archive is a settings pane.
///
/// One answer is on screen at a time in both. A new suggestion replaces the one
/// before it; it does not stack.
///
/// Colour has exactly two jobs here, and they are split by band. In the header
/// band, green and amber report *capture* — whether both sides are being heard,
/// whether the panel is out of the screen share. Inside the card, the accent
/// marks *the newest thing*: the live answer's heading, the rail on the point
/// that just landed, the label on the turn being spoken. Amber inside the card
/// is reserved for what needs checking before it is said aloud. Nothing else is
/// coloured — four turns of grey and one accented line is what gives the column
/// a place for the eye to land.
struct CallaCopilotLiveView: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var session = CopilotLiveSession.shared

    @State private var turns: [CallaCallTurn] = []
    @State private var now = Date()
    @State private var showsManualQuestion = false
    @State private var manualQuestion = ""

    /// Controls are an overlay on the card, not a band under it, and they stay
    /// out of the way until the pointer is on the panel. A permanent row cost
    /// the card 36pt of a surface that was already short — and on a call the
    /// thing worth reading is the answer, not four buttons that do not change.
    @State private var showsControls = false

    @Default(.callaCopilotPanelSurface) private var surface

    /// Answers as they arrive, newest last.
    ///
    /// The engine only ever carries the *latest* suggestion — it is a status poll,
    /// not a feed — so a call's earlier pointers were simply lost. Keeping them here
    /// is what lets the panel fall back to the previous answer rather than to blank.
    @State private var answers: [LiveAnswer] = []
    struct LiveAnswer: Identifiable, Equatable {
        let id: Int
        let headline: String
        let angles: [String]
    }

    /// Fast enough that a turn appears while it is still the thing being
    /// answered. The engine hands back only what is newer than `lastSeq`, so
    /// the cost of the shorter interval is a near-empty reply, not a re-read.
    ///
    /// A third of a second because the collapsed panel is subtitles now, and
    /// subtitles that arrive up to 0.8s after the words did read as lag rather
    /// than as captions. There is no interim transcript to poll for — turns are
    /// whole utterances, cut by the VAD — so this is the only part of the delay
    /// the app owns, and it should not be the part that shows.
    private let transcriptTick = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()
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
        VStack(alignment: .leading, spacing: NotchGlassSpace.snug) {
            // A geometry reader rather than a fixed column width. With the
            // answer pinned at 300pt and the transcript sized to its own ideal
            // width, the pair measured 512pt inside a 600pt panel and the root's
            // leading alignment dumped the whole 88pt remainder against the
            // right edge. Splitting the width that is actually there cannot do
            // that: the columns always add up to the panel.
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    // The answer is the reason the panel exists, so it takes the
                    // wider half rather than splitting evenly.
                    answerColumn
                        .frame(width: session.layout == .full
                               ? max(0, (geometry.size.width - 1) * 0.54)
                               : geometry.size.width,
                               alignment: .leading)
                    if session.layout == .full {
                        NotchColumnDivider()
                        transcriptColumn
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // Padded *inside* the geometry, never outside it. This was
                // `.frame(height: geometry.size.height)` followed by
                // `.padding(.top, 2)`, which makes the view two points taller
                // than the space it was given — so the bottom two points were
                // always drawn past the floor and cut by the clip. Small, and
                // exactly the kind of small that slices a caption in half.
                .frame(width: geometry.size.width - 4,
                       height: geometry.size.height - 2,
                       alignment: .leading)
                .padding(.top, 2)
                .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Content that outgrows its share is cut, never allowed to push.
            // Without this the card's intrinsic height wins the layout and the
            // footer is shoved past the frame — the controls end up drawn under
            // the notch's lower curve, which is where they went in the compact
            // panel during a real call.
            // The controls' strip is reserved always — never conditionally on
            // hover, which reflowed the whole panel under the pointer — but only
            // in the expanded panel, where the buttons are the content that band
            // holds. Collapsed reserves nothing: its caption belongs on the floor
            // of the panel, and 38pt of black under it was the "space at the
            // bottom" that kept coming up. Hovering a collapsed panel puts the
            // controls over the caption, which is a fair trade for a surface
            // whose whole job is a glance.
            .padding(.bottom, session.layout == .full ? NotchGlassSpace.control + 8 : 0)
            .clipped()
            // No card. The panel is already a surface — the notch's own glass —
            // and drawing a bordered card on it put a second edge a few points
            // inside the first, which is nesting rather than structure. The two
            // columns are separated by their divider and their headings; that is
            // all the structure this content needs, and dropping the fill hands
            // its padding and border back to the text.
            .overlay(alignment: .bottom) {
                if showsControls {
                    footer
                        .padding(.horizontal, 12)
                        .padding(.bottom, 2)
                        .background(alignment: .bottom) {
                            LinearGradient(colors: [.clear, .black.opacity(0.92)],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: 78)
                                .allowsHitTesting(false)
                        }
                        .transition(.opacity)
                }
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { showsControls = hovering }
        }
        // Tighter than a tab's. This panel is the one surface whose whole value
        // is how much of the conversation is on screen at once.
        // The card starts directly under the header band. Ten points of gap
        // between the state line and the first heading made the two read as
        // separate surfaces stacked on one another rather than one panel.
        .padding(.top, 0)
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(clockTick) { value in now = value }
        .onChange(of: copilot.suggestionAfterSeq) { _, seq in
            guard let seq, let headline = copilot.headline?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !headline.isEmpty, answers.last?.id != seq,
                  answers.last?.headline != headline
            else { return }
            answers.append(LiveAnswer(id: seq, headline: headline, angles: copilot.angles))
            if surface != "question" { session.markUnreadAnswer() }
            // A long call would otherwise grow this without bound.
            if answers.count > 30 { answers.removeFirst(answers.count - 30) }
        }
        .onReceive(transcriptTick) { _ in refresh() }
        .onAppear { refresh() }
        .animation(.smooth(duration: 0.25), value: session.layout)
        .alert("Answer this", isPresented: $showsManualQuestion) {
            TextField("Selected transcript text", text: $manualQuestion, axis: .vertical)
            Button("Answer") {
                let text = manualQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                engine.answerSelectedText(text)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Ask Copilot about selected or pasted transcript text.")
        }
    }

    // MARK: - The answer

    /// The one column both layouts keep.
    ///
    /// Its rule is that it is never blank. A call panel showing nothing is
    /// indistinguishable from a broken one, and an earlier version managed exactly
    /// that — before the first recap was compiled and before anything had been
    /// asked, the panel showed an empty box for the first minute of every call.
    ///
    /// So it falls through, most useful first: the live answer, the recap once
    /// there is one, and what was just said until then.
    private var answerColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            // No `Spacer` here any more. Collapsed still stacks upward from the
            // caption strip — `recapBody` and `answerBody` bottom-align inside
            // their own frames, which is what actually produces that — but a
            // spacer *plus* a child asking for infinite height is two greedy
            // children in one stack, and between them they took the space the
            // caption strip needed. The strip has priority, so it was never
            // supposed to lose; what it lost to was the stack being handed less
            // room than it asked for and resolving the shortfall by overflowing.
            // No heading here. It is drawn in the notch's header band, beside
            // the clock — a two-word label was costing a line of a panel whose
            // whole complaint was that the answer would not fit.
            Group {
                switch content {
                case .answer:
                    answerBody
                case .halfDeaf:
                    note("Only your side is being heard",
                         detail: "Grant Screen Recording so the other side of the call is transcribed.",
                         tint: NotchTint.attention)
                case .recap:
                    recapBody
                case .listening:
                    // No title: the heading above already says LISTENING, and
                    // "LISTENING / Listening…" spent two lines saying it twice.
                    Text("What is said appears here, then a running account, then an answer the moment there is a question worth one.")
                        .font(NotchGlassType.detail)
                        .foregroundStyle(NotchInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Collapsed keeps the only transcript there is: a caption strip
            // along the bottom.
            if session.layout == .compact, !turns.isEmpty {
                // Never the part that gives way. Everything above it can be
                // trimmed by a point or a line; the running caption is why the
                // collapsed panel is on screen at all.
                captionStream
                    .layoutPriority(1)
                    // Its height is 1pt of rule, 5 of spacing and one 15pt line:
                    // a fixed 21, and nothing above it may borrow from it.
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Collapsed sits closer to the edge: with one column and no heading
        // beside it there is nothing for a wide margin to align with, and the
        // width it costs is width the recap lines want.
        .padding(.leading, session.layout == .compact ? 5 : 10)
        .padding(.trailing, 10)
        // NOTE: the clip is applied *after* the frame below, not here. Clipping
        // first cuts to the column's own intrinsic bounds — which, when the
        // content overflows, are larger than the space available, so the clip
        // does nothing and the overflow is cut by the window instead: through
        // the middle of the caption line rather than through the oldest recap
        // line the mask was designed to take.
        // Top, level with the transcript's heading beside it.
        //
        // This was centred for a while, to stop a short answer floating above a
        // hand's width of empty card. With four recap points that reversed:
        // "SO FAR" sank a hundred points below "TRANSCRIPT" and the two columns
        // of one card read as two unrelated things. Two headings that begin at
        // different heights is the worse fault of the two, and the dead space
        // under a short answer belongs at the bottom where nothing has to align
        // with it.
        //
        // Collapsed anchors to the *bottom* instead, and that is the whole fix
        // for content being cut off at the floor of the panel. Top-aligned, an
        // account longer than the space overflows downward and the clip takes
        // the caption strip and the newest recap line with it — the two things
        // the collapsed panel exists to show. Anchored to the bottom, the same
        // overflow leaves through the top, where the mask already dissolves the
        // oldest line on purpose.
        // Both layouts anchor to the bottom. The account grows by appending, so
        // the newest line is the one worth reading and it belongs nearest the
        // eye — directly above the caption strip in the collapsed panel, and
        // level with the newest transcript turn beside it in the expanded one.
        // Top-aligned, a short account left the lower two thirds of the column
        // empty and a long one pushed its newest line off the floor.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        // Now that the bounds are the real ones, the clip cuts what it was meant
        // to cut and nothing reaches the window's edge.
        .clipped()
    }

    /// The collapsed panel's transcript: subtitles, not a log.
    ///
    /// It used to be one line prefixed "THEM, JUST NOW". The label was the
    /// larger half of a line whose whole job is the words, and who is speaking
    /// is already legible from the words themselves — so it reads as captions
    /// do: no speaker, no timestamp, the newest words always in view.
    ///
    /// Truncation is from the head for exactly that reason. A live turn grows
    /// at its end, so tail truncation would pin the panel to the start of a
    /// sentence and ellipsise the part being said right now.
    private var captionStream: some View {
        VStack(alignment: .leading, spacing: 5) {
            Rectangle()
                .fill(NotchInk.hairline)
                .frame(height: 1)
            Text(captionText)
                .font(NotchGlassType.detail)
                .foregroundStyle(NotchInk.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                // One line, filled from the bottom. It was two, and the second
                // line was the cheapest 15pt in the panel to give back when the
                // collapsed size came down: head truncation means the newest
                // words are on screen either way, and what the second line held
                // was the part already said.
                .frame(height: 15, alignment: .bottomLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.18), value: captionText)
                .textSelection(.enabled)
        }
    }

    /// The tail of the conversation as one running line. Two turns, because one
    /// leaves the strip empty every time a speaker changes.
    private var captionText: String {
        turns.suffix(2)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "  ")
    }

    private enum Content { case answer, recap, listening, halfDeaf }

    /// What the panel shows. **The reader's choice owns this**, and an arriving
    /// answer never takes the panel away from them.
    ///
    /// This flipped on its own: any answer while `mode == .suggesting` switched
    /// the panel to it, so a recap being read mid-call was yanked away and
    /// replaced by "Say this". Both lanes keep working regardless of which one
    /// is on screen; a new answer while the recap is up lights the unread dot on
    /// the Answers chip and waits to be asked for.
    private var content: Content {
        if mode == .halfDeaf, answers.isEmpty { return .halfDeaf }
        if surface == "question" {
            if !answers.isEmpty { return .answer }
            if let headline = copilot.headline, !headline.isEmpty { return .answer }
        }
        // Never blank: whichever surface is chosen falls back to what there is.
        if let summary = copilot.summary, !summary.isEmpty { return .recap }
        return .listening
    }

    /// The newest answer, and — collapsed or expanded — at most two supporting
    /// lines. `angleLines` caps them so the slab can never be grown by a verbose
    /// model.
    @ViewBuilder private var answerBody: some View {
        let latest = answers.last
        let headline = CallaCopilotPresentation.headlineLine(latest?.headline ?? copilot.headline,
                                                            limit: session.layout == .compact ? 150 : 110)
        // Collapsed carries the answer and the caption, and nothing between them:
        // the supporting lines are the first thing to go when the column is
        // short, because they are the part you can do without mid-sentence.
        let angles = CallaCopilotPresentation.angleLines(latest?.angles ?? copilot.angles,
                                                        limit: session.layout == .compact ? 0 : 3,
                                                        characters: 78)

        VStack(alignment: .leading, spacing: session.layout == .compact ? 8 : 11) {
            if let headline {
                Text(headline)
                    .font(session.layout == .compact
                          ? NotchGlassType.answerLarge
                          : NotchGlassType.answer)
                    .foregroundStyle(NotchInk.primary)
                    .lineLimit(4)
                    // The answer takes the lines it needs and nothing else gives
                    // way for it. Without these it was the flexible element in a
                    // column where the caption and the supporting lines had both
                    // been pinned, so it collapsed to one ellipsised line — the
                    // sentence you are supposed to say, unreadable.
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(2)
                    .textSelection(.enabled)
            }
            ForEach(Array(angles.enumerated()), id: \.offset) { _, angle in
                supportingLine(angle, tint: NotchInk.hairline)
            }
            // Kept visually distinct on purpose: this is the part that stops a
            // confident wrong answer.
            if session.layout == .full {
                ForEach(Array(copilot.confirm.prefix(1).enumerated()), id: \.offset) { _, item in
                    supportingLine(item, tint: NotchTint.attention.opacity(0.6))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The running account, when no question is on the table. Only the tail
    /// fits, and the last line reads loudest: it is what is being discussed now.
    @ViewBuilder private var recapBody: some View {
        let account = splitSummary(copilot.summary ?? "")
        // Collapsed runs as a teleprompter: it takes everything it has and the
        // column keeps only what fits, so each new point pushes the oldest off
        // the top rather than the account being capped at two lines nobody can
        // scroll past. Expanded is a fixed four, because it shares its height
        // with the transcript column.
        // Six, not eight. Each point may wrap to two lines, so eight of them can
        // want more height than the collapsed panel has — and because the list
        // is anchored to its floor, the overflow lands on the *newest* line,
        // which is the one line the panel exists to show. It was being sliced
        // through the middle of its second line.
        let recent = Array(account.points.suffix(session.layout == .compact ? 6 : 4))

        VStack(alignment: .leading, spacing: session.layout == .compact ? 6 : 8) {
            ForEach(Array(recent.enumerated()), id: \.offset) { index, point in
                let isNewest = index == recent.count - 1
                // The line that just landed is the one worth reading from across
                // a desk; the ones behind it are context. They used to be four
                // lines of one size behind four identical dots, which gave the
                // column no focal point at all — and the dot column spent 12pt
                // of width saying nothing the ink could not.
                Text(point)
                    .font(isNewest
                          ? .system(size: 13, weight: .medium)
                          : NotchGlassType.detail)
                    .foregroundStyle(isNewest ? NotchInk.primary : NotchInk.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    // The newest line takes the height it needs and nothing
                    // gives way for it — it is the reason the panel is on
                    // screen, and it was the line being cut.
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(isNewest ? 2 : 0)
                    // Hugging the left edge. This was 10pt on top of the
                    // column's own 10, so every line began 20pt in and the
                    // panel wore a margin it had no room for.
                    .padding(.leading, 7)
                    .background(alignment: .leading) {
                        if isNewest {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Color.effectiveAccent)
                                .frame(width: 3)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Only where there is room for it. In compact this was the fourth
            // band of a panel that has room for three.
            if session.layout == .full, let first = copilot.openQuestions.first {
                supportingLine("Still open: \(first)", tint: NotchTint.attention.opacity(0.6))
            }
            if session.layout == .full {
                Spacer(minLength: 0)
            }
        }
        // Collapsed: fill the column and sit on its floor, so the list grows
        // upward and the oldest line leaves through the top. Aligned any other
        // way vertically, an account longer than the space overflows downward
        // and takes the caption strip with it — the clip would cut the newest
        // line rather than the stalest one.
        //
        // `.bottomLeading`, not `.bottom`: `Alignment.bottom` is centre
        // horizontally, so the whole column was being centred on the panel. The
        // stack inside is `.leading`, but it hugs its widest line — so with one
        // short point on screen the block was narrow and sat in the middle,
        // and the account appeared to drift left and right as lines of
        // different lengths arrived.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .clipped()
        .mask(alignment: .bottom) {
            if session.layout == .compact {
                // Dissolve at the top rather than slice: a half-line cut by a
                // hard edge reads as a rendering fault.
                LinearGradient(colors: [.clear, .black, .black],
                               startPoint: .top,
                               endPoint: .init(x: 0.5, y: 0.28))
            } else {
                Rectangle()
            }
        }
    }

    private func supportingLine(_ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(text)
                .font(NotchGlassType.detail)
                .foregroundStyle(NotchInk.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        // The rail is a background rather than a sibling. As a sibling it was a
        // Shape with a width and no height — vertically flexible — so in a column
        // with spare height it swallowed the lot and left the two lines floating
        // 80pt apart with tall bars beside them.
        .padding(.leading, 12)
        .background(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(tint)
                .frame(width: 3)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ title: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(NotchGlassType.title)
                .foregroundStyle(tint == NotchInk.secondary ? NotchInk.primary : tint)
            Text(detail)
                .font(NotchGlassType.detail)
                .foregroundStyle(NotchInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Transcript

    /// Three turns. Newest at full ink, the two before it at tertiary, and the
    /// speaker named in caps rather than implied by which side the bubble sits
    /// on — the old alignment split cost 32pt of an already narrow column.
    private var transcriptColumn: some View {
        VStack(alignment: .leading, spacing: NotchGlassSpace.snug) {
            HStack(spacing: NotchGlassSpace.tight) {
                NotchCaps("Transcript")
                Rectangle().fill(NotchInk.hairline).frame(height: 1)
            }

            if turns.isEmpty {
                Text(copilot.systemAudioActive
                     ? "Turns appear here as they are transcribed on this Mac."
                     : "Grant Screen Recording so the other side is transcribed too.")
                    .font(NotchGlassType.detail)
                    .foregroundStyle(NotchInk.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                // Whole turns only. This used to be a scroll view over every turn
                // of the call, masked at the top — which meant the oldest line on
                // screen was always sliced through the middle of a sentence.
                // Four, because the column has the height for four and leaving it
                // short is the same waste as the answer stranded at the top.
                // The speaker is named only where it changes. Four consecutive
                // turns from the same person carried four identical THEM
                // labels, and the label was the loudest thing in the column.
                // Four, not five. Turns are no longer capped at three lines, so
                // a long one takes the room it needs; asking for five whole
                // turns is asking for more height than the column has.
                let shown = Array(turns.suffix(4))
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(shown.enumerated()), id: \.element.seq) { index, turn in
                        turnRow(turn,
                                isNewest: turn.seq == shown.last?.seq,
                                showsSpeaker: index == 0
                                    || shown[index - 1].isRemote != turn.isRemote)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: turns.last?.seq)
                // Anchored to the floor and dissolved at the top, the way the
                // recap column is. When whole turns do not fit, the oldest is
                // what should go — cutting the newest would hide the words
                // being said right now.
                // Bounded, then anchored to its floor and dissolved at the
                // top, the way the recap column is. When whole turns do not
                // fit, the oldest is what should go — cutting the newest would
                // hide the words being said right now.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .mask(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black, .black],
                                   startPoint: .top,
                                   endPoint: .init(x: 0.5, y: 0.22))
                }
            }
        }
        .padding(.horizontal, 10)
        .clipped()
        // The heading stays at the top; the turns below it are bottom-anchored
        // by their own frame, so new turns arrive at the floor and the oldest
        // leave through the dissolve above them.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func turnRow(_ turn: CallaCallTurn, isNewest: Bool, showsSpeaker: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsSpeaker || isNewest {
                NotchCaps(isNewest ? (turn.isRemote ? "Them · now" : "You · now")
                                   : (turn.isRemote ? "Them" : "You"),
                          tint: isNewest ? Color.effectiveAccent : NotchInk.tertiary)
            }
            Text(turn.text)
                .font(NotchGlassType.detail)
                // Explicit whites rather than .primary/.secondary: the panel is
                // translucent, so semantic colours land on whatever happens to
                // be behind it.
                .foregroundStyle(isNewest ? NotchInk.primary : NotchInk.tertiary)
                .textSelection(.enabled)
                // Whole turns. Three lines cut the long ones, and a transcript
                // that ends a sentence in an ellipsis is not a transcript — it
                // is the part of the call you cannot check. The column shows
                // fewer turns when they are long, which is the right trade.
                .fixedSize(horizontal: false, vertical: true)
        }
        // Your own turns sit in from the edge. Two speakers on one column need
        // to be told apart at a glance, and an indent does it without spending
        // a word on every line.
        .padding(.leading, turn.isRemote ? 0 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity.combined(with: .offset(y: 6)))
    }

    // MARK: - Footer

    /// The same four controls in both layouts, in the same order. Only the
    /// transcript verb flips — a control that moves between layouts has to be
    /// found again every time the panel changes size.
    private var footer: some View {
        HStack(spacing: 9) {
            NotchChip(action: {
                manualQuestion = turns.last?.text ?? ""
                showsManualQuestion = true
            }) {
                Image(systemName: "mic.fill").font(NotchGlassType.glyph)
                Text("Ask")
                // The literal binding below, spelled out. There is no
                // `KeyboardShortcuts.Name` for it to read back from.
                Text("⇧⌘A")
                    .font(NotchGlassType.minorFigure)
                    .foregroundStyle(NotchInk.tertiary)
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])

            NotchChip(action: {
                surface = surface == "question" ? "summary" : "question"
                if surface == "question" { session.clearUnreadAnswer() }
            }) {
                Image(systemName: surface == "question" ? "bubble.left.fill" : "text.alignleft")
                    .font(NotchGlassType.glyph)
                Text(surface == "question" ? "Answers" : "Recap")
                if session.unreadAnswer, surface != "question" {
                    Circle().fill(Color.effectiveAccent).frame(width: 5, height: 5)
                }
            }

            NotchChip(action: { session.toggleLayout() }) {
                Image(systemName: session.layout == .full ? "list.bullet.indent" : "list.bullet")
                    .font(NotchGlassType.glyph)
                Text(session.layout == .full ? "Hide transcript" : "Show transcript")
            }

            Spacer(minLength: 0)

            NotchChip(tint: NotchTint.stuck, action: { engine.endCall() }) {
                Text("End call")
            }
            .fixedSize()
        }
        .frame(height: NotchGlassSpace.control)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Activity

    private enum Activity {
        case them, you, answering, summarising, idle

        var label: String {
            switch self {
            case .them: "Them speaking"
            case .you: "You speaking"
            case .answering: "Finding an answer"
            // Named differently because it takes longer: four seconds labelled
            // "finding an answer" reads as a stall; the same wait labelled
            // "catching up" reads as work.
            case .summarising: "Catching up"
            case .idle: "Listening"
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

        /// Only the working states animate. A panel where everything moves tells
        /// you nothing about which thing is moving.
        var animates: Bool { self == .answering || self == .summarising }
    }

    private var activity: Activity {
        if surface == "question", copilot.questionWorking { return .answering }
        if surface == "summary", copilot.summaryWorking { return .summarising }
        // Older hosts expose the single legacy status only.
        switch copilot.working {
        case "answer" where surface == "question": return .answering
        case "summary" where surface == "summary": return .summarising
        default: break
        }
        switch copilot.speaking {
        case "them": return .them
        case "me": return .you
        default: return .idle
        }
    }

    // MARK: - Data

    /// One point per line, as the recap writes them.
    ///
    /// Strips any bullet character a model added despite being asked not to,
    /// because the alternative is a stray "-" sitting in the panel.
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
}

/// A short tinted label. Used in the header band either side of the housing,
/// where there is room for a word but not for a row.
struct CallaPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(NotchGlassType.caps)
            .tracking(notchCapsTracking)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.20), in: Capsule())
            .foregroundStyle(tint)
            .fixedSize()
    }
}

/// A recording dot that breathes while both legs are being captured.
struct LivePulse: View {
    let active: Bool
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(active ? NotchTint.healthy : NotchTint.attention)
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
/// controls on the other buys the answer plane a full row of height it would
/// otherwise spend on a status line. It is also why the panel below carries no
/// chrome of its own: this *is* the chrome.
struct CallaCopilotLiveHeader: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var session = CopilotLiveSession.shared
    @EnvironmentObject private var vm: BoringViewModel

    @State private var now = Date()
    @Default(.hideFromScreenRecording) private var hiddenFromCapture
    @Default(.callaIntelligenceProvider) private var preferredProvider
    private let clockTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    @Default(.callaCopilotPanelSurface) private var surface

    private var mode: CallaCopilotPresentation.Mode {
        CallaCopilotPresentation.mode(
            available: copilot.available,
            running: copilot.running,
            systemAudioActive: copilot.systemAudioActive,
            hasSuggestion: copilot.hasSuggestion)
    }

    /// The panel's own heading, drawn up here.
    private var heading: String {
        CallaCopilotPresentation.panelHeading(
            surface: surface,
            hasAnswer: copilot.hasSuggestion,
            hasSummary: !(copilot.summary ?? "").isEmpty,
            mode: mode,
            working: workingLabel)
    }

    private var workingLabel: String? {
        if copilot.questionWorking { return "Finding an answer" }
        if copilot.summaryWorking { return "Catching up" }
        switch copilot.working {
        case "answer": return "Finding an answer"
        case "summary": return "Catching up"
        default: return nil
        }
    }

    private var headingTint: Color {
        if workingLabel != nil { return .effectiveAccent }
        if mode == .halfDeaf { return NotchTint.attention }
        return NotchInk.primary
    }

    var body: some View {
        HStack(spacing: 0) {
            // Every label here is `fixedSize`, because the row it sits in is
            // split into two halves around a rigid camera housing and each half
            // is narrower than it looks. Without it SwiftUI meets the shortfall
            // by wrapping the text — "Hearing both sides" breaks mid-word, and a
            // clock reading "0:" over "…" is worse than no clock at all.
            HStack(spacing: NotchGlassSpace.tight) {
                LivePulse(active: copilot.running && copilot.systemAudioActive)
                // What the panel below is showing — "Say this", "So far" — where
                // the state pill used to be. The pulse already carries whether
                // both sides are heard, which is what the pill was mostly for,
                // and the panel gets its line back.
                Text(heading)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(headingTint)
                    .lineLimit(1)
                    .fixedSize()
                if let elapsed = CallaCopilotPresentation.elapsed(since: copilot.startedAt, now: now) {
                    Text(elapsed)
                        .font(NotchGlassType.inlineFigure)
                        .foregroundStyle(NotchInk.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                // Shown only when the brain answering is not the one chosen in
                // Settings — an automatic handover to the gateway is otherwise
                // indistinguishable from a copilot that has quietly gone vague.
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
                    CallaPill(text: CallaCopilotPersona.title(copilot.persona), tint: NotchInk.tertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The camera housing. Nothing may be drawn here.
            Color.clear.frame(width: vm.closedNotchSize.width)

            HStack(spacing: NotchGlassSpace.tight) {
                Spacer(minLength: 0)
                // Two facts worth one glyph each: is it hearing both sides, and
                // is it out of the screen share.
                // An answer landed while something else is on screen. A dot
                // beside the capture glyphs, because the alternative — swapping
                // the panel to it — is the thing that made a live call feel like
                // it was being taken out of your hands mid-sentence.
                if session.unreadAnswer {
                    Circle()
                        .fill(Color.effectiveAccent)
                        .frame(width: 6, height: 6)
                        .transition(.scale.combined(with: .opacity))
                        .help("An answer is waiting")
                }
                Image(systemName: copilot.micActive ? "mic.fill" : "mic.slash.fill")
                    .font(NotchGlassType.glyphSmall)
                    .foregroundStyle(copilot.micActive ? NotchInk.secondary : NotchTint.attention)
                    .help(copilot.micActive ? "Your microphone is being captured" : "Your microphone is not being captured")
                // Reports the setting rather than asserting a guarantee. The
                // panel is hidden from captures when "Hide from screen
                // recording" is on and visible when it is off, call or no call,
                // and a crossed-out eye that means neither is the one glyph
                // here that could cost someone the thing this feature exists to
                // protect.
                Image(systemName: hiddenFromCapture ? "eye.slash.fill" : "eye.fill")
                    .font(NotchGlassType.glyphSmall)
                    .foregroundStyle(hiddenFromCapture ? NotchInk.secondary : NotchTint.attention)
                    .help(hiddenFromCapture
                          ? "Hidden from screen recordings and shares"
                          : "Visible in screen recordings and shares — turn on Hide from screen recording in Settings")

                if session.layout == .full,
                   let shortcut = KeyboardShortcuts.getShortcut(for: .copilotToggleLayout) {
                    Text(shortcut.description)
                        .font(NotchGlassType.minorFigure)
                        .foregroundStyle(NotchInk.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(NotchPlane.chip,
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }

                // Collapse to the answer alone and back. The transcript is the
                // part worth surrendering first: it is the half you can
                // reconstruct by listening, where the answer is not.
                Button { session.toggleLayout() } label: {
                    Image(systemName: session.layout == .full
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(NotchGlassType.glyphSmall)
                }
                .buttonStyle(.plain)
                .foregroundStyle(NotchInk.secondary)
                .help(session.layout == .full ? "Collapse to the answer" : "Show the transcript again")

                // Pin governs whether a live call holds this notch open. It does
                // not start or end capture.
                Button { session.togglePin() } label: {
                    Image(systemName: session.pinned ? "pin.fill" : "pin")
                        .font(NotchGlassType.glyphSmall)
                }
                .buttonStyle(.plain)
                .foregroundStyle(NotchInk.secondary)
                .help(session.pinned ? "Unpin notch" : "Pin notch open")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .onReceive(clockTick) { now = $0 }
    }

    private func tint(for tone: CallaCopilotPresentation.Tone) -> Color {
        switch tone {
        case .active: return NotchTint.healthy
        case .ready: return .effectiveAccent
        case .warning: return NotchTint.attention
        }
    }
}
