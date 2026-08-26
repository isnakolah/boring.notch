import Foundation

/// The pieces of a system prompt, kept separate so a provider can send them
/// once per conversation and never restate them.
///
/// Ordering is fixed: `base` (the contract and house style), then `role` (the
/// persona), then `about` (who the user is), then `knowledge` (what this
/// particular call is about), then `taskGuidance`.
public struct PromptBlocks: Sendable, Hashable {
    public var base: String
    public var role: String
    public var about: String
    /// What the user has recorded about *this* call — the meeting's own details,
    /// notes attached to it, and what the last occurrence of it concluded.
    ///
    /// Kept apart from `about` because the two have different lifetimes and
    /// different limits: `about` is one paragraph that is true of every call,
    /// while this is assembled per call and is allowed to be much longer.
    public var knowledge: String
    public var taskGuidance: String

    public init(
        base: String = "",
        role: String = "",
        about: String = "",
        knowledge: String = "",
        taskGuidance: String = ""
    ) {
        self.base = base
        self.role = role
        self.about = about
        self.knowledge = knowledge
        self.taskGuidance = taskGuidance
    }

    public var isEmpty: Bool {
        base.isEmpty && role.isEmpty && about.isEmpty && knowledge.isEmpty && taskGuidance.isEmpty
    }
}

public struct IntelligenceRequest: Sendable {
    public let task: IntelligenceTask
    /// Maps to a provider conversation. Required for `.perSession`.
    public let sessionKey: String?
    /// Sent only in the first message of a conversation.
    public let system: PromptBlocks
    /// Only what is new. The conversation holds the rest.
    public let input: String
    /// Overrides `task.defaultTier` when a user picked something else.
    public let tier: ModelTier?
    /// Exact provider model id, when the caller cares and the transport can
    /// honour it. Ignored by transports that only take tiers.
    public let exactModel: String?
    /// Attachments are Engine-owned bytes. No provider may infer execution or
    /// progression authority from them.
    public let attachments: [IntelligenceAttachment]

    public init(
        task: IntelligenceTask,
        sessionKey: String? = nil,
        system: PromptBlocks = .init(),
        input: String,
        tier: ModelTier? = nil,
        exactModel: String? = nil,
        attachments: [IntelligenceAttachment] = []
    ) {
        self.task = task
        self.sessionKey = sessionKey
        self.system = system
        self.input = input
        self.tier = tier
        self.exactModel = exactModel
        self.attachments = attachments
    }

    public var effectiveTier: ModelTier { tier ?? task.defaultTier }
}

/// Who answered, how fast, and whether the preferred provider had to be
/// abandoned. Carried all the way to the UI: a silent failover is a bug.
public struct Attribution: Sendable, Hashable, Codable {
    public var provider: ProviderKind
    public var model: String
    public var latency: TimeInterval
    public var fellBack: Bool
    /// How many times this session has rolled to a fresh conversation to keep
    /// context (and therefore latency) flat.
    public var rollovers: Int
    /// Route selected before provider availability/fallback was known.
    public var selectedProvider: ProviderKind?
    /// Whether a provider's own transport changed (for example agent API -> CLI).
    public var transportFallback: Bool
    /// Whether Router changed providers.
    public var providerFallback: Bool
    /// Typed Router failure that caused provider fallback. Never user/model text.
    public var fallbackReason: String?

    public init(
        provider: ProviderKind,
        model: String,
        latency: TimeInterval,
        fellBack: Bool = false,
        rollovers: Int = 0,
        selectedProvider: ProviderKind? = nil,
        transportFallback: Bool = false,
        providerFallback: Bool = false,
        fallbackReason: String? = nil
    ) {
        self.provider = provider
        self.model = model
        self.latency = latency
        self.fellBack = fellBack
        self.rollovers = rollovers
        self.selectedProvider = selectedProvider
        self.transportFallback = transportFallback
        self.providerFallback = providerFallback
        self.fallbackReason = fallbackReason
    }
}

public struct Usage: Sendable, Hashable, Codable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// True when the numbers are estimated rather than reported. The agentapi
    /// fast path reports nothing, so estimates are the norm there.
    public var estimated: Bool

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, estimated: Bool = false) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.estimated = estimated
    }
}

public struct IntelligenceResponse: Sendable {
    public let text: String
    /// The contract's JSON object, extracted and re-encoded, when the task asked
    /// for one.
    public let payload: Data?
    public let attribution: Attribution
    public let usage: Usage?

    public init(text: String, payload: Data? = nil, attribution: Attribution, usage: Usage? = nil) {
        self.text = text
        self.payload = payload
        self.attribution = attribution
        self.usage = usage
    }
}

/// One increment of a streamed reply.
public enum IntelligenceDelta: Sendable {
    case text(String)
    case done(IntelligenceResponse)
}

/// Can this provider be used right now, and can we say why not.
public enum Availability: Sendable, Hashable {
    case ready(version: String?)
    case missing
    case unauthenticated
    case quotaExhausted
    case unreachable(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}
