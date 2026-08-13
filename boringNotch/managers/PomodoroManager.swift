//
//  PomodoroManager.swift
//  boringNotch
//
//  Owns the running Pomodoro session. Timekeeping is anchored to a wall-clock
//  end date rather than a decrementing counter, so a missed tick — a busy main
//  thread, a view that isn't mounted — can never make the timer drift. Phase
//  completion is driven by its own sleeping task and fires whether or not any
//  Pomodoro UI is on screen.
//

import AppKit
import Combine
import Defaults
import Foundation
import UserNotifications

extension Notification.Name {
    /// Posted when a phase ends and the notch should surface the Pomodoro tab.
    /// `ContentView` observes this because only it holds a `BoringViewModel`.
    static let pomodoroPhaseEnded = Notification.Name("pomodoroPhaseEnded")
}

@MainActor
final class PomodoroManager: NSObject, ObservableObject {
    static let shared = PomodoroManager()

    enum RunState {
        case idle
        /// Counting down.
        case running
        /// A phase is loaded and waiting for the user — either they paused, or
        /// the previous phase ended and auto-start is off for this phase.
        case paused
    }

    // MARK: - Published state

    @Published private(set) var runState: RunState = .idle
    @Published private(set) var phase: PomodoroPhase = .work
    /// Full length of the loaded phase, used for the progress ring.
    @Published private(set) var phaseDuration: TimeInterval = 0
    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var completedWorkBlocks: Int = 0
    @Published private(set) var sourceEventID: String?
    @Published private(set) var history: [PomodoroRecord] = []
    /// Optional intention for the session, editable while it runs.
    @Published var sessionTitle: String = "" {
        didSet { if runState != .idle { persist() } }
    }

    // MARK: - Derived

    var isActive: Bool { runState != .idle }
    var isRunning: Bool { runState == .running }

    /// 0…1 elapsed fraction of the loaded phase.
    var progress: Double {
        guard phaseDuration > 0 else { return 0 }
        return min(1, max(0, (phaseDuration - remaining) / phaseDuration))
    }

    /// Icon for the current surface — a paused session reads as paused first,
    /// phase second.
    var statusIcon: String {
        runState == .paused ? "pause.circle.fill" : phase.icon
    }

    var selectedPreset: PomodoroPreset {
        let presets = Defaults[.pomodoroPresets]
        return presets.first { $0.id == Defaults[.pomodoroSelectedPresetID] }
            ?? presets.first
            ?? .classic
    }

    /// Work blocks finished today and the focus time they added up to.
    var todayCompletedWorkBlocks: Int {
        todayWorkRecords.filter(\.completed).count
    }

    var todayFocusTime: TimeInterval {
        todayWorkRecords.reduce(0) { $0 + $1.actualDuration }
    }

    private var todayWorkRecords: [PomodoroRecord] {
        let calendar = Calendar.current
        return history.filter { $0.phase.isWork && calendar.isDateInToday($0.startedAt) }
    }

    /// Remaining blocks of a calendar-planned session. `nil` for a preset-driven
    /// session, which generates its next phase on demand and never ends on its own.
    private var plannedQueue: [PomodoroBlock]?
    /// Preset the running session was started with — snapshotted so editing
    /// presets mid-session doesn't change the phase lengths underneath the user.
    private var activePreset: PomodoroPreset = .classic

    // MARK: - Internals

    private var endsAt: Date?
    private var phaseStartedAt: Date = Date()
    private var completionTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var didRequestNotificationAuthorization = false
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    private static let historyLimit = 500
    private static let historyMaxAge: TimeInterval = 90 * 24 * 60 * 60
    private static let notificationCategoryID = "pomodoro.phase"

    private override init() {
        super.init()
        loadHistory()
        restorePersistedState()
        observeSleepWake()
    }

    // MARK: - Starting

    /// Starts an open-ended session driven by a preset: work, break, work, …
    func start(preset: PomodoroPreset, title: String? = nil) {
        activePreset = preset
        plannedQueue = nil
        sourceEventID = nil
        completedWorkBlocks = 0
        if let title { sessionTitle = title }
        requestNotificationAuthorizationIfNeeded()
        load(block: PomodoroBlock(phase: .work, duration: preset.duration(for: .work)), autoStart: true)
    }

    /// Starts a finite session against a pre-planned block list — used by the
    /// calendar hand-off, where the plan must end when the event does.
    func start(blocks: [PomodoroBlock], preset: PomodoroPreset, title: String?, sourceEventID: String?) {
        guard let first = blocks.first else { return }
        activePreset = preset
        plannedQueue = Array(blocks.dropFirst())
        self.sourceEventID = sourceEventID
        completedWorkBlocks = 0
        sessionTitle = title ?? ""
        requestNotificationAuthorizationIfNeeded()
        load(block: first, autoStart: true)
    }

    /// One-off block with no cycle behind it.
    func startCustom(minutes: Int, title: String? = nil) {
        var preset = selectedPreset
        preset.workMinutes = max(1, minutes)
        start(preset: preset, title: title)
    }

    // MARK: - Transport

    func toggle() {
        switch runState {
        case .idle: start(preset: selectedPreset)
        case .running: pause()
        case .paused: resume()
        }
    }

    func pause() {
        guard runState == .running else { return }
        remaining = max(0, endsAt?.timeIntervalSinceNow ?? remaining)
        endsAt = nil
        runState = .paused
        cancelTasks()
        persist()
    }

    func resume() {
        guard runState == .paused, remaining > 0 else { return }
        endsAt = Date().addingTimeInterval(remaining)
        runState = .running
        scheduleTasks()
        if phase.isWork { runFocusShortcut(Defaults[.pomodoroFocusShortcutStart]) }
        persist()
    }

    /// Ends the current phase early and moves to the next one.
    func skip() {
        guard isActive else { return }
        finishPhase(completed: false)
    }

    /// Ends the whole session and returns the notch to its idle surfaces.
    func stop() {
        endSession(recordingCurrentPhase: true)
    }

    /// `recordingCurrentPhase` is false when the caller has already filed the
    /// phase — otherwise the final block would land in history twice and the
    /// focus-end shortcut would fire twice.
    private func endSession(recordingCurrentPhase: Bool) {
        guard isActive else { return }
        if recordingCurrentPhase {
            recordCurrentPhase(completed: false)
            if phase.isWork { runFocusShortcut(Defaults[.pomodoroFocusShortcutEnd]) }
        }
        cancelTasks()
        runState = .idle
        endsAt = nil
        remaining = 0
        phaseDuration = 0
        phase = .work
        plannedQueue = nil
        sourceEventID = nil
        completedWorkBlocks = 0
        sessionTitle = ""
        Defaults[.pomodoroPersistedState] = nil
    }

    /// Restarts the current phase from the top without ending the session.
    func reset() {
        guard isActive else { return }
        let wasRunning = runState == .running
        remaining = phaseDuration
        phaseStartedAt = Date()
        if wasRunning {
            endsAt = Date().addingTimeInterval(phaseDuration)
            scheduleTasks()
        } else {
            endsAt = nil
            cancelTasks()
        }
        persist()
    }

    // MARK: - Phase lifecycle

    private func load(block: PomodoroBlock, autoStart: Bool) {
        cancelTasks()
        phase = block.phase
        phaseDuration = block.duration
        remaining = block.duration
        phaseStartedAt = Date()

        if autoStart {
            endsAt = Date().addingTimeInterval(block.duration)
            runState = .running
            scheduleTasks()
            if block.phase.isWork { runFocusShortcut(Defaults[.pomodoroFocusShortcutStart]) }
        } else {
            endsAt = nil
            runState = .paused
        }
        persist()
    }

    /// Called both by the completion task and by `skip()`.
    private func finishPhase(completed: Bool) {
        let endedPhase = phase
        recordCurrentPhase(completed: completed)
        if endedPhase.isWork {
            completedWorkBlocks += 1
            runFocusShortcut(Defaults[.pomodoroFocusShortcutEnd])
        }
        cancelTasks()

        guard let next = nextBlock(after: endedPhase) else {
            // A planned (calendar) session ran out of blocks — the window is over.
            announce(endedPhase: endedPhase, nextPhase: nil, completed: completed)
            endSession(recordingCurrentPhase: false)
            return
        }

        let autoStart = next.phase.isWork
            ? Defaults[.pomodoroAutoStartWork]
            : Defaults[.pomodoroAutoStartBreaks]

        load(block: next, autoStart: autoStart)
        announce(endedPhase: endedPhase, nextPhase: next.phase, completed: completed)
    }

    private func nextBlock(after endedPhase: PomodoroPhase) -> PomodoroBlock? {
        if plannedQueue != nil {
            guard let next = plannedQueue?.first else { return nil }
            plannedQueue?.removeFirst()
            return next
        }

        // Preset-driven sessions alternate forever.
        if endedPhase.isWork {
            let cycles = max(1, activePreset.cyclesBeforeLongBreak)
            let nextPhase: PomodoroPhase = completedWorkBlocks % cycles == 0 ? .longBreak : .shortBreak
            return PomodoroBlock(phase: nextPhase, duration: activePreset.duration(for: nextPhase))
        }
        return PomodoroBlock(phase: .work, duration: activePreset.duration(for: .work))
    }

    // MARK: - Tasks

    private func scheduleTasks() {
        guard let endsAt else { return }

        completionTask?.cancel()
        completionTask = Task { [weak self] in
            let interval = endsAt.timeIntervalSinceNow
            if interval > 0 {
                try? await Task.sleep(for: .seconds(interval))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.runState == .running else { return }
                self.remaining = 0
                self.finishPhase(completed: true)
            }
        }

        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    guard let self, let endsAt = self.endsAt, self.runState == .running else { return }
                    self.remaining = max(0, endsAt.timeIntervalSinceNow)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func cancelTasks() {
        completionTask?.cancel()
        completionTask = nil
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Phase-end effects

    private func announce(endedPhase: PomodoroPhase, nextPhase: PomodoroPhase?, completed: Bool) {
        // A skip is a deliberate user action — no need to alert them about it.
        guard completed else { return }

        if Defaults[.pomodoroPlaySound] {
            NSSound(named: Defaults[.pomodoroSoundName])?.play()
        }
        if Defaults[.pomodoroPostNotification] {
            postNotification(endedPhase: endedPhase, nextPhase: nextPhase)
        }
        if Defaults[.pomodoroOpenNotchOnPhaseEnd] {
            NotificationCenter.default.post(name: .pomodoroPhaseEnded, object: nil)
        }
    }

    private func requestNotificationAuthorizationIfNeeded() {
        guard !didRequestNotificationAuthorization, Defaults[.pomodoroPostNotification] else { return }
        didRequestNotificationAuthorization = true

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let category = UNNotificationCategory(
            identifier: Self.notificationCategoryID,
            actions: [
                UNNotificationAction(identifier: "pomodoro.start", title: "Start", options: []),
                UNNotificationAction(identifier: "pomodoro.skip", title: "Skip", options: []),
            ],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postNotification(endedPhase: PomodoroPhase, nextPhase: PomodoroPhase?) {
        let content = UNMutableNotificationContent()
        content.title = endedPhase.isWork ? "Focus block done" : "Break over"
        if let nextPhase {
            content.body = "Up next: \(nextPhase.title)."
        } else {
            content.body = "Session complete."
        }
        content.categoryIdentifier = Self.notificationCategoryID

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// macOS has no public API for toggling Do Not Disturb, so focus handoff
    /// goes through a Shortcut the user names in settings. Best effort: a
    /// missing or misnamed shortcut fails silently rather than interrupting.
    private func runFocusShortcut(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: trimmed)]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - History

    private func recordCurrentPhase(completed: Bool) {
        guard isActive, phaseDuration > 0 else { return }
        let elapsed = min(phaseDuration, max(0, phaseDuration - remaining))
        // Ignore blips — a phase abandoned within a few seconds isn't history.
        guard elapsed >= 5 else { return }

        history.append(
            PomodoroRecord(
                startedAt: phaseStartedAt,
                phase: phase,
                plannedDuration: phaseDuration,
                actualDuration: elapsed,
                title: sessionTitle.isEmpty ? nil : sessionTitle,
                sourceEventID: sourceEventID,
                completed: completed
            )
        )
        trimAndSaveHistory()
    }

    func clearHistory() {
        history = []
        Defaults[.pomodoroHistory] = nil
    }

    private func trimAndSaveHistory() {
        let cutoff = Date().addingTimeInterval(-Self.historyMaxAge)
        history = history.filter { $0.startedAt > cutoff }
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        Defaults[.pomodoroHistory] = try? JSONEncoder().encode(history)
    }

    private func loadHistory() {
        guard let data = Defaults[.pomodoroHistory],
              let decoded = try? JSONDecoder().decode([PomodoroRecord].self, from: data)
        else { return }
        history = decoded
    }

    // MARK: - Persistence

    private func persist() {
        guard isActive else {
            Defaults[.pomodoroPersistedState] = nil
            return
        }
        let snapshot = PomodoroPersistedState(
            phase: phase,
            remaining: runState == .running ? max(0, endsAt?.timeIntervalSinceNow ?? remaining) : remaining,
            currentBlockDuration: phaseDuration,
            completedWorkBlocks: completedWorkBlocks,
            queue: plannedQueue ?? [],
            title: sessionTitle.isEmpty ? nil : sessionTitle,
            sourceEventID: sourceEventID,
            phaseStartedAt: phaseStartedAt,
            savedAt: Date()
        )
        Defaults[.pomodoroPersistedState] = try? JSONEncoder().encode(snapshot)
    }

    /// Restores a session left behind by a quit or a sleep. Always comes back
    /// paused — resuming automatically would mean the user silently lost the
    /// minutes the Mac spent asleep.
    private func restorePersistedState() {
        guard let data = Defaults[.pomodoroPersistedState],
              let snapshot = try? JSONDecoder().decode(PomodoroPersistedState.self, from: data),
              snapshot.remaining > 0
        else { return }

        activePreset = selectedPreset
        phase = snapshot.phase
        phaseDuration = snapshot.currentBlockDuration
        remaining = snapshot.remaining
        completedWorkBlocks = snapshot.completedWorkBlocks
        plannedQueue = snapshot.sourceEventID == nil && snapshot.queue.isEmpty ? nil : snapshot.queue
        sessionTitle = snapshot.title ?? ""
        sourceEventID = snapshot.sourceEventID
        phaseStartedAt = snapshot.phaseStartedAt
        endsAt = nil
        runState = .paused
    }

    // MARK: - Sleep / wake

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                let manager = PomodoroManager.shared
                guard manager.runState == .running else { return }
                manager.pause()
            }
        }

        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                guard Defaults[.pomodoroAutoResumeAfterWake] else { return }
                PomodoroManager.shared.resume()
            }
        }
    }
}

// MARK: - Notification actions

extension PomodoroManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case "pomodoro.start": PomodoroManager.shared.resume()
            case "pomodoro.skip": PomodoroManager.shared.skip()
            default: break
            }
        }
    }
}
