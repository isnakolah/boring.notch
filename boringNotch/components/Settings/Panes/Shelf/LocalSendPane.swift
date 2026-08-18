//
//  LocalSendPane.swift
//  boringNotch
//

import Defaults
import SwiftUI

/// Sending shelf items to other devices on the same network.
///
/// A page of its own rather than a card in Shelf: a list of paired devices grows
/// with the network, and it was pushing the four switches that are actually
/// about the shelf off the bottom of the pane.
struct LocalSendPane: View {
    @StateObject private var quickShareService = QuickShareService.shared

    @Default(.localSendEnabled) private var localSendEnabled
    @Default(.kdeConnectEnabled) private var kdeConnectEnabled
    @Default(.shelfRemoveAfterSend) private var shelfRemoveAfterSend

    var body: some View {
        SettingsPane(SettingsPage.localSend) {
            SettingCard("LocalSend",
                        detail: "Pair each receiver while LocalSend is open on the same Wi-Fi. The macOS Share sheet stays available either way.") {
                VStack(spacing: 10) {
                    providerToggleRow(
                        "Enable LocalSend",
                        detail: "Off: no listener, no discovery, and macOS is never asked for the local network permission for it.",
                        isOn: $localSendEnabled)
                    if localSendEnabled {
                        Divider().opacity(0.4)
                        ForEach(LocalSendDestination.allCases) { destination in
                            localSendDestinationRow(destination)
                        }
                        HStack {
                            Button("Refresh nearby devices") { quickShareService.refreshDiscovery() }
                                .controlSize(.small)
                                .disabled(quickShareService.isDiscovering)
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    /// The provider's own on/off switch.
    ///
    /// Reconstructed after an uncommitted version of this pane was lost. Off is
    /// meant to be genuinely off — no listener and no discovery — so that macOS
    /// is never asked for the local network permission on this provider's
    /// behalf.
    private func providerToggleRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        SettingRow(title, detail: detail) {
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }

    @ViewBuilder
    private func localSendDestinationRow(_ destination: LocalSendDestination) -> some View {
        let binding = quickShareService.binding(for: destination)
        HStack(spacing: 10) {
            Image(systemName: destination.symbolName)
                .frame(width: 18)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.title)
                if let binding {
                    Text("\(binding.device.alias)\(quickShareService.isOnline(destination) ? " · Online" : " · Offline")")
                        .font(.caption)
                        .foregroundStyle(quickShareService.isOnline(destination) ? .green : .secondary)
                } else {
                    Text("Not paired")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu(binding == nil ? "Pair" : "Replace") {
                if quickShareService.nearbyDevices.isEmpty {
                    Text("No nearby LocalSend devices")
                } else {
                    ForEach(quickShareService.nearbyDevices) { device in
                        Button(device.displayName) {
                            quickShareService.bind(device, to: destination)
                        }
                    }
                }
            }
            if binding != nil {
                Button("Unpair", role: .destructive) {
                    quickShareService.unbind(destination)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}
