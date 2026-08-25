//
//  NotchCard.swift
//  boringNotch
//

import SwiftUI

/// The vocabulary the notch's own surfaces are drawn from.
///
/// Settings was given `NotchDesignSystem` and the notch was not. What grew there
/// instead, across `PomodoroView`, `CallaTabView`, `CallaCopilotTabView` and
/// `CallaCopilotLiveView`, was fourteen distinct font sizes between 7 and 28pt,
/// twenty-seven distinct opacity values between 0.07 and 0.97, and three
/// independent copies of the same fix for the notch's inward-curving lower
/// corners. None of that was decided; it accumulated.
///
/// The surface treatment is taken from the Usage tab rather than invented: one
/// flat card at 4% white, a 6% border, radius 16, and columns separated by a
/// hairline that fades out at both ends. An earlier pass here used translucent
/// "glass" — a lit top lip, an inset highlight, a coloured bloom behind whatever
/// was live — which read as a different application sitting next to Home and
/// Usage. The notch already had a house style; this is it.
enum NotchInk {
    /// The answer the reader opened the notch for.
    static let primary = Color.white
    /// The sentence that explains it.
    static let secondary = Color.white.opacity(0.70)
    /// Labels, units, and anything that is off.
    static let tertiary = Color.white.opacity(0.42)
    /// A rule or a track. Never text.
    static let hairline = Color.white.opacity(0.12)
}

/// The card, exactly as the Usage tab draws it.
enum NotchPlane {
    static let fill = Color.white.opacity(0.04)
    static let border = Color.white.opacity(0.06)
    /// A control inside a card.
    static let chip = Color.white.opacity(0.08)
    static let control = Color.white.opacity(0.10)
    /// A progress track.
    static let track = Color.primary.opacity(0.1)
}

/// Six sizes. SF Rounded carries the figures and nothing else, because the notch
/// is nothing but corner radii and the figures are what change in place.
enum NotchGlassType {
    /// One per surface, at most. The number you read from across the desk.
    /// Sized to the Usage tab's own figure rather than larger: two tabs showing
    /// their headline number at different sizes is how a house style comes apart.
    static let hero = Font.system(size: 30, weight: .bold, design: .rounded).monospacedDigit()
    /// A count worth a glance — blocks today, lessons done.
    static let figure = Font.system(size: 24, weight: .bold, design: .rounded).monospacedDigit()
    /// The thing to read: a suggestion, a lesson step, a blocker.
    static let title = Font.system(size: 14, weight: .semibold)
    /// Fields, transcript turns, what you are working on.
    static let row = Font.system(size: 12)
    /// The explanation under a row.
    static let detail = Font.system(size: 11)
    /// Small print under a figure. The Usage tab's caption, by another name.
    static let caption = Font.system(size: 10)
    /// State and labels. Always tracked, always upper-cased at the call site.
    static let caps = Font.system(size: 9, weight: .bold)
    /// A figure inline with text — elapsed time, a count in a header.
    static let inlineFigure = Font.system(size: 11, design: .rounded).monospacedDigit()
    /// The smallest figure that still changes in place.
    static let minorFigure = Font.system(size: 10, design: .rounded).monospacedDigit()

    /// The live answer, collapsed — it has the card to itself, and this is the
    /// size it is read at from across a desk mid-sentence.
    static let answerLarge = Font.system(size: 16, weight: .semibold)
    /// The live answer, expanded — it shares the card with the transcript.
    static let answer = Font.system(size: 14, weight: .semibold)
    /// A primary button's label.
    static let action = Font.system(size: 12, weight: .semibold)
    /// A chip's label.
    static let chipLabel = Font.system(size: 11, weight: .medium)

    /// Three glyph sizes, and no fourth. Icons had been drifting across 7, 8,
    /// 10, 12, 13 and 14pt in the same rows as each other.
    static let glyphSmall = Font.system(size: 9, weight: .semibold)
    static let glyph = Font.system(size: 11, weight: .medium)
    static let glyphLarge = Font.system(size: 13, weight: .bold)
    /// The disclosure arrow on a menu chip.
    static let chevron = Font.system(size: 8, weight: .bold)
}

enum NotchGlassRadius {
    static let card: CGFloat = 16
    static let chip: CGFloat = 10
    static let glyph: CGFloat = 7
}

enum NotchGlassSpace {
    /// A label to its own value.
    static let hair: CGFloat = 2
    /// Inside one control cluster.
    static let tight: CGFloat = 7
    /// Rows inside a card.
    static let snug: CGFloat = 6
    /// A card's own padding.
    static let card: CGFloat = 12
    /// Standard control height across every tab.
    static let control: CGFloat = 30
}

/// The tracking on `NotchGlassType.caps`, applied wherever caps are drawn.
let notchCapsTracking: CGFloat = 0.8

// MARK: - Surfaces

extension View {
    /// The tab's one card. Same fill, border and radius as the Usage tab's.
    func notchCard() -> some View {
        background(
            RoundedRectangle(cornerRadius: NotchGlassRadius.card, style: .continuous)
                .fill(NotchPlane.fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: NotchGlassRadius.card, style: .continuous)
                .strokeBorder(NotchPlane.border, lineWidth: 1)
        )
    }

    /// The insets every tab shares.
    ///
    /// The bottom one is load-bearing rather than cosmetic: the notch's lower
    /// corners curve inward, so a control row flush with the frame is drawn half
    /// outside the shape. Three views had each discovered that separately and
    /// written their own comment about it.
    ///
    /// What a tab actually gets is smaller than the notch, and this is the sum
    /// that two passes here got wrong. `openNotchSize` is 168pt, but
    /// `ContentView` draws the tab row above the tab at
    /// `max(24, vm.effectiveClosedNotchHeight)` — the real notch inset, 38pt on
    /// a 13-inch Air under the default `matchRealNotchSize`. So:
    ///
    ///     168 − 38 (tab row) − 14 (these insets) − 16 (card padding) ≈ 100pt
    ///
    /// One hundred points is the whole budget for a tab's content. A header
    /// line, a title, a caption and a control row is exactly that and nothing
    /// more; a fourth band does not fit, and the first version of these
    /// surfaces was drawn as though it did.
    func notchTabInsets() -> some View {
        padding(.top, 4)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
    }
}

/// The divider between two columns of one card, taken from the Usage tab: a
/// hairline that fades out at both ends rather than butting into the padding.
struct NotchColumnDivider: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, Color.primary.opacity(0.18), .clear],
                    startPoint: .top,
                    endPoint: .bottom)
            )
            .frame(width: 1)
            .padding(.vertical, 8)
    }
}

/// A progress track, drawn the way the Usage tab draws its quota bars.
struct NotchBar: View {
    let fraction: Double
    var tint: Color = .effectiveAccent
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(NotchPlane.track)
                Capsule()
                    .fill(tint)
                    .frame(width: geometry.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Shared pieces

/// Caps, tracked, in one ink step. The state of a surface — never its name: the
/// reader chose the tab and does not need to be told which one they opened.
struct NotchCaps: View {
    let text: String
    var tint: Color = NotchInk.tertiary

    init(_ text: String, tint: Color = NotchInk.tertiary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text.uppercased())
            .font(NotchGlassType.caps)
            .tracking(notchCapsTracking)
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}

/// Running, or not. Filled when live, an empty ring when idle — so the state
/// survives being read in greyscale or out of the corner of an eye.
struct NotchStatusDot: View {
    let live: Bool
    var tint: Color = .effectiveAccent

    var body: some View {
        Group {
            if live {
                Circle().fill(tint)
            } else {
                Circle().strokeBorder(NotchInk.tertiary, lineWidth: 1)
            }
        }
        .frame(width: 6, height: 6)
    }
}

/// A glyph button in a card's header line, styled like the Usage tab's refresh.
struct NotchGlyphButton: View {
    let symbol: String
    var help: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(NotchGlassType.glyphSmall)
                .foregroundStyle(hovering ? NotchInk.primary : NotchInk.tertiary)
                .padding(4)
                .background(Circle().fill(hovering ? Color.primary.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

/// A chip: the standard secondary control.
struct NotchChip<Content: View>: View {
    var tint: Color?
    var action: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        let body = HStack(spacing: NotchGlassSpace.tight) { content }
            .padding(.horizontal, 11)
            .frame(height: NotchGlassSpace.control)
            .background(tint?.opacity(0.16) ?? NotchPlane.chip,
                        in: RoundedRectangle(cornerRadius: NotchGlassRadius.chip, style: .continuous))
            .foregroundStyle(tint ?? NotchInk.secondary)
            .font(.system(size: 11, weight: tint == nil ? .medium : .semibold))

        if let action {
            Button(action: action) { body.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            body
        }
    }
}

/// The header line inside a card: what state this is in, and the one or two
/// controls that belong to it.
///
/// This replaces a full-width chrome row that named the tab it was in. The tab
/// is already selected in the header above; saying "TUTOR ·" again cost a band
/// of a 168pt surface to tell the reader something they did by hand.
struct NotchCardHeader<Trailing: View>: View {
    let state: String
    var live: Bool = false
    var tint: Color = .effectiveAccent
    var figure: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: NotchGlassSpace.tight) {
            NotchStatusDot(live: live, tint: tint)
            NotchCaps(state, tint: live ? NotchInk.secondary : NotchInk.tertiary)
            Spacer(minLength: 4)
            if let figure {
                Text(figure)
                    .font(NotchGlassType.inlineFigure)
                    .foregroundStyle(NotchInk.tertiary)
                    .lineLimit(1)
            }
            trailing
        }
        .frame(height: 18)
    }
}

extension NotchCardHeader where Trailing == EmptyView {
    init(state: String, live: Bool = false, tint: Color = .effectiveAccent, figure: String? = nil) {
        self.init(state: state, live: live, tint: tint, figure: figure) { EmptyView() }
    }
}
