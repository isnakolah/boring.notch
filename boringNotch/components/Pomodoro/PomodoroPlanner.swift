//
//  PomodoroPlanner.swift
//  boringNotch
//
//  Turns a calendar event's time window into a finite queue of Pomodoro
//  blocks. The plan always ends exactly when the event does — the last block
//  is trimmed rather than allowed to overrun into whatever comes next.
//

import Foundation

enum PomodoroPlanner {
    /// Blocks shorter than this are not worth their own phase; they get folded
    /// into the neighbouring work block instead.
    private static let minimumTailBlock: TimeInterval = 3 * 60
    /// Backstop so a pathological preset (or an all-day-length window) can't
    /// generate an unbounded queue.
    private static let maximumBlocks = 64

    /// Fills `[max(now, event.start), event.end]` with alternating work and
    /// break blocks drawn from `preset`.
    ///
    /// Example — 14:00–15:00 with the classic 25/5 preset started at 14:00:
    /// `work 25m → break 5m → work 25m` where the final work block is trimmed
    /// to 10m so the session lands on 15:00.
    static func plan(for event: EventModel, preset: PomodoroPreset, now: Date = Date()) -> [PomodoroBlock] {
        let start = max(now, event.start)
        return plan(window: event.end.timeIntervalSince(start), preset: preset)
    }

    /// Window-only entry point, kept separate so it is trivially testable and
    /// reusable for any "I have N minutes" case that isn't a calendar event.
    static func plan(window: TimeInterval, preset: PomodoroPreset) -> [PomodoroBlock] {
        guard window > 0 else { return [] }

        var blocks: [PomodoroBlock] = []
        var remaining = window
        var completedWork = 0
        var phase: PomodoroPhase = .work
        let cyclesBeforeLong = max(1, preset.cyclesBeforeLongBreak)

        while remaining > 0 && blocks.count < maximumBlocks {
            let full = preset.duration(for: phase)
            // A zero-length phase (user set the break to 0) would spin forever.
            guard full > 0 else {
                if phase.isWork { break }
                phase = .work
                continue
            }

            let duration = min(full, remaining)
            blocks.append(PomodoroBlock(phase: phase, duration: duration))
            remaining -= duration

            if phase.isWork {
                completedWork += 1
                phase = completedWork % cyclesBeforeLong == 0 ? .longBreak : .shortBreak
            } else {
                phase = .work
            }
        }

        return tidy(blocks)
    }

    /// Removes endings that would feel wrong: a break the user would sit
    /// through with nothing after it, or a work stub too short to get into
    /// anything. Absorbed time is handed back to the preceding work block, so
    /// the plan's total length — and therefore its end time — never changes.
    private static func tidy(_ blocks: [PomodoroBlock]) -> [PomodoroBlock] {
        var blocks = blocks
        guard blocks.count > 1 else { return blocks }

        // Trailing break → fold into the work block before it.
        if let last = blocks.last, !last.phase.isWork {
            blocks.removeLast()
            blocks[blocks.count - 1].duration += last.duration
        }

        // Trailing work stub → fold it *and* the break preceding it back into
        // the previous work block. Keeping the break would mean pausing for a
        // two-minute finish, which is worse than one slightly longer block.
        if blocks.count > 2, let last = blocks.last, last.phase.isWork, last.duration < minimumTailBlock {
            let stub = blocks.removeLast()
            let precedingBreak = blocks.removeLast()
            blocks[blocks.count - 1].duration += stub.duration + precedingBreak.duration
        }

        return blocks
    }
}
