import Foundation
import IntelligenceCore

/// The resident `agy` language server — the entire reason the local provider is
/// fast.
///
/// Every `agy` process pays ~6-8s of serialized Google round-trips before it will
/// answer anything: keyring auth, `ListExperiments`, `loadCodeAssist` ×3,
/// `fetchAvailableModels`. Measured, and no flag skips it. But each process runs
/// its language server **in-process** on two random localhost ports, and
/// `agy agentapi` is a client for that server. So: pay the handshake once by
/// keeping one process alive, then submit through `agentapi` in ~0.06s.
///
/// The host is launched with no prompt, so it makes **zero model calls** and
/// burns no quota while resident (verified: an idle host creates no conversation).
///
/// It runs under `/usr/bin/script` rather than a hand-rolled `openpty` because
/// the TUI opens `/dev/tty`, which needs a controlling terminal, which needs
/// `setsid` — `script` does both, and a GUI app has no tty to inherit. Its output
/// goes to `/dev/null`: nothing here is ever parsed, so there is no ANSI handling
/// anywhere in this provider.
public actor AgyHost {
    public struct Configuration: Sendable {
        /// Absolute path to `agy`.
        public var binary: String
        /// A dedicated, empty directory. No repo, no `AGENTS.md`, no `.agents/`,
        /// no MCP config — the agent should have nothing to reach for.
        public var workspace: URL
        /// How long to wait for the server to announce its port.
        public var startupTimeout: TimeInterval
        /// How long to wait after that for it to finish authenticating and
        /// fetching its model list.
        public var readinessTimeout: TimeInterval
        /// `agy agentapi` needs a project; the CLI's own default is fine and is
        /// created by `agy` itself.
        public var projectID: String

        public init(
            binary: String,
            workspace: URL,
            startupTimeout: TimeInterval = 30,
            readinessTimeout: TimeInterval = 20,
            projectID: String = "default-cli-project"
        ) {
            self.binary = binary
            self.workspace = workspace
            self.startupTimeout = startupTimeout
            self.readinessTimeout = readinessTimeout
            self.projectID = projectID
        }
    }

    public struct Endpoint: Sendable, Hashable {
        public let address: String
        public let projectID: String

        /// Environment additions every `agy agentapi` call needs.
        public var environment: [String: String] {
            ["ANTIGRAVITY_LS_ADDRESS": address, "ANTIGRAVITY_PROJECT_ID": projectID]
        }
    }

    private let configuration: Configuration
    private var process: Process?
    private var endpoint: Endpoint?
    private var isReady = false
    private var logURL: URL { configuration.workspace.appendingPathComponent("ls.log") }

    /// `Language server listening on random port at 57553 for HTTP` — the HTTP
    /// port, not the HTTPS/gRPC one on the line above it, which agentapi rejects
    /// with a TLS preface error.
    private static let portPattern = try! NSRegularExpression(
        pattern: #"listening on random port at (\d+) for HTTP$"#,
        options: [.anchorsMatchLines]
    )

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    /// Boots the server if needed and returns an endpoint that can actually
    /// answer.
    ///
    /// Announcing a port (~0.1s) is not the same as being ready: for the first
    /// second or so the server reports `no available models found`, because it is
    /// still authenticating and fetching its model list. Returning early makes the
    /// first request of a call fail for no reason, so readiness is part of the
    /// contract here (~0.9s measured).
    public func ensureRunning() async throws -> Endpoint {
        if let endpoint, isRunning, isReady { return endpoint }
        if endpoint == nil || !isRunning {
            try await start()
        }
        guard let endpoint else {
            throw IntelligenceFailure.sessionDied("agy host started but announced no endpoint")
        }
        if !isReady {
            try await waitUntilReady(endpoint)
            isReady = true
        }
        return endpoint
    }

    /// A conversation id that cannot exist, for a probe that spends no quota — it
    /// comes back `trajectory not found` once the RPC channel is alive.
    private static let readinessProbeID = "00000000-0000-0000-0000-000000000000"

    /// The line that actually matters. Until the server has fetched its model
    /// list, `new-conversation` fails with `no available models found`, while
    /// cheaper RPCs already succeed — so the RPC probe alone is not enough to
    /// call the host ready. Measured: port at ~0.1s, `Auth succeeded` at ~0.7s,
    /// this at ~4.7s, first successful create at ~4.8s.
    /// Deliberately the RPC URL, not the bare method name: an earlier line reads
    /// `Auth mode is unspecified, skipping fetchAvailableModels`, and matching that
    /// declares the host ready ~4s too early.
    private static let modelsFetchedMarker = "v1internal:fetchAvailableModels"

    private func waitUntilReady(_ endpoint: Endpoint) async throws {
        let deadline = Date().addingTimeInterval(configuration.readinessTimeout)
        var lastOutput = ""

        while Date() < deadline {
            guard process?.isRunning ?? false else {
                throw IntelligenceFailure.sessionDied("agy host exited before becoming ready")
            }
            if hasFetchedModels() {
                // Model list is in; confirm the channel answers before handing the
                // endpoint to a caller with a latency budget.
                if let result = try? await AgyProcessRunner.run(
                    binary: configuration.binary,
                    arguments: ["agentapi", "get-conversation-metadata", Self.readinessProbeID],
                    environment: endpoint.environment,
                    timeout: 5
                ) {
                    lastOutput = result.standardOutput + result.standardError
                    if !Self.isWarming(lastOutput) { return }
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // Only now is a persistent auth complaint actually about auth: the same
        // message appears transiently while the server is still starting up.
        throw AgyProcessRunner.failure(from: lastOutput.isEmpty ? "host never became ready" : lastOutput, status: 0)
    }

    private func hasFetchedModels() -> Bool {
        guard let log = try? String(contentsOf: logURL, encoding: .utf8) else { return false }
        return log.contains(Self.modelsFetchedMarker)
    }

    /// Startup noise, not a verdict. All of these clear on their own.
    static func isWarming(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return lowered.contains("available models")
            || lowered.contains("not logged into")
            || lowered.contains("token source")
            || lowered.contains("unavailable")
            || lowered.contains("connection refused")
            || lowered.contains("connection reset")
    }

    private func start() async throws {
        stop()
        let manager = FileManager.default
        // A fresh workspace each boot: the previous log's port must never be
        // mistaken for this one's.
        try? manager.removeItem(at: configuration.workspace)
        try manager.createDirectory(at: configuration.workspace, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", configuration.binary, "--log-file", logURL.path]
        process.currentDirectoryURL = configuration.workspace
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw IntelligenceFailure.providerMissing("could not launch agy host: \(error)")
        }
        self.process = process

        let deadline = Date().addingTimeInterval(configuration.startupTimeout)
        while Date() < deadline {
            if !process.isRunning {
                throw IntelligenceFailure.sessionDied(
                    "agy host exited during startup (status \(process.terminationStatus))"
                )
            }
            if let port = readPort() {
                endpoint = Endpoint(
                    address: "127.0.0.1:\(port)",
                    projectID: configuration.projectID
                )
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        stop()
        throw IntelligenceFailure.timedOut(configuration.startupTimeout)
    }

    private func readPort() -> String? {
        guard let log = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
        let range = NSRange(log.startIndex ..< log.endIndex, in: log)
        // Last match wins: a relaunch appends to the same file.
        let matches = Self.portPattern.matches(in: log, range: range)
        guard let match = matches.last, let portRange = Range(match.range(at: 1), in: log) else {
            return nil
        }
        return String(log[portRange])
    }

    /// Called when a submit fails: the host is the likeliest casualty.
    public func invalidate() {
        if !(process?.isRunning ?? false) {
            endpoint = nil
            process = nil
            isReady = false
        }
    }

    public func stop() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        endpoint = nil
        isReady = false
    }
}
