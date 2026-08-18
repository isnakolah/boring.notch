import Combine
import Defaults
import Foundation

/// Every meeting the copilot could be given something for, and what it already
/// has for each.
///
/// Settings needs a different view of the calendar from the notch: not "the next
/// thing" but "everything, so I can find the one I mean". It also has to list
/// meetings with nothing attached yet — the whole task is *adding* to those, and
/// a list that only showed meetings already prepared would hide exactly the ones
/// worth opening.
@MainActor
final class CallaKnowledgeLibrary: ObservableObject {
    static let shared = CallaKnowledgeLibrary()

    @Published private(set) var events: [EventModel] = []
    @Published private(set) var notes: [CallaKnowledgeNote] = []
    @Published private(set) var calls: [CallaCallRecord] = []
    @Published private(set) var isLoading = false

    private let calendarService: CalendarServiceProviding

    /// A week back and a month forward.
    ///
    /// Backwards because a call that already happened is still worth attaching a
    /// document to — the summary it left behind is filed against the same
    /// meeting, and next month's instance will read both.
    private static let past: TimeInterval = -7 * 24 * 60 * 60
    private static let future: TimeInterval = 30 * 24 * 60 * 60

    /// How much calendar is currently held.
    ///
    /// The default window is a week back and a month forward, which is the span
    /// worth attaching things to without being asked. Browsing past that widens
    /// it rather than replacing it, so paging back to March and forward again
    /// does not re-fetch April every time.
    @Published private(set) var loadedRange: ClosedRange<Date>?

    private init(calendarService: CalendarServiceProviding = CalendarService()) {
        self.calendarService = calendarService
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        let now = Date()
        await loadEvents(from: now.addingTimeInterval(Self.past),
                         to: now.addingTimeInterval(Self.future))

        await withCheckedContinuation { continuation in
            CallaEngineClient.shared.fetchKnowledge { [weak self] fetched in
                self?.notes = fetched
                continuation.resume()
            }
        }
        await withCheckedContinuation { continuation in
            CallaEngineClient.shared.fetchCalls(forEvent: nil, seriesID: nil) { [weak self] fetched in
                self?.calls = fetched
                continuation.resume()
            }
        }
    }

    /// Widen the window to cover a month the reader has paged to.
    ///
    /// A no-op when the month is already held, which is the common case: the
    /// default window already spans most of what anyone looks at first.
    func ensureLoaded(month: Date) async {
        let calendar = Calendar.current
        guard let start = calendar.dateInterval(of: .month, for: month)?.start,
              let end = calendar.dateInterval(of: .month, for: month)?.end else { return }
        if let range = loadedRange, range.contains(start), range.contains(end) { return }

        let from = min(start, loadedRange?.lowerBound ?? start)
        let to = max(end, loadedRange?.upperBound ?? end)
        isLoading = true
        defer { isLoading = false }
        await loadEvents(from: from, to: to)
    }

    private func loadEvents(from: Date, to: Date) async {
        let calendars = Array(CalendarManager.shared.selectedCalendarIDs)
        let fetched = await calendarService.events(from: from, to: to, calendars: calendars)
        events = fetched
            .filter { !$0.type.isReminder && !$0.isAllDay }
            .sorted { $0.start > $1.start }
        loadedRange = from...to
    }

    /// Every day in the given month that has at least one meeting, with how many
    /// of them have something attached.
    func dayIndex(for month: Date) -> [Date: (meetings: Int, prepared: Int)] {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [:] }
        var index: [Date: (meetings: Int, prepared: Int)] = [:]
        for event in events where interval.contains(event.start) {
            let day = calendar.startOfDay(for: event.start)
            var entry = index[day] ?? (0, 0)
            entry.meetings += 1
            if !notes(for: event).isEmpty { entry.prepared += 1 }
            index[day] = entry
        }
        return index
    }

    /// Just one day's meetings, for when the reader has picked one.
    func events(on day: Date) -> [EventModel] {
        let calendar = Calendar.current
        return events
            .filter { calendar.isDate($0.start, inSameDayAs: day) }
            .sorted { $0.start < $1.start }
    }

    /// Notes attached to one event, counting the series it belongs to.
    ///
    /// Both, because that is what the copilot will actually see in that meeting —
    /// showing only the occurrence-scoped ones would under-report what is there
    /// and invite someone to attach a second copy.
    func notes(for event: EventModel) -> [CallaKnowledgeNote] {
        notes.filter { note in
            guard let key = note.scopeKey else { return false }
            if note.scope == "event" { return key == event.id }
            if note.scope == "series" { return key == event.seriesID }
            return false
        }
    }

    func notes(scope: String) -> [CallaKnowledgeNote] {
        notes.filter { $0.scope == scope }
    }

    func callCount(for event: EventModel) -> Int {
        calls.filter { call in
            if let seriesID = event.seriesID, !seriesID.isEmpty { return call.seriesID == seriesID }
            return call.eventID == event.id
        }.count
    }

    /// Meetings that have something attached, most recent first. Used for the
    /// "prepared" summary rather than for the browsing list.
    var preparedEvents: [EventModel] {
        events.filter { !notes(for: $0).isEmpty }
    }

    /// Notes filed against a meeting that is no longer in the calendar window —
    /// a series whose occurrences have all passed, or an event that was deleted.
    ///
    /// Surfaced rather than hidden: they still apply to any future occurrence, and
    /// silently orphaned settings are how a knowledge base becomes untrustworthy.
    var orphanedNotes: [CallaKnowledgeNote] {
        let known = Set(events.map(\.id)) .union(Set(events.compactMap(\.seriesID)))
        return notes.filter { note in
            guard note.scope == "event" || note.scope == "series" else { return false }
            guard let key = note.scopeKey else { return false }
            return !known.contains(key)
        }
    }

    /// Events grouped by day, newest day first, for a sectioned list.
    func groupedByDay(matching query: String) -> [(day: Date, events: [EventModel])] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = trimmed.isEmpty ? events : events.filter { event in
            event.title.lowercased().contains(trimmed)
                || notes(for: event).contains {
                    $0.title.lowercased().contains(trimmed)
                        || ($0.originName ?? "").lowercased().contains(trimmed)
                }
        }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.start) }
        return grouped
            .map { (day: $0.key, events: $0.value.sorted { $0.start < $1.start }) }
            .sorted { $0.day > $1.day }
    }
}
