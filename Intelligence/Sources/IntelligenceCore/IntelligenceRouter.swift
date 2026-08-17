import Foundation

/// Picks a provider, enforces the latency budget, retries once, falls back, and
/// reports which brain actually answered.
///
/// Also the single-flight gate: a live call produces input faster than any model
/// answers, so inputs that arrive mid-request accumulate and go out as one
/// request rather than queueing up a backlog of stale ones.
public actor IntelligenceRouter {
    /// Runtime preferences, passed in. Core never reads Defaults.
    public struct Policy: Sendable {
        /// Force a provider for a task id, overriding the task's own order.
        public var preferred: [String: ProviderKind]
        /// When false, only the first candidate is ever tried.
        public var fallbackEnabled: Bool
        /// Override `task.defaultTier` per task id.
        public var tiers: [String: ModelTier]
        /// Exact model id per task id, for transports that honour one.
        public var exactModels: [String: String]

        public init(
            preferred: [String: ProviderKind] = [:],
            fallbackEnabled: Bool = true,
            tiers: [String: ModelTier] = [:],
            exactModels: [String: String] = [:]
        ) {
            self.preferred = preferred
            self.fallbackEnabled = fallbackEnabled
            self.tiers = tiers
            self.exactModels = exactModels
        }
    }

    private let providers: [ProviderKind: any IntelligenceProvider]
    private var policy: Policy
    /// Providers that failed in a way retrying cannot fix (missing binary, no
    /// auth, quota gone). Skipped for the rest of the session.
    private var disabled: Set<ProviderKind> = []

    private var inFlight: Set<String> = []
    private var pending: [String: [IntelligenceRequest]] = [:]

    private var onResponse: (@Sendable (IntelligenceResponse) -> Void)?
    private var onFailure: (@Sendable (IntelligenceFailure) -> Void)?

    public init(providers: [any IntelligenceProvider], policy: Policy = .init()) {
        var map: [ProviderKind: any IntelligenceProvider] = [:]
        for provider in providers { map[provider.kind] = provider }
        self.providers = map
        self.policy = policy
    }

    public func setPolicy(_ policy: Policy) {
        self.policy = policy
    }

    public func setHandlers(
        onResponse: @escaping @Sendable (IntelligenceResponse) -> Void,
        onFailure: @escaping @Sendable (IntelligenceFailure) -> Void
    ) {
        self.onResponse = onResponse
        self.onFailure = onFailure
    }

    /// Re-enable providers after, say, a host restart or a new call.
    public func resetDisabledProviders() {
        disabled.removeAll()
    }

    // MARK: - Push path

    /// Fire-and-forget. Coalesces per session and delivers through the handlers.
    public func enqueue(_ request: IntelligenceRequest) {
        let key = request.sessionKey ?? request.task.id
        guard !inFlight.contains(key) else {
            pending[key, default: []].append(request)
            return
        }
        inFlight.insert(key)
        Task { await self.run(request, key: key) }
    }

    private func run(_ request: IntelligenceRequest, key: String) async {
        do {
            let response = try await respond(to: request)
            onResponse?(response)
        } catch let failure as IntelligenceFailure {
            onFailure?(failure)
        } catch {
            onFailure?(.transport(String(describing: error)))
        }
        finish(key: key)
    }

    private func finish(key: String) {
        inFlight.remove(key)
        guard let queued = pending.removeValue(forKey: key), !queued.isEmpty else { return }
        // Everything that arrived while we were waiting becomes one request.
        let merged = IntelligenceRequest(
            task: queued[0].task,
            sessionKey: queued[0].sessionKey,
            system: queued[0].system,
            input: queued.map(\.input).joined(separator: "\n"),
            tier: queued[0].tier,
            exactModel: queued[0].exactModel
        )
        enqueue(merged)
    }

    /// How many inputs are waiting behind the in-flight request. For diagnostics
    /// and the segmentation-ratio log.
    public func pendingCount(for sessionKey: String) -> Int {
        pending[sessionKey]?.count ?? 0
    }

    // MARK: - Await path

    /// Routes, times out, retries once, falls back. Throws `IntelligenceFailure`
    /// from the last provider tried.
    public func respond(to request: IntelligenceRequest) async throws -> IntelligenceResponse {
        let effective = applyPolicy(to: request)
        let candidates = await resolveCandidates(for: effective.task)
        guard !candidates.isEmpty else {
            throw IntelligenceFailure.providerMissing(
                "no available provider for \(effective.task.id)"
            )
        }

        var lastFailure: IntelligenceFailure = .providerMissing(effective.task.id)

        for (index, kind) in candidates.enumerated() {
            guard let provider = providers[kind] else { continue }
            let fellBack = index > 0
            // One retry in place, but only for failures a retry can fix.
            for attempt in 0 ... 1 {
                do {
                    let started = Date()
                    var response = try await withBudget(effective.task.latencyBudget) {
                        try await provider.respond(to: effective)
                    }
                    response = IntelligenceResponse(
                        text: response.text,
                        payload: response.payload,
                        attribution: Attribution(
                            provider: kind,
                            model: response.attribution.model,
                            latency: Date().timeIntervalSince(started),
                            fellBack: fellBack || response.attribution.fellBack,
                            rollovers: response.attribution.rollovers
                        ),
                        usage: response.usage
                    )
                    return response
                } catch let failure as IntelligenceFailure {
                    lastFailure = failure
                    if failure.disablesProvider { disabled.insert(kind) }
                    if attempt == 0, failure.isRetryableInPlace, !failure.disablesProvider { continue }
                    break
                } catch {
                    lastFailure = .transport(String(describing: error))
                    break
                }
            }
        }
        throw lastFailure
    }

    // MARK: - Routing

    private func applyPolicy(to request: IntelligenceRequest) -> IntelligenceRequest {
        let tier = request.tier ?? policy.tiers[request.task.id]
        let exact = request.exactModel ?? policy.exactModels[request.task.id]
        guard tier != request.tier || exact != request.exactModel else { return request }
        return IntelligenceRequest(
            task: request.task,
            sessionKey: request.sessionKey,
            system: request.system,
            input: request.input,
            tier: tier,
            exactModel: exact
        )
    }

    private func resolveCandidates(for task: IntelligenceTask) async -> [ProviderKind] {
        var ordered = task.allowedProviders
        if let forced = policy.preferred[task.id] {
            ordered = [forced] + ordered.filter { $0 != forced }
        }
        if !policy.fallbackEnabled {
            ordered = Array(ordered.prefix(1))
        }

        var usable: [ProviderKind] = []
        for kind in ordered {
            guard !disabled.contains(kind), let provider = providers[kind] else { continue }
            guard provider.supports(task) else { continue }
            guard await provider.availability().isReady else { continue }
            usable.append(kind)
        }
        return usable
    }

    // MARK: - Budget

    /// Races the work against the task's budget. A model that answers after the
    /// moment has passed is worse than no answer, because the caller is still
    /// blocked waiting for it.
    private func withBudget<T: Sendable>(
        _ budget: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard budget > 0 else { return try await operation() }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                throw IntelligenceFailure.timedOut(budget)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw IntelligenceFailure.timedOut(budget)
            }
            return result
        }
    }
}
