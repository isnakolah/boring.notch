import XCTest
@testable import IntelligenceCore
@testable import IntelligenceProviders

/// A transport that records what it was asked, so the provider's own rules —
/// bootstrap once, delta after, roll over before the context slows answers down,
/// fall back to the slow transport when the host dies — can be checked without
/// launching `agy`.
final class RecordingTransport: AgyTransport, @unchecked Sendable {
    struct Call {
        let prompt: String
        let conversationID: String?
        let tier: ModelTier
        let exactModel: String?
    }

    private(set) var calls: [Call] = []
    var reply: String
    var failOpen: IntelligenceFailure?
    var failSend: IntelligenceFailure?
    private var counter = 0

    init(reply: String = #"{"headline": "ok", "angles": []}"# + "\n<<<CALLA_END>>>") {
        self.reply = reply
    }

    func open(
        prompt: String, tier: ModelTier, exactModel: String?, title: String, budget: TimeInterval
    ) async throws -> AgyExchange {
        calls.append(Call(prompt: prompt, conversationID: nil, tier: tier, exactModel: exactModel))
        if let failOpen { throw failOpen }
        counter += 1
        return AgyExchange(conversationID: "conv-\(counter)", text: reply, model: "fake")
    }

    func send(
        prompt: String, conversationID: String, tier: ModelTier, exactModel: String?, budget: TimeInterval
    ) async throws -> AgyExchange {
        calls.append(Call(prompt: prompt, conversationID: conversationID, tier: tier, exactModel: exactModel))
        if let failSend { throw failSend }
        return AgyExchange(conversationID: conversationID, text: reply, model: "fake")
    }
}

final class AgyProviderTests: XCTestCase {
    private let task = IntelligenceTask(
        id: "copilot.suggest",
        defaultTier: .balanced,
        contract: .sentinelJSON(keys: ["headline", "angles"], marker: "<<<CALLA_END>>>"),
        latencyBudget: 6,
        conversation: .perSession,
        batching: .manual,
        allowedProviders: [.localAgy]
    )

    private func makeProvider(
        fast: RecordingTransport,
        slow: RecordingTransport,
        rolloverBudget: Int = 45_000
    ) -> AgyProvider {
        AgyProvider(
            configuration: .init(
                runtimeRoot: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agy-tests"),
                rolloverTokenBudget: rolloverBudget,
                providerOverheadTokens: 15_000,
                briefExchanges: 2
            ),
            binary: "/usr/bin/true",
            transports: (fast: fast, slow: slow)
        )
    }

    private func request(_ input: String, session: String = "call-1") -> IntelligenceRequest {
        IntelligenceRequest(
            task: task,
            sessionKey: session,
            system: .init(base: "BASE", role: "ROLE"),
            input: input
        )
    }

    func testGuidanceIsSentOnceThenOnlyDeltas() async throws {
        let fast = RecordingTransport()
        let provider = makeProvider(fast: fast, slow: RecordingTransport())

        _ = try await provider.respond(to: request("Them: first"))
        _ = try await provider.respond(to: request("Them: second"))
        _ = try await provider.respond(to: request("Them: third"))

        XCTAssertEqual(fast.calls.count, 3)
        XCTAssertTrue(fast.calls[0].prompt.contains("BASE"), "bootstrap carries guidance")
        XCTAssertNil(fast.calls[0].conversationID)
        XCTAssertEqual(fast.calls[1].prompt, "Them: second", "later turns carry only what is new")
        XCTAssertEqual(fast.calls[2].prompt, "Them: third")
        XCTAssertEqual(fast.calls[1].conversationID, "conv-1", "one conversation, appended to")
    }

    func testContractIsParsedIntoAPayload() async throws {
        let fast = RecordingTransport(
            reply: "Here you go:\n{\"headline\": \"Ask for the SLA\", \"angles\": [\"uptime\"]}\n<<<CALLA_END>>>"
        )
        let provider = makeProvider(fast: fast, slow: RecordingTransport())

        let response = try await provider.respond(to: request("Them: hi"))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(response.payload)) as? [String: Any]
        )
        XCTAssertEqual(object["headline"] as? String, "Ask for the SLA")
        XCTAssertEqual(response.attribution.provider, .localAgy)
    }

    func testUnparseableReplyIsReportedNotPassedThrough() async {
        let fast = RecordingTransport(reply: "I could not think of anything.")
        let provider = makeProvider(fast: fast, slow: RecordingTransport())

        do {
            _ = try await provider.respond(to: request("Them: hi"))
            XCTFail("a reply that misses the contract must not reach the UI")
        } catch let failure as IntelligenceFailure {
            guard case .unparseable = failure else {
                return XCTFail("expected .unparseable, got \(failure)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// A host swap cannot carry a conversation over (verified against the real
    /// CLI), so a dead host must restart on the slow transport with a fresh
    /// conversation seeded from the brief — not lose the call's context.
    func testHostDeathFallsBackToSlowTransportAndReseeds() async throws {
        let fast = RecordingTransport()
        let slow = RecordingTransport()
        let provider = makeProvider(fast: fast, slow: slow)

        _ = try await provider.respond(to: request("Them: first"))
        fast.failSend = .sessionDied("connection reset")

        let response = try await provider.respond(to: request("Them: second"))
        XCTAssertEqual(slow.calls.count, 1)
        XCTAssertNil(slow.calls[0].conversationID, "the old conversation is gone with the host")
        XCTAssertTrue(slow.calls[0].prompt.contains("BASE"), "so guidance is re-sent")
        XCTAssertTrue(
            slow.calls[0].prompt.contains("Earlier in this session"),
            "and the call's context is carried forward"
        )
        XCTAssertEqual(response.attribution.provider, .localAgy)
    }

    func testRolloverStartsAFreshConversationWithABrief() async throws {
        let fast = RecordingTransport()
        // Small budget so the second request trips it.
        let provider = makeProvider(fast: fast, slow: RecordingTransport(), rolloverBudget: 15_100)

        _ = try await provider.respond(to: request("Them: first"))
        let second = try await provider.respond(to: request("Them: second"))

        XCTAssertNil(fast.calls[1].conversationID, "rolled over instead of growing context")
        XCTAssertTrue(fast.calls[1].prompt.contains("Earlier in this session"))
        XCTAssertEqual(second.attribution.rollovers, 1, "and it is visible, not silent")
    }

    func testUsageIsEstimatedWhenTheFastPathReportsNone() async throws {
        let provider = makeProvider(fast: RecordingTransport(), slow: RecordingTransport())
        let response = try await provider.respond(to: request("Them: hi"))
        let usage = try XCTUnwrap(response.usage)
        XCTAssertTrue(usage.estimated, "agentapi reports no tokens; say so rather than implying precision")
        XCTAssertGreaterThan(usage.inputTokens ?? 0, 15_000, "the provider's own preamble is charged too")
    }

    func testPerSessionTaskWithoutASessionKeyIsRejected() async {
        let provider = makeProvider(fast: RecordingTransport(), slow: RecordingTransport())
        let request = IntelligenceRequest(task: task, sessionKey: nil, input: "x")
        do {
            _ = try await provider.respond(to: request)
            XCTFail("a per-session task without a key must not silently share one")
        } catch let failure as IntelligenceFailure {
            guard case .missingSessionKey = failure else {
                return XCTFail("expected .missingSessionKey, got \(failure)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testOneShotTaskNeverReusesAConversation() async throws {
        let fast = RecordingTransport()
        let provider = makeProvider(fast: fast, slow: RecordingTransport())
        let oneShot = IntelligenceTask(
            id: "one.shot",
            defaultTier: .fast,
            contract: .freeform,
            latencyBudget: 5,
            conversation: .oneShot,
            batching: .manual,
            allowedProviders: [.localAgy]
        )

        _ = try await provider.respond(to: .init(task: oneShot, input: "a"))
        _ = try await provider.respond(to: .init(task: oneShot, input: "b"))
        XCTAssertEqual(fast.calls.compactMap(\.conversationID).count, 0)
    }

    func testMissingBinaryReportsUnavailableRatherThanFailingLater() async {
        let provider = AgyProvider(
            configuration: .init(runtimeRoot: URL(fileURLWithPath: NSTemporaryDirectory())),
            binary: nil
        )
        let availability = await provider.availability()
        XCTAssertEqual(availability, .missing)
        XCTAssertFalse(availability.isReady)
    }

    func testTokenEstimateTracksLength() {
        XCTAssertEqual(AgyProvider.estimateTokens(String(repeating: "x", count: 400)), 100)
        XCTAssertEqual(AgyProvider.estimateTokens(""), 1)
    }

    func testTutorJPEGUsesPrivateAtReferenceWithoutBase64OrFileURL() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agy-tutor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fast = RecordingTransport()
        let slow = RecordingTransport(reply: #"{"message":"Check lamp position","assessment":"needs_help","basis":"screenshot"}"#)
        let provider = AgyProvider(
            configuration: .init(runtimeRoot: root),
            binary: "/usr/bin/true",
            transports: (fast: fast, slow: slow)
        )
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0xFF, 0xD9])
        let request = IntelligenceRequest(
            task: .tutorFeedback,
            sessionKey: "run-1",
            system: .init(base: "Return Tutor JSON."),
            input: "Why did this fail?",
            attachments: [.init(
                identifier: "capture-1",
                mimeType: "image/jpeg",
                bytes: jpeg,
                pixelWidth: 2,
                pixelHeight: 2,
                purpose: "target-window"
            )]
        )

        let response = try await provider.respond(to: request)
        XCTAssertTrue(response.text.contains("Check lamp position"))
        XCTAssertTrue(fast.calls.isEmpty, "Tutor images never reach resident transport")
        let prompt = try XCTUnwrap(slow.calls.first?.prompt)
        XCTAssertTrue(prompt.contains("@capture-"))
        XCTAssertFalse(prompt.contains("file://"))
        XCTAssertFalse(prompt.contains(jpeg.base64EncodedString()))
        XCTAssertFalse(prompt.contains("/agy/print/capture-"))
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("agy/print"),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(leftovers.contains { $0.lastPathComponent.hasPrefix("capture-") })
    }

    func testTutorAttachmentArgumentsRemainPrintOnlyAndSandboxed() {
        let arguments = AgyPrintTransport.tutorAttachmentArguments(
            prompt: "Inspect @capture-12345678-1234-1234-1234-123456789abc.jpg",
            model: "gemini-3.7-flash-low"
        )
        XCTAssertEqual(arguments.first, "--print")
        XCTAssertTrue(arguments.contains("--sandbox"))
        XCTAssertTrue(arguments.contains("--mode"))
        XCTAssertTrue(arguments.contains("plan"))
        XCTAssertTrue(arguments.contains("--disable-slash-commands"))
        XCTAssertFalse(arguments.contains("--add-dir"))
        XCTAssertFalse(arguments.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(arguments.joined(separator: " ").contains("file://"))
        XCTAssertFalse(arguments.joined(separator: " ").contains("base64"))
    }

    func testTutorJPEGStagingUsesPrivateModesAndRejectsNonJPEG() throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agy-stage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let stager = AgyAttachmentStager(workspace: workspace)
        let jpeg = IntelligenceAttachment(
            identifier: "capture-1", mimeType: "image/jpeg",
            bytes: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            pixelWidth: 1, pixelHeight: 1, purpose: "target-window"
        )
        let staged = try stager.stageTutorJPEG(jpeg)
        let workspaceMode = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: workspace.path)[.posixPermissions] as? NSNumber)?.intValue
        )
        let fileMode = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: staged.path)[.posixPermissions] as? NSNumber)?.intValue
        )
        XCTAssertEqual(workspaceMode & 0o777, 0o700)
        XCTAssertEqual(fileMode & 0o777, 0o600)
        XCTAssertThrowsError(try stager.stageTutorJPEG(.init(
            identifier: "not-jpeg", mimeType: "image/png", bytes: Data([0x89, 0x50]),
            pixelWidth: 1, pixelHeight: 1, purpose: "target-window"
        )))
        stager.cleanup(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }
}
