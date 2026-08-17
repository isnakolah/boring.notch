import Foundation

/// Reading `agy`'s sign-in flow out of a pty stream.
///
/// Pure and dependency-free so it compiles into the SPM validation target, like
/// its command-validation sibling. It parses another program's console output,
/// which is the sort of thing that breaks quietly on an upgrade — so the exact
/// strings the CLI emits today are pinned by tests rather than trusted.
///
/// What `agy` actually does, when stdin is a terminal and no credentials exist:
///
///     Authentication required. Please visit the URL to log in:
///       https://accounts.google.com/o/oauth2/auth?...&state=...
///
///     Waiting for authentication (timeout 60s)...
///     Or, paste the authorization code here and press Enter:
///
/// and on a bad code:
///
///     Error: authentication failed: token exchange failed: oauth2: "invalid_grant" "Malformed auth code."
public enum CallaAgyLoginParsing {
    /// The Google sign-in URL, if it has been printed yet.
    ///
    /// Stops at whitespace and at quotes: the URL arrives on its own line, and a
    /// greedy match would swallow the prompt that follows it.
    public static func signInURL(in output: String) -> String? {
        // Only URL-legal characters. `[^\\s]+` looks equivalent and is not: the TUI
        // draws box-drawing glyphs, which are not whitespace, so a greedy match
        // swallowed the divider line after the link and produced a 1415-character
        // "URL" instead of the real 704-character one.
        guard let range = output.range(
            of: "https://accounts\\.google\\.com/o/oauth2/auth\\?[A-Za-z0-9._~:/?#\\[\\]@!$&'()*+,;=%-]+",
            options: .regularExpression
        ) else { return nil }
        return String(output[range])
    }

    /// The TUI's login-method menu, which must be answered before anything else
    /// happens. `1. Google OAuth` is preselected, so a bare Return picks it.
    public static func isAtLoginMethodMenu(_ output: String) -> Bool {
        output.contains("Select login method")
    }

    /// Whether the TUI is showing its own error line.
    public static func hasError(_ output: String) -> Bool {
        output.contains("Got an error:")
    }

    /// Whether `agy` is sitting at its paste prompt.
    ///
    /// The UI shows its code field on this rather than on the wording of the last
    /// status message, which any other action can overwrite mid-sign-in.
    public static func isAwaitingCode(_ output: String) -> Bool {
        output.contains("paste the authorization code")
    }

    /// True once credentials have been exchanged successfully.
    public static func didSucceed(_ output: String) -> Bool {
        output.contains("silent auth succeeded") || output.contains("Authentication successful")
    }

    /// Why a sign-in failed, in terms the user can act on.
    ///
    /// An exit code cannot distinguish a mistyped code from an expired flow from a
    /// refusal to run non-interactively, and those need three different responses.
    public static func failureMessage(from output: String, status: Int32) -> String {
        let lowered = output.lowercased()
        if lowered.contains("malformed auth code") {
            return "That code was not valid — copy it again from the sign-in page"
        }
        if lowered.contains("invalid_grant") {
            return "That code was rejected or had already expired"
        }
        if lowered.contains("timed out") || lowered.contains("timeout") {
            return "Sign-in timed out — start it again"
        }
        if lowered.contains("run 'agy' to log in") {
            // Reached when stdin was not a terminal. Worth saying plainly, because
            // no amount of retrying in the app will fix it.
            return "agy refused an automated sign-in — run `agy` once in a terminal"
        }
        if lowered.contains("could not reach") || lowered.contains("no such host")
            || lowered.contains("connection refused")
        {
            return "Could not reach Google — check the network and try again"
        }
        return "Sign-in did not complete (status \(status))"
    }
}
