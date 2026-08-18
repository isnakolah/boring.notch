//
//  AppearancePane.swift
//  boringNotch
//
//  Moved out of SettingsView.swift. That file had grown to 2076 lines holding
//  eleven panes and an XPC subsystem, while every newer pane already lived in
//  its own file under Panes/.
//

import AVFoundation
import Defaults
import SwiftUI

/// What the notch looks like.
///
/// The Music card left for Media. Whether the spectrogram takes its colour from
/// the album art is a fact about how music is drawn, and it was sitting two
/// panes away from every other music setting.
struct Appearance: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared

    var body: some View {
        SettingsPane(.appearance) {
            SettingCard("Notch") {
                VStack(spacing: 12) {
                    SettingRow("Always show tabs",
                               detail: "Off hides the Shelf tab until the shelf has something in it.") {
                        Toggle("", isOn: $coordinator.alwaysShowTabs).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            SettingsSubpageList(section: .appearance)
        }
    }

    func checkVideoInput() -> Bool {
        if AVCaptureDevice.default(for: .video) != nil {
            return true
        }

        return false
    }
}
