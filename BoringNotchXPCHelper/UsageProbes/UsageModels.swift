//
//  UsageModels.swift
//  BoringNotchXPCHelper
//
//  Lean domain models for the usage-probe stack, trimmed from ClaudeBar's
//  Domain layer. Only session/weekly quotas are supported here.
//

import Foundation

/// The type of usage quota being tracked.
enum QuotaType: Sendable, Equatable, Hashable {
    /// Rolling 5-hour session limit
    case session
    /// Rolling 7-day weekly limit
    case weekly

    var displayName: String {
        switch self {
        case .session: "Session"
        case .weekly: "Weekly"
        }
    }
}

/// A single usage quota measurement for an AI provider.
struct UsageQuota: Sendable, Equatable {
    /// The percentage of quota remaining (capped at 100, may be negative when over quota).
    let percentRemaining: Double
    let quotaType: QuotaType
    let providerId: String
    let resetsAt: Date?
    let resetText: String?

    init(
        percentRemaining: Double,
        quotaType: QuotaType,
        providerId: String,
        resetsAt: Date? = nil,
        resetText: String? = nil
    ) {
        self.percentRemaining = min(100, percentRemaining)
        self.quotaType = quotaType
        self.providerId = providerId
        self.resetsAt = resetsAt
        self.resetText = resetText
    }
}

/// A snapshot of usage quotas captured from a provider probe.
struct UsageSnapshot: Sendable, Equatable {
    let providerId: String
    let quotas: [UsageQuota]
    let capturedAt: Date

    init(providerId: String, quotas: [UsageQuota], capturedAt: Date = Date()) {
        self.providerId = providerId
        self.quotas = quotas
        self.capturedAt = capturedAt
    }
}

/// Errors that can occur when probing a CLI.
enum ProbeError: Error, Sendable, LocalizedError, Equatable {
    case cliNotFound(String)
    case authenticationRequired
    case parseFailed(String)
    case timeout
    case updateRequired
    case folderTrustRequired
    case executionFailed(String)
    case subscriptionRequired

    var errorDescription: String? {
        switch self {
        case .cliNotFound(let binary): "CLI not found: \(binary)"
        case .authenticationRequired: "Authentication required. Please log in."
        case .parseFailed(let reason): "Failed to parse output: \(reason)"
        case .timeout: "Request timed out"
        case .updateRequired: "CLI update required"
        case .folderTrustRequired: "Please trust this folder in Claude CLI"
        case .executionFailed(let reason): reason
        case .subscriptionRequired: "Subscription required for usage data"
        }
    }
}

/// Adapter that probes a provider's CLI for usage quotas.
protocol UsageProbe: Sendable {
    func isAvailable() async -> Bool
    func probe() async throws -> UsageSnapshot
}
