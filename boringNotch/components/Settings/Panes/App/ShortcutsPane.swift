//
//  ShortcutsPane.swift
//  boringNotch
//

import KeyboardShortcuts
import SwiftUI

/// Every key combination the app answers to.
///
/// There were three of these. This pane owned two recorders, the copilot pane
/// owned three, and Pomodoro owned three more — so "what is bound to ⌥⌘C" could
/// not be answered without opening three panes, and nothing stopped two features
/// claiming the same chord.
///
/// Grouped by the feature each belongs to, because that is the question people
/// arrive with. The feature panes keep no recorders of their own; they point
/// here.
///
/// Four further names exist in `ShortcutConstants` — clipboard history,
/// microphone toggle, and the two backlight steps — and are deliberately absent:
/// nothing handles them, so a recorder for them would bind a key to nothing.
struct ShortcutsPane: View {
    var body: some View {
        SettingsPane(.shortcuts) {
            SettingCard("The notch") {
                VStack(spacing: NotchSpace.row) {
                    row("Open and close the notch", .toggleNotchOpen,
                        detail: "Toggles the notch whether or not Open on hover is set.")
                    Divider().opacity(0.35)
                    row("Peek at what is playing", .toggleSneakPeek,
                        detail: "Shows the current track without opening the notch.")
                }
            }

            SettingCard("Call copilot",
                        detail: "The live panel is read mid-sentence, so it is driven from the keyboard rather than the pointer.") {
                VStack(spacing: NotchSpace.row) {
                    row("Start or end a call", .copilotToggleCall)
                    Divider().opacity(0.35)
                    row("Full panel or pointer only", .copilotToggleLayout)
                    Divider().opacity(0.35)
                    row("Close the notch", .copilotDismiss,
                        detail: "The call keeps running; the next pointer brings the panel back.")
                }
            }

            SettingCard("Pomodoro") {
                VStack(spacing: NotchSpace.row) {
                    row("Start / pause", .pomodoroStartPause)
                    Divider().opacity(0.35)
                    row("Skip to next block", .pomodoroSkipPhase)
                    Divider().opacity(0.35)
                    row("Stop", .pomodoroStopTimer)
                }
            }
        }
    }

    private func row(_ title: String, _ name: KeyboardShortcuts.Name,
                     detail: String? = nil) -> some View {
        SettingRow(title, detail: detail) {
            KeyboardShortcuts.Recorder("", name: name)
        }
    }
}
