import Foundation
import SwiftTerm

/// Probes the Claude CLI (`claude /usage`) to fetch session + weekly usage quotas.
///
/// Strips `CLAUDE_CODE_OAUTH_TOKEN` from the subprocess environment so `/usage`
/// falls back to stored credentials (from `claude login`) which carry the
/// `user:profile` scope required for quota data.
///
/// Trimmed from ClaudeBar: only "Current session" + "Current week (all models)"
/// are parsed — no account/tier detection, /cost fallback, extra-usage cost
/// parsing, or Opus/Sonnet model quotas.
final class ClaudeUsageProbe: UsageProbe, @unchecked Sendable {
    private let claudeBinary: String
    private let timeout: TimeInterval
    private let cliExecutor: CLIExecutor
    private let terminalRenderer: TerminalRenderer

    /// `CLAUDE_CODE_OAUTH_TOKEN` is excluded because setup-tokens only have
    /// `user:inference` scope and cannot access quota data via `/usage`.
    static let envExclusions = ["CLAUDE_CODE_OAUTH_TOKEN"]

    init(
        claudeBinary: String = "claude",
        timeout: TimeInterval = 20.0,
        cliExecutor: CLIExecutor? = nil
    ) {
        self.claudeBinary = claudeBinary
        self.timeout = timeout
        self.cliExecutor = cliExecutor ?? DefaultCLIExecutor(environmentExclusions: Self.envExclusions)
        self.terminalRenderer = TerminalRenderer(cols: 160, rows: 50)
    }

    func isAvailable() async -> Bool {
        if cliExecutor.locate(claudeBinary) != nil {
            return true
        }
        AppLog.probes.error("Claude binary '\(self.claudeBinary)' not found in PATH")
        return false
    }

    func probe() async throws -> UsageSnapshot {
        let workingDir = probeWorkingDirectory()
        // Pre-trust the probe dir so the first run skips the folder-trust /
        // onboarding prompt entirely (saves a full ~20s prompt+retry cycle).
        _ = writeClaudeTrust(for: workingDir)
        // The XPC helper's claude subprocess can't read the login Keychain
        // non-interactively, so it would fall back to the "API Usage Billing"
        // screen with no quota bars. Mirror the Keychain OAuth token into
        // ~/.claude/.credentials.json, which claude reads with higher precedence,
        // so it authenticates as the real subscription.
        syncClaudeCredentialsFile()
        AppLog.probes.info("Starting Claude probe with /usage command...")

        let usageResult: CLIResult
        do {
            usageResult = try cliExecutor.execute(
                binary: claudeBinary,
                args: ["/usage", "--allowed-tools", ""],
                input: "",
                timeout: timeout,
                workingDirectory: workingDir,
                // Keys match against an ANSI-normalized buffer (see InteractiveRunner),
                // so multi-word phrases match despite per-word cursor moves. Kept
                // minimal and specific to the trust/onboarding screens: broad or
                // footer-matching keys (e.g. "Esc to cancel") also appear on the
                // /usage screen and would send stray Enters that navigate the TUI
                // tabs, scrolling the quota rows out of view.
                autoResponses: [
                    // claude 2.1.x folder-trust prompt — "Yes, I trust this folder"
                    // is pre-highlighted, so a single Enter confirms it.
                    "Yes, I trust this folder": "\r",
                    "Ready to code here?": "\r",
                    "Press Enter to continue": "\r",
                ],
                // /usage shows a "loading usage data…" screen then falls silent
                // during the fetch; wait for a rendered quota row before idle-exit.
                completionMarkers: ["% used", "% left"]
            )
        } catch {
            AppLog.probes.error("Claude /usage probe failed: \(error.localizedDescription)")
            throw ProbeError.executionFailed(error.localizedDescription)
        }

        AppLog.probes.info("Claude /usage output:\n\(usageResult.output)")

        do {
            return try parseClaudeOutput(usageResult.output)
        } catch ProbeError.folderTrustRequired {
            AppLog.probes.info("Writing trust for probe directory and retrying...")
            if writeClaudeTrust(for: workingDir) {
                return try await probe()
            }
            throw ProbeError.folderTrustRequired
        }
    }

    // MARK: - Parsing

    /// Parses Claude CLI /usage output into a UsageSnapshot (for testing).
    static func parse(_ text: String) throws -> UsageSnapshot {
        try ClaudeUsageProbe().parseClaudeOutput(text)
    }

    private func parseClaudeOutput(_ text: String) throws -> UsageSnapshot {
        let clean = renderTerminalOutput(text)
        // The /usage TUI scrolls, so the SwiftTerm 50-row viewport can miss the
        // quota rows. A flattened view of the raw stream keeps every line that was
        // ever emitted, so we fall back to it when the rendered screen comes up short.
        let flat = flattenForParsing(text)

        if let error = extractUsageError(clean) {
            throw error
        }

        let sessionPct = extractPercent(labelSubstring: "Current session", text: clean)
            ?? extractPercentFlat(after: "current session", in: flat)
        let weeklyPct = extractPercent(labelSubstring: "Current week (all models)", text: clean)
            ?? extractPercentFlat(after: "current week (all models)", in: flat)

        guard let sessionPct else {
            AppLog.probes.error("Claude parse failed: could not find 'Current session' percentage")
            AppLog.probes.debug("Rendered output:\n\(clean)")
            AppLog.probes.debug("Flattened output:\n\(flat)")
            throw ProbeError.parseFailed("Could not find session usage")
        }

        let sessionReset = extractReset(labelSubstring: "Current session", text: clean)
            ?? extractResetFlat(after: "current session", in: flat)
        let weeklyReset = extractReset(labelSubstring: "Current week", text: clean)
            ?? extractResetFlat(after: "current week", in: flat)

        var quotas: [UsageQuota] = []

        quotas.append(UsageQuota(
            percentRemaining: Double(sessionPct),
            quotaType: .session,
            providerId: "claude",
            resetsAt: parseResetDate(sessionReset),
            resetText: cleanResetText(sessionReset)
        ))

        if let weeklyPct {
            quotas.append(UsageQuota(
                percentRemaining: Double(weeklyPct),
                quotaType: .weekly,
                providerId: "claude",
                resetsAt: parseResetDate(weeklyReset),
                resetText: cleanResetText(weeklyReset)
            ))
        }

        return UsageSnapshot(providerId: "claude", quotas: quotas, capturedAt: Date())
    }

    // MARK: - Text Parsing Helpers

    private func renderTerminalOutput(_ text: String) -> String {
        terminalRenderer.render(text)
    }

    /// Collapses the raw PTY stream into a single lowercased line with ANSI/escape
    /// sequences replaced by spaces. Unlike the rendered viewport this preserves
    /// every line ever emitted, so quota rows that scrolled off screen survive.
    private func flattenForParsing(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\x1B\[[0-9;?]*[A-Za-z]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\x1B[\(\)][AB012]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\u{1B}", with: " ")
        s = s.replacingOccurrences(of: "\u{07}", with: " ")
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.lowercased()
    }

    /// Reads the "N% used/left" nearest after `label` in the flattened blob,
    /// stopping before the next "current " section so weekly ≠ session.
    private func extractPercentFlat(after label: String, in flat: String) -> Int? {
        guard let range = flat.range(of: label) else { return nil }
        let rest = flat[range.upperBound...]
        let end = rest.range(of: "current ")?.lowerBound ?? rest.endIndex
        return percentFromLine(String(rest[..<end]))
    }

    /// Reads reset text nearest after `label` in the flattened blob.
    private func extractResetFlat(after label: String, in flat: String) -> String? {
        guard let range = flat.range(of: label) else { return nil }
        let rest = flat[range.upperBound...]
        let end = rest.range(of: "current ")?.lowerBound ?? rest.endIndex
        let window = String(rest[..<end])
        guard let r = window.range(of: #"resets\s+[^%]*?(?=\s{2,}|current |$)"#, options: .regularExpression) else {
            return nil
        }
        return deduplicateResetText(String(window[r]).trimmingCharacters(in: .whitespaces))
    }

    private func extractPercent(labelSubstring: String, text: String) -> Int? {
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

    private func percentFromLine(_ line: String) -> Int? {
        let pattern = #"([0-9]{1,3})\s*%\s*(used|left)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges >= 3,
              let valRange = Range(match.range(at: 1), in: line),
              let kindRange = Range(match.range(at: 2), in: line) else {
            return nil
        }
        let rawVal = Int(line[valRange]) ?? 0
        let isUsed = line[kindRange].lowercased().contains("used")
        return isUsed ? max(0, 100 - rawVal) : rawVal
    }

    private func extractReset(labelSubstring: String, text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        let label = labelSubstring.lowercased()

        for (idx, line) in lines.enumerated() where line.lowercased().contains(label) {
            let window = lines.dropFirst(idx).prefix(14)
            for candidate in window {
                let lower = candidate.lowercased()
                if lower.contains("reset") ||
                   (lower.contains("in") && (lower.contains("h") || lower.contains("m"))) {
                    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                    return deduplicateResetText(trimmed)
                }
            }
        }
        return nil
    }

    /// Removes duplicate "Resets..." text caused by terminal redraw artifacts.
    private func deduplicateResetText(_ text: String) -> String {
        var positions: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let range = text.range(of: "resets", options: .caseInsensitive, range: searchStart..<text.endIndex) {
            positions.append(range)
            searchStart = text.index(after: range.lowerBound)
        }

        if positions.count > 1, let lastRange = positions.last {
            return String(text[lastRange.lowerBound...]).trimmingCharacters(in: .whitespaces)
        }

        return text
    }

    private func cleanResetText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("reset") {
            return trimmed
        }
        return "Resets \(trimmed)"
    }

    // MARK: - Date Parsing

    private func parseResetDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        if let relativeDate = parseRelativeDuration(text) {
            return relativeDate
        }
        return parseAbsoluteDate(text)
    }

    private func parseRelativeDuration(_ text: String) -> Date? {
        var totalSeconds: TimeInterval = 0

        if let dayMatch = text.range(of: #"(\d+)\s*d(?:ays?)?"#, options: .regularExpression) {
            if let days = Int(String(text[dayMatch]).filter { $0.isNumber }) {
                totalSeconds += Double(days) * 24 * 3600
            }
        }
        if let hourMatch = text.range(of: #"(\d+)\s*h(?:ours?|r)?"#, options: .regularExpression) {
            if let hours = Int(String(text[hourMatch]).filter { $0.isNumber }) {
                totalSeconds += Double(hours) * 3600
            }
        }
        if let minMatch = text.range(of: #"(\d+)\s*m(?:in(?:utes?)?)?"#, options: .regularExpression) {
            if let minutes = Int(String(text[minMatch]).filter { $0.isNumber }) {
                totalSeconds += Double(minutes) * 60
            }
        }

        if totalSeconds > 0 {
            return Date().addingTimeInterval(totalSeconds)
        }
        return nil
    }

    private func parseAbsoluteDate(_ text: String) -> Date? {
        let timeZone = extractTimeZone(from: text)

        var cleaned = text
        cleaned = cleaned
            .replacingOccurrences(of: #"\s+\d{1,3}%\s*(?:used|left)\s*$"#, with: "", options: .regularExpression)

        if let lastResets = cleaned.range(of: "resets", options: [.caseInsensitive, .backwards]) {
            cleaned = String(cleaned[lastResets.upperBound...])
        }
        cleaned = cleaned
            .replacingOccurrences(of: #"\s*\([^)]+\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        cleaned = cleaned.replacingOccurrences(of: #"\s+at\s+"#, with: ", ", options: .regularExpression)

        let formats: [String] = [
            "MMM d, yyyy, h:mma",
            "MMM d, yyyy, ha",
            "MMM d, yyyy",
            "MMM d, h:mma",
            "MMM d, ha",
            "h:mma",
            "ha",
            "MMM d",
        ]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone ?? .current

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) {
                return resolveToFutureDate(date, format: format, timeZone: formatter.timeZone)
            }
        }
        return nil
    }

    private func extractTimeZone(from text: String) -> TimeZone? {
        guard let match = text.range(of: #"\(([^)]+)\)"#, options: [.regularExpression, .backwards]) else {
            return nil
        }
        let content = String(text[match]).dropFirst().dropLast()
        let identifier = String(content).trimmingCharacters(in: .whitespaces)
        return TimeZone(identifier: identifier)
    }

    private func resolveToFutureDate(_ parsedDate: Date, format: String, timeZone: TimeZone) -> Date {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let now = Date()

        let hasYear = format.contains("yyyy")
        let hasMonth = format.contains("MMM")
        let hasTime = format.contains("h") || format.contains("H")

        if hasYear {
            return parsedDate
        }

        if hasMonth && hasTime {
            var components = calendar.dateComponents([.month, .day, .hour, .minute, .second], from: parsedDate)
            components.year = calendar.component(.year, from: now)
            if let candidate = calendar.date(from: components), candidate > now {
                return candidate
            }
            components.year = calendar.component(.year, from: now) + 1
            return calendar.date(from: components) ?? parsedDate
        }

        if hasMonth {
            var components = calendar.dateComponents([.month, .day], from: parsedDate)
            components.hour = 0
            components.minute = 0
            components.second = 0
            components.year = calendar.component(.year, from: now)
            if let candidate = calendar.date(from: components), candidate > now {
                return candidate
            }
            components.year = calendar.component(.year, from: now) + 1
            return calendar.date(from: components) ?? parsedDate
        }

        if hasTime {
            let parsedComponents = calendar.dateComponents([.hour, .minute, .second], from: parsedDate)
            var todayComponents = calendar.dateComponents([.year, .month, .day], from: now)
            todayComponents.hour = parsedComponents.hour
            todayComponents.minute = parsedComponents.minute
            todayComponents.second = parsedComponents.second
            if let candidate = calendar.date(from: todayComponents), candidate > now {
                return candidate
            }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) {
                todayComponents = calendar.dateComponents([.year, .month, .day], from: tomorrow)
                todayComponents.hour = parsedComponents.hour
                todayComponents.minute = parsedComponents.minute
                todayComponents.second = parsedComponents.second
                return calendar.date(from: todayComponents) ?? parsedDate
            }
        }

        return parsedDate
    }

    // MARK: - Error Detection

    private func extractUsageError(_ text: String) -> ProbeError? {
        let lower = text.lowercased()

        if (lower.contains("do you trust the files in this folder?") ||
            lower.contains("is this a project you created or one you trust")),
           !lower.contains("current session") {
            AppLog.probes.error("Claude probe blocked: folder trust required")
            return .folderTrustRequired
        }

        if lower.contains("token_expired") || lower.contains("token has expired") {
            return .authenticationRequired
        }
        if lower.contains("authentication_error") {
            return .authenticationRequired
        }
        if lower.contains("not logged in") || lower.contains("please log in") {
            return .authenticationRequired
        }
        if lower.contains("update required") || lower.contains("please update") {
            return .updateRequired
        }
        if lower.contains("/usage is only available for subscription plans") {
            return .subscriptionRequired
        }

        let isRateLimitError = (lower.contains("rate limited") ||
                                lower.contains("rate limit exceeded") ||
                                lower.contains("too many requests")) &&
                               !lower.contains("rate limits are")
        if isRateLimitError {
            return .executionFailed("Rate limited - too many requests")
        }

        return nil
    }

    // MARK: - Helpers

    /// Writes a trust entry for the given directory to ~/.claude.json so the CLI
    /// won't show the workspace trust dialog on next invocation.
    private func writeClaudeTrust(for directory: URL) -> Bool {
        let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        let claudeJsonURL = (configDir ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent(".claude.json")

        guard FileManager.default.fileExists(atPath: claudeJsonURL.path) else {
            AppLog.probes.warning("\(claudeJsonURL.path) not found, cannot write trust")
            return false
        }

        var root: [String: Any]
        if let data = try? Data(contentsOf: claudeJsonURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = json
        } else {
            AppLog.probes.warning("\(claudeJsonURL.path) is not valid JSON, cannot write trust")
            return false
        }

        if let existing = root["projects"], !(existing is [String: Any]) {
            return false
        }
        var projects = root["projects"] as? [String: Any] ?? [:]
        let key = directory.path

        if let existingEntry = projects[key], !(existingEntry is [String: Any]) {
            return false
        }
        var entry = projects[key] as? [String: Any] ?? [:]

        // The current Claude CLI gates the folder prompt on
        // `hasCompletedProjectOnboarding`, not `hasTrustDialogAccepted`. Set both.
        // Bail (no rewrite → no retry loop) only when both are already set.
        if entry["hasCompletedProjectOnboarding"] as? Bool == true,
           entry["hasTrustDialogAccepted"] as? Bool == true {
            return false
        }

        entry["hasTrustDialogAccepted"] = true
        entry["hasCompletedProjectOnboarding"] = true
        if entry["projectOnboardingSeenCount"] == nil {
            entry["projectOnboardingSeenCount"] = 1
        }
        projects[key] = entry
        root["projects"] = projects

        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: claudeJsonURL, options: .atomic)
            AppLog.probes.info("Wrote trust for \(key)")
            return true
        } catch {
            AppLog.probes.error("Failed to write trust: \(error.localizedDescription)")
            return false
        }
    }

    /// Mirrors the Keychain OAuth token into `~/.claude/.credentials.json`.
    ///
    /// The credentials file takes precedence over the Keychain when claude picks
    /// an auth source, so seeding it lets the sandbox-isolated helper's claude
    /// authenticate without needing interactive Keychain access. Best-effort: only
    /// overwrites when the `security` CLI returns a valid JSON token. claude writes
    /// refreshed tokens back to the Keychain, so re-mirroring each probe keeps the
    /// file from going stale.
    private func syncClaudeCredentialsFile() {
        let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        let credURL = home.appendingPathComponent(".credentials.json")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  // Sanity-check it's the expected token JSON before writing.
                  (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) != nil,
                  raw.contains("claudeAiOauth") || raw.contains("accessToken") else {
                AppLog.probes.debug("Keychain credential mirror skipped (no valid token read)")
                return
            }
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try Data(raw.utf8).write(to: credURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credURL.path)
            AppLog.probes.info("Mirrored Keychain credentials to \(credURL.path)")
        } catch {
            AppLog.probes.debug("Keychain credential mirror failed: \(error.localizedDescription)")
        }
    }

    private func probeWorkingDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let dir = base
            .appendingPathComponent("BoringNotch", isDirectory: true)
            .appendingPathComponent("UsageProbe", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
