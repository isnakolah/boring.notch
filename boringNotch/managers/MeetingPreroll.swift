import Combine
import Defaults
import Foundation

/// Arms the copilot before a meeting on the calendar starts.
///
/// The other two start paths both react to something that has already happened:
/// `MeetingDetector` waits for the microphone to go live, and the calendar row
/// waits for a tap. Both are correct and both are late — the first suggestion of
/// a call costs about ten seconds of cold `agy` boot plus the whisper model load,
/// and that lands in the opening minutes, which is where the questions worth
/// answering are.
///
/// This pays that cost while nobody is talking. What it deliberately does not do
/// is record: the capture legs stay stopped until the user presses Join or Start,
/// so a copilot that booted early is not a copilot that listened early. That
/// distinction is the whole design, and the notch states it in as many words.
@MainActor
final class MeetingPreroll: ObservableObject {
    static let shared = MeetingPreroll()

    /// The meeting currently armed, if any. Drives the pre-roll card.
    @Published private(set) var armed: EventModel?

    private let calendarService: CalendarServiceProviding
    private var pending: Task<Void, Never>?
    private var refreshTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    /// Events already handled this run, by id.
    ///
    /// Without it, a refresh that lands while a meeting is still in its lead
    /// window arms it again — which for a `prewarm` means spawning a second host
    /// on top of the first.
    private var handled: Set<String> = []

    /// How far ahead to look. Comfortably more than the lead time, so an event
    /// that appears in the calendar between refreshes is still seen in time.
    private static let horizon: TimeInterval = 2 * 60 * 60
    private static let refreshInterval: TimeInterval = 5 * 60

    private init(calendarService: CalendarServiceProviding = CalendarService()) {
        self.calendarService = calendarService
    }

    func start() {
        scheduleRefresh()
        Task { await refresh() }

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            // A meeting can be moved, cancelled or created inside its own lead
            // window, so a store change is worth a re-read rather than waiting
            // out the next timer.
            Task { @MainActor in await self?.refresh() }
        })

        // A call that ends releases the arming for whatever comes next, and one
        // that starts by any other route means this meeting is already handled.
        CallaEngineClient.shared.$status
            .map(\.copilot.isRecording)
            .removeDuplicates()
            .sink { [weak self] running in
                guard let self, running else { return }
                if let armed { handled.insert(armed.id) }
                self.armed = nil
            }
            .store(in: &cancellables)
    }

    /// Drops the arming without touching the host. Used when the user says "not
    /// this one" — `cancel()` is what actually stops the process.
    func disarm() {
        pending?.cancel()
        pending = nil
        if let armed { handled.insert(armed.id) }
        armed = nil
    }

    /// The user declined this meeting's pre-roll: stop the warm host and do not
    /// arm this event again.
    func cancel() {
        CallaEngineClient.shared.endCall()
        disarm()
    }

    /// Starts recording the meeting that was warmed up.
    func release() {
        CallaEngineClient.shared.releaseCall()
        if let armed { handled.insert(armed.id) }
    }

    /// The meeting's join link, for the Join button.
    var joinURL: URL? { armed?.videoCallURL }

    // MARK: - Scheduling

    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        // `.common` so the timer keeps firing while a menu is open or the notch
        // is being dragged; the default mode stalls for both.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func refresh() async {
        guard Defaults[.callaCopilotEnabled], Defaults[.callaCopilotPrerollEnabled] else {
            disarm()
            return
        }
        // The same selection the calendar tab shows. Reading it from the manager
        // rather than re-deriving it from Defaults keeps one interpretation of
        // "all calendars", which is the case the enum has a separate case for.
        let calendars = Array(CalendarManager.shared.selectedCalendarIDs)
        let events = await calendarService.upcoming(within: Self.horizon, calendars: calendars)
        guard let next = nextCandidate(among: events) else { return }
        schedule(next)
    }

    /// The next meeting worth arming.
    ///
    /// A video link is the filter, not attendee count: an event with a Meet or
    /// Zoom URL is one someone intends to talk in, whereas a two-person "lunch"
    /// with no link is not something to spawn a transcription host for. Declined
    /// events are skipped for the obvious reason.
    private func nextCandidate(among events: [EventModel]) -> EventModel? {
        let excluded = Set(Defaults[.callaCopilotPrerollExcluded])
        return events.first { event in
            guard event.videoCallURL != nil else { return false }
            guard !handled.contains(event.id), !excluded.contains(event.id) else { return false }
            guard event.eventStatus != .ended else { return false }
            if case .event(.declined) = event.type { return false }
            return true
        }
    }

    private func schedule(_ event: EventModel) {
        // Already waiting on this one; re-scheduling would only move the fire
        // time around for no reason.
        guard armed?.id != event.id else { return }
        pending?.cancel()
        armed = nil

        let lead = max(30, Defaults[.callaCopilotPrerollLead])
        let fireAt = event.start.addingTimeInterval(-lead)
        let delay = fireAt.timeIntervalSinceNow

        pending = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            await self.arm(event)
        }
    }

    private func arm(_ event: EventModel) async {
        guard Defaults[.callaCopilotEnabled], Defaults[.callaCopilotPrerollEnabled] else { return }
        guard !handled.contains(event.id) else { return }

        let engine = CallaEngineClient.shared
        guard engine.status.copilot.available else { return }
        // Something is already running — a call started by hand, or an earlier
        // pre-roll that was never released. Either way this meeting is not the one
        // to spawn a second host for.
        guard !engine.status.copilot.running else {
            handled.insert(event.id)
            return
        }

        armed = event
        engine.prewarmCall(
            persona: Defaults[.callaCopilotPersona],
            model: Defaults[.callaCopilotLiveModel],
            meeting: CallaMeeting(event))
        CopilotLiveSession.shared.beginPreroll(title: event.title, startsAt: event.start)
    }
}
