//
//  GeneralPane.swift
//  boringNotch
//

import Defaults
import LaunchAtLogin
import SwiftUI

/// How the app starts, how big the notch is, and what opens it.
///
/// Displays and Gestures were cards here. Both are self-contained — one is about
/// which screen, the other is a beta feature with its own enable switch — and
/// both were pushing this pane past what one scroll should hold.
struct GeneralSettings: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Environment(\.settingsRouter) private var router

    @Default(.minimumHoverDuration) var minimumHoverDuration
    @Default(.nonNotchHeight) var nonNotchHeight
    @Default(.nonNotchHeightMode) var nonNotchHeightMode
    @Default(.notchHeight) var notchHeight
    @Default(.notchHeightMode) var notchHeightMode
    @Default(.openNotchOnHover) var openNotchOnHover
    @Default(.enableGestures) var enableGestures

    @Default(.menubarIcon) private var menubarIcon
    @Default(.enableHaptics) private var enableHaptics

    var body: some View {
        SettingsPane(.general) {
            SettingCard("System") {
                VStack(spacing: NotchSpace.row) {
                    SettingRow("Show menu bar icon") {
                        Toggle("", isOn: $menubarIcon).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Launch at login") {
                        LaunchAtLogin.Toggle("").labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            SettingCard("Size") {
                VStack(spacing: NotchSpace.row) {
                    SettingRow("On displays with a notch") {
                        Picker("", selection: $notchHeightMode) {
                            Text("Match the real notch").tag(WindowHeightMode.matchRealNotchSize)
                            Text("Match the menu bar").tag(WindowHeightMode.matchMenuBar)
                            Text("Custom").tag(WindowHeightMode.custom)
                        }
                        .labelsHidden().frame(width: 200)
                    }
                    if notchHeightMode == .custom {
                        heightSlider(value: $notchHeight, range: 15...45)
                    }
                    SettingRow("On displays without one") {
                        Picker("", selection: $nonNotchHeightMode) {
                            Text("Match the menu bar").tag(WindowHeightMode.matchMenuBar)
                            Text("Match a real notch").tag(WindowHeightMode.matchRealNotchSize)
                            Text("Custom").tag(WindowHeightMode.custom)
                        }
                        .labelsHidden().frame(width: 200)
                    }
                    if nonNotchHeightMode == .custom {
                        heightSlider(value: $nonNotchHeight, range: 0...40)
                    }
                }
            }

            SettingCard("Opening") {
                VStack(spacing: NotchSpace.row) {
                    SettingRow("Open on hover") {
                        Toggle("", isOn: $openNotchOnHover).labelsHidden().toggleStyle(.switch)
                    }
                    if openNotchOnHover {
                        SettingRow("Hover delay") {
                            HStack(spacing: NotchSpace.tight) {
                                Slider(value: $minimumHoverDuration, in: 0...1, step: 0.1)
                                    .frame(width: 150)
                                Text("\(minimumHoverDuration, specifier: "%.1f")s")
                                    .font(NotchType.figure).foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .trailing)
                            }
                        }
                    }
                    SettingRow("Haptic feedback") {
                        Toggle("", isOn: $enableHaptics).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Remember last tab") {
                        Toggle("", isOn: $coordinator.openLastTabByDefault)
                            .labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            SettingsSubpageList(section: .general)
        }
        .toolbar {
            Button("Quit app") { NSApp.terminate(self) }
        }
        .onChange(of: notchHeightMode) {
            switch notchHeightMode {
            case .matchRealNotchSize: notchHeight = 38
            case .matchMenuBar: notchHeight = 44
            case .custom: notchHeight = 38
            }
            NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
        }
        .onChange(of: nonNotchHeightMode) {
            switch nonNotchHeightMode {
            case .matchMenuBar: nonNotchHeight = 24
            case .matchRealNotchSize: nonNotchHeight = 32
            case .custom: nonNotchHeight = 32
            }
            NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
        }
        .onChange(of: notchHeight) {
            NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
        }
        .onChange(of: nonNotchHeight) {
            NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
        }
        .onChange(of: minimumHoverDuration) {
            NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
        }
        .onChange(of: openNotchOnHover) {
            if !openNotchOnHover { enableGestures = true }
        }
    }

    private func heightSlider(value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        SettingRow("Custom height") {
            HStack(spacing: NotchSpace.tight) {
                Slider(value: value, in: range, step: 1).frame(width: 150)
                Text("\(value.wrappedValue, specifier: "%.0f")pt")
                    .font(NotchType.figure).foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }
}
