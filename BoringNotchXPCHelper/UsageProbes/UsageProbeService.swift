//
//  UsageProbeService.swift
//  BoringNotchXPCHelper
//
//  Orchestrates provider probes and maps their snapshots/errors into the
//  Codable UsageReportDTO carried across the XPC boundary. Coalesces
//  duplicate in-flight requests per provider so a burst of XPC calls can't
//  spawn concurrent `claude`/`codex` subprocesses.
//

import Foundation

actor UsageProbeService {
    static let shared = UsageProbeService()

    private var inFlight: [String: Task<UsageReportDTO, Never>] = [:]

    func fetchUsage(provider: String) async -> UsageReportDTO {
        if let existing = inFlight[provider] {
            return await existing.value
        }

        let task = Task<UsageReportDTO, Never> { [provider] in
            await Self.runProbe(provider: provider)
        }
        inFlight[provider] = task
        let result = await task.value
        inFlight[provider] = nil
        return result
    }

    private static func runProbe(provider: String) async -> UsageReportDTO {
        let probe: UsageProbe
        switch provider {
        case "claude":
            probe = ClaudeUsageProbe()
        case "codex":
            probe = CodexUsageProbe()
        default:
            return UsageReportDTO(
                provider: provider,
                status: .error,
                errorDescription: "Unknown provider '\(provider)'",
                session: nil,
                weekly: nil,
                capturedAt: Date()
            )
        }

        guard await probe.isAvailable() else {
            return UsageReportDTO(
                provider: provider,
                status: .cliNotInstalled,
                errorDescription: "\(provider) CLI not found",
                session: nil,
                weekly: nil,
                capturedAt: Date()
            )
        }

        do {
            let snapshot = try await probe.probe()
            return map(snapshot: snapshot, provider: provider)
        } catch let error as ProbeError {
            return map(error: error, provider: provider)
        } catch {
            return UsageReportDTO(
                provider: provider,
                status: .error,
                errorDescription: error.localizedDescription,
                session: nil,
                weekly: nil,
                capturedAt: Date()
            )
        }
    }

    private static func map(snapshot: UsageSnapshot, provider: String) -> UsageReportDTO {
        func quota(for type: QuotaType) -> UsageReportDTO.Quota? {
            guard let q = snapshot.quotas.first(where: { $0.quotaType == type }) else { return nil }
            return UsageReportDTO.Quota(
                percentRemaining: q.percentRemaining,
                resetText: q.resetText,
                resetsAt: q.resetsAt
            )
        }

        return UsageReportDTO(
            provider: provider,
            status: .ok,
            errorDescription: nil,
            session: quota(for: .session),
            weekly: quota(for: .weekly),
            capturedAt: snapshot.capturedAt
        )
    }

    private static func map(error: ProbeError, provider: String) -> UsageReportDTO {
        let status: UsageReportDTO.Status
        let description: String

        switch error {
        case .cliNotFound:
            status = .cliNotInstalled
            description = "\(provider) CLI not found"
        case .authenticationRequired:
            status = .notLoggedIn
            description = "Not logged in"
        case .subscriptionRequired:
            status = .error
            description = "API-billing account — no quota data"
        default:
            status = .error
            description = error.errorDescription ?? "Usage probe failed"
        }

        return UsageReportDTO(
            provider: provider,
            status: status,
            errorDescription: description,
            session: nil,
            weekly: nil,
            capturedAt: Date()
        )
    }
}
