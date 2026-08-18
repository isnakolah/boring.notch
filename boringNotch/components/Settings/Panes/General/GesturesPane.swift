//
//  GesturesPane.swift
//  boringNotch
//

import Defaults
import SwiftUI

/// Swiping the notch open and closed.
struct GesturesPane: View {
    @Default(.enableGestures) var enableGestures
    @Default(.closeGestureEnabled) private var closeGestureEnabled
    @Default(.gestureSensitivity) var gestureSensitivity
    @Default(.openNotchOnHover) var openNotchOnHover

    var body: some View {
        SettingsPane(SettingsPage.gestures) {
            SettingCard(detail: "Two-finger swipe down on the notch opens it, up closes it. Available while Open on hover is off.") {
                VStack(spacing: NotchSpace.row) {
                    HStack(spacing: NotchSpace.tight) {
                        SettingBadge("Beta")
                        Spacer()
                    }
                    SettingRow("Enable gestures") {
                        Toggle("", isOn: $enableGestures)
                            .labelsHidden().toggleStyle(.switch)
                            .disabled(!openNotchOnHover)
                    }
                    if enableGestures {
                        SettingRow("Close gesture") {
                            Toggle("", isOn: $closeGestureEnabled).labelsHidden().toggleStyle(.switch)
                        }
                        SettingRow("Sensitivity") {
                            HStack(spacing: NotchSpace.tight) {
                                Slider(value: $gestureSensitivity, in: 100...300, step: 100)
                                    .frame(width: 150)
                                Text(sensitivityLabel)
                                    .font(NotchType.figure).foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    private var sensitivityLabel: String {
        gestureSensitivity == 100 ? "High" : gestureSensitivity == 200 ? "Medium" : "Low"
    }
}
