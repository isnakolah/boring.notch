import Foundation

// A build-output directory sitting beside a dependency manifest is reproducible:
// deleting it loses nothing that the manifest cannot rebuild. The manifest is the
// evidence — `package-lock.json` beside `node_modules`, `Cargo.lock` beside
// `target`. The pairing of a manifest to the directory it regenerates is a fact
// about build tools, not a catalogue of paths: discovery already found the
// directory; this only reads whether a manifest stands next to it.
struct LockfileSignal: Signal {
    let name = "Lockfile"

    // Each artifact directory and the manifests that regenerate it. These are
    // build-tool facts (this manifest rebuilds this directory), the evidence a
    // reproducible tree carries — not a list of things to go looking for.
    private struct Rule {
        let artifact: String
        let manifests: [String]
    }
    private static let rules: [Rule] = [
        Rule(artifact: "node_modules", manifests: ["package-lock.json", "yarn.lock", "pnpm-lock.yaml"]),
        Rule(artifact: "target", manifests: ["Cargo.lock"]),
        Rule(artifact: "Pods", manifests: ["Podfile.lock"]),
        Rule(artifact: ".build", manifests: ["Package.resolved"]),
    ]

    func evaluate(_ node: Node, owner: Owner?, context: SignalContext) -> [Evidence] {
        guard node.isDirectory else { return [] }
        let dirName = node.url.lastPathComponent

        // Also recognise a project's own `bin`/`obj` beside a `.csproj`, which is
        // the .NET shape — the manifest is any `*.csproj` in the parent.
        let parent = node.url.deletingLastPathComponent()
        let siblings = (try? context.fileSystem.contentsOfDirectory(at: parent))?
            .map(\.lastPathComponent) ?? []

        if let rule = Self.rules.first(where: { $0.artifact == dirName }),
           let manifest = rule.manifests.first(where: siblings.contains) {
            return [reproducible(from: manifest)]
        }

        if (dirName == "bin" || dirName == "obj"),
           let csproj = siblings.first(where: { $0.hasSuffix(".csproj") }) {
            return [reproducible(from: csproj)]
        }

        return []
    }

    private func reproducible(from manifest: String) -> Evidence {
        Evidence(
            signal: name,
            polarity: .reclaimable,
            weight: 0.8,
            reason: "Rebuildable from \(manifest) in the same directory.",
            category: .buildArtifact)
    }
}
