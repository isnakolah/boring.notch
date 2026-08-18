//
//  MediaPane.swift
//  boringNotch
//
//  Moved out of SettingsView.swift. That file had grown to 2076 lines holding
//  eleven panes and an XPC subsystem, while every newer pane already lived in
//  its own file under Panes/.
//

import Defaults
import SwiftUI

struct Media: View {
    @Default(.waitInterval) var waitInterval
    @Default(.mediaController) var mediaController
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.hideNotchOption) var hideNotchOption
    @Default(.enableSneakPeek) private var enableSneakPeek
    @Default(.sneakPeekStyles) var sneakPeekStyles

    @Default(.enableLyrics) var enableLyrics

    @Default(.coloredSpectrogram) private var coloredSpectrogram
    @Default(.playerColorTinting) private var playerColorTinting
    @Default(.lightingEffect) private var lightingEffect
    @Default(.sliderColor) private var sliderColor
    var body: some View {
        SettingsPane(.media) {
            SettingCard("Source", detail: sourceDetail) {
                VStack(alignment: .leading, spacing: 8) {
                    SettingRow("Read playback from") {
                        Picker("", selection: $mediaController) {
                            ForEach(availableMediaControllers) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 200)
                    }
                    if MusicManager.shared.isNowPlayingDeprecated {
                        Link("github.com/pear-devs/pear-desktop",
                             destination: URL(string: "https://github.com/pear-devs/pear-desktop")!)
                            .font(NotchType.rowDetail)
                    }
                }
            }

            SettingCard("Live activity") {
                VStack(spacing: 12) {
                    SettingRow("Show music live activity") {
                        Toggle("", isOn: $coordinator.musicLiveActivityEnabled.animation())
                            .labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Sneak peek on track change",
                               detail: "Shows the title and artist under the notch for a moment.") {
                        Toggle("", isOn: $enableSneakPeek).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Sneak peek style") {
                        Picker("", selection: $sneakPeekStyles) {
                            ForEach(SneakPeekStyle.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 160)
                    }
                    SettingRow("Inactivity timeout",
                               detail: "How long the activity stays after playback stops.") {
                        HStack(spacing: 8) {
                            Text("\(waitInterval, specifier: "%.0f")s")
                                .font(NotchType.figure).foregroundStyle(.secondary)
                            Stepper("", value: $waitInterval, in: 0...10, step: 1).labelsHidden()
                        }
                    }
                }
            }

            SettingCard(detail: "What happens to the notch when something goes full screen.") {
                VStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Text("Full screen").font(NotchType.cardTitle)
                        SettingBadge("Beta")
                        Spacer()
                    }
                    SettingRow("Hide the notch") {
                        Picker("", selection: $hideNotchOption) {
                            Text("For all apps").tag(HideNotchOption.always)
                            Text("For the media app").tag(HideNotchOption.nowPlayingOnly)
                            Text("Never").tag(HideNotchOption.never)
                        }
                        .labelsHidden().frame(width: 180)
                    }
                }
            }

            SettingCard("Music") {
                VStack(spacing: 12) {
                    SettingRow("Colored spectrogram",
                               detail: "Takes its colour from the album art.") {
                        Toggle("", isOn: $coloredSpectrogram).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Tint the player") {
                        Toggle("", isOn: $playerColorTinting).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Blur behind album art") {
                        Toggle("", isOn: $lightingEffect).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Slider colour") {
                        Picker("", selection: $sliderColor) {
                            ForEach(SliderColorEnum.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 160)
                    }
                }
            }

            SettingsSubpageList(section: .media)
        }
        .onChange(of: mediaController) { _, _ in
            NotificationCenter.default.post(name: Notification.Name.mediaControllerChanged, object: nil)
        }
    }

    private var sourceDetail: String {
        MusicManager.shared.isNowPlayingDeprecated
            ? "YouTube Music needs a third-party helper app installed."
            : "Now Playing works with every media app and was the only option in earlier versions."
    }

    // Only show controller options that are available on this macOS version
    private var availableMediaControllers: [MediaControllerType] {
        if MusicManager.shared.isNowPlayingDeprecated {
            return MediaControllerType.allCases.filter { $0 != .nowPlaying }
        } else {
            return MediaControllerType.allCases
        }
    }
}
