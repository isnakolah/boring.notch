//
//  SettingsLanding.swift
//  boringNotch
//

import SwiftUI

/// What a section's front page is made of.
///
/// The landing panes were a master switch in a card and a column of drill rows —
/// a menu standing in front of the pages someone actually wanted, and a scroll
/// as soon as a section had six of them. Three pieces fix that:
///
/// - `SettingsStateBand` answers "is this working right now" at the top, which
///   is the question a landing pane is best placed to answer and the one it
///   never did.
/// - `SettingsTileGrid` lays the destinations out as a map instead of a list,
///   and each tile carries what its page currently says, so the value can be
///   read without opening it.
/// - `SettingsPane(nav:)` lets a page point at its siblings from the header, so
///   a page that *is* the work — Sweep — does not have to spend a card on
///   navigation to be navigable.

// MARK: - State band

/// The master switch, and what the feature is doing at this moment.
///
/// Deliberately not a `SettingCard`: it spans the pane, leads with a 40pt glyph
/// and takes the wash, so it reads as the pane's subject rather than as the
/// first of several equal things.
struct SettingsStateBand<Trailing: View>: View {
    let symbol: String
    /// The state, in two or three words. "In a call", "Engine running", "Idle".
    let title: String
    /// One line of specifics under it.
    let detail: String
    /// Colour it only when it is reporting live state; an ordinary band that
    /// shouts leaves nothing for the one that needs to.
    var tint: Color?
    @Binding var isOn: Bool
    /// Live readouts that belong beside the switch — capture levels, a row of
    /// health dots.
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: NotchSpace.card) {
            SettingGlyph(symbol: symbol, tint: tint ?? NotchTint.active, size: 40)
            VStack(alignment: .leading, spacing: NotchSpace.hair) {
                Text(title).font(NotchType.cardTitle)
                Text(detail)
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: NotchSpace.snug)
            trailing
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
        .padding(NotchSpace.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NotchSurface.raised,
                    in: RoundedRectangle(cornerRadius: NotchRadius.card, style: .continuous))
        .background {
            if let tint { NotchWash(tint: tint) }
        }
        .overlay(
            RoundedRectangle(cornerRadius: NotchRadius.card, style: .continuous)
                .strokeBorder(tint?.opacity(0.30) ?? NotchSurface.hairline, lineWidth: 1)
        )
        .animation(NotchMotion.settle, value: title)
    }
}

extension SettingsStateBand where Trailing == EmptyView {
    init(symbol: String, title: String, detail: String, tint: Color? = nil,
         isOn: Binding<Bool>) {
        self.init(symbol: symbol, title: title, detail: detail, tint: tint,
                  isOn: isOn) { EmptyView() }
    }
}

/// A capture level, drawn rather than named.
///
/// "Capturing" and "Silent" are the same word until the microphone is actually
/// dead, and by then the call is half over. Bars move.
struct SettingsLevelMeter: View {
    let label: String
    /// 0…1. Seven bars is enough to read as movement and few enough to sit in a
    /// band without becoming a chart.
    let level: Double
    var tint: Color = NotchTint.active

    private static let weights: [Double] = [0.35, 0.72, 1.0, 0.55, 0.86, 0.62, 0.30]

    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(Self.weights.enumerated()), id: \.offset) { _, weight in
                    Capsule()
                        .fill(level > 0.02 ? tint : Color.secondary.opacity(0.45))
                        .frame(width: 2, height: max(2, 14 * weight * max(level, 0.14)))
                }
            }
            .frame(height: 14, alignment: .bottom)
            SettingsMicroLabel(text: label)
        }
        .animation(NotchMotion.settle, value: level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(level > 0.02 ? "Capturing" : "Silent")
    }
}

/// A named health light. Three of these say more in a band than three rows say
/// in a card.
struct SettingsHealthDot: View {
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            SettingsMicroLabel(text: label)
        }
    }
}

// MARK: - Tiles

/// A destination, with what it currently says.
///
/// The drill row's replacement on a landing pane. A row spends a whole line of a
/// scroll on one destination; three tiles fit on the same line, and the tile has
/// room for the current value where the row only had room for a badge.
struct SettingsTile: View {
    let symbol: String
    let title: String
    /// What the page behind this says right now: "This Mac · Balanced",
    /// "3 apps allowed", "Running · build 2f91c". Not a description — the
    /// description belongs on the page.
    let value: String
    var tint: Color = NotchTint.active
    /// Draw the value in the accent when it is reporting something live.
    var valueIsLive = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: NotchSpace.tight) {
                HStack(alignment: .top, spacing: 0) {
                    SettingGlyph(symbol: symbol, tint: tint, size: 26)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovering ? .secondary : .tertiary)
                        .padding(.top, 3)
                }
                Text(title).font(NotchType.rowTitle)
                Text(value)
                    .font(NotchType.rowDetail)
                    .foregroundStyle(valueIsLive ? AnyShapeStyle(NotchTint.active)
                                                 : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(NotchSpace.row)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(NotchSurface.raised,
                        in: RoundedRectangle(cornerRadius: NotchRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: NotchRadius.card, style: .continuous)
                    .strokeBorder(hovering ? tint.opacity(0.35) : NotchSurface.hairline,
                                  lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NotchMotion.settle, value: hovering)
    }
}

/// Tiles on a grid, three across by default.
///
/// Three is what fits the 708pt detail column at the pane margin without the
/// value line wrapping to three lines. Four is for sections with exactly four
/// destinations, where a 3+1 grid would leave a hole.
struct SettingsTileGrid<Content: View>: View {
    var columns: Int = 3
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: NotchSpace.stack),
                           count: columns),
            spacing: NotchSpace.stack
        ) {
            content
        }
    }
}

// MARK: - Header navigation

/// A sibling page, reachable from the header.
///
/// The alternative was a card of drill rows at the bottom of a page that already
/// had its own work to show — which is how Sweep ended up with an Overview pane
/// whose entire job was to stand in front of Clean Up. A chip in the header
/// costs one line and no card.
struct SettingsHeaderNav: View {
    let pages: [SettingsPage]
    @Environment(\.settingsRouter) private var router

    var body: some View {
        if let router {
            HStack(spacing: NotchSpace.tight) {
                ForEach(pages, id: \.self) { page in
                    NavChip(title: String(localized: page.title)) { router.push(page) }
                }
            }
        }
    }

    private struct NavChip: View {
        let title: String
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 5) {
                    Text(title).font(NotchType.rowDetail)
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(NotchSurface.raised, in: Capsule())
                .overlay(Capsule().strokeBorder(NotchSurface.hairline, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(NotchMotion.settle, value: hovering)
        }
    }
}

// MARK: - Columns

/// Two columns of cards.
///
/// The detail column is 708pt wide and most cards in this window are a title, a
/// sentence and two or three rows — which leaves half the width empty and pushes
/// the fourth card below the fold. A pane that scrolls is the thing this redesign
/// is against, so short cards pair up.
///
/// Not for cards with wide content: a path editor, a calendar, a transcript.
/// Those stay full width.
struct SettingsColumns<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: NotchSpace.stack) {
            VStack(spacing: NotchSpace.stack) { leading }
                .frame(maxWidth: .infinity, alignment: .top)
            VStack(spacing: NotchSpace.stack) { trailing }
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}
