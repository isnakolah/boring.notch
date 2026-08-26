import Foundation

/// Which brain answered. Ordered preference lives on the task, not here.
public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    /// The local Antigravity CLI (`agy`), talking to a resident language server.
    case localAgy = "local"
    /// The remote OpenClaw Gateway websocket.
    case callaGateway = "gateway"
}

/// What an attachment means, rather than an arbitrary filename or prompt hint.
/// Providers may render the bytes but never treat them as commands.
public struct IntelligenceAttachment: Sendable, Hashable {
    public let identifier: String
    public let mimeType: String
    public let bytes: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let purpose: String

    public init(identifier: String, mimeType: String, bytes: Data, pixelWidth: Int, pixelHeight: Int, purpose: String) {
        self.identifier = identifier
        self.mimeType = mimeType
        self.bytes = bytes
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.purpose = purpose
    }

    public var isJPEG: Bool {
        mimeType == "image/jpeg" && bytes.count >= 4 && bytes.starts(with: [0xFF, 0xD8, 0xFF]) && bytes.suffix(2) == Data([0xFF, 0xD9])
    }
}

public enum AttachmentCapability: Sendable, Hashable {
    case none
    /// Provider receives only an Engine-staged private relative file reference.
    case fileReference
    /// Provider's API accepts image bytes as a first-class attachment.
    case inlineImage
}

/// Ordered task route. Attempt time is bounded independently, while Router
/// also enforces one total task deadline across every route.
public struct ProviderRoute: Sendable, Hashable {
    public let provider: ProviderKind
    public let maximumAttemptDuration: TimeInterval

    public init(provider: ProviderKind, maximumAttemptDuration: TimeInterval) {
        self.provider = provider
        self.maximumAttemptDuration = maximumAttemptDuration
    }
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
    /// Empty for legacy tasks, which use `allowedProviders` and full task budget.
    /// Tutor feedback supplies an explicit ordered route.
    public let providerRoutes: [ProviderRoute]

    public init(
        id: String,
        defaultTier: ModelTier,
        contract: OutputContract,
        latencyBudget: TimeInterval,
        conversation: ConversationPolicy,
        batching: BatchingPolicy,
        allowedProviders: [ProviderKind],
        providerRoutes: [ProviderRoute] = []
    ) {
        self.id = id
        self.defaultTier = defaultTier
        self.contract = contract
        self.latencyBudget = latencyBudget
        self.conversation = conversation
        self.batching = batching
        self.allowedProviders = allowedProviders
        self.providerRoutes = providerRoutes
    }

    public static func == (lhs: IntelligenceTask, rhs: IntelligenceTask) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public var isTutorFeedback: Bool { id == "tutor.feedback" }

    public var effectiveRoutes: [ProviderRoute] {
        if !providerRoutes.isEmpty { return providerRoutes }
        return allowedProviders.map { ProviderRoute(provider: $0, maximumAttemptDuration: latencyBudget) }
    }

    /// Tool-free, bounded screenshot feedback. Engine owns capture, storage,
    /// verifier result and lesson advancement; providers only return this JSON.
    public static let tutorFeedback = IntelligenceTask(
        id: "tutor.feedback",
        defaultTier: .fast,
        contract: .json(keys: ["message", "assessment", "basis"]),
        latencyBudget: 15,
        conversation: .perSession,
        batching: .manual,
        allowedProviders: [.localAgy, .callaGateway],
        providerRoutes: [
            ProviderRoute(provider: .localAgy, maximumAttemptDuration: 5),
            ProviderRoute(provider: .callaGateway, maximumAttemptDuration: 15),
        ])
}
