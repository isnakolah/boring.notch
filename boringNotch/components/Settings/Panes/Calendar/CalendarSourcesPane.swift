//
//  CalendarSourcesPane.swift
//  boringNotch
//

import Defaults
import SwiftUI

/// Which calendars and reminder lists the notch reads.
///
/// A list of sources is a different kind of thing from the handful of switches
/// that decide how events are drawn, and it grows with the account rather than
/// with the app.
struct CalendarSourcesPane: View {
    @ObservedObject private var calendarManager = CalendarManager.shared

    /// The master switch lives on the Calendar pane; the source toggles were
    /// always disabled while it was off, and still are.
    @Default(.showCalendar) private var showCalendar

    var body: some View {
        SettingsPane(SettingsPage.calendarSources) {
            calendarSourceCard(
                title: "Calendars",
                granted: calendarManager.calendarAuthorizationStatus == .fullAccess,
                deniedMessage: "Boring cannot read your calendars until Calendar access is granted.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",
                sources: calendarManager.eventCalendars)

            calendarSourceCard(
                title: "Reminder lists",
                granted: calendarManager.reminderAuthorizationStatus == .fullAccess,
                deniedMessage: "Boring cannot read your reminders until Reminders access is granted.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders",
                sources: calendarManager.reminderLists)
        }
        .onAppear {
            Task {
                await calendarManager.checkCalendarAuthorization()
                await calendarManager.checkReminderAuthorization()
            }
        }
    }

    /// Calendars and reminder lists differ only in which permission gates them
    /// and which Settings pane grants it, so they share one card.
    ///
    /// A denied source used to render red centred text inside a `Section`; it
    /// now tints the whole card, which is what the status ramp is for.
    @ViewBuilder
    private func calendarSourceCard(title: String, granted: Bool, deniedMessage: String,
                                    settingsURL: String, sources: [CalendarModel]) -> some View {
        SettingCard(title, tint: granted ? nil : NotchTint.attention) {
            if !granted {
                VStack(alignment: .leading, spacing: 8) {
                    Text(deniedMessage)
                        .font(NotchType.rowDetail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Privacy Settings") {
                        if let url = URL(string: settingsURL) { NSWorkspace.shared.open(url) }
                    }
                    .controlSize(.small)
                }
            } else if sources.isEmpty {
                Text("Nothing to show here yet.")
                    .font(NotchType.rowDetail).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(sources, id: \.id) { source in
                        HStack(spacing: 8) {
                            Circle().fill(Color(nsColor: source.color)).frame(width: 8, height: 8)
                            Text(source.title).font(NotchType.rowTitle)
                            Spacer(minLength: 8)
                            Toggle("", isOn: Binding(
                                get: { calendarManager.getCalendarSelected(source) },
                                set: { isSelected in
                                    Task { await calendarManager.setCalendarSelected(source, isSelected: isSelected) }
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .tint(lighterColor(from: source.color))
                            .disabled(!showCalendar)
                        }
                    }
                }
            }
        }
    }
}

