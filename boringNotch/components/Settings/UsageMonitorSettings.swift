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

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .usageMonitorTab) {
                    Text("Enable usage tab")
                }
                .onChange(of: usageMonitorTab) {
                    // Leaving the tab selected after disabling would strand the notch
                    // on an empty view — fall back to Home.
                    if !usageMonitorTab && coordinator.currentView == .usage {
                        coordinator.currentView = .home
                    }
                }

                Picker("Refresh interval", selection: $usageMonitorRefreshInterval) {
                    ForEach(intervalOptions, id: \.seconds) { option in
                        Text(option.label).tag(option.seconds)
                    }
                }
                .pickerStyle(.menu)

                Defaults.Toggle(key: .showUsageBesideNotch) {
                    Text("Show usage beside notch")
                }
            } header: {
                Text("Usage Monitor")
            } footer: {
                Text("Usage data comes from your local claude and codex CLIs. Session (5h) and weekly (7d) quotas are shown for each.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Usage")
    }
}
