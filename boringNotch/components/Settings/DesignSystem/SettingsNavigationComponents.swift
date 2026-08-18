//
//  SettingsNavigationComponents.swift
//  boringNotch
//
//  The pieces a window with depth needs and a flat one did not.
//

import SwiftUI

// MARK: - Going deeper

/// A row that goes somewhere.
///
/// Promoted from `CopilotKnowledgePane`'s private `navigationRow`, which was the
/// one place in the app that had already got this right: a tinted glyph, a
/// two-line label, a count on the trailing side, a chevron, and a hit area that
/// covers the whole row rather than just the text.
///
/// This is deliberately not tied to the route model. A drill row is a shape —
/// glyph, label, chevron — and taking an action closure means it also works for
/// the rows that open a sheet or a panel rather than pushing a page. The
/// route-aware convenience initialiser sits alongside the route model instead.
struct SettingsDrillRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var detail: String?
    var tint: Color = NotchTint.active
    /// A short trailing summary: what this page currently says, so the reader
    /// does not have to open it to find out. "3 personas", "Off", "Needs access".
    var badge: String?
    var badgeTint: Color?
    let action: () -> Void
    @ViewBuilder var trailing: Trailing

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NotchSpace.row) {
                SettingGlyph(symbol: symbol, tint: tint, size: 26)
                VStack(alignment: .leading, spacing: NotchSpace.hair) {
                    Text(title).font(NotchType.rowTitle)
                    if let detail {
                        Text(detail)
                            .font(NotchType.rowDetail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: NotchSpace.tight)
                trailing
                if let badge { SettingBadge(badge, tint: badgeTint) }
                Image(systemName: "chevron.forward")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? .secondary : .tertiary)
            }
            .padding(.vertical, NotchSpace.tight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .background(
            RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.04 : 0))
                .padding(.horizontal, -NotchSpace.tight)
        )
        .animation(NotchMotion.settle, value: hovering)
    }
}

extension SettingsDrillRow where Trailing == EmptyView {
    init(symbol: String, title: String, detail: String? = nil, tint: Color = NotchTint.active,
         badge: String? = nil, badgeTint: Color? = nil, action: @escaping () -> Void) {
        self.init(symbol: symbol, title: title, detail: detail, tint: tint,
                  badge: badge, badgeTint: badgeTint, action: action) { EmptyView() }
    }
}

/// A card whose content is drill rows, ruled between them.
///
/// The rule is inset past the glyph so the column of icons reads as a column
/// rather than as a stack of separate cards.
struct SettingsDrillGroup<Content: View>: View {
    var title: String?
    var detail: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        SettingCard(title, detail: detail) {
            VStack(spacing: 0) {
                content
            }
        }
    }
}

// MARK: - Figures

/// A number worth reading at a glance, with what it is and how it is doing.
///
/// Promoted from `UsageQuotaTile`, which was the best stat presentation in the
/// app and was `private` to the usage monitor. It also replaces Sweep's
/// `metric(_:_:)` and Knowledge's `figure(_:_:)`, which were the same view
/// written twice with different padding.
struct SettingsStatTile: View {
    /// Pre-formatted. Byte counts, durations and percentages are all formatted
    /// differently and none of that belongs in a tile.
    let value: String
    let label: String
    var caption: String?
    var tint: Color?
    /// Draws a hairline meter under the value when the number is part of a whole.
    var fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: NotchSpace.hair) {
            Text(value)
                .font(NotchType.stat)
                .foregroundStyle(tint ?? .primary)
                .contentTransition(.numericText())
            Text(label)
                .font(NotchType.rowDetail)
                .foregroundStyle(.secondary)
            if let fraction {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10))
                        Capsule().fill(tint ?? Color.secondary)
                            .frame(width: max(0, geometry.size.width * min(max(fraction, 0), 1)))
                    }
                }
                .frame(height: 3)
                .padding(.top, NotchSpace.hair)
            }
            if let caption {
                Text(caption)
                    .font(NotchType.figure)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(NotchMotion.settle, value: value)
    }
}

/// A row of tiles sharing one baseline.
struct SettingsStatRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: NotchSpace.group) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Permissions

/// Whether macOS has allowed something.
///
/// `undetermined` is its own case rather than a flavour of denied, because the
/// two want different words: one can be asked for in place, the other can only
/// be granted in System Settings. Four of the five hand-written permission rows
/// this replaces treated "not yet asked" as a failure and said so in red.
enum PermissionStatus: Hashable {
    case granted, denied, undetermined, checking

    var isGranted: Bool { self == .granted }

    var tint: Color {
        switch self {
        case .granted: return NotchTint.healthy
        case .denied: return NotchTint.attention
        case .undetermined: return NotchTint.paused
        case .checking: return NotchTint.paused
        }
    }

    var summary: String {
        switch self {
        case .granted: return "Allowed"
        case .denied: return "Not allowed"
        case .undetermined: return "Not asked yet"
        case .checking: return "Checking…"
        }
    }
}

/// One permission, said the same way everywhere it appears.
///
/// This shape is used twice on purpose: the pane that needs a permission renders
/// it so the reader can fix the thing they are looking at, and Privacy renders
/// all of them so the reader can see what the app has been given. Same
/// component, so the two can never disagree about what "allowed" looks like.
struct SettingsPermissionRow: View {
    let permission: SystemPermission
    let status: PermissionStatus
    /// What stops working without it. One sentence, in the concrete.
    var why: String?
    /// Asking in place. `nil` when macOS will not show a prompt any more, which
    /// leaves the System Settings link as the only honest route.
    var request: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NotchSpace.row) {
            VStack(alignment: .leading, spacing: NotchSpace.hair) {
                HStack(spacing: NotchSpace.tight) {
                    Image(systemName: permission.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(status.tint)
                    Text(permission.title).font(NotchType.rowTitle)
                    SettingBadge(status.summary, tint: status.isGranted ? nil : status.tint)
                }
                if let why {
                    Text(why)
                        .font(NotchType.rowDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: NotchSpace.tight)
            if !status.isGranted {
                if let request, status == .undetermined {
                    Button("Allow…", action: request)
                } else {
                    Button("Open Settings") {
                        NSWorkspace.shared.open(permission.privacyPaneURL)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(NotchMotion.settle, value: status)
    }
}

// MARK: - Absence

/// Nothing here yet, and what to do about it.
///
/// Four panes had written this by hand and disagreed on all three of glyph, tone
/// and whether there was anything to press.
struct SettingsEmptyState: View {
    let symbol: String
    let title: String
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: NotchSpace.snug) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            VStack(spacing: NotchSpace.hair) {
                Text(title).font(NotchType.rowTitle)
                if let detail {
                    Text(detail)
                        .font(NotchType.rowDetail)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NotchSpace.group)
    }
}

// MARK: - Structure

/// A named break inside a long pane, for when a second card would be one card
/// too many.
struct SettingsDivider: View {
    var title: String?

    init(_ title: String? = nil) { self.title = title }

    var body: some View {
        HStack(spacing: NotchSpace.snug) {
            if let title {
                Text(title.uppercased())
                    .font(NotchType.eyebrow)
                    .kerning(0.5)
                    .foregroundStyle(.tertiary)
            }
            Rectangle()
                .fill(NotchSurface.hairline)
                .frame(height: 1)
        }
        .padding(.top, NotchSpace.snug)
    }
}

/// The bar a pane grows when it has something to commit.
///
/// Promoted from Sweep's `cleanupBar` and `optionsBar`, which were the same bar
/// twice and the only two places in Settings using `.bar` material.
struct SettingsActionBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: NotchSpace.snug) {
            leading
            Spacer(minLength: NotchSpace.snug)
            trailing
        }
        .padding(.horizontal, NotchSpace.card)
        .padding(.vertical, NotchSpace.snug)
        .background(NotchSurface.raised)
        .overlay(alignment: .top) {
            Rectangle().fill(NotchSurface.hairline).frame(height: 1)
        }
    }
}

/// A 9pt uppercase micro-label.
///
/// Promoted from the copilot's `activityChip`. It is the same typographic idea
/// as `NotchType.eyebrow` at a smaller size, so it lives here rather than being
/// reinvented per pane. Where it marks state, the symbol carries the meaning as
/// well as the tint — colour alone is not a label.
struct SettingsMicroLabel: View {
    let text: String
    var symbol: String?
    var tint: Color?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            }
            Text(text.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
        }
        .foregroundStyle(tint ?? .secondary)
    }
}
