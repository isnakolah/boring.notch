//
//  HUDPane.swift
//  boringNotch
//
//  Moved out of SettingsView.swift. That file had grown to 2076 lines holding
//  eleven panes and an XPC subsystem, while every newer pane already lived in
//  its own file under Panes/.
//

import Defaults
import SwiftUI

struct HUD: View {
    @EnvironmentObject var vm: BoringViewModel
    @Default(.inlineHUD) var inlineHUD
    @Default(.enableGradient) var enableGradient
    @Default(.optionKeyAction) var optionKeyAction
    @Default(.hudReplacement) var hudReplacement
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @State private var accessibilityAuthorized = false
    
    @Default(.systemEventIndicatorShadow) private var indicatorShadow
    @Default(.systemEventIndicatorUseAccent) private var indicatorUseAccent
    @Default(.showOpenNotchHUD) private var showOpenNotchHUD
    @Default(.showOpenNotchHUDPercentage) private var showOpenNotchHUDPercentage
    @Default(.showClosedNotchHUDPercentage) private var showClosedNotchHUDPercentage
    @Default(.showInlineHUDLabel) private var showInlineHUDLabel

    var body: some View {
        SettingsPane(SettingsPage.huds) {
            SettingCard(tint: accessibilityAuthorized ? nil : NotchTint.attention) {
                VStack(spacing: 10) {
                    SettingRow("Replace the system HUD",
                               detail: accessibilityAuthorized
                               ? "Everything below applies only while this is on."
                               : "Needs Accessibility access, which is what lets Boring see the key press.") {
                        Toggle("", isOn: $hudReplacement)
                            .labelsHidden().toggleStyle(.switch).controlSize(.large)
                            .disabled(!accessibilityAuthorized)
                    }
                    if !accessibilityAuthorized {
                        HStack {
                            Button("Request Accessibility") {
                                XPCHelperClient.shared.requestAccessibilityAuthorization()
                            }
                            .controlSize(.small)
                            Spacer()
                        }
                    }
                }
            }

            Group {
                SettingCard("Appearance") {
                    VStack(spacing: 12) {
                        SettingRow("Option key behaviour") {
                            Picker("", selection: $optionKeyAction) {
                                ForEach(OptionKeyAction.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden().frame(width: 200)
                        }
                        SettingRow("Progress bar") {
                            Picker("", selection: $enableGradient) {
                                Text("Hierarchical").tag(false)
                                Text("Gradient").tag(true)
                            }
                            .labelsHidden().pickerStyle(.segmented).frame(width: 200)
                        }
                        SettingRow("Glow") {
                            Toggle("", isOn: $indicatorShadow).labelsHidden().toggleStyle(.switch)
                        }
                        SettingRow("Tint with accent color") {
                            Toggle("", isOn: $indicatorUseAccent).labelsHidden().toggleStyle(.switch)
                        }
                    }
                }

                SettingCard(detail: "What the HUD looks like while the notch is already open.") {
                    VStack(spacing: 12) {
                        HStack(spacing: 6) {
                            Text("Open notch").font(NotchType.cardTitle)
                            SettingBadge("Beta")
                            Spacer()
                        }
                        SettingRow("Show HUD in the open notch") {
                            Toggle("", isOn: $showOpenNotchHUD).labelsHidden().toggleStyle(.switch)
                        }
                        SettingRow("Show percentage") {
                            Toggle("", isOn: $showOpenNotchHUDPercentage)
                                .labelsHidden().toggleStyle(.switch)
                                .disabled(!showOpenNotchHUD)
                        }
                    }
                }

                SettingCard("Closed notch") {
                    VStack(spacing: 12) {
                        SettingRow("Style") {
                            Picker("", selection: $inlineHUD) {
                                Text("Default").tag(false)
                                Text("Inline").tag(true)
                            }
                            .labelsHidden().pickerStyle(.segmented).frame(width: 200)
                        }
                        SettingRow("Show percentage") {
                            Toggle("", isOn: $showClosedNotchHUDPercentage)
                                .labelsHidden().toggleStyle(.switch)
                        }
                        SettingRow("Show label",
                                   detail: inlineHUD ? nil : "Inline style only.") {
                            Toggle("", isOn: $showInlineHUDLabel)
                                .labelsHidden().toggleStyle(.switch)
                                .disabled(!inlineHUD)
                        }
                    }
                }
            }
            .disabled(!hudReplacement)
            .opacity(hudReplacement ? 1 : 0.5)
        }
        .onChange(of: inlineHUD) {
            if inlineHUD {
                withAnimation {
                    indicatorShadow = false
                    enableGradient = false
                }
            }
        }
        .task {
            accessibilityAuthorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
        }
        .onAppear {
            XPCHelperClient.shared.startMonitoringAccessibilityAuthorization()
        }
        .onDisappear {
            XPCHelperClient.shared.stopMonitoringAccessibilityAuthorization()
        }
        .onReceive(NotificationCenter.default.publisher(for: .accessibilityAuthorizationChanged)) { notification in
            if let granted = notification.userInfo?["granted"] as? Bool {
                accessibilityAuthorized = granted
            }
        }
    }
}

#Preview {
    HUD()
}
