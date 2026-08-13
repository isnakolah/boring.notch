import AppKit
import SwiftUI

/// The vocabulary every Calla surface is drawn from.
///
/// There was none until now, and it showed. Four view files each spelled out
/// their own sizes and radii, so the same course row was 9pt round in the menu
/// bar and 12pt round in Settings, three separate `card(...)` helpers disagreed
/// about padding, and the rule about what red means lived in a comment rather
/// than anywhere the code could reach. None of that was a decision — it was four
/// independent guesses at the same one.
///
/// Nothing here has behaviour. It is only the set of choices that should be made
/// once.

// MARK: - Colour

/// What a colour means, so no view has to remember which green.
enum CallaTint {
    /// Working, granted, connected.
    static var healthy: Color { .green }
    /// Calla is working on it, or is waiting for a permission. Not a failure.
    static var attention: Color { .orange }
    /// Reserved for stopped.
    ///
    /// Orange means Calla is still getting somewhere; red means it is not.
    /// Spending red on an ordinary reconnect is how a learner is taught to
    /// ignore it, and then it is spent for good.
    static var stuck: Color { .red }
    /// A lesson is being taught, or is the thing being pointed at.
    static var teaching: Color { .accentColor }
    /// Off, hidden, or not applicable — never wrong, just not running.
    static var paused: Color { .secondary }
}

// MARK: - Type

/// One scale, in the sizes these surfaces already used.
///
/// Semantic styles (`.body`, `.caption`) are deliberately not used: the menu bar
/// panel and an overlay tooltip have to hold a fixed density regardless of the
/// reader's text-size preference, because they are laid out against a window
/// that is not theirs.
enum CallaFont {
    /// The name of a pane, once, at the top of it.
    static var paneTitle: Font { .system(size: 22, weight: .semibold) }
    /// The heading of a card that owns a whole task.
    static var cardTitle: Font { .system(size: 15, weight: .semibold) }
    /// A group of rows within a pane.
    static var sectionTitle: Font { .system(size: 14, weight: .semibold) }
    /// The subject of a row: a course, an application, a permission.
    static var rowTitle: Font { .system(size: 12, weight: .medium) }
    /// Ordinary running text. By some way the most used size here.
    static var body: Font { .system(size: 12) }
    /// The sentence under a row that explains it.
    static var detail: Font { .system(size: 11) }
    /// Provenance: a bundle id, a timestamp, a lesson list.
    static var caption: Font { .system(size: 10) }
    /// A count worth reading at a glance.
    static var stat: Font { .system(size: 17, weight: .semibold, design: .rounded) }
    /// Any number that changes in place, so it does not jitter.
    static var figure: Font { .system(size: 11, design: .rounded) }
    /// A key combination, or anything else read character by character.
    static var mono: Font { .system(size: 11, design: .monospaced) }
    /// The small uppercase strip above a group in the menu bar panel.
    static var eyebrow: Font { .system(size: 10, weight: .semibold) }
}

// MARK: - Shape

enum CallaRadius {
    static let card: CGFloat = 12
    static let control: CGFloat = 8
    /// The tinted square behind a glyph.
    static let chip: CGFloat = 10
}

// MARK: - Card

/// One card, everywhere.
///
/// This replaces three private helpers that had drifted apart: 14pt padding at
/// radius 12 in Settings, 10pt at radius 8 in the menu, and a third for
/// approvals that differed only in its fill. A tint makes it speak up; without
/// one it is just a surface.
private struct CallaCard: ViewModifier {
    let tint: Color?
    let emphasised: Bool

    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: CallaRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CallaRadius.card, style: .continuous)
                    .strokeBorder(border, lineWidth: 1))
    }

    private var background: some ShapeStyle {
        guard let tint else { return AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) }
        return AnyShapeStyle(tint.opacity(0.11))
    }

    private var border: some ShapeStyle {
        guard let tint else { return AnyShapeStyle(Color.primary.opacity(0.06)) }
        return AnyShapeStyle(tint.opacity(emphasised ? 0.45 : 0.22))
    }
}

extension View {
    /// A surface for one thing. Pass a tint only when the card is asking for
    /// something; an ordinary card that shouts has nothing left for the one that
    /// needs to.
    func callaCard(tint: Color? = nil, emphasised: Bool = false) -> some View {
        modifier(CallaCard(tint: tint, emphasised: emphasised))
    }
}

// MARK: - Headings

/// A group of rows, with the sentence that says what the group is for.
struct CallaSectionHeader: View {
    let title: String
    var detail: String?
    /// The count belonging to this group, when the group is a list of things.
    var count: Int?

    init(_ title: String, detail: String? = nil, count: Int? = nil) {
        self.title = title
        self.detail = detail
        self.count = count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).font(CallaFont.sectionTitle)
                if let count {
                    Text("\(count)")
                        .font(CallaFont.detail).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
            }
            if let detail {
                Text(detail).font(CallaFont.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The uppercase strip the menu bar panel uses instead of a section title.
///
/// Kept distinct from `CallaSectionHeader` on purpose: the panel is 340pt wide
/// and cannot spend a 14pt line plus a sentence on saying what a group is.
struct CallaEyebrow: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(CallaFont.eyebrow)
            .foregroundStyle(.tertiary)
            .kerning(0.4)
    }
}

// MARK: - Status

/// Granted or not, connected or not — the same mark for the same meaning.
struct CallaStatusIcon: View {
    let ok: Bool
    var size: CGFloat = 13
    /// Use `stuck` instead of `attention` when the thing has stopped trying.
    var failedTint: Color = CallaTint.attention

    var body: some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.system(size: size))
            .foregroundStyle(ok ? CallaTint.healthy : failedTint)
    }
}

/// One fact and its state, on a line.
struct CallaStatusLine: View {
    let title: String
    let ok: Bool
    var value: String?
    var failedTint: Color = CallaTint.attention

    var body: some View {
        HStack(spacing: 6) {
            CallaStatusIcon(ok: ok, size: 12, failedTint: failedTint)
            Text(title).font(CallaFont.detail)
            if let value {
                Spacer(minLength: 6)
                Text(value).font(CallaFont.detail).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

// MARK: - Course progress

/// How far through a course, in lessons.
///
/// The bar carries the shape and the words carry the number. A bare "0/1" told
/// the learner nothing about how much a course even is, and it appeared in two
/// places drawn two different ways.
struct CourseProgressBar: View {
    let done: Int
    let total: Int
    /// Tinted while this is the course being taught.
    var active = false
    var showsLabel = true

    var body: some View {
        HStack(spacing: 7) {
            GeometryReader { geometry in
                let fraction = total == 0 ? 0 : Double(done) / Double(total)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(active ? CallaTint.teaching : Color.secondary)
                        .frame(width: max(0, geometry.size.width * fraction))
                }
            }
            .frame(height: 4)
            if showsLabel {
                Text(label)
                    .font(CallaFont.figure)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
    }

    private var label: String {
        guard done != total || total == 0 else { return "Done" }
        return "\(done) of \(total) \(total == 1 ? "lesson" : "lessons")"
    }
}

// MARK: - Icons

/// An application's own icon, at whatever size the surface needs.
///
/// The menu bar drew this at 16 and the Applications pane at 20, from two copies
/// of the same six lines.
struct AppIcon: View {
    let bundleID: String
    var size: CGFloat = 16

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: size * 0.8))
                .foregroundStyle(.tertiary)
                .frame(width: size, height: size)
        }
    }
}

/// A course's own mark, falling back to the application it teaches.
///
/// A course is never listed without something beside it: an unmarked row among
/// marked ones reads as broken rather than as unadorned.
struct CourseIcon: View {
    let symbol: String
    var bundleID: String?
    var size: CGFloat = 16

    var body: some View {
        if !symbol.isEmpty, NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
            Image(systemName: symbol)
                .font(.system(size: size * 0.85))
                .foregroundStyle(CallaTint.teaching)
                .frame(width: size, height: size)
        } else if let bundleID {
            AppIcon(bundleID: bundleID, size: size)
        } else {
            Image(systemName: "book.closed")
                .font(.system(size: size * 0.8))
                .foregroundStyle(.tertiary)
                .frame(width: size, height: size)
        }
    }
}

/// The tinted square a pane or card leads with.
struct CallaGlyph: View {
    let symbol: String
    var tint: Color = CallaTint.teaching
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: CallaRadius.chip, style: .continuous))
    }
}

// MARK: - Relative time

enum CallaTime {
    /// "just now", "4s ago", "6m ago" — short enough to sit at the end of a line.
    ///
    /// `RelativeDateTimeFormatter` says "in 0 seconds" for the present moment,
    /// which reads as a bug in a status line that is updated every few seconds.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<2: return "just now"
        case ..<60: return "\(seconds)s ago"
        case ..<3_600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3_600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }
}
