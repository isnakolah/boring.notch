//
//  PomodoroModels.swift
//  boringNotch
//
//  Value types behind the Pomodoro section: the phases a session cycles
//  through, the user-editable presets that define their lengths, the block
//  queue a session actually runs, and the history rows it leaves behind.
//

import Defaults
import Foundation
import SwiftUI

// MARK: - Phase

/// One leg of a Pomodoro cycle. Drives icon, tint and copy everywhere the
/// timer surfaces — notch badge, open section, menu bar, notifications.
enum PomodoroPhase: String, Codable, Hashable, Defaults.Serializable {
    case work
    case shortBreak
    case longBreak

    var isWork: Bool { self == .work }

    /// SF Symbol shown on the left of the closed notch and in the menu bar.
    var icon: String {
        switch self {
        case .work: return "brain.head.profile"
        case .shortBreak: return "cup.and.saucer.fill"
        case .longBreak: return "figure.walk"
        }
    }

    var tint: Color {
        switch self {
        case .work: return .effectiveAccent
        case .shortBreak: return .init(red: 0.24, green: 0.80, blue: 0.66)
        case .longBreak: return .init(red: 0.34, green: 0.72, blue: 0.96)
        }
    }

    var title: String {
        switch self {
        case .work: return "Focus"
        case .shortBreak: return "Break"
        case .longBreak: return "Long break"
        }
    }
}

// MARK: - Preset

/// A named set of durations. Presets are the one-tap entry point in the idle
/// view and the input to `PomodoroPlanner` when starting from a calendar event.
struct PomodoroPreset: Codable, Hashable, Identifiable, Defaults.Serializable {
    var id: String
    var name: String
    /// All durations are stored in minutes — that is what the settings UI edits.
    var workMinutes: Int
    var shortBreakMinutes: Int
    var longBreakMinutes: Int
    /// Number of work blocks before a long break replaces the short one.
    var cyclesBeforeLongBreak: Int

    func duration(for phase: PomodoroPhase) -> TimeInterval {
        switch phase {
        case .work: return TimeInterval(workMinutes) * 60
        case .shortBreak: return TimeInterval(shortBreakMinutes) * 60
        case .longBreak: return TimeInterval(longBreakMinutes) * 60
        }
    }

    /// Short form used on the idle view's chips, e.g. "25/5".
    var chipLabel: String { "\(workMinutes)/\(shortBreakMinutes)" }

    static let classic = PomodoroPreset(
        id: "classic", name: "Classic",
        workMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15,
        cyclesBeforeLongBreak: 4
    )
    static let deep = PomodoroPreset(
        id: "deep", name: "Deep work",
        workMinutes: 50, shortBreakMinutes: 10, longBreakMinutes: 30,
        cyclesBeforeLongBreak: 2
    )
    static let long = PomodoroPreset(
        id: "long", name: "Long haul",
        workMinutes: 90, shortBreakMinutes: 20, longBreakMinutes: 20,
        cyclesBeforeLongBreak: 2
    )

    /// Starter values for a fresh install. They are ordinary user presets:
    /// names, timings, and membership all remain editable in Settings.
    static let seeded: [PomodoroPreset] = [.classic, .deep, .long]
}

// MARK: - Block

/// A single scheduled leg of a session. A preset-driven session generates these
/// lazily and endlessly; a calendar-driven session gets a finite, pre-planned
/// list from `PomodoroPlanner`.
struct PomodoroBlock: Codable, Hashable {
    var phase: PomodoroPhase
    var duration: TimeInterval
}

// MARK: - History

/// One completed (or abandoned) leg, appended when a phase ends. Feeds the
/// "Today" counters and the history list in settings.
struct PomodoroRecord: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var startedAt: Date
    var phase: PomodoroPhase
    var plannedDuration: TimeInterval
    var actualDuration: TimeInterval
    var title: String?
    var sourceEventID: String?
    /// False when the user skipped or stopped before the block ran out.
    var completed: Bool
}

// MARK: - Persistence

/// Snapshot written on every state transition so a relaunch — or a wake from
/// sleep — restores the session instead of losing it. Always restored *paused*:
/// the timer must never silently burn a block while the Mac was asleep.
struct PomodoroPersistedState: Codable {
    var phase: PomodoroPhase
    var remaining: TimeInterval
    var currentBlockDuration: TimeInterval
    var completedWorkBlocks: Int
    var queue: [PomodoroBlock]
    var title: String?
    var sourceEventID: String?
    var phaseStartedAt: Date
    var savedAt: Date
}

// MARK: - Formatting

/// Human-readable interval for expanded surfaces and menu bar. Seconds are
/// rounded up so a fresh 25-minute block reads "25m 00s" rather than
/// immediately dropping to 24.
func twoUnitString(_ interval: TimeInterval) -> String {
    let total = Int(max(0, interval).rounded(.up))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60

    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m \(String(format: "%02d", seconds))s"
}

/// Compact clock interval for either side of the closed notch. Keep minutes
/// unpadded below an hour, while lower units remain padded: "5:03", "10:35",
/// "1:00:00". This is intentionally separate from `twoUnitString`, whose
/// words are easier to parse in the expanded timer and menu bar.
func notchClockString(_ interval: TimeInterval) -> String {
    let total = Int(max(0, interval).rounded(.up))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60

    if hours > 0 {
        return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", seconds))"
    }
    return "\(minutes):\(String(format: "%02d", seconds))"
}

/// Compact form for the "Today" counters, where seconds are noise.
func focusTotalString(_ interval: TimeInterval) -> String {
    let total = Int(max(0, interval))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}
