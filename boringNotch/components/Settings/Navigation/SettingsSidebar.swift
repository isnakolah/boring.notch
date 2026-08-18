//
//  SettingsSidebar.swift
//  boringNotch
//

import SwiftUI

/// A row that pushes a page, named by the page itself.
///
/// The design-system row takes a symbol and a title because it is also used for
/// rows that open a sheet. This is the route-aware form, and it is the one panes
/// should reach for: it cannot disagree with the breadcrumb, because both read
/// the same model.
extension SettingsDrillRow where Trailing == EmptyView {
    init(_ page: SettingsPage, router: SettingsRouter, badge: String? = nil, badgeTint: Color? = nil) {
        self.init(symbol: page.symbol,
                  title: String(localized: page.title),
                  detail: page.detail.map { String(localized: $0) },
                  badge: badge,
                  badgeTint: badgeTint) { router.push(page) }
    }
}

/// Everything a section offers, as rows.
struct SettingsSubpageList: View {
    let section: SettingsSection
    @Environment(\.settingsRouter) private var router

    var body: some View {
        if !section.subpages.isEmpty, let router {
            SettingsDrillGroup {
                ForEach(Array(section.subpages.enumerated()), id: \.element) { index, page in
                    if index > 0 {
                        Divider().opacity(0.35).padding(.leading, 38)
                    }
                    SettingsDrillRow(page, router: router)
                }
            }
        }
    }
}

// MARK: - The sidebar

/// Thirteen destinations, a live notch above them, and a search field.
///
/// The search field is not polish. Merging twenty-seven flat rows into thirteen
/// sections puts roughly twenty destinations one click deep, and a flat list at
/// least let everything be found by scanning. Search is what pays that back —
/// it matches subpage titles and per-page keywords, so "full disk access",
/// "whisper" or "lyrics" land on the page that owns them rather than on the
/// section that contains it.
///
/// The old group headers are gone with the flat list. At thirteen rows they
/// stopped earning their line, and the space goes to the preview well.
struct SettingsSidebar: View {
    @ObservedObject var router: SettingsRouter
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            NotchPreviewWell(content: router.route.previewContent)

            SettingsSearchField(query: $query)
                .padding(.horizontal, NotchSpace.snug)
                .padding(.vertical, NotchSpace.tight)

            if query.isEmpty {
                SettingsSectionList(router: router)
            } else {
                SettingsSearchResults(query: query, router: router)
            }
        }
        .background(NotchSurface.base)
    }
}

private struct SettingsSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: NotchSpace.tight) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(NotchType.rowTitle)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, NotchSpace.tight)
        .padding(.vertical, 5)
        .background(NotchSurface.raised,
                    in: RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                .strokeBorder(NotchSurface.hairline, lineWidth: 1)
        )
    }
}

private struct SettingsSearchResults: View {
    let query: String
    @ObservedObject var router: SettingsRouter

    var body: some View {
        List {
            if matches.isEmpty {
                Text("No settings match “\(query)”.")
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, NotchSpace.tight)
            }
            ForEach(matches, id: \.identifier) { match in
                Button { router.go(match.route) } label: {
                    HStack(spacing: NotchSpace.tight) {
                        Image(systemName: match.symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(match.title).font(NotchType.rowTitle)
                            if let context = match.context {
                                Text(context)
                                    .font(NotchType.rowDetail)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private var matches: [SettingsSearchIndex.Match] { SettingsSearchIndex.search(query) }
}


/// The thirteen rows.
///
/// Hand-built rather than a `List(selection:)` so the highlight can slide
/// between rows instead of blinking — the same `matchedGeometryEffect` capsule
/// the notch's own tab bar uses. Thirteen rows is the count where that reads as
/// craft rather than as noise.
private struct SettingsSectionList: View {
    @ObservedObject var router: SettingsRouter
    @Namespace private var capsule

    var body: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(SettingsSection.allCases) { section in
                    SettingsSectionRow(
                        section: section,
                        selected: router.route.section == section,
                        namespace: capsule) {
                            router.section.wrappedValue = section
                        }
                }
            }
            .padding(.horizontal, NotchSpace.tight)
            .padding(.vertical, NotchSpace.tight)
        }
        .scrollContentBackground(.hidden)
    }
}

private struct SettingsSectionRow: View {
    let section: SettingsSection
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NotchSpace.snug) {
                Image(systemName: section.symbol)
                    .font(.system(size: 12))
                    .frame(width: 18)
                Text(section.title)
                    .font(NotchType.rowTitle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, NotchSpace.snug)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                        .fill(Color.effectiveAccent)
                        .matchedGeometryEffect(id: "sidebarSelection", in: namespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NotchMotion.settle, value: selected)
        .animation(NotchMotion.settle, value: hovering)
    }
}
