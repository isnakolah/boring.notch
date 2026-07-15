//
//  UsageMonitorManager.swift
//  boringNotch
//
//  Owns cached CLI usage state for Claude + Codex and drives refreshes via the
//  non-sandboxed XPC helper. The helper is stateless/on-demand, so the cache
//  lives here.
//

import Defaults
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

    private init() {
        // Seed from the last successful reports so a fresh launch (or a launch
        // while Claude/Codex are unreachable) still shows the previous usage.
        if let cached = Self.loadCachedReport(for: "claude") { claude = .loaded(cached) }
        if let cached = Self.loadCachedReport(for: "codex") { codex = .loaded(cached) }
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
    func refreshIfStale() {
        let interval = Defaults[.usageMonitorRefreshInterval]
        for provider in ["claude", "codex"] {
            if isStale(state(for: provider), interval: interval) {
                refresh(provider: provider, force: false)
            }
        }
    }

    private func isStale(_ state: ProviderUsageState, interval: TimeInterval) -> Bool {
        guard let report = state.report else { return true }
        return Date().timeIntervalSince(report.capturedAt) >= interval
    }

    /// Refreshes both providers as independent concurrent tasks.
    func refresh(force: Bool) {
        refresh(provider: "claude", force: force)
        refresh(provider: "codex", force: force)
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
                        self.setState(.loaded(dto), for: provider)
                        if dto.status == .ok {
                            Self.persistReport(dto, for: provider)
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
