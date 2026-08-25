//
//  UsageMonitorManager.swift
//  boringNotch
//
//  Owns cached CLI usage state for Claude + Codex and drives refreshes via the
//  non-sandboxed XPC helper. The helper is stateless/on-demand, so the cache
//  lives here.
//

import Defaults
import UserNotifications
import Foundation
import SwiftUI

/// Per-provider view state. Keeps the previously loaded report visible while a
/// re-sync is in flight so the UI never flashes an empty column.
enum ProviderUsageState {
    case idle
    case syncing(previous: UsageReportDTO?)
    case loaded(UsageReportDTO)

    /// The most recent report available, if any (loaded or carried through a sync).
    var report: UsageReportDTO? {
        switch self {
        case .idle: nil
        case .syncing(let previous): previous
        case .loaded(let dto): dto
        }
    }

    var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }
}

@MainActor
final class UsageMonitorManager: ObservableObject {
    static let shared = UsageMonitorManager()

    @Published private(set) var claude: ProviderUsageState = .idle
    @Published private(set) var codex: ProviderUsageState = .idle

    private var inFlight: Set<String> = []
    /// Usage badges can be recreated as the notch opens and closes. Keep the
    /// refresh lifetime here instead of in a particular SwiftUI surface, so a
    /// visible stale badge is never left waiting for another `onAppear`.
    private var periodicRefreshTask: Task<Void, Never>?

    private init() {
        // Seed from the last successful reports so a fresh launch (or a launch
        // while Claude/Codex are unreachable) still shows the previous usage.
        if let cached = Self.loadCachedReport(for: "claude") { claude = .loaded(cached) }
        if let cached = Self.loadCachedReport(for: "codex") { codex = .loaded(cached) }
        startPeriodicRefresh()
    }

    deinit {
        periodicRefreshTask?.cancel()
    }

    // MARK: - Running out

    /// Notify on the crossing, not on the state.
    ///
    /// A quota that is already low is low every time it is polled; saying so
    /// every five minutes is how a useful warning becomes something you turn
    /// off. This fires only when a reading moves from above the mark to below it.
    private func announceIfNewlyLow(provider: String,
                                    previous: UsageReportDTO?,
                                    current: UsageReportDTO) {
        guard Defaults[.usageNotifyOnLow] else { return }
        let low = Defaults[.usageLowThreshold]

        func crossed(_ old: UsageReportDTO.Quota?, _ new: UsageReportDTO.Quota?) -> Double? {
            guard let new, new.percentRemaining < low else { return nil }
            guard let old, old.percentRemaining >= low else { return nil }
            return new.percentRemaining
        }

        let hit = crossed(previous?.session, current.session) ?? crossed(previous?.weekly, current.weekly)
        guard let remaining = hit else { return }

        let name = provider == "claude" ? "Claude" : "Codex"
        let content = UNMutableNotificationContent()
        content.title = "\(name) is running low"
        content.body = "\(Int(remaining.rounded()))% of your allowance is left."
        if let reset = current.session?.resetText ?? current.weekly?.resetText {
            content.body += " \(reset)."
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "usage.low.\(provider)", content: content, trigger: nil))
    }

    // MARK: - Persistent cache

    private static func cacheKey(for provider: String) -> Defaults.Key<Data?> {
        provider == "claude" ? .cachedClaudeUsage : .cachedCodexUsage
    }

    private static func loadCachedReport(for provider: String) -> UsageReportDTO? {
        guard let data = Defaults[cacheKey(for: provider)] else { return nil }
        return try? UsageReportDTO.decoder.decode(UsageReportDTO.self, from: data)
    }

    private static func persistReport(_ report: UsageReportDTO, for provider: String) {
        Defaults[cacheKey(for: provider)] = try? UsageReportDTO.encoder.encode(report)
    }

    // MARK: - State access

    private func state(for provider: String) -> ProviderUsageState {
        provider == "claude" ? claude : codex
    }

    private func setState(_ state: ProviderUsageState, for provider: String) {
        if provider == "claude" {
            claude = state
        } else {
            codex = state
        }
    }

    // MARK: - Refresh

    /// Refreshes any provider whose cached report is older than the configured
    /// interval (or has never loaded). Called when the Usage tab becomes visible.
    /// The providers the reader has asked for. Someone who only uses one should
    /// not have the other reported as missing forever, or probed on a timer.
    static var enabledProviders: [String] {
        var out: [String] = []
        if Defaults[.usageShowClaude] { out.append("claude") }
        if Defaults[.usageShowCodex] { out.append("codex") }
        return out
    }

    func refreshIfStale() {
        let interval = Defaults[.usageMonitorRefreshInterval]
        for provider in Self.enabledProviders {
            if isStale(state(for: provider), interval: interval) {
                refresh(provider: provider, force: false)
            }
        }
    }

    private func startPeriodicRefresh() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshIfStale()

                let interval = max(30, Defaults[.usageMonitorRefreshInterval])
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
            }
        }
    }

    private func isStale(_ state: ProviderUsageState, interval: TimeInterval) -> Bool {
        guard let report = state.report else { return true }
        return Date().timeIntervalSince(report.capturedAt) >= interval
    }

    /// Refreshes both providers as independent concurrent tasks.
    func refresh(force: Bool) {
        for provider in Self.enabledProviders {
            refresh(provider: provider, force: force)
        }
    }

    private func refresh(provider: String, force: Bool) {
        guard !inFlight.contains(provider) else { return }

        if !force {
            let interval = Defaults[.usageMonitorRefreshInterval]
            if !isStale(state(for: provider), interval: interval) { return }
        }

        inFlight.insert(provider)
        setState(.syncing(previous: state(for: provider).report), for: provider)

        Task { [provider] in
            let dto = await XPCHelperClient.shared.fetchUsage(provider: provider)
            await MainActor.run {
                self.inFlight.remove(provider)
                if let dto {
                    // A failed probe (network hiccup, CLI timeout) should not
                    // wipe real numbers — keep the last good report visible.
                    // cliNotInstalled/notLoggedIn are genuine states and replace it.
                    if dto.status == .error,
                       let previous = self.state(for: provider).report,
                       previous.status == .ok {
                        self.setState(.loaded(previous), for: provider)
                    } else {
                        let before = self.state(for: provider).report
                        self.setState(.loaded(dto), for: provider)
                        if dto.status == .ok {
                            Self.persistReport(dto, for: provider)
                            self.announceIfNewlyLow(provider: provider, previous: before, current: dto)
                        }
                    }
                } else {
                    // Transport failure — synthesize an error report so the column
                    // shows something actionable instead of spinning forever.
                    let previous = self.state(for: provider).report
                    if let previous {
                        self.setState(.loaded(previous), for: provider)
                    } else {
                        self.setState(.loaded(UsageReportDTO(
                            provider: provider,
                            status: .error,
                            errorDescription: "Helper unavailable",
                            session: nil,
                            weekly: nil,
                            capturedAt: Date()
                        )), for: provider)
                    }
                }
            }
        }
    }
}
