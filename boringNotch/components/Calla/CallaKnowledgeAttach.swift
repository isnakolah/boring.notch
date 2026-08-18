import AppKit
import Combine
import Defaults
import Foundation
import UniformTypeIdentifiers

/// Where a piece of knowledge is going.
///
/// A separate type from the store's scope string because it carries the *label*
/// too: every place this appears, the user is choosing between "this Tuesday's
/// standup" and "every Tuesday standup", and those have to be nameable.
struct KnowledgeTarget: Identifiable, Equatable {
    enum Kind: Equatable {
        case always
        case event(id: String)
        case series(id: String)
    }

    var kind: Kind
    var title: String
    var detail: String
    var startsAt: Date?

    var id: String {
        switch kind {
        case .always: "always"
        case let .event(id): "event:\(id)"
        case let .series(id): "series:\(id)"
        }
    }

    var scope: String {
        switch kind {
        case .always: "always"
        case .event: "event"
        case .series: "series"
        }
    }

    var scopeKey: String? {
        switch kind {
        case .always: nil
        case let .event(id), let .series(id): id
        }
    }

    static let everyCall = KnowledgeTarget(
        kind: .always,
        title: "Every call",
        detail: "Background the copilot should always have")

    /// The choices one calendar event offers.
    ///
    /// A recurring meeting gets two, and the repeat is listed first because it is
    /// nearly always the right answer — a briefing document for a weekly review is
    /// wanted every week, not once. Someone who genuinely means "just this one"
    /// can say so, but they should have to.
    static func choices(for event: EventModel) -> [KnowledgeTarget] {
        var targets: [KnowledgeTarget] = []
        if let seriesID = event.seriesID, !seriesID.isEmpty, event.hasRecurrenceRules {
            targets.append(KnowledgeTarget(
                kind: .series(id: seriesID),
                title: event.title,
                detail: "Every time this meeting repeats",
                startsAt: event.start))
        }
        targets.append(KnowledgeTarget(
            kind: .event(id: event.id),
            title: event.title,
            detail: targets.isEmpty ? "This meeting" : "Only the one on \(Self.day(event.start))",
            startsAt: event.start))
        return targets
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date)
    }
}

/// Reads dropped files and files them against a meeting.
///
/// One place, three callers: the notch drop, the calendar's right-click, and the
/// Settings pane. They differ only in how the target is chosen — everything after
/// that is identical, and it was worth not writing three times.
@MainActor
final class CallaKnowledgeAttach: ObservableObject {
    static let shared = CallaKnowledgeAttach()

    /// Files waiting for a target, after a drop onto the notch.
    @Published private(set) var pending: [PendingFile] = []
    /// The meeting already chosen, when the surface was opened from the calendar
    /// rather than by a drop. Nil means the surface still has to ask.
    @Published private(set) var presetTarget: KnowledgeTarget?
    /// What is already filed against `presetTarget`, so the surface can show it.
    @Published private(set) var attached: [CallaKnowledgeNote] = []
    /// Meetings the drop can be filed against, newest-soonest first.
    @Published private(set) var targets: [KnowledgeTarget] = []
    /// Whether the notch is showing this surface.
    ///
    /// Read by `CopilotLiveSession.preferredOpenSize`, which is what the
    /// no-argument `vm.open()` consults — so a drop that opens the notch gets the
    /// right height without every caller having to know about it.
    @Published private(set) var isPresenting = false
    @Published private(set) var isWorking = false
    /// The last thing that happened, in words, for whichever surface is showing.
    @Published var status: String?
    @Published var failure: String?

    struct PendingFile: Identifiable, Equatable {
        let id = UUID()
        var url: URL
        var name: String { url.lastPathComponent }
    }

    private let calendarService: CalendarServiceProviding

    private init(calendarService: CalendarServiceProviding = CalendarService()) {
        self.calendarService = calendarService
    }

    // MARK: - Dropping onto the notch

    /// Takes the file URLs out of a drop and offers them a home.
    ///
    /// Returns false when the drop carried nothing this can read, so the caller
    /// can leave the Shelf to handle it — a dragged image or zip is a Shelf
    /// gesture, not a knowledge one, and hijacking it would be wrong.
    func accept(_ providers: [NSItemProvider]) async -> Bool {
        let urls = await Self.fileURLs(from: providers)
        let readable = urls.filter { KnowledgeDocumentReader.canRead($0) }
        guard !readable.isEmpty else { return false }

        pending = readable.map { PendingFile(url: $0) }
        failure = nil
        status = nil
        isPresenting = true
        await refreshTargets()
        return true
    }

    func cancelPending() {
        pending = []
        presetTarget = nil
        attached = []
        status = nil
        failure = nil
        isPresenting = false
    }

    // MARK: - Arriving from the calendar

    /// Opens the same surface a drop lands on, already pointed at one meeting.
    ///
    /// A recurring meeting defaults to the repeat rather than the single
    /// occurrence: a briefing document for a weekly review is wanted every week,
    /// and getting that wrong fails silently — the file simply would not be there
    /// next Tuesday. The choice is still offered, it just is not the default.
    func begin(for event: EventModel) {
        pending = []
        status = nil
        failure = nil
        presetTarget = KnowledgeTarget.choices(for: event).first ?? .everyCall
        targets = KnowledgeTarget.choices(for: event) + [.everyCall]
        isPresenting = true
        refreshAttached()
    }

    /// Switches which meeting the open surface is filing against.
    func retarget(_ target: KnowledgeTarget) {
        presetTarget = target
        refreshAttached()
    }

    /// Re-reads what is filed against the current target.
    func refreshAttached() {
        guard let presetTarget, let key = presetTarget.scopeKey else {
            attached = []
            return
        }
        let isSeries = presetTarget.scope == "series"
        CallaEngineClient.shared.fetchKnowledge(
            eventID: isSeries ? nil : key,
            seriesID: isSeries ? key : nil
        ) { [weak self] fetched in
            // Only what belongs to this meeting. The fetch also returns the
            // always-on notes, which apply everywhere and would read here as
            // though someone had attached them to this event.
            self?.attached = fetched.filter { $0.scope == "event" || $0.scope == "series" }
        }
    }

    /// The meetings worth offering, plus the always-on option.
    ///
    /// Today and tomorrow only. A picker listing three weeks of calendar is a
    /// worse answer than a short list plus the Settings pane, and the file being
    /// dropped is nearly always for something imminent.
    func refreshTargets() async {
        let calendars = Array(CalendarManager.shared.selectedCalendarIDs)
        let events = await calendarService.upcoming(within: 36 * 60 * 60, calendars: calendars)
        var seen = Set<String>()
        var list: [KnowledgeTarget] = []
        for event in events where !event.isAllDay && !event.type.isReminder {
            for target in KnowledgeTarget.choices(for: event) where !seen.contains(target.id) {
                seen.insert(target.id)
                list.append(target)
            }
        }
        targets = list + [.everyCall]
    }

    /// Reads every pending file and files it against `target`.
    func commitPending(to target: KnowledgeTarget) async {
        let files = pending
        guard !files.isEmpty else { return }
        pending = []
        await attach(files.map(\.url), to: target)
        // Land on the same surface, now showing the meeting that was picked and
        // everything filed against it — so "did that work" is answered on screen
        // rather than by going to look.
        presetTarget = target
        refreshAttached()
    }

    /// Files picked from the open panel rather than dragged.
    func attachChosenFiles(to target: KnowledgeTarget) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = KnowledgeDocumentReader.readableTypes
        panel.prompt = "Attach"
        panel.message = "Choose what the copilot should be able to read during this call."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { await attach(urls, to: target) }
    }

    func remove(_ note: CallaKnowledgeNote) {
        CallaEngineClient.shared.deleteKnowledge(id: note.id) { [weak self] _ in
            self?.refreshAttached()
            CallaKnowledgeFocus.shared.refresh()
            NotificationCenter.default.post(name: .callaKnowledgeDidChange, object: nil)
        }
    }

    // MARK: - Attaching

    /// Reads the files and saves them. Safe to call from any surface.
    func attach(_ urls: [URL], to target: KnowledgeTarget) async {
        guard !urls.isEmpty else { return }
        isWorking = true
        failure = nil
        defer { isWorking = false }

        var saved = 0
        var problems: [String] = []

        for url in urls {
            // Extraction is genuinely slow for a scanned PDF — Vision runs OCR
            // page by page — so it goes off the main actor. The save afterwards
            // hops back, because the engine client is main-actor bound.
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try KnowledgeDocumentReader.read(url) }
            }.value

            switch outcome {
            case let .success(document):
                let note = CallaKnowledgeNote.document(
                    name: document.name,
                    kind: document.kind,
                    text: document.text,
                    byteSize: document.byteSize,
                    pageCount: document.pageCount,
                    scope: target.scope,
                    scopeKey: target.scopeKey)
                await save(note)
                saved += 1
            case let .failure(error):
                problems.append((error as? LocalizedError)?.errorDescription
                    ?? "\(url.lastPathComponent) could not be read.")
            }
        }

        CallaKnowledgeFocus.shared.refresh()
        NotificationCenter.default.post(name: .callaKnowledgeDidChange, object: nil)
        refreshAttached()

        if saved > 0 {
            status = saved == 1
                ? "Added to \(target.title)."
                : "\(saved) files added to \(target.title)."
        }
        failure = problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    /// Files a piece of typed text. Same path, no reading step.
    func attach(text: String, title: String, to target: KnowledgeTarget) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        var note = CallaKnowledgeNote.new(scope: target.scope, scopeKey: target.scopeKey)
        note.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        note.body = body
        await save(note)
        CallaKnowledgeFocus.shared.refresh()
        NotificationCenter.default.post(name: .callaKnowledgeDidChange, object: nil)
        refreshAttached()
        status = "Added to \(target.title)."
    }

    private func save(_ note: CallaKnowledgeNote) async {
        await withCheckedContinuation { continuation in
            CallaEngineClient.shared.saveKnowledge(note) { _ in continuation.resume() }
        }
    }

    // MARK: - Providers

    /// Pulls file URLs out of a drop.
    ///
    /// The router's resolver, not a second copy: it is the one that learned a
    /// Finder drag can arrive registered as `public.url` rather than
    /// `public.file-url`, and a drop must read the same here as it does there.
    private static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        await NotchDropRouter.resolveFileURLs(providers)
    }
}

extension Notification.Name {
    /// Posted whenever a note is written, so every open surface re-reads.
    static let callaKnowledgeDidChange = Notification.Name("callaKnowledgeDidChange")
    /// Posted when the calendar wants the notch grown to the filing surface.
    ///
    /// The calendar lives inside the notch, so it cannot resize the panel itself
    /// without reaching for the view model through a chain of parents.
    static let callaKnowledgeWantsNotch = Notification.Name("callaKnowledgeWantsNotch")
}
