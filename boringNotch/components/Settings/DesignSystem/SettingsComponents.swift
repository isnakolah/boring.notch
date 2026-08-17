import SwiftUI

// MARK: - Pane shell

/// The header every pane leads with, so no pane re-implements it.
///
/// The eyebrow names the sidebar group the pane belongs to, which is the one
/// piece of orientation the old flat list of fourteen items could not give.
struct SettingsPane<Content: View>: View {
    let eyebrow: String
    let title: String
    var detail: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(eyebrow.uppercased())
                        .font(NotchType.eyebrow)
                        .foregroundStyle(.tertiary)
                        .kerning(0.5)
                    Text(title).font(NotchType.paneTitle)
                    if let detail {
                        Text(detail)
                            .font(NotchType.paneDetail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(NotchSurface.base)
    }
}

// MARK: - Card

/// A surface for one thing.
///
/// This replaces `Section` inside `Form(.grouped)`. A card can carry a tint when
/// it is reporting live state; an ordinary card that shouts leaves nothing for
/// the one that needs to, so the tint is reserved for status.
struct SettingCard<Content: View>: View {
    var title: String?
    var detail: String?
    /// Set only when the card carries live state worth colouring.
    var tint: Color?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, detail: String? = nil, tint: Color? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || detail != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let title { Text(title).font(NotchType.cardTitle) }
                    if let detail {
                        Text(detail)
                            .font(NotchType.rowDetail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: NotchRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NotchRadius.card, style: .continuous)
                .strokeBorder(cardBorder, lineWidth: 1)
        )
    }

    private var cardBackground: AnyShapeStyle {
        guard let tint else { return AnyShapeStyle(NotchSurface.raised) }
        return AnyShapeStyle(tint.opacity(0.10))
    }

    private var cardBorder: AnyShapeStyle {
        guard let tint else { return AnyShapeStyle(NotchSurface.hairline) }
        return AnyShapeStyle(tint.opacity(0.30))
    }
}

// MARK: - Row

/// One setting, with the sentence that explains it.
///
/// The explanation belongs under the label rather than in a `Form` footer, which
/// is where the old panes put it — far enough from the control that it read as
/// commentary on the whole section.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(NotchType.rowTitle)
                if let detail {
                    Text(detail)
                        .font(NotchType.rowDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A fact the reader cannot change, with its value aligned right.
struct SettingFact: View {
    let title: String
    let value: String
    var tint: Color?

    var body: some View {
        HStack(spacing: 8) {
            if let tint {
                Circle().fill(tint).frame(width: 6, height: 6)
            }
            Text(title).font(NotchType.rowTitle)
            Spacer(minLength: 8)
            Text(value)
                .font(NotchType.figure)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Badge

/// One badge, everywhere.
///
/// Replaces `proFeatureBadge`, `comingSoonTag`, `customBadge` and
/// `warningBadge`, which were four functions that differed only in their fill
/// and, in one case, returned a whole `Section`.
struct SettingBadge: View {
    let text: String
    var tint: Color?

    init(_ text: String, tint: Color? = nil) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint ?? .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background((tint ?? Color.secondary).opacity(0.14), in: Capsule())
    }
}

// MARK: - Status

/// Granted or not, connected or not — the same mark for the same meaning.
struct SettingStatusIcon: View {
    let ok: Bool
    var size: CGFloat = 13
    /// Use `stuck` when the thing has stopped trying, `attention` when it has not.
    var failedTint: Color = NotchTint.attention

    var body: some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.system(size: size))
            .foregroundStyle(ok ? NotchTint.healthy : failedTint)
    }
}

/// The tinted square a card or pane leads with.
struct SettingGlyph: View {
    let symbol: String
    var tint: Color = NotchTint.active
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: NotchRadius.chip, style: .continuous))
    }
}

/// How far through a set of things, in things.
struct SettingProgressBar: View {
    let done: Int
    let total: Int
    var active = false

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geometry in
                let fraction = total == 0 ? 0 : Double(done) / Double(total)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(active ? NotchTint.active : Color.secondary)
                        .frame(width: max(0, geometry.size.width * fraction))
                }
            }
            .frame(height: 4)
            Text(label)
                .font(NotchType.figure)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private var label: String {
        guard done != total || total == 0 else { return "Done" }
        return "\(done) of \(total)"
    }
}
