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
                        // A three-position scale, so the control says so: the
                        // number was never the point, and "200" told nobody
                        // whether they were asking for more or less.
                        NotchStopSlider(
                            selection: $gestureSensitivity,
                            stops: [
                                .init(value: 100, title: "High", caption: "a nudge opens it"),
                                .init(value: 200, title: "Medium"),
                                .init(value: 300, title: "Low", caption: "a deliberate swipe"),
                            ],
                            label: "Sensitivity")
                    }
                }
            }
        }
    }
}
