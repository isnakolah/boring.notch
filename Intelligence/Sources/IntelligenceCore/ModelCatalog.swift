import Foundation

/// What a provider can be asked to run, and how a tier maps onto it.
///
/// Two names per entry, because the two `agy` transports disagree: `agentapi`
/// (the fast path) takes coarse tiers like `flash`, while print mode takes exact
/// ids like `gemini-3.7-flash-low`. Anything user-facing must go through here so
/// the allowlists cannot drift between the app, the XPC engine, and the host.
public struct ModelCatalog: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public let tier: ModelTier
        /// Coarse token the session API accepts.
        public let tierToken: String
        /// Exact model id, when the transport can honour one.
        public let exactID: String
        /// Shown in Settings.
        public let displayName: String

        public init(tier: ModelTier, tierToken: String, exactID: String, displayName: String) {
            self.tier = tier
            self.tierToken = tierToken
            self.exactID = exactID
            self.displayName = displayName
        }
    }

    public let provider: ProviderKind
    public let entries: [Entry]

    public init(provider: ProviderKind, entries: [Entry]) {
        self.provider = provider
        self.entries = entries
    }

    public func entry(for tier: ModelTier) -> Entry? {
        entries.first { $0.tier == tier }
    }

    public func tierToken(for tier: ModelTier) -> String? {
        entry(for: tier)?.tierToken
    }

    public func exactID(for tier: ModelTier) -> String? {
        entry(for: tier)?.exactID
    }

    /// Exact ids a user may pick for a live, latency-bound task. Deliberately
    /// excludes deep-tier models: a `pro` model on a live call turn is a stall,
    /// not an upgrade.
    public var liveIDs: [String] {
        entries.filter { $0.tier != .deep }.map(\.exactID)
    }

    /// Exact ids a user may pick for an end-of-call or otherwise unhurried pass.
    public var deepIDs: [String] {
        entries.filter { $0.tier != .fast }.map(\.exactID)
    }

    public func isKnown(_ exactID: String) -> Bool {
        entries.contains { $0.exactID == exactID }
    }
}
