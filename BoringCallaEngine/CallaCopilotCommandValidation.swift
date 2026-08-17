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
    public static let allowedActions: Set<String> = ["start", "stop", "set_persona"]

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

    public static func persona(_ value: String?) -> String? {
        guard let value = trimmed(value)?.lowercased(), allowedPersonas.contains(value) else { return nil }
        return value
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
