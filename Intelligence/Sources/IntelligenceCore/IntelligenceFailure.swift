import Foundation

/// Every way a request can fail, typed, because the router's fallback decision
/// depends on which one it was: a missing binary means skip this provider for
/// the rest of the session, a timeout means try once more.
public enum IntelligenceFailure: Error, Sendable, Hashable {
    /// The provider's binary or endpoint is not installed.
    case providerMissing(String)
    case unauthenticated(String)
    case quotaExceeded(String)
    /// Exceeded the task's latency budget.
    case timedOut(TimeInterval)
    /// The reply arrived but did not satisfy the task's contract.
    case unparseable(String)
    /// A long-lived session died underneath us. Retryable after a restart, but
    /// the conversation is gone — see `AgyProvider`'s rollover seeding.
    case sessionDied(String)
    case unsupportedTask(String)
    /// A `sessionKey` was required by the conversation policy and not supplied.
    case missingSessionKey(String)
    case transport(String)
    case unsupportedAttachment(String)
    case invalidRequest(String)

    public var code: String {
        switch self {
        case .providerMissing: "provider_missing"
        case .unauthenticated: "unauthenticated"
        case .quotaExceeded: "quota_exhausted"
        case .timedOut: "timed_out"
        case .unparseable: "invalid_response_contract"
        case .sessionDied: "dead_session"
        case .unsupportedTask: "unsupported_task"
        case .missingSessionKey: "missing_session_key"
        case .transport: "unreachable_transport"
        case .unsupportedAttachment: "unsupported_image_attachment"
        case .invalidRequest: "invalid_request"
        }
    }

    /// Whether retrying the *same* provider could plausibly help.
    public var isRetryableInPlace: Bool {
        switch self {
        case .timedOut, .unparseable, .transport, .sessionDied: true
        case .providerMissing, .unauthenticated, .quotaExceeded, .unsupportedTask, .missingSessionKey, .unsupportedAttachment, .invalidRequest: false
        }
    }

    /// Whether this provider should be skipped for the rest of the session
    /// rather than retried on the next request.
    public var disablesProvider: Bool {
        switch self {
        case .providerMissing, .unauthenticated, .quotaExceeded: true
        default: false
        }
    }

    /// Only failures caused after local route selection may cross from local
    /// Tutor feedback to Gateway. Storage, capture and request validation live
    /// above Router and must never call this path.
    public var isEligibleTutorProviderFallback: Bool {
        switch self {
        case .providerMissing, .unauthenticated, .quotaExceeded, .timedOut, .unparseable, .sessionDied, .transport, .unsupportedAttachment:
            true
        case .unsupportedTask, .missingSessionKey, .invalidRequest:
            false
        }
    }
}
