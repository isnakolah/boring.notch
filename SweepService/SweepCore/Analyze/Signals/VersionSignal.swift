import Foundation

// The RustRover protection, generalised. A version-suffixed directory whose owner
// is installed is compared against the installed version:
//   - a different version is a leftover of an old release → reclaimable (0.7);
//   - the *matching* version is live configuration for the current release, and is
//     a protective veto — no amount of staleness or cache-shape may override it.
//
// This is the signal that separates the stale `GoLand2026.1` from the current
// `RustRover2026.1`, which look otherwise identical.
struct VersionSignal: Signal {
    let name = "Version"

    func evaluate(_ node: Node, owner: Owner?, context: SignalContext) -> [Evidence] {
        guard node.isDirectory,
              let dirVersion = VersionNormalizer.fromDirectoryName(node.url.lastPathComponent),
              let owner, owner.isInstalled,
              let installedRaw = owner.installedVersion,
              let installedVersion = VersionNormalizer.majorMinor(installedRaw)
        else { return [] }

        if dirVersion == installedVersion {
            return [Evidence(
                signal: name,
                polarity: .protective,
                weight: 1.0,        // veto
                reason: "Matches the installed \(owner.displayName) \(installedRaw), so this is live configuration, not a leftover.",
                category: .duplicateVersion)]
        }

        return [Evidence(
            signal: name,
            polarity: .reclaimable,
            weight: 0.7,
            reason: "An older version than the installed \(owner.displayName) \(installedRaw).",
            category: .duplicateVersion)]
    }
}
