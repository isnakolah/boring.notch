//
//  KDEConnectPane.swift
//  boringNotch
//

import Defaults
import SwiftUI

/// Sending shelf items to a paired phone through KDE Connect.
///
/// A page of its own rather than a card in Shelf: a list of paired devices grows
/// with the network, and it was pushing the four switches that are actually
/// about the shelf off the bottom of the pane.
struct KDEConnectPane: View {
    @StateObject private var kdeConnectService = KDEConnectService.shared

    @Default(.localSendEnabled) private var localSendEnabled
    @Default(.kdeConnectEnabled) private var kdeConnectEnabled
    @Default(.shelfRemoveAfterSend) private var shelfRemoveAfterSend

    var body: some View {
        SettingsPane(SettingsPage.kdeConnect) {
            SettingCard("KDE Connect",
                        detail: "Pair once with a matching code while KDE Connect is open on the same Wi-Fi, then choose it from the Shelf send card.") {
                VStack(spacing: 10) {
                    providerToggleRow(
                        "Enable KDE Connect",
                        detail: "Off: no listener, no discovery, and macOS is never asked for the local network permission for it.",
                        isOn: $kdeConnectEnabled)
                    if kdeConnectEnabled {
                        Divider().opacity(0.4)
                        ForEach(LocalSendDestination.allCases) { destination in
                            kdeConnectDestinationRow(destination)
                        }
                        HStack {
                            Button("Refresh nearby devices") { kdeConnectService.refreshDiscovery() }
                                .controlSize(.small)
                                .disabled(kdeConnectService.isDiscovering)
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
    private func kdeConnectDestinationRow(_ destination: LocalSendDestination) -> some View {
        let binding = kdeConnectService.binding(for: destination)
        HStack(spacing: 10) {
            Image(systemName: destination.symbolName)
                .frame(width: 18)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.title)
                if let binding {
                    Text("\(binding.device.name)\(kdeConnectService.isOnline(destination) ? " · Online" : " · Offline")")
                        .font(.caption)
                        .foregroundStyle(kdeConnectService.isOnline(destination) ? .green : .secondary)
                } else {
                    Text("Not paired")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu(binding == nil ? "Pair" : "Replace") {
                if kdeConnectService.nearbyDevices.isEmpty {
                    Text("No nearby KDE Connect devices")
                } else {
                    ForEach(kdeConnectService.nearbyDevices) { device in
                        Button(device.displayName) {
                            kdeConnectService.beginPair(device, to: destination)
                        }
                    }
                }
            }
            if binding != nil {
                Button("Forget", role: .destructive) {
                    kdeConnectService.unbind(destination)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}
