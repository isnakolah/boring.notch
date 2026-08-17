import Foundation

/// Validation for owner-issued call-copilot commands.
///
/// Pure and dependency-free on purpose, like its course-command sibling: it
/// compiles into the SPM validation target so every rule here is unit-tested
/// without launching an XPC service. Everything a command carries ends up
/// either naming a process to spawn or riding into a model prompt, so each
/// field is checked against an allowlist rather than sanitised.
public enum CallaCopilotCommandValidation {
    /// Commands the notch may send. Anything else is refused outright.
    public static let allowedActions: Set<String> = [
        "start", "stop", "set_persona", "set_provider", "archive", "fetch_model", "login",
        // A rehearsal of the sign-in against a throwaway HOME, so the flow can be
        // watched without signing out.
        "test_login",
        // Clearing credentials, and putting them back. Both name a file this
        // service owns; neither takes a path from the caller.
        "sign_out", "restore_login",
        // Live display preferences, which also change what the copilot is asked.
        "set_detail",
    ]

    /// Which brain answers a call.
    ///
    /// `local` runs the Antigravity CLI on this Mac and needs no gateway;
    /// `gateway` is the remote OpenClaw host. Two values, both of which name a
    /// code path in this repository — never a host, a URL, or a binary, so there
    /// is nothing here to steer.
    public static let allowedProviders: Set<String> = ["local", "gateway"]

    /// Model tiers the local provider's fast path can ask for.
    ///
    /// Tiers rather than model names because `agy agentapi` — the only transport
    /// fast enough for a live call — accepts `flash_lite | flash | pro` and
    /// nothing finer. `IntelligenceCore.ModelTier` holds the same three cases and
    /// `ModelCatalog.agy` maps them onto tokens; these must stay in step.
    public static let allowedTiers: Set<String> = ["fast", "balanced", "deep"]

    /// Exact model ids allowed for the unhurried end-of-call pass, which runs
    /// through the print transport and therefore *can* name a model.
    ///
    /// Deliberately no `flash` entry: this pass exists to be better than the live
    /// tier, and deliberately no free-form value, because it becomes an argument
    /// to a spawned process.
    public static let allowedSummaryModels: Set<String> = [
        "gemini-3.1-pro-high", "claude-sonnet-4-6",
    ]

    /// Personas the gateway flow knows. Kept in lockstep with `PERSONAS` in
    /// `apps/call-copilot/integrations/openclaw/src/protocol.mjs`; a value the
    /// gateway would reject should never leave this machine.
    public static let allowedPersonas: Set<String> = ["generic", "interview", "sales", "support"]

    /// Live transcription models the host may be asked to run.
    ///
    /// The archive model is deliberately absent: it carries a CoreML encoder,
    /// which forces whisper's full 30s context per utterance and would make the
    /// live leg unusable.
    public static let allowedLiveModels: Set<String> = ["whisper-small-en", "whisper-base-en"]

    private static let callIDPattern = try? NSRegularExpression(pattern: "^call-[A-Za-z0-9-]{8,72}$")

    public static func action(_ value: String?) -> String? {
        guard let value = trimmed(value), allowedActions.contains(value) else { return nil }
        return value
    }

    public static func provider(_ value: String?) -> String? {
        guard let value = trimmed(value)?.lowercased(), allowedProviders.contains(value) else { return nil }
        return value
    }

    public static func tier(_ value: String?) -> String? {
        guard let value = trimmed(value)?.lowercased(), allowedTiers.contains(value) else { return nil }
        return value
    }

    public static func summaryModel(_ value: String?) -> String? {
        guard let value = trimmed(value), allowedSummaryModels.contains(value) else { return nil }
        return value
    }

    public static func persona(_ value: String?) -> String? {
        guard let value = trimmed(value)?.lowercased() else { return nil }
        if allowedPersonas.contains(value) { return value }
        // A user-defined persona is still an identifier, so it stays
        // allowlist-*shaped* even though it is not on a fixed list: an id can
        // end up naming a file or a session key, which a paragraph cannot.
        guard value.range(of: "^[a-z0-9-]{1,24}$", options: .regularExpression) != nil else { return nil }
        return value
    }

    /// The one place free text is accepted, and the rules that make that safe.
    ///
    /// The rest of this file allowlists, because the rest of a command names a
    /// process or a route. Prompt text cannot be allowlisted — the whole point
    /// is that the user writes it — so the guarantee moves: bounded length,
    /// no control characters, and the caller hands it to the host on **stdin**
    /// rather than as an argument, so it never becomes part of a command line.
    /// Over-length is refused rather than truncated: a silently shortened
    /// prompt is a different prompt than the one Settings shows.
    public static func profile(about: String?,
                               personaGuidance: String?,
                               baseGuidance: String?) -> ProfileFields? {
        guard case .accepted(let about) = promptText(about, limit: aboutLimit),
              case .accepted(let persona) = promptText(personaGuidance, limit: personaGuidanceLimit),
              case .accepted(let base) = promptText(baseGuidance, limit: baseGuidanceLimit)
        else { return nil }

        if about == nil, persona == nil, base == nil { return nil }
        return ProfileFields(about: about, personaGuidance: persona, baseGuidance: base)
    }

    public static let aboutLimit = 1200
    public static let personaGuidanceLimit = 2000
    public static let baseGuidanceLimit = 8000

    /// A validated prompt payload. Codable so the engine can hand it straight to
    /// the host without a second hand-mirrored struct.
    public struct ProfileFields: Codable, Equatable {
        public let about: String?
        public let personaGuidance: String?
        public let baseGuidance: String?

        enum CodingKeys: String, CodingKey {
            case about
            case personaGuidance = "persona_guidance"
            case baseGuidance = "base_guidance"
        }

        public init(about: String?, personaGuidance: String?, baseGuidance: String?) {
            self.about = about
            self.personaGuidance = personaGuidance
            self.baseGuidance = baseGuidance
        }
    }

    /// Absent and refused are different answers.
    ///
    /// Collapsing them into one optional would let a rejected paragraph read as
    /// an unset one, and the call would then run on the gateway's default
    /// wording while Settings showed something else.
    public enum PromptResult: Equatable {
        /// Accepted; `nil` payload means the field was simply not set.
        case accepted(String?)
        case refused
    }

    private static func promptText(_ value: String?, limit: Int) -> PromptResult {
        guard let value else { return .accepted(nil) }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .accepted(nil) }
        guard trimmed.count <= limit else { return .refused }
        // Newline and tab are ordinary in a prompt; everything else in the
        // control range is either a terminal escape or a null, and neither has
        // any business in text that will be rendered and re-serialised.
        let forbidden = trimmed.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control && scalar != "\n" && scalar != "\r" && scalar != "\t"
        }
        guard !forbidden else { return .refused }
        return .accepted(trimmed.replacingOccurrences(of: "\r\n", with: "\n"))
    }

    public static func liveModel(_ value: String?) -> String? {
        guard let value = trimmed(value), allowedLiveModels.contains(value) else { return nil }
        return value
    }

    public static func callID(_ value: String?) -> String? {
        guard let value = trimmed(value), let callIDPattern else { return nil }
        let range = NSRange(value.startIndex..., in: value)
        guard callIDPattern.firstMatch(in: value, range: range) != nil else { return nil }
        return value
    }

    /// The gateway route the host is allowed to reach.
    ///
    /// Restricted to `wss:` on the Boring-owned Tailscale host. The transcript
    /// of a live call is the most sensitive thing this feature touches, and a
    /// command carrying an arbitrary URL would be enough to send it anywhere.
    public static func gatewayURL(_ value: String?) -> URL? {
        guard let value = trimmed(value),
              let url = URL(string: value),
              url.scheme == "wss",
              url.host == "nomonhomelab.tailec0dca.ts.net",
              url.path == "/call-copilot/stream"
        else { return nil }
        return url
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
