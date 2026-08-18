//
//  AdvancedPane.swift
//  boringNotch
//

import Defaults
import SwiftUI

/// The settings that change how the window sits against the rest of the system.
///
/// Accent colour used to lead this pane. It moved to Appearance, where the thing
/// it colours is configured.
struct Advanced: View {
    @Default(.extendHoverArea) var extendHoverArea
    @Default(.showOnLockScreen) var showOnLockScreen
    @Default(.hideFromScreenRecording) var hideFromScreenRecording

    let icons: [String] = ["logo2"]
    @State private var selectedIcon: String = "logo2"

    @Default(.enableShadow) private var enableShadow
    @Default(.cornerRadiusScaling) private var cornerRadiusScaling
    @Default(.hideTitleBar) private var hideTitleBar

    var body: some View {
        SettingsPane(SettingsPage.advanced) {
            SettingCard("Shape") {
                VStack(spacing: 12) {
                    SettingRow("Window shadow") {
                        Toggle("", isOn: $enableShadow).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Scale corner radius",
                               detail: "Rounds the notch's corners in proportion to its height.") {
                        Toggle("", isOn: $cornerRadiusScaling).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            SettingCard("Behaviour") {
                VStack(spacing: 12) {
                    SettingRow("Extend hover area",
                               detail: "Makes the notch easier to hit without aiming for it.") {
                        Toggle("", isOn: $extendHoverArea).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Hide title bar") {
                        Toggle("", isOn: $hideTitleBar).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Show on the lock screen") {
                        Toggle("", isOn: $showOnLockScreen).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Hide from screen recording",
                               detail: "Keeps the notch out of captures and shared screens.") {
                        Toggle("", isOn: $hideFromScreenRecording).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            SettingCard(detail: "One icon for now.") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text("App icon").font(NotchType.cardTitle)
                        SettingBadge("Coming soon")
                        Spacer()
                    }
                    HStack(spacing: 14) {
                        ForEach(icons, id: \.self) { icon in
                            Image(icon)
                                .resizable().frame(width: 56, height: 56)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(icon == selectedIcon ? Color.effectiveAccent : .clear,
                                                      lineWidth: 2))
                        }
                        Spacer(minLength: 0)
                    }
                    .disabled(true)
                    .opacity(0.6)
                }
            }
        }
    }
}
