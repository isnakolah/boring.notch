import Darwin
import Foundation

/// Where `agy` keeps its state, and the environment every spawn of it needs.
///
/// This exists because of a bug that presents as a lie: Settings says "signed in"
/// while a call pops a browser asking the user to sign in again.
///
/// `agy` stores credentials under `$HOME/.gemini`. The app is sandboxed, so in it
/// `NSHomeDirectory()` is the container (`~/Library/Containers/…/Data`), not the
/// user's home — and passing that as `HOME` to a child points it at a `.gemini`
/// that does not exist, so it starts a fresh OAuth flow. Meanwhile whichever
/// process happened to be unsandboxed reported the real credentials as present.
/// Two answers to one question.
///
/// `getpwuid` is the fix: the sandbox redirects `NSHomeDirectory()` but not the
/// passwd database, so every process in the app — sandboxed or not — resolves the
/// same home and therefore the same credentials.
public enum AgyEnvironment {
    /// The user's real home directory, whatever the caller's sandbox says.
    public static let userHome: String = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty { return path }
        }
        // Only reachable if the passwd entry is unreadable, in which case the
        // container path is no worse than nothing.
        return NSHomeDirectory()
    }()

    public static var configDirectory: URL {
        URL(fileURLWithPath: userHome).appendingPathComponent(".gemini")
    }

    public static var credentialsFile: URL {
        configDirectory.appendingPathComponent("oauth_creds.json")
    }

    public static var accountsFile: URL {
        configDirectory.appendingPathComponent("google_accounts.json")
    }

    public static var conversationsDirectory: URL {
        configDirectory.appendingPathComponent("antigravity-cli/conversations")
    }

    public static var brainDirectory: URL {
        configDirectory.appendingPathComponent("antigravity-cli/brain")
    }

    /// Environment for a spawned `agy`, with `HOME` pinned to the real one so the
    /// child reads the same credentials the app reports on.
    ///
    /// A GUI app also inherits a minimal `PATH`, so the usual install locations
    /// are added — `agy` shells out to `git` and friends.
    public static func processEnvironment(
        adding extra: [String: String] = [:]
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = userHome
        let path = environment["PATH"] ?? ""
        let needed = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let missing = needed.filter { !path.split(separator: ":").map(String.init).contains($0) }
        if !missing.isEmpty {
            environment["PATH"] = (path.isEmpty ? "" : path + ":") + missing.joined(separator: ":")
        }
        for (key, value) in extra { environment[key] = value }
        return environment
    }
}
