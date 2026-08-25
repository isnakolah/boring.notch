//
//  CopilotPane.swift
//  boringNotch
//

import Defaults
import AppKit
import SwiftUI

/// The copilot's front page.
///
/// Six destinations that used to sit as six siblings in the sidebar. They are
/// stages of one feature — what it hears, what it knows, what it says, and what
/// it left behind — and several of them were writing prose to point at each
/// other because the flat list could not.
struct CopilotPane: View {
    @Default(.callaCopilotEnabled) private var enabled
    @State private var result: String?

    var body: some View {
        SettingsPane(.copilot) {
            SettingCard {
                SettingRow("Call copilot",
                           detail: "Listens to a call you are in and suggests what to say next.") {
                    Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingCard("Copilot settings", detail: "Exports only this domain. Import validates before applying; changes take effect on the next call.") {
                HStack {
                    Button("Export…") { exportSettings() }
                    Button("Import…") { importSettings() }
                    Spacer()
                    Button("Reset Copilot", role: .destructive) {
                        CallaCopilotSettings.reset()
                        result = "Copilot settings reset"
                    }
                }
                .controlSize(.small)
                if let result {
                    Text(result).font(NotchType.rowDetail).foregroundStyle(.secondary)
                }
            }
            SettingsSubpageList(section: .copilot)
        }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "calla-copilot-settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CallaCopilotSettings.exportData().write(to: url, options: .atomic)
            result = "Settings exported"
        } catch { result = error.localizedDescription }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CallaCopilotSettings.importData(Data(contentsOf: url))
            result = "Settings imported; applies next call"
        } catch { result = error.localizedDescription }
    }
}
