//
//  TutorAccessPane.swift
//  boringNotch
//
//  Split out of TutorPane.swift, which held a router and four sibling panes in
//  one 564-line file.
//

import AppKit
import Defaults
import SwiftUI

struct TutorAccessPane: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @Default(.callaAllowedBundleIDs) private var allowedBundleIDs

    var body: some View {
        SettingsPane(SettingsPage.tutorAccess) {
            SettingCard("Allowed applications", detail: allowedBundleIDs.isEmpty
                        ? "Calla cannot teach anything until at least one app is allowed."
                        : nil) {
                VStack(spacing: 6) {
                    ForEach(allowedBundleIDs, id: \.self) { id in
                        HStack {
                            Text(id).font(NotchType.mono)
                            Spacer(minLength: 8)
                            Button("Remove", role: .destructive) {
                                allowedBundleIDs.removeAll { $0 == id }
                            }
                            .controlSize(.small)
                        }
                    }
                    HStack {
                        Button("Add frontmost application") { addFrontmostApplication() }
                            .controlSize(.small)
                        Spacer()
                    }
                }
            }
            SettingCard("Permissions",
                        detail: "Requests are always explicit. Opening this pane changes nothing.",
                        tint: permissionsTint) {
                VStack(spacing: 10) {
                    permissionRow(
                        "Screen Recording",
                        granted: engine.status.screenRecordingGranted,
                        note: "Calla cannot see the app without it.",
                        action: { engine.requestScreenRecording() })
                    permissionRow(
                        "Accessibility",
                        granted: engine.status.accessibilityGranted,
                        note: "Only needed when a lesson reaches an action you have approved.",
                        action: { engine.requestAccessibility() })
                }
            }
        }
        .onChange(of: allowedBundleIDs) { _, _ in engine.applyCurrentPreferences() }
    }

    private var permissionsTint: Color? {
        engine.status.screenRecordingGranted ? nil : NotchTint.attention
    }

    private func permissionRow(_ title: String, granted: Bool, note: String,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            SettingStatusIcon(ok: granted)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(NotchType.rowTitle)
                Text(granted ? "Allowed" : note)
                    .font(NotchType.rowDetail).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !granted {
                Button("Request") { action() }.controlSize(.small)
            }
        }
    }

    private func addFrontmostApplication() {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              id != Bundle.main.bundleIdentifier,
              !allowedBundleIDs.contains(id) else { return }
        allowedBundleIDs.append(id)
    }
}
