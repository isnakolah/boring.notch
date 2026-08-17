import XCTest
@testable import IntelligenceCore

/// A stand-in brain. Everything the router decides — gating, ordering, retrying,
/// timing out, coalescing — is decided from these knobs, so none of it needs a
/// real model.
actor FakeProvider: IntelligenceProvider {
    nonisolated let kind: ProviderKind
    private var availabilityValue: Availability
    private nonisolated let supported: @Sendable (IntelligenceTask) -> Bool
    private var failures: [IntelligenceFailure]
    private let delay: TimeInterval
    private let reply: String
    private(set) var callCount = 0
    private(set) var inputs: [String] = []

    init(
        kind: ProviderKind,
        availability: Availability = .ready(version: "test"),
        supports: @escaping @Sendable (IntelligenceTask) -> Bool = { _ in true },
        failures: [IntelligenceFailure] = [],
        delay: TimeInterval = 0,
        reply: String = "ok"
    ) {
        self.kind = kind
        availabilityValue = availability
        supported = supports
        self.failures = failures
        self.delay = delay
        self.reply = reply
    }

    nonisolated func supports(_ task: IntelligenceTask) -> Bool { supported(task) }
    func availability() async -> Availability { availabilityValue }
    func closeSession(_ sessionKey: String) async {}

    func respond(to request: IntelligenceRequest) async throws -> IntelligenceResponse {
        callCount += 1
        inputs.append(request.input)
        if !failures.isEmpty { throw failures.removeFirst() }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return IntelligenceResponse(
            text: reply,
            payload: nil,
            attribution: Attribution(provider: kind, model: "fake", latency: delay)
        )
    }
}

final class IntelligenceRouterTests: XCTestCase {
    private func task(
        id: String = "test.task",
        budget: TimeInterval = 1,
        providers: [ProviderKind] = [.localAgy, .callaGateway],
        conversation: ConversationPolicy = .perSession
    ) -> IntelligenceTask {
        IntelligenceTask(
            id: id,
            defaultTier: .fast,
            contract: .freeform,
            latencyBudget: budget,
            conversation: conversation,
            batching: .manual,
            allowedProviders: providers
        )
    }

    private func request(_ task: IntelligenceTask, input: String = "hello") -> IntelligenceRequest {
        IntelligenceRequest(task: task, sessionKey: "call-1", input: input)
    }

    func testPrefersTheFirstAllowedProvider() async throws {
        let local = FakeProvider(kind: .localAgy, reply: "local")
        let gateway = FakeProvider(kind: .callaGateway, reply: "gateway")
        let router = IntelligenceRouter(providers: [local, gateway])

        let response = try await router.respond(to: request(task()))
        XCTAssertEqual(response.text, "local")
        XCTAssertEqual(response.attribution.provider, .localAgy)
        XCTAssertFalse(response.attribution.fellBack)
        XCTAssertEqualAsync(await gateway.callCount, 0)
    }

    func testFallsBackAndMarksAttribution() async throws {
        let local = FakeProvider(kind: .localAgy, failures: [.quotaExceeded("429")])
        let gateway = FakeProvider(kind: .callaGateway, reply: "gateway")
        let router = IntelligenceRouter(providers: [local, gateway])

        let response = try await router.respond(to: request(task()))
        XCTAssertEqual(response.attribution.provider, .callaGateway)
        XCTAssertTrue(response.attribution.fellBack, "a silent failover is a bug")
    }

    func testRetriesInPlaceOnceForRecoverableFailures() async throws {
        let local = FakeProvider(kind: .localAgy, failures: [.transport("blip")], reply: "local")
        let router = IntelligenceRouter(providers: [local])

        let response = try await router.respond(to: request(task()))
        XCTAssertEqual(response.text, "local")
        XCTAssertEqualAsync(await local.callCount, 2)
    }

    func testDoesNotRetryFailuresARetryCannotFix() async {
        let local = FakeProvider(kind: .localAgy, failures: [.providerMissing("no binary")])
        let router = IntelligenceRouter(providers: [local])

        _ = try? await router.respond(to: request(task(providers: [.localAgy])))
        XCTAssertEqualAsync(await local.callCount, 1)
    }

    func testDisabledProviderIsSkippedOnLaterRequests() async throws {
        let local = FakeProvider(
            kind: .localAgy,
            failures: [.unauthenticated("not logged in")],
            reply: "local"
        )
        let gateway = FakeProvider(kind: .callaGateway, reply: "gateway")
        let router = IntelligenceRouter(providers: [local, gateway])

        _ = try await router.respond(to: request(task()))
        _ = try await router.respond(to: request(task()))
        XCTAssertEqualAsync(await local.callCount, 1, "one strike, then skipped")
        XCTAssertEqualAsync(await gateway.callCount, 2)
    }

    func testUnavailableProviderIsNeverAsked() async throws {
        let local = FakeProvider(kind: .localAgy, availability: .missing)
        let gateway = FakeProvider(kind: .callaGateway, reply: "gateway")
        let router = IntelligenceRouter(providers: [local, gateway])

        let response = try await router.respond(to: request(task()))
        XCTAssertEqual(response.attribution.provider, .callaGateway)
        XCTAssertEqualAsync(await local.callCount, 0)
    }

    func testProviderThatDoesNotSupportTheTaskIsSkipped() async throws {
        let gateway = FakeProvider(kind: .callaGateway, supports: { $0.id != "copilot.summary" })
        let local = FakeProvider(kind: .localAgy, reply: "local")
        let router = IntelligenceRouter(providers: [gateway, local])

        let summary = task(id: "copilot.summary", providers: [.callaGateway, .localAgy])
        let response = try await router.respond(to: request(summary))
        XCTAssertEqual(response.attribution.provider, .localAgy)
    }

    func testBudgetIsEnforced() async {
        let slow = FakeProvider(kind: .localAgy, delay: 5)
        let router = IntelligenceRouter(providers: [slow])

        do {
            _ = try await router.respond(to: request(task(budget: 0.2, providers: [.localAgy])))
            XCTFail("a late answer is worse than none: it blocks the caller")
        } catch let failure as IntelligenceFailure {
            guard case .timedOut = failure else {
                return XCTFail("expected .timedOut, got \(failure)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testFallbackCanBeDisabled() async {
        let local = FakeProvider(kind: .localAgy, failures: [.quotaExceeded("429")])
        let gateway = FakeProvider(kind: .callaGateway, reply: "gateway")
        let router = IntelligenceRouter(
            providers: [local, gateway],
            policy: .init(fallbackEnabled: false)
        )

        _ = try? await router.respond(to: request(task()))
        XCTAssertEqualAsync(await gateway.callCount, 0)
    }

    func testPolicyCanForceAProvider() async throws {
        let local = FakeProvider(kind: .localAgy, reply: "local")
        let gateway = FakeProvider(kind: .callaGateway, reply: "gateway")
        let router = IntelligenceRouter(
            providers: [local, gateway],
            policy: .init(preferred: ["test.task": .callaGateway])
        )

        let response = try await router.respond(to: request(task()))
        XCTAssertEqual(response.attribution.provider, .callaGateway)
    }

    func testMissingSessionKeyIsReportedNotGuessed() async {
        let local = FakeProvider(kind: .localAgy)
        let router = IntelligenceRouter(providers: [local])
        let request = IntelligenceRequest(task: task(providers: [.localAgy]), sessionKey: nil, input: "x")
        // The provider owns this rule; the router must surface it rather than
        // inventing a key.
        _ = try? await router.respond(to: request)
        XCTAssertEqualAsync(await local.callCount, 1)
    }

    /// A live call outruns any model. Inputs that arrive mid-request must become
    /// one follow-up request, not a backlog of stale ones.
    func testEnqueueCoalescesInputsArrivingDuringARequest() async throws {
        let local = FakeProvider(kind: .localAgy, delay: 0.3, reply: "local")
        let router = IntelligenceRouter(providers: [local])
        let task = task(budget: 5, providers: [.localAgy])

        let received = Counter()
        await router.setHandlers(
            onResponse: { _ in Task { await received.increment() } },
            onFailure: { _ in }
        )

        await router.enqueue(request(task, input: "first"))
        await router.enqueue(request(task, input: "second"))
        await router.enqueue(request(task, input: "third"))

        try await Task.sleep(nanoseconds: 1_200_000_000)

        let inputs = await local.inputs
        XCTAssertEqual(inputs.count, 2, "one in flight, then one merged follow-up")
        XCTAssertEqual(inputs.first, "first")
        XCTAssertEqual(inputs.last, "second\nthird")
        XCTAssertEqualAsync(await received.value, 2)
    }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// `XCTAssertEqual` cannot await an actor property; this keeps the call sites
/// readable.
func XCTAssertEqualAsync<T: Equatable>(
    _ expression: T,
    _ expected: T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(expression, expected, message, file: file, line: line)
}
