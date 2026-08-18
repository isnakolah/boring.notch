//
//  SettingsSearchIndex.swift
//  boringNotch
//

import Foundation

/// What the sidebar search field looks through.
///
/// Every section and every payload-free page, each carrying the words someone
/// would actually type. A title-only index would fail the common case: nobody
/// searching for "full disk access" is looking for a page called "Options", and
/// nobody searching "lyrics" knows the setting lives under Media.
enum SettingsSearchIndex {
    struct Match {
        let identifier: String
        let title: String
        let symbol: String
        /// Which section this sits in, shown under the title. `nil` for a
        /// section itself, where it would only repeat the title.
        let context: String?
        let route: SettingsRoute
    }

    private struct Entry {
        let match: Match
        let haystack: [String]
    }

    private static let entries: [Entry] = {
        var out: [Entry] = []
        for section in SettingsSection.allCases {
            let title = String(localized: section.title)
            out.append(Entry(
                match: Match(identifier: section.rawValue, title: title, symbol: section.symbol,
                             context: nil, route: .init(section)),
                haystack: [title, String(localized: section.detail)].map { $0.lowercased() }))
        }
        for page in SettingsPage.indexable {
            let title = String(localized: page.title)
            let context = String(localized: page.section.title)
            var words = [title, context] + page.keywords
            if let detail = page.detail { words.append(String(localized: detail)) }
            out.append(Entry(
                match: Match(identifier: page.identifier, title: title, symbol: page.symbol,
                             context: context, route: .init(page.section, [page])),
                haystack: words.map { $0.lowercased() }))
        }
        return out
    }()

    static func search(_ query: String) -> [Match] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }

        // Ranked, not just filtered: a title that starts with what was typed
        // beats one that merely contains it, which beats a keyword hit. Without
        // that, typing "cal" puts "Local Send" above "Calendar".
        func rank(_ entry: Entry) -> Int? {
            let title = entry.haystack[0]
            if title.hasPrefix(needle) { return 0 }
            if title.contains(needle) { return 1 }
            if entry.haystack.dropFirst().contains(where: { $0.hasPrefix(needle) }) { return 2 }
            if entry.haystack.dropFirst().contains(where: { $0.contains(needle) }) { return 3 }
            return nil
        }

        return entries
            .compactMap { entry in rank(entry).map { (entry, $0) } }
            .sorted { ($0.1, $0.0.match.title) < ($1.1, $1.0.match.title) }
            .map(\.0.match)
    }
}
