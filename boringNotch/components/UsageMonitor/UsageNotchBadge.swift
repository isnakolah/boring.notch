//
//  UsageNotchBadge.swift
//  boringNotch
//
//  Always-on CLI usage badges shown beside the physical notch (Claude on the
//  left, Codex on the right). Each badge shows session/weekly remaining % like
//  "23/38", with each number colored by its own QuotaDisplayStatus threshold.
//  Fed by UsageMonitorManager; polls while visible.
//

import Defaults
import SwiftUI

/// Lays out both provider badges around the physical notch gap and owns the
/// refresh polling while the closed notch is showing them.
struct UsageNotchBadges: View {
    let notchWidth: CGFloat
    let height: CGFloat
    /// Called when a side badge is hovered — opens the notch to the usage tab.
    /// Only the badges trigger this; hovering the center notch keeps normal flow.
    var onBadgeHover: (() -> Void)? = nil

    @ObservedObject private var manager = UsageMonitorManager.shared
    @Default(.usageMonitorRefreshInterval) private var refreshInterval
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            UsageNotchBadge(provider: "CLAUDE", state: manager.claude, alignment: .trailing)
                .padding(.trailing, 10)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .onHover { if $0 { onBadgeHover?() } }

            Rectangle()
                .fill(.black)
                .frame(width: notchWidth)

            UsageNotchBadge(provider: "CODEX", state: manager.codex, alignment: .leading)
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onHover { if $0 { onBadgeHover?() } }
        }
        .frame(height: height, alignment: .center)
        .onAppear {
            manager.refreshIfStale()
            startPolling()
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(30, refreshInterval)))
                if Task.isCancelled { break }
                await MainActor.run { manager.refreshIfStale() }
            }
        }
    }
}

/// A single provider badge: a small label over the "session/weekly" pair.
struct UsageNotchBadge: View {
    let provider: String
    let state: ProviderUsageState
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(provider)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.4)

            HStack(spacing: 1) {
                number(for: session)
                Text("/")
                    .foregroundStyle(.secondary)
                number(for: weekly)
            }
            .font(.system(size: 11.5, weight: .bold, design: .rounded))
            .monospacedDigit()
        }
        .fixedSize()
    }

    // MARK: - Data

    private var session: Double? { state.report?.session?.percentRemaining }
    private var weekly: Double? { state.report?.weekly?.percentRemaining }

    @ViewBuilder
    private func number(for percent: Double?) -> some View {
        if let percent {
            Text("\(Int(percent.rounded()))")
                .foregroundStyle(QuotaDisplayStatus.from(percentRemaining: percent).color)
        } else {
            Text("—")
                .foregroundStyle(.secondary)
        }
    }
}
