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
/// Mostly a way in to the three pages below it now. The Music card left for
/// Media, and "Always show tabs" left for Shelf — it decides whether the Shelf
/// tab is visible before the shelf has anything in it, which is a fact about the
/// shelf and was filed under the colour of things.
struct Appearance: View {

    var body: some View {
        SettingsPane(.appearance) {

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
