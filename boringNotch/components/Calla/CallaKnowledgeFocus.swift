import Combine
import Foundation

/// Which meeting the Knowledge pane should be showing, and a cheap answer to
/// "does this event have anything written for it yet".
///
/// Two jobs, one object, because they share the same cache. The calendar row
/// needs the second answer on every redraw and the list redraws constantly, so
/// asking the engine per row is out — the store is across an XPC hop and behind a
/// sandbox boundary. Instead the set of meetings that have notes is fetched once
/// and refreshed whenever something is written.
@MainActor
final class CallaKnowledgeFocus: ObservableObject {
    static let shared = CallaKnowledgeFocus()

    /// The meeting the Knowledge pane opened for, set by the calendar row on its
    /// way to Settings.
    @Published private(set) var eventID: String?
    @Published private(set) var seriesID: String?
    @Published private(set) var title: String?

    /// Event and series ids that have at least one note attached.
    ///
    /// Only ids the user actually wrote something against — an `always` note is
    /// not "prep for this meeting", and marking every row would make the glyph
    /// mean nothing.
    @Published private(set) var prepared: Set<String> = []

    private var refreshing = false

    private init() {}

    func focus(on event: EventModel) {
        eventID = event.id
        seriesID = event.seriesID
        title = event.title
    }

    func clearFocus() {
        eventID = nil
        seriesID = nil
        title = nil
    }

    func hasNotes(eventID: String?, seriesID: String?) -> Bool {
        if let eventID, prepared.contains(eventID) { return true }
        if let seriesID, prepared.contains(seriesID) { return true }
        return false
    }

    /// Re-reads which meetings have notes. Called on launch and after every edit.
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        CallaEngineClient.shared.fetchKnowledge { [weak self] notes in
            guard let self else { return }
            refreshing = false
            prepared = Set(notes.compactMap { note in
                // Scoped notes only: `always` and per-persona notes apply to every
                // meeting, so they say nothing about any particular one.
                guard note.scope == "event" || note.scope == "series" else { return nil }
                return note.scopeKey
            })
        }
    }
}
