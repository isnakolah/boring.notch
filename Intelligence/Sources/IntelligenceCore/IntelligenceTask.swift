import Foundation

/// Which brain answered. Ordered preference lives on the task, not here.
public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    /// The local Antigravity CLI (`agy`), talking to a resident language server.
    case localAgy = "local"
    /// The remote OpenClaw Gateway websocket.
    case callaGateway = "gateway"
}

/// Providers advertise tiers, not model names. `agy agentapi` only accepts
/// `flash_lite | flash | pro`, so a tier is the widest thing every transport can
/// honour; exact model ids are a print-transport-only luxury.
public enum ModelTier: String, Codable, Sendable, CaseIterable {
    case fast, balanced, deep
}

/// What shape of answer the caller can parse.
public enum OutputContract: Sendable, Hashable {
    /// Prose. Whatever the model said is the answer.
    case freeform
    /// A JSON object somewhere in the reply, with these keys required.
    case json(keys: [String])
    /// A JSON object followed by a line containing exactly `marker`. The marker
    /// is what makes a streamed or line-buffered reply unambiguously complete.
    case sentinelJSON(keys: [String], marker: String)

    public var requiredKeys: [String] {
        switch self {
        case .freeform: []
        case let .json(keys): keys
        case let .sentinelJSON(keys, _): keys
        }
    }

    public var marker: String? {
        switch self {
        case let .sentinelJSON(_, marker): marker
        case .freeform, .json: nil
        }
    }
}

/// How much history a request carries with it.
public enum ConversationPolicy: Sendable, Hashable {
    /// No history. Every request is its own conversation.
    case oneShot
    /// One conversation per `sessionKey` (a call, a lesson), appended to.
    case perSession
    /// One long-lived conversation under a fixed key.
    case persistent(key: String)
}

/// When accumulated input is worth spending a request on.
public enum BatchingPolicy: Sendable, Hashable {
    /// Send every input as it arrives.
    case everyInput
    /// Buffer until a complete statement is detected. See `StatementSegmenter`.
    case statement(StatementRules)
    /// The caller decides; the layer never fires on its own.
    case manual
}

/// A feature's identity in the intelligence layer.
///
/// Adding an intelligence-backed feature means declaring one of these, not
/// wiring a new subsystem. See `docs/intelligence.md`.
public struct IntelligenceTask: Sendable, Hashable {
    /// Dotted, stable, and used as a Defaults-key suffix: `copilot.suggest`.
    public let id: String
    public let defaultTier: ModelTier
    public let contract: OutputContract
    /// How long the caller is willing to wait before this counts as a failure.
    public let latencyBudget: TimeInterval
    public let conversation: ConversationPolicy
    public let batching: BatchingPolicy
    /// Ordered preference. The router takes the first that is available and
    /// supports the task.
    public let allowedProviders: [ProviderKind]

    public init(
        id: String,
        defaultTier: ModelTier,
        contract: OutputContract,
        latencyBudget: TimeInterval,
        conversation: ConversationPolicy,
        batching: BatchingPolicy,
        allowedProviders: [ProviderKind]
    ) {
        self.id = id
        self.defaultTier = defaultTier
        self.contract = contract
        self.latencyBudget = latencyBudget
        self.conversation = conversation
        self.batching = batching
        self.allowedProviders = allowedProviders
    }

    public static func == (lhs: IntelligenceTask, rhs: IntelligenceTask) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
