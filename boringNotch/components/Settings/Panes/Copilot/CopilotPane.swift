//
//  CopilotPane.swift
//  boringNotch
//

import Defaults
import AppKit
import SwiftUI

/// The copilot's front page.
///
/// It used to be a switch in a card and six drill rows — a menu standing in
/// front of the pages, and a scroll as soon as the sixth row appeared. The
/// landing pane is the one place in the section that can answer "is this
/// working right now", and it was the one place that did not.
///
/// So the switch becomes a band that reports the live call, with both capture
/// legs drawn rather than named — only your own side being heard is the failure
/// that looks like success, and "Capturing"/"Silent" reads the same until the
/// call is half over. The destinations become tiles carrying what their page
/// currently says, so "which model is answering" is legible without opening
/// anything.
struct CopilotPane: View {
    @ObservedObject private var engine = CallaEngineClient.shared
    @ObservedObject private var library = CallaKnowledgeLibrary.shared
    @Environment(\.settingsRouter) private var router

    @Default(.callaCopilotEnabled) private var enabled
    @Default(.callaCopilotPersona) private var persona
    @Default(.callaCopilotCustomPersonas) private var customPersonas
    @Default(.callaIntelligenceProvider) private var provider
    @Default(.callaIntelligenceLiveTier) private var liveTier
    @Default(.callaCopilotLiveModel) private var speechModel

    private var copilot: CallaCopilotStatus { engine.status.copilot }

    var body: some View {
        SettingsPane(.copilot) {
            band
            if let router { tiles(router) }
        }
        .task { engine.refresh() }
    }

    // MARK: - Band

    private var band: some View {
        SettingsStateBand(
            symbol: "waveform.badge.mic",
            title: stateTitle,
            detail: stateDetail,
            tint: bandTint,
            isOn: $enabled
        ) {
            if copilot.isRecording {
                HStack(spacing: NotchSpace.stack) {
                    SettingsLevelMeter(
                        label: "You",
                        level: copilot.micActive ? (copilot.speaking == "me" ? 1 : 0.4) : 0,
                        tint: copilot.micActive ? NotchTint.active : NotchTint.attention)
                    SettingsLevelMeter(
                        label: "Them",
                        level: copilot.systemAudioActive ? (copilot.speaking == "them" ? 1 : 0.4) : 0,
                        tint: copilot.systemAudioActive ? NotchTint.active : NotchTint.attention)
                }
                .padding(.trailing, NotchSpace.tight)
            }
        }
    }

    private var stateTitle: String {
        if !copilot.available { return "Call host is not installed" }
        if copilot.isRecording { return "In a call" }
        if copilot.prewarming { return "Warming up" }
        if copilot.starting { return "Starting" }
        return "Idle"
    }

    private var stateDetail: String {
        if !copilot.available {
            return "The copilot ships with Boring's Calla runtime. Redeploy to install it."
        }
        if copilot.isRecording {
            var parts: [String] = []
            parts.append(copilot.systemAudioActive
                         ? "Both sides captured"
                         : "Only your side is being heard")
            parts.append(copilot.activeProvider == "gateway" ? "answering on the gateway"
                                                             : "answering on this Mac")
            parts.append("\(copilot.turnCount) turns heard")
            return parts.joined(separator: " · ")
        }
        if copilot.prewarming, let meeting = copilot.meetingTitle {
            return "Armed for \(meeting). Nothing is recorded until you press Start."
        }
        return "Listens to a call you are in and suggests what to say next."
    }

    private var bandTint: Color? {
        if !copilot.available { return NotchTint.attention }
        if copilot.isRecording {
            // Half a conversation is the failure worth colouring differently.
            return copilot.systemAudioActive ? NotchTint.active : NotchTint.attention
        }
        if copilot.prewarming { return NotchTint.active }
        return nil
    }

    // MARK: - Tiles

    private func tiles(_ router: SettingsRouter) -> some View {
        SettingsTileGrid {
            SettingsTile(symbol: SettingsPage.copilotCall.symbol,
                         title: String(localized: SettingsPage.copilotCall.title),
                         value: callValue,
                         valueIsLive: copilot.isRecording) { router.push(.copilotCall) }
            SettingsTile(symbol: SettingsPage.copilotModels.symbol,
                         title: String(localized: SettingsPage.copilotModels.title),
                         value: modelsValue) { router.push(.copilotModels) }
            SettingsTile(symbol: SettingsPage.copilotPrompts.symbol,
                         title: String(localized: SettingsPage.copilotPrompts.title),
                         value: promptsValue) { router.push(.copilotPrompts) }
            SettingsTile(symbol: SettingsPage.copilotKnowledge.symbol,
                         title: String(localized: SettingsPage.copilotKnowledge.title),
                         value: knowledgeValue) { router.push(.copilotKnowledge) }
            SettingsTile(symbol: SettingsPage.copilotHistory.symbol,
                         title: String(localized: SettingsPage.copilotHistory.title),
                         value: "Past calls, their transcripts and what was suggested") {
                router.push(.copilotHistory)
            }
            SettingsTile(symbol: SettingsPage.copilotBackup.symbol,
                         title: String(localized: SettingsPage.copilotBackup.title),
                         value: "Export these settings, bring them back, or start over") {
                router.push(.copilotBackup)
            }
        }
    }

    private var callValue: String {
        if copilot.isRecording {
            guard let startedAt = copilot.startedAt else { return "In a call" }
            let minutes = Int(Date().timeIntervalSince(startedAt) / 60)
            return "In a call · \(minutes) min"
        }
        return copilot.available ? "Idle · ready to start" : "Host not installed"
    }

    private var modelsValue: String {
        let brain = provider == "local" ? "This Mac" : "Gateway"
        let tier = liveTier == "fast" ? "Fast" : "Balanced"
        let ear = speechModel.contains("small") ? "Small" : "Base"
        return "\(brain) · \(tier) · whisper \(ear)"
    }

    private var promptsValue: String {
        let title = CallaCopilotPersona.title(persona)
        guard !customPersonas.isEmpty else { return "\(title) persona" }
        return "\(title) · ^[\(customPersonas.count) custom persona](inflect: true)"
    }

    private var knowledgeValue: String {
        guard !library.notes.isEmpty else { return "Files and notes the copilot reads" }
        let documents = library.notes.filter(\.isDocument).count
        return "^[\(documents) file](inflect: true) · ^[\(library.notes.count - documents) note](inflect: true)"
    }
}
