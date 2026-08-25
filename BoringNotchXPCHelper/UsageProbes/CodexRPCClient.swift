import Foundation

// MARK: - Codex Service Protocol

/// Protocol for the Codex service - "Is it available?" and "Get my stats".
protocol CodexRPCClient: Sendable {
    func isAvailable() -> Bool
    func fetchRateLimits() async throws -> CodexRateLimitsResponse
    func shutdown()
}

/// Response from Codex rate limits API.
///
/// A list of windows rather than a `primary`/`secondary` pair, because those two
/// keys never meant "session" and "weekly". OpenAI has moved which bucket the
/// 5-hour limit lives in more than once: it was `primary` with `secondary`
/// weekly, then for a period only a single weekly window in `primary` (which is
/// what an account on Plus reports today), and the response now also carries
/// `rateLimitsByLimitId` with a bucket per limit. Reading position and calling
/// the first one "session" was wrong in two of those three shapes, and is what
/// made the 5-hour figure disappear from the notch.
///
/// So: collect every window the response contains, wherever it lives, and let
/// each one say what it is.
struct CodexRateLimitsResponse: Sendable, Equatable {
    let windows: [CodexRateLimitWindow]
    let planType: String?

    init(windows: [CodexRateLimitWindow], planType: String? = nil) {
        self.windows = windows
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

    /// How long this window covers, in minutes.
    ///
    /// The declared duration where there is one. Where there is not, the time
    /// left until it resets is the only evidence available — it is a floor
    /// rather than the duration, but a window resetting in under five hours
    /// cannot be the weekly one, which is all this has to decide.
    var estimatedMinutes: Int? {
        if let windowDurationMins { return windowDurationMins }
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        return Int(remaining / 60)
    }

    /// Anything covering less than a day is the rolling session limit; the
    /// weekly one is 10080 minutes and has never been close to the boundary.
    var isSession: Bool {
        guard let minutes = estimatedMinutes else { return false }
        return minutes < 24 * 60
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

        var windows = parseBucket(rateLimits)

        // Newer responses carry a bucket per limit alongside the flat one, and
        // that is where a reinstated 5-hour window turns up first — the flat
        // `rateLimits` object mirrors only one of them. Reading both means the
        // figure appears the moment the API reports it, with no further change
        // here.
        if let byID = result["rateLimitsByLimitId"] as? [String: Any] {
            for (_, bucket) in byID {
                guard let bucket = bucket as? [String: Any] else { continue }
                windows.append(contentsOf: parseBucket(bucket))
            }
        }

        windows = Self.deduplicate(windows)

        if windows.isEmpty {
            if planType == "free" {
                return CodexRateLimitsResponse(
                    windows: [CodexRateLimitWindow(usedPercent: 0,
                                                   resetDescription: "Free plan",
                                                   windowDurationMins: 5 * 60)],
                    planType: planType
                )
            }
            throw ProbeError.parseFailed("No rate limits available yet - make some API calls first")
        }

        AppLog.probes.info(
            "Codex windows: \(windows.map { "\($0.estimatedMinutes.map(String.init) ?? "?")m@\(Int($0.usedPercent))%" }.joined(separator: ", "))")
        return CodexRateLimitsResponse(windows: windows, planType: planType)
    }

    /// Both windows out of one `{primary, secondary}` object.
    private func parseBucket(_ bucket: [String: Any]) -> [CodexRateLimitWindow] {
        [parseWindow(bucket["primary"]), parseWindow(bucket["secondary"])].compactMap { $0 }
    }

    /// The same window arrives in the flat object and again under its limit id.
    /// Two windows are the same when they cover the same span and reset at the
    /// same moment; where a duplicate pair disagrees on usage the higher figure
    /// wins, because that is the one that will actually stop you.
    static func deduplicate(_ windows: [CodexRateLimitWindow]) -> [CodexRateLimitWindow] {
        var best: [String: CodexRateLimitWindow] = [:]
        var order: [String] = []
        for window in windows {
            let key = "\(window.estimatedMinutes.map { $0 / 60 } ?? -1)|\(window.resetsAt?.timeIntervalSince1970.rounded() ?? -1)"
            if let existing = best[key] {
                if window.usedPercent > existing.usedPercent { best[key] = window }
            } else {
                best[key] = window
                order.append(key)
            }
        }
        return order.compactMap { best[$0] }
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

        var windows: [CodexRateLimitWindow] = []

        if let pct = fiveHourPct {
            windows.append(CodexRateLimitWindow(
                usedPercent: Double(100 - pct),
                resetDescription: nil,
                windowDurationMins: 5 * 60
            ))
        }
        if let pct = weeklyPct {
            windows.append(CodexRateLimitWindow(
                usedPercent: Double(100 - pct),
                resetDescription: nil,
                windowDurationMins: 7 * 24 * 60
            ))
        }

        guard !windows.isEmpty else {
            throw ProbeError.parseFailed("Could not find usage limits in Codex output")
        }

        return CodexRateLimitsResponse(windows: windows)
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
        // `as? Double` alone: the API sends whole numbers as JSON integers, and
        // NSNumber's bridge is the only reason that has been working.
        guard let usedPercent = (dict["usedPercent"] as? NSNumber)?.doubleValue else { return nil }

        var resetDescription: String?
        var resetDate: Date?
        let windowDurationMins = (dict["windowDurationMins"] as? NSNumber)?.intValue
        if let resetsAt = (dict["resetsAt"] as? NSNumber)?.intValue {
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
