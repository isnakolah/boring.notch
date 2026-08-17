import XCTest
@testable import IntelligenceCore
@testable import IntelligenceProviders

/// Exercises the real `agy` binary: boots a language-server host, submits through
/// `agentapi`, and reads the reply out of the conversation's JSONL log.
///
/// Skipped unless `AGY_LIVE=1`, because it spends model quota and needs a signed-in
/// CLI. Run it after touching anything in the transport stack:
///
///     AGY_LIVE=1 swift test --filter AgyLiveTests
final class AgyLiveTests: XCTestCase {
    private func requireLive() throws -> String {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AGY_LIVE"] == "1",
            "set AGY_LIVE=1 to run tests that call the real agy"
        )
        return try XCTUnwrap(AgyLocator.locate(), "agy is not installed")
    }

    private func scratch(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agy-live-\(name)-\(UUID().uuidString)")
    }

    private let task = IntelligenceTask(
        id: "copilot.suggest",
        defaultTier: .balanced,
        contract: .sentinelJSON(keys: ["headline", "angles"], marker: "<<<CALLA_END>>>"),
        latencyBudget: 30,
        conversation: .perSession,
        batching: .manual,
        allowedProviders: [.localAgy]
    )

    func testHostBootsAndAnnouncesAnEndpoint() async throws {
        let binary = try requireLive()
        let workspace = scratch("host")
        let host = AgyHost(configuration: .init(binary: binary, workspace: workspace))
        defer { Task { await host.stop() } }

        let started = Date()
        let endpoint = try await host.ensureRunning()
        let boot = Date().timeIntervalSince(started)

        XCTAssertTrue(endpoint.address.hasPrefix("127.0.0.1:"))
        XCTAssertLessThan(boot, 20, "boot: \(boot)s")
        print("[live] host boot \(String(format: "%.2f", boot))s at \(endpoint.address)")

        // The host must be idle: no prompt, so no model call and no quota spent.
        let conversations = URL(
            fileURLWithPath: NSString(string: "~/.gemini/antigravity-cli/conversations").expandingTildeInPath
        )
        let before = (try? FileManager.default.contentsOfDirectory(atPath: conversations.path))?.count ?? 0
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let after = (try? FileManager.default.contentsOfDirectory(atPath: conversations.path))?.count ?? 0
        XCTAssertEqual(before, after, "an idle host must not start conversations")
    }

    /// The measurement the whole design rests on: a suggestion in ~1.6s rather
    /// than the ~8.5s a fresh `agy -p` costs.
    func testFastPathAnswersWithinTheLatencyBudget() async throws {
        _ = try requireLive()
        let provider = AgyProvider(configuration: .init(runtimeRoot: scratch("provider")))
        defer { Task { await provider.shutdown() } }

        await provider.prewarm()

        let system = PromptBlocks(
            base: "You advise the user during a live call. Be concrete and brief.",
            role: "Sales call. Surface the next thing worth saying."
        )

        // Pay the handshake and the bootstrap while the call is still greetings.
        let startedOpen = Date()
        let opened = await provider.openSession(task: task, sessionKey: "live-call-1", system: system)
        print("[live] openSession \(String(format: "%.2f", Date().timeIntervalSince(startedOpen)))s opened=\(opened)")
        XCTAssertTrue(opened)

        let first = IntelligenceRequest(
            task: task,
            sessionKey: "live-call-1",
            system: system,
            input: "Them: what does your SLA actually guarantee?"
        )

        let startedFirst = Date()
        let firstResponse = try await provider.respond(to: first)
        let firstLatency = Date().timeIntervalSince(startedFirst)
        XCTAssertNotNil(firstResponse.payload, "the contract must be honoured, not approximated")
        print("[live] first real reply \(String(format: "%.2f", firstLatency))s")
        // The point of openSession: the opening suggestion is a plain append, not
        // a ~10.7s handshake-plus-bootstrap.
        XCTAssertLessThan(firstLatency, 6, "first suggestion took \(firstLatency)s")

        let second = IntelligenceRequest(
            task: task,
            sessionKey: "live-call-1",
            system: system,
            input: "Them: and what happens if you miss it two months running?"
        )
        let startedSecond = Date()
        let secondResponse = try await provider.respond(to: second)
        let secondLatency = Date().timeIntervalSince(startedSecond)
        print("[live] appended reply \(String(format: "%.2f", secondLatency))s")

        XCTAssertNotNil(secondResponse.payload)
        // The gate from the plan: anything slower means it has silently degraded
        // to the print transport, which defeats the point.
        XCTAssertLessThan(secondLatency, 6, "appended reply took \(secondLatency)s")
        XCTAssertEqual(secondResponse.attribution.provider, .localAgy)

        await provider.closeSession("live-call-1")
    }
}
