//
//  CalendarPane.swift
//  boringNotch
//
//  Moved out of SettingsView.swift. That file had grown to 2076 lines holding
//  eleven panes and an XPC subsystem, while every newer pane already lived in
//  its own file under Panes/.
//

import Defaults
import SwiftUI

struct CalendarSettings: View {
    @ObservedObject private var calendarManager = CalendarManager.shared
    @Default(.showCalendar) var showCalendar: Bool
    @Default(.hideCompletedReminders) var hideCompletedReminders
    @Default(.hideAllDayEvents) var hideAllDayEvents
    @Default(.autoScrollToNextEvent) var autoScrollToNextEvent

    @Default(.showFullEventTitles) private var showFullEventTitles
    @Default(.openMeetingsInApp) private var openMeetingsInApp

    var body: some View {
        SettingsPane(.calendar) {
            SettingCard("Display") {
                VStack(spacing: 12) {
                    SettingRow("Show calendar") {
                        Toggle("", isOn: $showCalendar).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Hide all-day events") {
                        Toggle("", isOn: $hideAllDayEvents).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Hide completed reminders") {
                        Toggle("", isOn: $hideCompletedReminders).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Scroll to the next event") {
                        Toggle("", isOn: $autoScrollToNextEvent).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Always show full titles",
                               detail: "Off truncates a long title to one line.") {
                        Toggle("", isOn: $showFullEventTitles).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Open meetings in their own app",
                               detail: "Off opens the meeting link in your browser.") {
                        Toggle("", isOn: $openMeetingsInApp).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            SettingsSubpageList(section: .calendar)
        }
    }
}
