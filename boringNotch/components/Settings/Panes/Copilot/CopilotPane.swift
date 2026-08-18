//
//  CopilotPane.swift
//  boringNotch
//

import Defaults
import SwiftUI

/// The copilot's front page.
///
/// Six destinations that used to sit as six siblings in the sidebar. They are
/// stages of one feature — what it hears, what it knows, what it says, and what
/// it left behind — and several of them were writing prose to point at each
/// other because the flat list could not.
struct CopilotPane: View {
    @Default(.callaCopilotEnabled) private var enabled

    var body: some View {
        SettingsPane(.copilot) {
            SettingCard {
                SettingRow("Call copilot",
                           detail: "Listens to a call you are in and suggests what to say next.") {
                    Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsSubpageList(section: .copilot)
        }
    }
}
