//
//  UsageNotchBadge.swift
//  boringNotch
//
//  Always-on CLI usage badges shown beside the physical notch (Claude on the
//  left, Codex on the right). Each badge shows only quotas reported by its CLI,
//  with each number colored by its own QuotaDisplayStatus threshold.
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
            UsageNotchBadge(provider: "CLAUDE", state: manager.claude, alignment: .leading)
                .padding(.trailing, 10)
                .onHover { if $0 { onBadgeHover?() } }

            Rectangle()
                .fill(.black)
                .frame(width: notchWidth)

            UsageNotchBadge(provider: "CODEX", state: manager.codex, alignment: .leading)
                .padding(.leading, 10)
                .onHover { if $0 { onBadgeHover?() } }
        }
        // Size to content so the black notch background hugs the badges (extends
        // only to where the usage numbers reach) instead of ballooning to the
        // 512pt window cap. Mirrors the sneak-peek closed content's .fixedSize().
        .fixedSize()
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

/// A single provider badge: a small label over its available quota values.
struct UsageNotchBadge: View {
    let provider: String
    let state: ProviderUsageState
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(provider)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(QuotaDisplayStatus.worstColor(session, weekly) ?? .secondary)
                .tracking(0.4)

            HStack(spacing: 1) {
                ForEach(Array(availablePercents.enumerated()), id: \.offset) { index, percent in
                    number(for: percent)
                    if index < availablePercents.count - 1 {
                        Text("|")
                            .foregroundStyle(.secondary)
                    }
                }

                if availablePercents.isEmpty {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11.5, weight: .bold, design: .rounded))
            .monospacedDigit()
        }
        .fixedSize()
    }

    // MARK: - Data

    private var session: Double? { state.report?.session?.percentRemaining }
    private var weekly: Double? { state.report?.weekly?.percentRemaining }
    private var availablePercents: [Double] { [session, weekly].compactMap { $0 } }

    private func number(for percent: Double) -> some View {
        // Keep a full quota from advertising literal 100 in the compact menubar
        // surface. The expanded usage tab still shows the exact value.
        Text("\(min(99, Int(percent.rounded())))")
            .foregroundStyle(QuotaDisplayStatus.from(percentRemaining: percent).color)
    }
}
