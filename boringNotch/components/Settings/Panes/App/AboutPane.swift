//
//  AboutPane.swift
//  boringNotch
//
//  Moved out of SettingsView.swift. That file had grown to 2076 lines holding
//  eleven panes and an XPC subsystem, while every newer pane already lived in
//  its own file under Panes/.
//

import Defaults
import Sparkle
import SwiftUI

struct About: View {
    @State private var showBuildNumber: Bool = false
    let updaterController: SPUStandardUpdaterController
    @Environment(\.openWindow) var openWindow
    var body: some View {
        SettingsPane(.about) {
            SettingCard("Version") {
                VStack(spacing: 10) {
                    SettingFact(title: "Release name", value: Defaults[.releaseName])
                    SettingFact(title: "Version", value: versionText)
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { showBuildNumber.toggle() } }
            }

            SettingCard("Updates") {
                // Sparkle ships this as a bare `Section`, so it needs a Form to
                // sit in. Scoped to this card rather than the whole pane.
                Form { UpdaterSettingsView(updater: updaterController.updater) }
                    .formStyle(.columns)
            }

            SettingCard("Source") {
                HStack(spacing: 8) {
                    Image("Github")
                        .resizable().aspectRatio(contentMode: .fit).frame(width: 16)
                    Text("TheBoredTeam/boring.notch").font(NotchType.rowTitle)
                    Spacer(minLength: 8)
                    Button("Open on GitHub") {
                        if let url = URL(string: "https://github.com/TheBoredTeam/boring.notch") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }

            Text("Made with 🫶🏻 by not so boring not.people")
                .font(NotchType.rowDetail)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
        }
        .toolbar {
            CheckForUpdatesView(updater: updaterController.updater)
        }
    }

    private var versionText: String {
        let version = Bundle.main.releaseVersionNumber ?? "unknown"
        guard showBuildNumber, let build = Bundle.main.buildVersionNumber else { return version }
        return "\(version) (\(build))"
    }
}
