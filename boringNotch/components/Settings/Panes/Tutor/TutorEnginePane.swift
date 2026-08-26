//
//  TutorEnginePane.swift
//  boringNotch
//
//  Split out of TutorPane.swift, which held a router and four sibling panes in
//  one 564-line file.
//

import AppKit
import SwiftUI

struct TutorEnginePane: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @State private var history: [CallaTutorFeedback] = []
    @State private var historyQuery = ""
    @State private var historyCursor: String?
    @State private var revealedCaptureID: String?
    @State private var revealedCapture: NSImage?

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
            intelligenceCard
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
        .task { reloadHistory() }
    }

    private var engineTint: Color? {
        if !status.running { return NotchTint.stuck }
        if !status.hostReady { return NotchTint.attention }
        return nil
    }

    private var intelligenceCard: some View {
        let intelligence = status.tutorIntelligence
        return SettingCard("Tutor Intelligence", detail: "Both routes may send target-window screenshots to remote model services. Local agy owns its session here; its model service is remote.") {
            VStack(spacing: 10) {
                Picker("Feedback provider", selection: Binding(
                    get: { intelligence?.selectedProvider ?? "local" },
                    set: { engine.setTutorProvider($0) }
                )) {
                    Text("Local agy").tag("local")
                    Text("Gateway").tag("gateway")
                }
                .pickerStyle(.segmented)
                SettingFact(title: "Local agy", value: localState(intelligence),
                            tint: intelligence?.localAgyAvailable == true && intelligence?.localAgyAuthenticated == true ? NotchTint.healthy : NotchTint.attention)
                SettingFact(title: "Gateway feedback", value: intelligence?.gatewayFeedbackAvailable == true ? "Available" : "Unavailable",
                            tint: intelligence?.gatewayFeedbackAvailable == true ? NotchTint.healthy : NotchTint.attention)
                SettingFact(title: "Target capture", value: intelligence?.captureAvailable == true ? "Ready" : "Screen Recording and frontmost allowed target required",
                            tint: intelligence?.captureAvailable == true ? NotchTint.healthy : NotchTint.attention)
                if let active = intelligence?.activeProvider {
                    SettingFact(title: "Active route", value: active)
                }
                Divider().opacity(0.35)
                HStack {
                    TextField("Search retained feedback", text: $historyQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { reloadHistory() }
                    Button("Search") { reloadHistory() }.controlSize(.small)
                }
                if history.isEmpty {
                    Text("No Tutor feedback retained yet. Screenshots are retained until app data is manually removed.")
                        .font(NotchType.rowDetail).foregroundStyle(.secondary)
                } else {
                    ForEach(history) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(item.state.replacingOccurrences(of: "_", with: " ").capitalized).font(NotchType.rowTitle)
                                Spacer()
                                Text(item.actualProvider ?? item.selectedProvider ?? "No provider").font(NotchType.rowDetail).foregroundStyle(.secondary)
                            }
                            if let question = item.question { Text(question).font(NotchType.rowDetail).lineLimit(2) }
                            if let answer = item.answer { Text(answer).font(NotchType.rowDetail).foregroundStyle(.secondary).lineLimit(3) }
                            if let fallback = item.fallbackReason { Text("Fallback: \(fallback)").font(NotchType.rowDetail).foregroundStyle(NotchTint.attention) }
                            if let captureID = item.captureID {
                                Button(revealedCaptureID == captureID ? "Hide screenshot" : "Reveal screenshot") {
                                    toggleCapture(captureID)
                                }
                                .controlSize(.small)
                                if revealedCaptureID == captureID, let revealedCapture {
                                    Image(nsImage: revealedCapture)
                                        .resizable().scaledToFit().frame(maxHeight: 220)
                                        .accessibilityLabel("Retained target-window screenshot")
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                    }
                    if historyCursor != nil {
                        Button("Load more") { reloadHistory(cursor: historyCursor, append: true) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func localState(_ intelligence: CallaTutorIntelligenceStatus?) -> String {
        guard intelligence?.localAgyAvailable == true else { return "Not installed" }
        return intelligence?.localAgyAuthenticated == true ? "Installed and authenticated" : "Sign in required"
    }

    private func reloadHistory(cursor: String? = nil, append: Bool = false) {
        let query = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        engine.tutorHistory(query: query.isEmpty ? nil : query, cursor: cursor) { page in
            Task { @MainActor in
                if append { self.history += page?.entries ?? [] }
                else {
                    self.history = page?.entries ?? []
                    self.revealedCaptureID = nil
                    self.revealedCapture = nil
                }
                self.historyCursor = page?.nextCursor
            }
        }
    }

    private func toggleCapture(_ captureID: String) {
        if revealedCaptureID == captureID {
            revealedCaptureID = nil; revealedCapture = nil; return
        }
        engine.tutorCapture(captureID) { data in
            Task { @MainActor in
                guard let data, let image = NSImage(data: data) else { return }
                self.revealedCaptureID = captureID; self.revealedCapture = image
            }
        }
    }
}
