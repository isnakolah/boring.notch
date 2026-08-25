//
//  CopilotBackupPane.swift
//  boringNotch
//

import AppKit
import SwiftUI

/// Moving the copilot's settings between machines, and starting over.
///
/// This was a card on the landing pane, sitting under the master switch and
/// above the destinations — three destructive-ish buttons in the first thing
/// anyone saw, on a page whose job is to say whether the copilot is working.
/// It is a page you visit twice: once when you set up a second Mac, once when
/// something has gone wrong enough to reset.
struct CopilotBackupPane: View {
    @State private var result: String?

    var body: some View {
        SettingsPane(SettingsPage.copilotBackup) {
            SettingCard("Move these settings",
                        detail: "Exports only this domain — personas, prompts, model choices and capture options. Nothing from the rest of Boring, and no call audio or transcripts.") {
                HStack(spacing: NotchSpace.snug) {
                    Button("Export…") { exportSettings() }
                    Button("Import…") { importSettings() }
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
                Text("Import validates the file before applying any of it, and changes take effect on the next call rather than mid-one.")
                    .font(NotchType.rowDetail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingCard("Start over",
                        detail: "Puts every copilot setting back to its default. Your knowledge, prompts you wrote and archived calls are files, and are not touched.") {
                HStack {
                    Button("Reset copilot settings", role: .destructive) {
                        CallaCopilotSettings.reset()
                        result = "Copilot settings reset"
                    }
                    .controlSize(.small)
                    Spacer(minLength: 0)
                }
            }

            if let result {
                SettingCard(tint: NotchTint.healthy) {
                    HStack(spacing: NotchSpace.snug) {
                        SettingStatusIcon(ok: true)
                        Text(result).font(NotchType.rowDetail).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
            }
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
