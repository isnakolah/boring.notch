//
//  DisplaysPane.swift
//  boringNotch
//

import Defaults
import SwiftUI

/// Which screen the notch lives on.
struct DisplaysPane: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared

    @State private var screens: [(uuid: String, name: String)] = NSScreen.screens.compactMap { screen in
        guard let uuid = screen.displayUUID else { return nil }
        return (uuid, screen.localizedName)
    }

    @Default(.showOnAllDisplays) var showOnAllDisplays
    @Default(.automaticallySwitchDisplay) var automaticallySwitchDisplay

    var body: some View {
        SettingsPane(SettingsPage.displays) {
            SettingCard {
                VStack(spacing: NotchSpace.row) {
                    SettingRow("Show on all displays") {
                        Toggle("", isOn: $showOnAllDisplays).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Preferred display",
                               detail: showOnAllDisplays ? "Not used while the notch is on every display." : nil) {
                        Picker("", selection: $coordinator.preferredScreenUUID) {
                            ForEach(screens, id: \.uuid) { screen in
                                Text(screen.name).tag(screen.uuid as String?)
                            }
                        }
                        .labelsHidden().frame(width: 200)
                        .disabled(showOnAllDisplays)
                    }
                    SettingRow("Follow the active display",
                               detail: "Moves the notch to whichever display you are working on.") {
                        Toggle("", isOn: $automaticallySwitchDisplay)
                            .labelsHidden().toggleStyle(.switch)
                            .disabled(showOnAllDisplays)
                    }
                }
            }
        }
        .onChange(of: showOnAllDisplays) {
            NotificationCenter.default.post(name: Notification.Name.showOnAllDisplaysChanged, object: nil)
        }
        .onChange(of: automaticallySwitchDisplay) {
            NotificationCenter.default.post(name: Notification.Name.automaticallySwitchDisplayChanged, object: nil)
        }
        .onChange(of: NSScreen.screens) {
            screens = NSScreen.screens.compactMap { screen in
                guard let uuid = screen.displayUUID else { return nil }
                return (uuid, screen.localizedName)
            }
        }
    }
}
