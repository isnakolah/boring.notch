//
//  TutorBehaviorPane.swift
//  boringNotch
//
//  Split out of TutorPane.swift, which held a router and four sibling panes in
//  one 564-line file.
//

import Defaults
import SwiftUI

struct TutorBehaviorPane: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @Default(.callaTutorEnabled) private var tutorEnabled
    @Default(.callaCaptureEnabled) private var captureEnabled
    @Default(.callaCaptureLongEdge) private var captureLongEdge
    @Default(.callaTooltipWidth) private var tooltipWidth
    @Default(.callaHideTooltipOnHover) private var hideTooltipOnHover
    @Default(.callaCursorSize) private var cursorSize
    @Default(.callaTooltipOpacity) private var tooltipOpacity
    @Default(.callaShowStatusHUD) private var showStatusHUD
    @Default(.callaCalendarEnabled) private var calendarEnabled

    var body: some View {
        SettingsPane(SettingsPage.tutorBehavior) {
            SettingCard("Tutor") {
                // There was no way to turn Tutor off anywhere in the app, even
                // though this preference gates engine startup and the notch tab.
                SettingRow("Enable Tutor",
                           detail: "Off stops the engine and hides the Calla tab in the notch.") {
                    Toggle("", isOn: $tutorEnabled).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingCard("Watching") {
                VStack(spacing: 12) {
                    SettingRow("Watch screen",
                               detail: "Off pauses every capture. Calla refuses to teach until it is back on.") {
                        Toggle("", isOn: $captureEnabled).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Capture detail",
                               detail: "1600 px costs roughly 27,000 tokens and 13 seconds a look; 2048 about 44,000.") {
                        Picker("", selection: $captureLongEdge) {
                            Text("1024").tag(1024)
                            Text("1600").tag(1600)
                            Text("2048").tag(2048)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 200)
                    }
                }
            }
            SettingCard("On screen") {
                VStack(spacing: 12) {
                    SettingRow("Tooltip width",
                               detail: "How much of a line the lesson text gets.") {
                        Picker("", selection: $tooltipWidth) {
                            ForEach([300, 340, 380, 440, 520], id: \.self) { Text("\($0) pt").tag($0) }
                        }
                        .labelsHidden().frame(width: 120)
                    }
                    SettingRow("Pointer size", detail: nil) {
                        Picker("", selection: $cursorSize) {
                            ForEach([24, 30, 38], id: \.self) { Text("\($0) pt").tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 200)
                    }
                    SettingRow("Tooltip opacity", detail: nil) {
                        Picker("", selection: $tooltipOpacity) {
                            Text("85%").tag(0.85)
                            Text("92%").tag(0.92)
                            Text("100%").tag(1.0)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 200)
                    }
                    SettingRow("Hide tooltip on hover",
                               detail: "Moves the tooltip out of the way when your own pointer is over it.") {
                        Toggle("", isOn: $hideTooltipOnHover).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Show status HUD",
                               detail: "The small capsule naming what Calla is doing.") {
                        Toggle("", isOn: $showStatusHUD).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
            SettingCard("Calendar") {
                SettingRow("Calendar starts lessons",
                           detail: "An event bound to a course starts it, with a Pomodoro bounded by the event.") {
                    Toggle("", isOn: $calendarEnabled).labelsHidden().toggleStyle(.switch)
                }
            }
        }
        .onChange(of: captureEnabled) { _, _ in engine.applyCurrentPreferences() }
        .onChange(of: captureLongEdge) { _, _ in engine.applyCurrentPreferences() }
        .onChange(of: tooltipWidth) { _, _ in engine.applyCurrentPreferences() }
        .onChange(of: hideTooltipOnHover) { _, _ in engine.applyCurrentPreferences() }
        .onChange(of: cursorSize) { _, _ in engine.applyCurrentPreferences() }
        .onChange(of: tooltipOpacity) { _, _ in engine.applyCurrentPreferences() }
        .onChange(of: showStatusHUD) { _, _ in engine.applyCurrentPreferences() }
    }
}
