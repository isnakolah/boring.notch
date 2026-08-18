//
//  TutorPane.swift
//  boringNotch
//

import Defaults
import SwiftUI

/// Tutor's front page.
///
/// Five destinations that used to sit as five siblings in the sidebar, and
/// before that as a segmented picker inside one pane. They are stages of one
/// feature: what is installed, how to make more, how it behaves, what it may
/// look at, and whether the engine is running.
struct TutorPane: View {
    @Default(.callaTutorEnabled) private var enabled

    var body: some View {
        SettingsPane(.tutor) {
            SettingCard {
                SettingRow("Tutor",
                           detail: "Watches the screen during a lesson and points at the next step.") {
                    Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsSubpageList(section: .tutor)
        }
    }
}
