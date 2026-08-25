//
//  UsageMonitorSettings.swift
//  boringNotch
//
//  What is left of the Claude and Codex allowances, read from the two CLIs on
//  this Mac. Nothing here is about processor or memory load — that was a wrong
//  guess in an earlier version of this pane's copy.
//

import Defaults
import SwiftUI

struct UsageMonitorSettings: View {
    @ObservedObject private var manager = UsageMonitorManager.shared

    @Default(.usageMonitorTab) private var usageMonitorTab
    @Default(.usageMonitorRefreshInterval) private var refreshInterval
    @Default(.showUsageBesideNotch) private var showUsageBesideNotch
    @Default(.usageShowClaude) private var showClaude
    @Default(.usageShowCodex) private var showCodex
    @Default(.usageLowThreshold) private var lowThreshold
    @Default(.usageNotifyOnLow) private var notifyOnLow

    private let intervalOptions: [(label: String, seconds: Double)] = [
        ("1 minute", 60),
        ("5 minutes", 300),
        ("15 minutes", 900),
        ("30 minutes", 1800),
    ]

    var body: some View {
        SettingsPane(SettingsPage.usage) {
            nowCard
            providersCard
            whereCard
            runningLowCard
        }
        .task { manager.refreshIfStale() }
    }

    // MARK: - What it says right now

    /// The numbers themselves, above the switches that decide how they are shown.
    ///
    /// A settings pane for a readout that does not show the readout makes you
    /// close it to find out whether any of it worked.
    private var nowCard: some View {
        SettingCard("Right now", detail: "Read from the CLIs on this Mac. Nothing is sent anywhere to work it out.") {
            VStack(spacing: NotchSpace.row) {
                if UsageMonitorManager.enabledProviders.isEmpty {
                    SettingsEmptyState(
                        symbol: "gauge.with.needle",
                        title: "Neither CLI is being read",
                        detail: "Turn one on below and its allowance appears here.")
                } else {
                    if showClaude { providerRow("Claude", state: manager.claude) }
                    if showClaude, showCodex { Divider().opacity(0.35) }
                    if showCodex { providerRow("Codex", state: manager.codex) }
                }

                HStack {
                    Text(lastCheckedText)
                        .font(NotchType.figure)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Check now") { manager.refresh(force: true) }
                        .controlSize(.small)
                        .disabled(UsageMonitorManager.enabledProviders.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private func providerRow(_ name: String, state: ProviderUsageState) -> some View {
        VStack(alignment: .leading, spacing: NotchSpace.tight) {
            HStack(spacing: NotchSpace.tight) {
                Text(name).font(NotchType.rowTitle)
                if let badge = statusBadge(for: state) {
                    SettingBadge(badge.text, tint: badge.tint)
                }
                Spacer(minLength: 0)
            }
            if let report = state.report, report.status == .ok {
                SettingsStatRow {
                    quotaTile("Session", report.session)
                    quotaTile("This week", report.weekly)
                }
            } else {
                Text(explanation(for: state))
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func quotaTile(_ label: String, _ quota: UsageReportDTO.Quota?) -> some View {
        if let quota {
            SettingsStatTile(
                value: "\(Int(quota.percentRemaining.rounded()))%",
                label: label,
                caption: quota.resetText,
                tint: QuotaDisplayStatus.from(percentRemaining: quota.percentRemaining).color,
                fraction: quota.percentRemaining / 100)
        } else {
            SettingsStatTile(value: "—", label: label, caption: "Not reported")
        }
    }

    private func statusBadge(for state: ProviderUsageState) -> (text: String, tint: Color?)? {
        guard let report = state.report else { return ("Not read yet", NotchTint.paused) }
        switch report.status {
        case .ok: return nil
        case .cliNotInstalled: return ("CLI not installed", NotchTint.paused)
        case .notLoggedIn: return ("Not signed in", NotchTint.attention)
        case .error: return ("Could not read", NotchTint.attention)
        }
    }

    private func explanation(for state: ProviderUsageState) -> String {
        guard let report = state.report else { return "Waiting for the first reading." }
        switch report.status {
        case .ok: return ""
        case .cliNotInstalled: return "Install the CLI and sign in, and the allowance appears here."
        case .notLoggedIn: return "Sign in from a terminal, and the allowance appears here."
        case .error: return report.errorDescription ?? "The CLI did not answer."
        }
    }

    private var lastCheckedText: String {
        let stamps = [manager.claude.report?.capturedAt, manager.codex.report?.capturedAt].compactMap { $0 }
        guard let newest = stamps.max() else { return "Not read yet" }
        return "Last read \(newest.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: - Which CLIs

    private var providersCard: some View {
        SettingCard("Which CLIs to read",
                    detail: "One you do not use is one that reports itself missing forever, and gets asked again on every refresh.") {
            VStack(spacing: NotchSpace.row) {
                SettingRow("Claude") {
                    Toggle("", isOn: $showClaude).labelsHidden().toggleStyle(.switch)
                }
                SettingRow("Codex") {
                    Toggle("", isOn: $showCodex).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }

    // MARK: - Where it shows

    private var whereCard: some View {
        SettingCard("Where it shows") {
            VStack(spacing: NotchSpace.row) {
                SettingRow("Tab in the notch",
                           detail: "A tab showing both allowances in full.") {
                    Toggle("", isOn: $usageMonitorTab).labelsHidden().toggleStyle(.switch)
                }
                SettingRow("Beside the notch",
                           detail: "A compact readout either side of the notch, always visible.") {
                    Toggle("", isOn: $showUsageBesideNotch).labelsHidden().toggleStyle(.switch)
                }
                SettingRow("Check every",
                           detail: "Each check runs the CLI, so often is not free.") {
                    Picker("", selection: $refreshInterval) {
                        ForEach(intervalOptions, id: \.seconds) { option in
                            Text(option.label).tag(option.seconds)
                        }
                    }
                    .labelsHidden().frame(width: 140)
                }
            }
        }
    }

    // MARK: - Running out

    private var runningLowCard: some View {
        SettingCard("Running low") {
            VStack(alignment: .leading, spacing: NotchSpace.row) {
                NotchSlider(value: $lowThreshold,
                            range: 5...40,
                            step: 5,
                            label: "Low mark",
                            format: { "\(Int($0))%" },
                            ends: ("5%", "40%"))
                Text("Below this a figure is drawn as critical. Warning starts at \(Int((lowThreshold * 2.5).rounded()))%, which moves with it.")
                    .font(NotchType.rowDetail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingRow("Tell me when it drops below",
                           detail: "Once, on the way down — not every time it is checked and still low.") {
                    Toggle("", isOn: $notifyOnLow).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}
