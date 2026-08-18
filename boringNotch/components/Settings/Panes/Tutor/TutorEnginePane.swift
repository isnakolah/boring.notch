//
//  TutorEnginePane.swift
//  boringNotch
//
//  Split out of TutorPane.swift, which held a router and four sibling panes in
//  one 564-line file.
//

import SwiftUI

struct TutorEnginePane: View {
    @ObservedObject private var engine = CallaEngineClient.shared

    private var status: CallaEngineStatus { engine.status }

    var body: some View {
        SettingsPane(SettingsPage.tutorEngine) {
            SettingCard("Runtime", tint: engineTint) {
                VStack(spacing: 10) {
                    SettingFact(title: "Engine", value: status.running ? "Running" : "Stopped",
                                tint: status.running ? NotchTint.healthy : NotchTint.paused)
                    // Host and Gateway are separate facts. Folding them together
                    // reported a healthy Mac as Offline whenever the tailnet
                    // route was down, even though cached courses teach fine.
                    SettingFact(title: "Tutor host",
                                value: status.hostReady ? "Listening" : "Not listening",
                                tint: status.hostReady ? NotchTint.healthy : NotchTint.attention)
                    SettingFact(title: "Gateway",
                                value: status.gatewayReachable ? "Reachable" : "Unavailable",
                                tint: status.gatewayReachable ? NotchTint.healthy : NotchTint.attention)
                    SettingFact(title: "Calla Mac node",
                                value: status.nodeConnected ? "Connected" : "Disconnected",
                                tint: status.nodeConnected ? NotchTint.healthy : NotchTint.attention)
                    SettingFact(title: "Build", value: status.engineBuild ?? "Waiting for capability receipt")
                    HStack {
                        Button(status.running ? "Stop engine" : "Start engine") {
                            status.running ? engine.stop() : engine.start()
                        }
                        Button("Refresh runtime") {
                            engine.courseControl(.init(action: "refresh_runtime"))
                        }
                        Spacer()
                    }
                    .controlSize(.small)
                }
            }
            SettingCard("Gateway release") {
                VStack(spacing: 10) {
                    SettingFact(title: "Current", value: status.releaseVersion ?? "Unknown")
                    SettingFact(title: "Last update", value: status.lastGatewayUpdate ?? "None")
                    HStack {
                        Button("Retry Gateway update") { engine.requestGatewayUpdate() }
                        Spacer()
                    }
                    .controlSize(.small)
                }
            }
            SettingCard("Last result") {
                Text(status.lastResult).font(NotchType.rowDetail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !status.diagnostics.isEmpty {
                // Competing-install warnings arrive here: the engine reports a
                // legacy host holding the socket, or a second Calla Mac node.
                SettingCard("Diagnostics", detail: "The last few bounded notes from the engine.") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(status.diagnostics, id: \.self) { line in
                            Text(line).font(NotchType.mono).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var engineTint: Color? {
        if !status.running { return NotchTint.stuck }
        if !status.hostReady { return NotchTint.attention }
        return nil
    }
}
