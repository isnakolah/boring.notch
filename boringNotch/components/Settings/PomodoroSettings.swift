//
//  PomodoroSettings.swift
//  boringNotch
//
//  Settings pane for the Pomodoro notch tab. Reached from SettingsView's
//  sidebar ("Pomodoro").
//

import Defaults
import KeyboardShortcuts
import SwiftUI

struct PomodoroSettings: View {
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @ObservedObject private var pomodoro = PomodoroManager.shared

    @Default(.pomodoroTab) var pomodoroTab
    @Default(.pomodoroPresets) var presets
    @Default(.pomodoroSelectedPresetID) var selectedPresetID
    @Default(.pomodoroSoundName) var soundName
    @Default(.pomodoroFocusShortcutStart) var focusShortcutStart
    @Default(.pomodoroFocusShortcutEnd) var focusShortcutEnd

    /// Built-in macOS alert sounds — using these means no audio asset ships
    /// with the app and the user picks something they already recognise.
    private let soundOptions = ["Glass", "Ping", "Hero", "Submarine", "Blow", "Funk", "Purr"]

    @Default(.pomodoroShowInMenuBar) private var showInMenuBar
    @Default(.pomodoroCalendarIcon) private var calendarIcon
    @Default(.pomodoroAutoStartBreaks) private var autoStartBreaks
    @Default(.pomodoroAutoStartWork) private var autoStartWork
    @Default(.pomodoroOpenNotchOnPhaseEnd) private var openNotchOnPhaseEnd
    @Default(.pomodoroAutoResumeAfterWake) private var autoResumeAfterWake
    @Default(.pomodoroPlaySound) private var playSound
    @Default(.pomodoroPostNotification) private var postNotification

    var body: some View {
        SettingsPane(.pomodoro) {
            SettingCard("Pomodoro") {
                VStack(spacing: 12) {
                    SettingRow("Enable Pomodoro tab") {
                        Toggle("", isOn: $pomodoroTab).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Countdown in the menu bar",
                               detail: "Needs the boring.notch menu bar icon turned on in General.") {
                        Toggle("", isOn: $showInMenuBar).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Timer button on calendar events",
                               detail: "Starts a session that fills the event and ends exactly when it does.") {
                        Toggle("", isOn: $calendarIcon).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            SettingCard("Presets",
                        detail: "A long break replaces the short one after the given number of focus blocks.") {
                VStack(spacing: 14) {
                    ForEach($presets) { $preset in
                        presetEditor($preset)
                    }
                    HStack {
                        Button("New preset") { addPreset() }
                        Button("Restore defaults") {
                            presets = PomodoroPreset.seeded
                            selectedPresetID = PomodoroPreset.classic.id
                        }
                        Spacer()
                    }
                    .controlSize(.small)
                    SettingRow("Default preset") {
                        Picker("", selection: $selectedPresetID) {
                            ForEach(presets) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().frame(width: 160)
                    }
                }
            }

            SettingCard("Cycle",
                        detail: "The timer always pauses when the Mac sleeps, so a block is never spent while you are away.") {
                VStack(spacing: 12) {
                    SettingRow("Start breaks automatically") {
                        Toggle("", isOn: $autoStartBreaks).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Start the next block automatically") {
                        Toggle("", isOn: $autoStartWork).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Open the notch when a block ends") {
                        Toggle("", isOn: $openNotchOnPhaseEnd).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Resume after the Mac wakes") {
                        Toggle("", isOn: $autoResumeAfterWake).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            SettingCard("Alerts") {
                VStack(spacing: 12) {
                    SettingRow("Play a sound") {
                        Toggle("", isOn: $playSound).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Sound", detail: "Plays as you choose it.") {
                        Picker("", selection: $soundName) {
                            ForEach(soundOptions, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(width: 140)
                    }
                    SettingRow("Post a notification") {
                        Toggle("", isOn: $postNotification).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            SettingCard("Focus",
                        detail: "macOS gives an app no way to switch Do Not Disturb directly. Make two shortcuts in the Shortcuts app — one turning a Focus on, one off — and name them here. Leave blank to skip.") {
                VStack(spacing: 12) {
                    SettingRow("Run at focus start") {
                        TextField("Shortcut name", text: $focusShortcutStart).frame(width: 180)
                    }
                    SettingRow("Run at focus end") {
                        TextField("Shortcut name", text: $focusShortcutEnd).frame(width: 180)
                    }
                }
            }

            // The three Pomodoro recorders moved to Settings › Shortcuts.

            SettingCard("History", detail: "Focus blocks are kept on this Mac for 90 days.") {
                VStack(spacing: 10) {
                    SettingFact(title: "Today",
                                value: "\(pomodoro.todayCompletedWorkBlocks) blocks · \(focusTotalString(pomodoro.todayFocusTime))")
                    if recentSessions.isEmpty {
                        Text("No sessions recorded yet.")
                            .font(NotchType.rowDetail).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(recentSessions) { record in
                            historyRow(record)
                        }
                        HStack {
                            Button("Clear history", role: .destructive) { pomodoro.clearHistory() }
                                .controlSize(.small)
                            Spacer()
                        }
                    }
                }
            }
        }
        .onChange(of: pomodoroTab) {
            // Leaving the tab selected after disabling would strand the notch on
            // a hidden view — fall back to Home.
            if !pomodoroTab && coordinator.currentView == .pomodoro {
                coordinator.currentView = .home
            }
        }
        .onChange(of: soundName) { NSSound(named: soundName)?.play() }
    }

    /// One preset, as a bordered block rather than its own `Section`. Five
    /// steppers per preset in a flat list made every preset look like a new
    /// pane; the border is what says where one ends.
    private func presetEditor(_ preset: Binding<PomodoroPreset>) -> some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Preset name", text: preset.name).frame(width: 180)
                Spacer()
                if presets.count > 1 {
                    Button("Delete", role: .destructive) { deletePreset(id: preset.wrappedValue.id) }
                        .controlSize(.small)
                }
            }
            minuteRow("Focus", value: preset.workMinutes, range: 1...240)
            minuteRow("Short break", value: preset.shortBreakMinutes, range: 0...120)
            minuteRow("Long break", value: preset.longBreakMinutes, range: 0...120)
            HStack {
                Text("Long break every").font(NotchType.rowTitle)
                Spacer()
                Text("\(preset.wrappedValue.cyclesBeforeLongBreak) blocks")
                    .font(NotchType.figure).foregroundStyle(.secondary)
                Stepper("", value: preset.cyclesBeforeLongBreak, in: 1...12).labelsHidden()
            }
        }
        .padding(10)
        .overlay(
            RoundedRectangle(cornerRadius: NotchRadius.control, style: .continuous)
                .strokeBorder(NotchSurface.hairline, lineWidth: 1))
    }

    private func minuteRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            Text(title).font(NotchType.rowTitle)
            Spacer()
            Text("\(value.wrappedValue)m").font(NotchType.figure).foregroundStyle(.secondary)
            Stepper("", value: value, in: range).labelsHidden()
        }
    }

    private func addPreset() {
        let template = presets.first { $0.id == selectedPresetID } ?? presets.first ?? .classic
        var preset = template
        preset.id = UUID().uuidString
        preset.name = uniquePresetName(basedOn: template.name)
        presets.append(preset)
        selectedPresetID = preset.id
    }

    private func deletePreset(id: String) {
        guard presets.count > 1 else { return }
        let removedSelectedPreset = selectedPresetID == id
        presets.removeAll { $0.id == id }
        if removedSelectedPreset {
            selectedPresetID = presets.first?.id ?? PomodoroPreset.classic.id
        }
    }

    private func uniquePresetName(basedOn name: String) -> String {
        let base = name.isEmpty ? "Focus" : name
        var copyNumber = 2
        var candidate = "\(base) copy"
        while presets.contains(where: { $0.name.localizedCaseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "\(base) copy \(copyNumber)"
            copyNumber += 1
        }
        return candidate
    }

    /// Only focus blocks are worth listing — breaks would just be noise.
    private var recentSessions: [PomodoroRecord] {
        Array(pomodoro.history.filter(\.phase.isWork).suffix(12).reversed())
    }

    private func historyRow(_ record: PomodoroRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(record.title ?? "Focus")
                    .lineLimit(1)
                Text(record.startedAt, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(focusTotalString(record.actualDuration))
                .monospacedDigit()
                .foregroundColor(record.completed ? .secondary : .orange)
        }
    }
}
