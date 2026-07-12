import Foundation

/// Probes the Codex CLI to fetch session + weekly usage quotas.
struct CodexUsageProbe: UsageProbe {
    private let client: CodexRPCClient

    init(client: CodexRPCClient? = nil) {
        self.client = client ?? DefaultCodexRPCClient()
    }

    func isAvailable() async -> Bool {
        client.isAvailable()
    }

    func probe() async throws -> UsageSnapshot {
        AppLog.probes.info("Starting Codex probe...")
        defer { client.shutdown() }

        let limits = try await client.fetchRateLimits()
        let snapshot = try Self.mapRateLimitsToSnapshot(limits)

        AppLog.probes.info("Codex probe success: \(snapshot.quotas.count) quotas found")
        return snapshot
    }

    /// Maps RPC rate limits response to a UsageSnapshot.
    static func mapRateLimitsToSnapshot(_ limits: CodexRateLimitsResponse) throws -> UsageSnapshot {
        var quotas: [UsageQuota] = []

        if let primary = limits.primary {
            quotas.append(UsageQuota(
                percentRemaining: max(0, 100 - primary.usedPercent),
                quotaType: .session,
                providerId: "codex",
                resetsAt: primary.resetsAt,
                resetText: primary.resetDescription
            ))
        }

        if let secondary = limits.secondary {
            quotas.append(UsageQuota(
                percentRemaining: max(0, 100 - secondary.usedPercent),
                quotaType: .weekly,
                providerId: "codex",
                resetsAt: secondary.resetsAt,
                resetText: secondary.resetDescription
            ))
        }

        guard !quotas.isEmpty else {
            throw ProbeError.parseFailed("No rate limits found")
        }

        return UsageSnapshot(providerId: "codex", quotas: quotas, capturedAt: Date())
    }

    // MARK: - Parsing (for TTY fallback)

    static func parse(_ text: String) throws -> UsageSnapshot {
        let clean = stripANSICodes(text)

        if let error = extractUsageError(clean) {
            throw error
        }

        let fiveHourPct = extractPercent(labelSubstring: "5h limit", text: clean)
        let weeklyPct = extractPercent(labelSubstring: "Weekly limit", text: clean)

        var quotas: [UsageQuota] = []

        if let fiveHourPct {
            quotas.append(UsageQuota(percentRemaining: Double(fiveHourPct), quotaType: .session, providerId: "codex"))
        }
        if let weeklyPct {
            quotas.append(UsageQuota(percentRemaining: Double(weeklyPct), quotaType: .weekly, providerId: "codex"))
        }

        if quotas.isEmpty {
            throw ProbeError.parseFailed("Could not find usage limits in Codex output")
        }

        return UsageSnapshot(providerId: "codex", quotas: quotas, capturedAt: Date())
    }

    // MARK: - Text Parsing Helpers

    static func stripANSICodes(_ text: String) -> String {
        let pattern = #"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])"#
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    private static func extractPercent(labelSubstring: String, text: String) -> Int? {
        let lines = text.components(separatedBy: .newlines)
        let label = labelSubstring.lowercased()

        for (idx, line) in lines.enumerated() where line.lowercased().contains(label) {
            let window = lines.dropFirst(idx).prefix(12)
            for candidate in window {
                if let pct = percentFromLine(candidate) {
                    return pct
                }
            }
        }
        return nil
    }

    private static func percentFromLine(_ line: String) -> Int? {
        let pattern = #"([0-9]{1,3})%\s+left"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges >= 2,
              let valRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return Int(line[valRange])
    }

    static func extractUsageError(_ text: String) -> ProbeError? {
        let lower = text.lowercased()

        if lower.contains("data not available yet") {
            return .parseFailed("Data not available yet")
        }
        if lower.contains("update available") && lower.contains("codex") {
            return .updateRequired
        }
        if lower.contains("not logged in") || lower.contains("please log in") {
            return .authenticationRequired
        }
        return nil
    }
}
