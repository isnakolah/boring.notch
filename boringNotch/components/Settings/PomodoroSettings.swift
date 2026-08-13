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

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .pomodoroTab) {
                    Text("Enable Pomodoro tab")
                }
                .onChange(of: pomodoroTab) {
                    // Leaving the tab selected after disabling would strand the
                    // notch on a hidden view — fall back to Home.
                    if !pomodoroTab && coordinator.currentView == .pomodoro {
                        coordinator.currentView = .home
                    }
                }

                Defaults.Toggle(key: .pomodoroShowInMenuBar) {
                    Text("Show countdown in the menu bar")
                }

                Defaults.Toggle(key: .pomodoroCalendarIcon) {
                    Text("Show a timer button on calendar events")
                }
            } header: {
                Text("Pomodoro")
            } footer: {
                Text("The menu bar countdown needs the boring.notch menu bar icon turned on in General. The calendar button starts a session that fills the event's time window and ends exactly when the event does.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach($presets) { $preset in
                Section {
                    TextField("Preset name", text: $preset.name)
                    Stepper("Focus: \(preset.workMinutes)m", value: $preset.workMinutes, in: 1...240)
                    Stepper("Short break: \(preset.shortBreakMinutes)m", value: $preset.shortBreakMinutes, in: 0...120)
                    Stepper("Long break: \(preset.longBreakMinutes)m", value: $preset.longBreakMinutes, in: 0...120)
                    Stepper("Long break every \(preset.cyclesBeforeLongBreak) blocks", value: $preset.cyclesBeforeLongBreak, in: 1...12)
                    if presets.count > 1 {
                        Button("Delete preset", role: .destructive) {
                            deletePreset(id: preset.id)
                        }
                    }
                } header: {
                    Text(preset.name)
                }
            }

            Section {
                Button {
                    addPreset()
                } label: {
                    Label("New preset", systemImage: "plus")
                }
            } footer: {
                Text("New presets copy current default, then can be renamed and edited.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Picker("Default preset", selection: $selectedPresetID) {
                    ForEach(presets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .pickerStyle(.menu)

                Button("Restore seeded presets") {
                    presets = PomodoroPreset.seeded
                    selectedPresetID = PomodoroPreset.classic.id
                }
            } header: {
                Text("Default duration")
            } footer: {
                Text("A long break replaces the short one after the given number of focus blocks.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Defaults.Toggle(key: .pomodoroAutoStartBreaks) {
                    Text("Start breaks automatically")
                }
                Defaults.Toggle(key: .pomodoroAutoStartWork) {
                    Text("Start the next focus block automatically")
                }
                Defaults.Toggle(key: .pomodoroOpenNotchOnPhaseEnd) {
                    Text("Open the notch when a block ends")
                }
                Defaults.Toggle(key: .pomodoroAutoResumeAfterWake) {
                    Text("Resume automatically after the Mac wakes")
                }
            } header: {
                Text("Cycle")
            } footer: {
                Text("The timer always pauses when the Mac sleeps, so a block is never spent while you are away.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Defaults.Toggle(key: .pomodoroPlaySound) {
                    Text("Play a sound when a block ends")
                }

                Picker("Sound", selection: $soundName) {
                    ForEach(soundOptions, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: soundName) {
                    NSSound(named: soundName)?.play()
                }

                Defaults.Toggle(key: .pomodoroPostNotification) {
                    Text("Post a notification when a block ends")
                }
            } header: {
                Text("Alerts")
            }

            Section {
                TextField("Shortcut to run at focus start", text: $focusShortcutStart)
                TextField("Shortcut to run at focus end", text: $focusShortcutEnd)
            } header: {
                Text("Focus")
            } footer: {
                Text("macOS provides no way for an app to switch Do Not Disturb directly. Create two shortcuts in the Shortcuts app — one turning a Focus on, one turning it off — and enter their names here. Leave blank to skip.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                KeyboardShortcuts.Recorder("Start / pause timer", name: .pomodoroStartPause)
                KeyboardShortcuts.Recorder("Skip to next block", name: .pomodoroSkipPhase)
                KeyboardShortcuts.Recorder("Stop timer", name: .pomodoroStopTimer)
            } header: {
                Text("Keyboard shortcuts")
            }

            Section {
                HStack {
                    Text("Today")
                    Spacer()
                    Text("\(pomodoro.todayCompletedWorkBlocks) blocks · \(focusTotalString(pomodoro.todayFocusTime))")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

                if recentSessions.isEmpty {
                    Text("No sessions recorded yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(recentSessions) { record in
                        historyRow(record)
                    }

                    Button("Clear history", role: .destructive) {
                        pomodoro.clearHistory()
                    }
                }
            } header: {
                Text("History")
            } footer: {
                Text("Focus blocks are kept locally for 90 days.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Pomodoro")
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
