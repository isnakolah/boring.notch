import Foundation

// The teardown registry (C5) — an ENRICHMENT OVERLAY, never an input to discovery
// or classification.
//
// It is consulted only after the classifier has already concluded a node is
// reclaimable, and only to answer one question: does this node's *attributed
// owner* have a safer teardown of its own than deleting files directly? A
// toolchain that owns its cache can clean it more completely than `rm` (and can
// reach root-owned state Sweep cannot), so where an owner matches, Sweep runs the
// vendor's command instead.
//
// Two invariants, both enforced by test:
//   - nothing is discovered or classified because it appears here — the pipeline
//     produces identical verdicts with this registry emptied;
//   - absence from the registry never prevents reclaim — an unmatched owner falls
//     back to a direct trash or delete.
//
// Matching is on owner identity (bundle id or display name), NEVER on a path.
struct KnownTools {

    // A vendor's own teardown for its data.
    struct Teardown: Equatable {
        let owner: String                 // display name for the row
        let binary: String                // the executable to resolve on the login PATH
        let arguments: [String]           // args after the binary
        let precondition: Precondition
        /// When the binary is missing, may Sweep safely delete the target directly
        /// instead? True for a plain cache directory; false when only the tool can
        /// tear its state down correctly (a running daemon, root-owned state).
        let directDeleteSafeIfBinaryMissing: Bool

        var command: [String] { [binary] + arguments }
    }

    // A gate that must hold before a delegated command may run (C5).
    enum Precondition: Equatable {
        case none
        case commandSucceeds(binary: String, arguments: [String])       // e.g. `docker info`
        case appsNotRunning([String])                                   // bundle ids
        case commandOutputContainsOnly(binary: String, arguments: [String], allowed: String)
    }

    private let entries: [Teardown]

    /// The C5 registry. Passing an empty array models "registry emptied" for the
    /// independence tests.
    init(entries: [Teardown]? = nil) {
        self.entries = entries ?? KnownTools.c5Entries
    }

    static let empty = KnownTools(entries: [])

    /// The teardown for a target's owner, or nil when the owner is unmatched (or
    /// there is no owner). A nil result means "reclaim directly" — never "do not
    /// reclaim".
    func teardown(for owner: Owner?) -> Teardown? {
        guard let owner else { return nil }
        let name = owner.displayName.lowercased()
        let bundle = owner.bundleIdentifier?.lowercased()
        return entries.first { entry in
            entry.matchers.contains { matcher in
                name == matcher || bundle == matcher || bundle?.hasPrefix(matcher + ".") == true
            }
        }
    }

    // The C5 table. Owner matchers are tool identities, which is exactly what this
    // registry is allowed to name — it enriches a verdict, it never makes one.
    static let c5Entries: [Teardown] = [
        Teardown(owner: "Xcode simulators", binary: "xcrun",
                 arguments: ["simctl", "delete", "unavailable"],
                 precondition: .appsNotRunning(["com.apple.dt.Xcode", "com.apple.iphonesimulator"]),
                 directDeleteSafeIfBinaryMissing: false),
        // Lima and simulator-runtime deletions are deliberately absent: they need a
        // per-instance name/id (`limactl delete <name>`) that a static, parameter-
        // free registry cannot supply without bespoke per-tool output parsing. Their
        // instance directories are reclaimed by a direct delete of the specific
        // nominated path, which frees the real bytes safely (see problems.md P-006).
        Teardown(owner: "Docker", binary: "docker",
                 arguments: ["system", "prune", "-a", "-f"],
                 precondition: .commandSucceeds(binary: "docker", arguments: ["info"]),
                 directDeleteSafeIfBinaryMissing: false),
        Teardown(owner: "Homebrew", binary: "brew",
                 arguments: ["cleanup", "-s"],
                 precondition: .none,
                 directDeleteSafeIfBinaryMissing: true),
        Teardown(owner: "Go", binary: "go",
                 arguments: ["clean", "-cache"],
                 precondition: .none,
                 directDeleteSafeIfBinaryMissing: true),
        Teardown(owner: "npm", binary: "npm",
                 arguments: ["cache", "clean", "--force"],
                 precondition: .none,
                 directDeleteSafeIfBinaryMissing: true),
        Teardown(owner: "NuGet", binary: "dotnet",
                 arguments: ["nuget", "locals", "all", "--clear"],
                 precondition: .none,
                 directDeleteSafeIfBinaryMissing: true),
    ]
}

extension KnownTools.Teardown {
    // The owner identities this teardown applies to, lower-cased. These are tool
    // names, which the registry is expressly permitted to carry.
    var matchers: [String] {
        switch owner {
        case "Xcode simulators": return ["xcode", "simulator", "coresimulator", "com.apple.dt.xcode", "com.apple.coresimulator"]
        case "Docker": return ["docker", "com.docker.docker"]
        case "Homebrew": return ["homebrew", "brew"]
        case "Go": return ["go", "golang"]
        case "npm": return ["npm", "node"]
        case "NuGet": return ["nuget", "dotnet", ".net", "net"]
        default: return [owner.lowercased()]
        }
    }
}
