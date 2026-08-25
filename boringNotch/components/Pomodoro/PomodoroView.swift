//
//  PomodoroView.swift
//  boringNotch
//
//  The open-notch Pomodoro section.
//
//  One card, two columns, split the way the Usage tab splits its two providers.
//  Idle and running are the same frame: the figure, the field, the bar and the
//  Today column never move — idle shows what pressing play would buy, in a
//  quieter ink, and the transport in the header line changes shape.
//
//  Two earlier mistakes, both visible in the deployed build: a chrome row that
//  spent a band of a 168pt surface naming the tab the reader had just clicked,
//  and a separate control rail below the card, which pushed the whole layout
//  past the notch's lower curve so the Start button was drawn outside the shape.
//  Controls live in the card's header line now, and there is no second band.
//

import AppKit
import Defaults
import SwiftUI

struct PomodoroView: View {
    @ObservedObject private var pomodoro = PomodoroManager.shared
    @Default(.pomodoroPresets) private var presets
    @Default(.pomodoroSelectedPresetID) private var selectedPresetID

    @FocusState private var titleFieldFocused: Bool

    /// Lengths offered beside the saved presets, so a one-off block does not
    /// need a row of its own on a surface that has no room for one.
    private let customLengths = [15, 45, 60, 90]

    var body: some View {
        HStack(spacing: 0) {
            timerColumn
                .frame(maxWidth: .infinity)
            NotchColumnDivider()
            todayColumn
                .frame(width: 116)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        // The card takes the whole tab rather than hugging its content: a slab
        // with a band of dead black under it reads as a layout that failed to
        // load, not as restraint.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .notchCard()
        .notchTabInsets()
        .animation(.smooth(duration: 0.25), value: pomodoro.isActive)
    }

    // MARK: - Timer

    private var timerColumn: some View {
        VStack(alignment: .leading, spacing: NotchGlassSpace.snug) {
            NotchCardHeader(state: stateLine,
                            live: pomodoro.isActive,
                            tint: phaseTint) {
                transport
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(figureText)
                    .font(NotchGlassType.hero)
                    .foregroundStyle(figureTint)
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.25), value: pomodoro.remaining)
                    .fixedSize()
                titleField
            }

            NotchBar(fraction: pomodoro.isActive ? pomodoro.progress : 0, tint: phaseTint)

            Text(edgeNote)
                .font(NotchGlassType.caption)
                .foregroundStyle(NotchInk.tertiary)
                .lineLimit(1)
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 12)
    }

    /// The one field, in the same slot whether or not a block is running.
    private var titleField: some View {
        TextField("What are you working on?", text: $pomodoro.sessionTitle)
            .textFieldStyle(.plain)
            .font(NotchGlassType.row)
            .foregroundStyle(pomodoro.isActive ? NotchInk.secondary : NotchInk.tertiary)
            .focused($titleFieldFocused)
            .lineLimit(1)
            // Stays in layout focused or not: a conditional layer here used to
            // change the intrinsic width and shove the figure sideways.
            .overlay {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(!titleFieldFocused)
                    .onTapGesture {
                        NSApp.activate(ignoringOtherApps: true)
                        DispatchQueue.main.async { titleFieldFocused = true }
                    }
            }
            .onSubmit { titleFieldFocused = false }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Transport in the header line, where the Usage tab keeps its refresh.
    @ViewBuilder private var transport: some View {
        if pomodoro.isActive {
            NotchGlyphButton(symbol: pomodoro.isRunning ? "pause.fill" : "play.fill",
                             help: pomodoro.isRunning ? "Pause timer" : "Resume timer",
                             action: pomodoro.toggle)
            NotchGlyphButton(symbol: "forward.end.fill", help: "Skip phase", action: pomodoro.skip)
            NotchGlyphButton(symbol: "arrow.counterclockwise", help: "Reset phase", action: pomodoro.reset)
            NotchGlyphButton(symbol: "stop.fill", help: "Stop timer", action: pomodoro.stop)
        } else {
            presetMenu
            NotchGlyphButton(symbol: "play.fill", help: "Start focus") {
                if let preset = selectedPreset { pomodoro.start(preset: preset) }
            }
        }
    }

    /// Saved presets and a few one-off lengths. A menu rather than a rail of
    /// chips: the choice is made rarely, and a rail costs a band this surface
    /// does not have.
    private var presetMenu: some View {
        Menu {
            ForEach(presets) { preset in
                Button("\(preset.name) · \(preset.chipLabel)") {
                    selectedPresetID = preset.id
                    if pomodoro.isActive { pomodoro.start(preset: preset) }
                }
            }
            Divider()
            ForEach(customLengths, id: \.self) { minutes in
                Button("Just \(minutes) minutes") { pomodoro.startCustom(minutes: minutes) }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(NotchGlassType.chevron)
                .foregroundStyle(NotchInk.tertiary)
                .padding(4)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose a preset or a one-off length")
    }

    // MARK: - Today

    private var todayColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            NotchCaps("Today")
            Text("\(pomodoro.todayCompletedWorkBlocks)")
                .font(NotchGlassType.figure)
                .foregroundStyle(pomodoro.todayCompletedWorkBlocks > 0 ? NotchInk.primary : NotchInk.tertiary)
            Text("\(focusTotalString(pomodoro.todayFocusTime)) focused")
                .font(NotchGlassType.caption)
                .foregroundStyle(NotchInk.tertiary)
                .lineLimit(1)
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 12)
    }

    // MARK: - Copy

    private var selectedPreset: PomodoroPreset? {
        presets.first { $0.id == selectedPresetID } ?? presets.first
    }

    private var stateLine: String {
        guard pomodoro.isActive else { return selectedPreset?.name ?? "Ready" }
        if pomodoro.runState == .paused { return "Paused" }
        guard pomodoro.phase.isWork else { return pomodoro.phase.title }
        return "\(pomodoro.phase.title) · Block \(pomodoro.completedWorkBlocks + 1)"
    }

    /// The caption under the bar: when this phase gives out.
    private var edgeNote: String {
        guard pomodoro.isActive else {
            guard let preset = selectedPreset else { return "" }
            return "\(preset.workMinutes)m focus, then \(preset.shortBreakMinutes)m break"
        }
        let ends = Date().addingTimeInterval(pomodoro.remaining)
        let next = pomodoro.phase.isWork ? "Break" : "Focus"
        return "\(next) at \(ends.formatted(date: .omitted, time: .shortened))"
    }

    /// Running counts down; idle shows what pressing play would buy.
    private var figureText: String {
        guard pomodoro.isActive else {
            let minutes = selectedPreset?.workMinutes ?? 25
            return "\(minutes):00"
        }
        return notchClockString(pomodoro.remaining)
    }

    private var figureTint: Color {
        guard pomodoro.isActive else { return NotchInk.secondary }
        return isFinalStretch ? NotchTint.stuck : NotchInk.primary
    }

    private var phaseTint: Color {
        pomodoro.runState == .paused ? NotchInk.tertiary : pomodoro.phase.tint
    }

    private var isFinalStretch: Bool {
        pomodoro.isRunning && pomodoro.remaining <= 60
    }
}
