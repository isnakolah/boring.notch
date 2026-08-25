import Foundation

// MARK: - Codex Service Protocol

/// Protocol for the Codex service - "Is it available?" and "Get my stats".
protocol CodexRPCClient: Sendable {
    func isAvailable() -> Bool
    func fetchRateLimits() async throws -> CodexRateLimitsResponse
    func shutdown()
}

/// Response from Codex rate limits API.
struct CodexRateLimitsResponse: Sendable, Equatable {
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
    let planType: String?

    init(primary: CodexRateLimitWindow?, secondary: CodexRateLimitWindow?, planType: String? = nil) {
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
    }
}

/// A rate limit window from the Codex API.
struct CodexRateLimitWindow: Sendable, Equatable {
    let usedPercent: Double
    let resetDescription: String?
    let resetsAt: Date?
    let windowDurationMins: Int?

    init(
        usedPercent: Double,
        resetDescription: String?,
        resetsAt: Date? = nil,
        windowDurationMins: Int? = nil
    ) {
        self.usedPercent = usedPercent
        self.resetDescription = resetDescription
        self.resetsAt = resetsAt
        self.windowDurationMins = windowDurationMins
    }
}

/// Default implementation of CodexRPCClient that communicates with `codex app-server`.
final class DefaultCodexRPCClient: CodexRPCClient, @unchecked Sendable {
    private let executable: String
    private let cliExecutor: CLIExecutor
    private var nextID = 1

    init(executable: String = "codex", cliExecutor: CLIExecutor? = nil) {
        self.executable = executable
        self.cliExecutor = cliExecutor ?? DefaultCLIExecutor()
    }

    func isAvailable() -> Bool {
        if cliExecutor.locate(executable) != nil {
            return true
        }
        AppLog.probes.error("Codex binary '\(self.executable)' not found in PATH")
        return false
    }

    func fetchRateLimits() async throws -> CodexRateLimitsResponse {
        do {
            return try await fetchViaRPC()
        } catch {
            AppLog.probes.warning("Codex RPC failed: \(error.localizedDescription), trying TTY fallback...")
            return try await fetchViaTTY()
        }
    }

    // MARK: - RPC Approach

    private func fetchViaRPC() async throws -> CodexRateLimitsResponse {
        let transport = try ProcessRPCTransport(
            executable: executable,
            // Codex CLI 0.149 removed the old `untrusted` approval policy.
            // This probe performs no agent work, and must not wait for UI approval.
            arguments: ["-s", "read-only", "-a", "never", "app-server"]
        )
        defer { transport.close() }

        _ = try await request(transport: transport, method: "initialize", params: [
            "clientInfo": ["name": "boringnotch", "version": "1.0.0"]
        ])
        try sendNotification(transport: transport, method: "initialized")

        let message = try await request(transport: transport, method: "account/rateLimits/read")

        if let data = try? JSONSerialization.data(withJSONObject: message, options: .prettyPrinted),
           let jsonString = String(data: data, encoding: .utf8) {
            AppLog.probes.debug("Codex RPC raw response:\n\(jsonString)")
        }

        guard let result = message["result"] as? [String: Any] else {
            throw ProbeError.parseFailed("Invalid rate limits response")
        }
        guard let rateLimits = result["rateLimits"] as? [String: Any] else {
            throw ProbeError.parseFailed("No rateLimits in response")
        }

        let planType = rateLimits["planType"] as? String
        AppLog.probes.info("Codex plan type: \(planType ?? "unknown")")

        let primary = parseWindow(rateLimits["primary"])
        let secondary = parseWindow(rateLimits["secondary"])

        if primary == nil && secondary == nil {
            if planType == "free" {
                return CodexRateLimitsResponse(
                    primary: CodexRateLimitWindow(usedPercent: 0, resetDescription: "Free plan"),
                    secondary: nil,
                    planType: planType
                )
            }
            throw ProbeError.parseFailed("No rate limits available yet - make some API calls first")
        }

        return CodexRateLimitsResponse(primary: primary, secondary: secondary, planType: planType)
    }

    // MARK: - TTY Fallback

    private func fetchViaTTY() async throws -> CodexRateLimitsResponse {
        AppLog.probes.info("Starting Codex TTY fallback...")

        let result = try cliExecutor.execute(
            binary: executable,
            args: ["-s", "read-only", "-a", "never"],
            input: "/status\n",
            timeout: 20.0,
            workingDirectory: nil,
            autoResponses: [:]
        )

        AppLog.probes.debug("Codex TTY raw output:\n\(result.output)")
        return try parseTTYOutput(result.output)
    }

    private func parseTTYOutput(_ text: String) throws -> CodexRateLimitsResponse {
        let clean = CodexUsageProbe.stripANSICodes(text)

        if let error = CodexUsageProbe.extractUsageError(clean) {
            throw error
        }

        let fiveHourPct = extractTTYPercent(labelSubstring: "5h limit", text: clean)
        let weeklyPct = extractTTYPercent(labelSubstring: "Weekly limit", text: clean)

        var primary: CodexRateLimitWindow?
        var secondary: CodexRateLimitWindow?

        if let pct = fiveHourPct {
            primary = CodexRateLimitWindow(
                usedPercent: Double(100 - pct),
                resetDescription: nil,
                windowDurationMins: 5 * 60
            )
        }
        if let pct = weeklyPct {
            secondary = CodexRateLimitWindow(
                usedPercent: Double(100 - pct),
                resetDescription: nil,
                windowDurationMins: 7 * 24 * 60
            )
        }

        guard primary != nil || secondary != nil else {
            throw ProbeError.parseFailed("Could not find usage limits in Codex output")
        }

        return CodexRateLimitsResponse(primary: primary, secondary: secondary)
    }

    private func extractTTYPercent(labelSubstring: String, text: String) -> Int? {
        let lines = text.components(separatedBy: .newlines)
        let label = labelSubstring.lowercased()

        for (idx, line) in lines.enumerated() where line.lowercased().contains(label) {
            let window = lines.dropFirst(idx).prefix(12)
            for candidate in window {
                if let pct = ttyPercentFromLine(candidate) {
                    return pct
                }
            }
        }
        return nil
    }

    private func ttyPercentFromLine(_ line: String) -> Int? {
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

    // MARK: - Parsing Helpers

    private func parseWindow(_ value: Any?) -> CodexRateLimitWindow? {
        guard let dict = value as? [String: Any] else { return nil }
        guard let usedPercent = dict["usedPercent"] as? Double else { return nil }

        var resetDescription: String?
        var resetDate: Date?
        let windowDurationMins = (dict["windowDurationMins"] as? NSNumber)?.intValue
        if let resetsAt = dict["resetsAt"] as? Int {
            let date = Date(timeIntervalSince1970: TimeInterval(resetsAt))
            resetDate = date
            resetDescription = formatResetTime(date)
        }
        return CodexRateLimitWindow(
            usedPercent: usedPercent,
            resetDescription: resetDescription,
            resetsAt: resetDate,
            windowDurationMins: windowDurationMins
        )
    }

    private func formatResetTime(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "Resets soon" }

        let days = Int(interval / 86400)
        let hours = Int((interval.truncatingRemainder(dividingBy: 86400)) / 3600)
        let minutes = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)

        if days > 0 {
            return "Resets in \(days)d \(hours)h \(minutes)m"
        } else if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        } else {
            return "Resets in \(minutes)m"
        }
    }

    func shutdown() {}

    // MARK: - JSON-RPC

    private func request(transport: RPCTransport, method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        let id = nextID
        nextID += 1

        try sendRequest(transport: transport, id: id, method: method, params: params)

        while true {
            let message = try await readNextMessage(transport: transport)
            if message["id"] == nil { continue }
            guard let messageID = message["id"] as? Int, messageID == id else { continue }

            if let error = message["error"] as? [String: Any],
               let errorMessage = error["message"] as? String {
                throw ProbeError.executionFailed("RPC error: \(errorMessage)")
            }
            return message
        }
    }

    private func sendNotification(transport: RPCTransport, method: String) throws {
        try sendPayload(transport: transport, payload: ["method": method, "params": [:]])
    }

    private func sendRequest(transport: RPCTransport, id: Int, method: String, params: [String: Any]?) throws {
        try sendPayload(transport: transport, payload: ["id": id, "method": method, "params": params ?? [:]])
    }

    private func sendPayload(transport: RPCTransport, payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        try transport.send(data)
    }

    private func readNextMessage(transport: RPCTransport) async throws -> [String: Any] {
        while true {
            let data = try await transport.receive()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return json
        }
    }
}
