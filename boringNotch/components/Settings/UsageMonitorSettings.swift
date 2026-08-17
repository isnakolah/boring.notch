//
//  UsageMonitorSettings.swift
//  boringNotch
//
//  Settings pane for the Claude/Codex usage notch tab. Reached from
//  SettingsView's sidebar ("Usage").
//

import Defaults
import SwiftUI

struct UsageMonitorSettings: View {
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @Default(.usageMonitorTab) var usageMonitorTab
    @Default(.usageMonitorRefreshInterval) var usageMonitorRefreshInterval

    private let intervalOptions: [(label: String, seconds: Double)] = [
        ("1 minute", 60),
        ("5 minutes", 300),
        ("15 minutes", 900),
        ("30 minutes", 1800),
    ]

    @Default(.showUsageBesideNotch) private var showUsageBesideNotch

    var body: some View {
        SettingsPane(eyebrow: "Tools", title: "Usage",
                     detail: "Session and weekly quotas, read from the claude and codex CLIs on this Mac.") {
            SettingCard("Usage monitor") {
                VStack(spacing: 12) {
                    SettingRow("Enable usage tab",
                               detail: "Adds a Usage tab to the notch.") {
                        Toggle("", isOn: $usageMonitorTab).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Show beside the notch",
                               detail: "Keeps a compact quota readout next to the notch.") {
                        Toggle("", isOn: $showUsageBesideNotch).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Refresh interval",
                               detail: "How often the CLIs are asked again.") {
                        Picker("", selection: $usageMonitorRefreshInterval) {
                            ForEach(intervalOptions, id: \.seconds) { option in
                                Text(option.label).tag(option.seconds)
                            }
                        }
                        .labelsHidden().frame(width: 140)
                    }
                }
            }
        }
        .onChange(of: usageMonitorTab) {
            // Leaving the tab selected after disabling would strand the notch
            // on an empty view — fall back to Home.
            if !usageMonitorTab && coordinator.currentView == .usage {
                coordinator.currentView = .home
            }
        }
    }
}
