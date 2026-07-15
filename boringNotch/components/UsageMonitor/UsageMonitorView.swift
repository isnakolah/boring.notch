//
//  UsageMonitorView.swift
//  boringNotch
//
//  Notch tab showing Claude + Codex CLI usage (session + weekly), fed by the
//  non-sandboxed XPC helper via UsageMonitorManager. Fits the ~488×100pt notch
//  content area without resizing the notch.
//

import AppKit
import Defaults
import SwiftUI

// MARK: - Root

struct UsageMonitorView: View {
    @ObservedObject private var manager = UsageMonitorManager.shared
    @Default(.usageMonitorRefreshInterval) private var refreshInterval

    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            ProviderUsageColumn(
                provider: .claude,
                state: manager.claude,
                onRefresh: { manager.refresh(force: true) }
            )
            .frame(maxWidth: .infinity)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, Color.primary.opacity(0.18), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 1)
                .padding(.vertical, 8)

            ProviderUsageColumn(
                provider: .codex,
                state: manager.codex,
                onRefresh: { manager.refresh(force: true) }
            )
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .onAppear {
            manager.refreshIfStale()
            startPolling()
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    /// Re-polls only while the tab is visible. Cache lives in the manager; the
    /// helper is stateless/on-demand.
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

// MARK: - Provider brand

/// Brand identity for the two supported CLIs — drives the header icon badge.
private enum UsageProvider {
    case claude
    case codex

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// Candidate desktop-app bundle IDs, tried in order for the real app icon.
    var appBundleIDs: [String] {
        switch self {
        case .claude: ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        case .codex: ["com.openai.chat", "com.openai.codex", "com.openai.ChatGPT"]
        }
    }

    /// Rounded-square tint behind the fallback glyph.
    var badgeBackground: Color {
        switch self {
        case .claude: Color(red: 0.36, green: 0.19, blue: 0.13)   // muted terracotta
        case .codex: Color(red: 0.10, green: 0.22, blue: 0.14)    // dark green
        }
    }

    var glyphColor: Color {
        switch self {
        case .claude: Color(red: 0.90, green: 0.51, blue: 0.34)   // Claude terracotta
        case .codex: Color(red: 0.40, green: 0.85, blue: 0.50)    // terminal green
        }
    }

    /// The real desktop-app icon, if that app is installed.
    var appIcon: NSImage? {
        let ws = NSWorkspace.shared
        for id in appBundleIDs {
            if let url = ws.urlForApplication(withBundleIdentifier: id) {
                return ws.icon(forFile: url.path)
            }
        }
        return nil
    }
}

/// Rounded-square brand badge sitting left of the provider name. Prefers the
/// installed desktop app's real icon; falls back to a drawn glyph.
private struct ProviderIconBadge: View {
    let provider: UsageProvider

    var body: some View {
        if let icon = provider.appIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(provider.badgeBackground)
                .frame(width: 20, height: 20)
                .overlay(glyph)
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch provider {
        case .claude:
            Image(systemName: "asterisk")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(provider.glyphColor)
        case .codex:
            Text(">_")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(provider.glyphColor)
        }
    }
}

// MARK: - Provider Column

private struct ProviderUsageColumn: View {
    let provider: UsageProvider
    let state: ProviderUsageState
    var onRefresh: (() -> Void)? = nil

    private var providerName: String { provider.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
    }

    private var header: some View {
        HStack(spacing: 7) {
            ProviderIconBadge(provider: provider)

            Text(providerName)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(
                    QuotaDisplayStatus.worstColor(
                        state.report?.session?.percentRemaining,
                        state.report?.weekly?.percentRemaining
                    ) ?? .primary
                )

            if state.isSyncing {
                ProgressView()
                    .controlSize(.mini)
            }

            Spacer(minLength: 0)

            if let report = state.report {
                Text(capturedAgo(report.capturedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let onRefresh {
                RefreshButton(action: onRefresh)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let report = state.report {
            switch report.status {
            case .ok:
                quotaTiles(for: report)
            case .cliNotInstalled:
                MessageView(icon: "wrench.and.screwdriver",
                            text: "\(providerName.lowercased()) CLI not found")
            case .notLoggedIn:
                MessageView(icon: "person.crop.circle.badge.exclamationmark",
                            text: "Not logged in")
            case .error:
                MessageView(icon: "exclamationmark.triangle",
                            text: report.errorDescription ?? "Unavailable")
            }
        } else {
            // First load — no cached report yet.
            MessageView(icon: nil, text: "Checking usage…", showSpinner: true)
        }
    }

    @ViewBuilder
    private func quotaTiles(for report: UsageReportDTO) -> some View {
        let quotas = availableQuotas(for: report)

        if quotas.isEmpty {
            UsageQuotaTile(label: "", quota: nil, isWeekly: false)
        } else {
            HStack(spacing: 8) {
                ForEach(quotas) { quota in
                    UsageQuotaTile(
                        label: quota.isWeekly ? "WEEKLY" : "SESSION",
                        quota: quota.value,
                        isWeekly: quota.isWeekly
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func availableQuotas(for report: UsageReportDTO) -> [AvailableQuota] {
        [
            report.session.map { AvailableQuota(value: $0, isWeekly: false) },
            report.weekly.map { AvailableQuota(value: $0, isWeekly: true) }
        ]
        .compactMap { $0 }
    }

    private func capturedAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
    }
}

private struct AvailableQuota: Identifiable {
    let value: UsageReportDTO.Quota
    let isWeekly: Bool

    var id: String { isWeekly ? "weekly" : "session" }
}

// MARK: - Quota Tile

private struct UsageQuotaTile: View {
    let label: String
    let quota: UsageReportDTO.Quota?
    let isWeekly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let quota {
                let status = QuotaDisplayStatus.from(percentRemaining: quota.percentRemaining)

                Text("\(Int(quota.percentRemaining.rounded()))%")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(status.color)

                progressBar(percent: quota.percentRemaining, color: status.color)

                resetLabel(quota)
            } else {
                Text("—")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 62)
    }

    private func progressBar(percent: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * max(0, min(1, percent / 100)))
            }
        }
        .frame(height: 5)
    }

    @ViewBuilder
    private func resetLabel(_ quota: UsageReportDTO.Quota) -> some View {
        if let resetsAt = quota.resetsAt {
            // Just the clock time (session) or date+time (weekly) it comes back —
            // no "Resets in" wording. Refreshed each minute.
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Text(Self.resetString(for: resetsAt, isWeekly: isWeekly))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if let resetText = quota.resetText {
            // Fallback string (e.g. Codex TTY path) — strip the "Resets in/…" prefix.
            Text(Self.stripResetPrefix(resetText))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            EmptyView()
        }
    }

    /// Session → time of day ("03:59"); weekly → day + time, using a relative
    /// day word for today/tomorrow ("Today at 16:59", "Tmrw at 16:59") and
    /// the date otherwise ("Jul 18 at 16:59").
    private static func resetString(for date: Date, isWeekly: Bool) -> String {
        let time = timeFormatter.string(from: date)
        guard isWeekly else { return time }

        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(date) {
            day = "Today"
        } else if cal.isDateInTomorrow(date) {
            day = "Tmrw"
        } else {
            day = dateFormatter.string(from: date)
        }
        return "\(day) at \(time)"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func stripResetPrefix(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"^\s*resets?(\s+in)?\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }
}

/// Compact refresh control for the usage header — a subtle secondary glyph that
/// highlights on hover, sized to sit inline next to the "updated" caption.
private struct RefreshButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? Color.primary : .secondary)
                .padding(4)
                .background(Circle().fill(hovering ? Color.primary.opacity(0.12) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Message / Status helpers

private struct MessageView: View {
    let icon: String?
    let text: String
    var showSpinner: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if showSpinner {
                ProgressView().controlSize(.small)
            } else if let icon {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 62, alignment: .center)
    }
}

/// Threshold-based display status for a quota's remaining percentage.
enum QuotaDisplayStatus {
    case healthy    // > 50
    case warning    // 20...50
    case critical   // 0 < x < 20
    case depleted   // <= 0

    static func from(percentRemaining: Double) -> QuotaDisplayStatus {
        switch percentRemaining {
        case let x where x > 50: .healthy
        case let x where x >= 20: .warning
        case let x where x > 0: .critical
        default: .depleted
        }
    }

    /// Color of the worst (lowest-remaining) quota among the given values — used
    /// to tint a provider's name by its most-depleted metric. `nil` when no quota
    /// data is available, so callers keep their default tint.
    static func worstColor(_ percents: Double?...) -> Color? {
        guard let worst = percents.compactMap({ $0 }).min() else { return nil }
        return from(percentRemaining: worst).color
    }

    var color: Color {
        switch self {
        case .healthy: .green
        case .warning: .orange
        case .critical: .red
        case .depleted: Color.red.opacity(0.6)
        }
    }
}
