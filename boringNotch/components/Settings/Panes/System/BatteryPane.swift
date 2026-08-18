//
//  BatteryPane.swift
//  boringNotch
//
//  Moved out of SettingsView.swift. That file had grown to 2076 lines holding
//  eleven panes and an XPC subsystem, while every newer pane already lived in
//  its own file under Panes/.
//

import Defaults
import SwiftUI

struct Charge: View {
    @Default(.showPowerStatusNotifications) private var showPowerStatusNotifications
    @Default(.showBatteryPercentage) private var showBatteryPercentage
    @Default(.showPowerStatusIcons) private var showPowerStatusIcons

    var body: some View {
        SettingsPane(SettingsPage.battery) {
            SettingCard("In the notch",
                        detail: "Whether the indicator is in the header at all is set in Notch › Layout.") {
                VStack(spacing: 12) {
                    SettingRow("Show percentage",
                               detail: "The number beside the indicator.") {
                        Toggle("", isOn: $showBatteryPercentage).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Show power status icons",
                               detail: "Charging, low power mode, and connected-but-not-charging.") {
                        Toggle("", isOn: $showPowerStatusIcons).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
            SettingCard("Notifications") {
                SettingRow("Announce power changes",
                           detail: "Peeks the notch when the charger goes in or out.") {
                    Toggle("", isOn: $showPowerStatusNotifications).labelsHidden().toggleStyle(.switch)
                }
            }
        }
        .onAppear {
            Task { @MainActor in
                await XPCHelperClient.shared.isAccessibilityAuthorized()
            }
        }
    }
}
