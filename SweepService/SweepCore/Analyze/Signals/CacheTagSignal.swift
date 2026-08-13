import Foundation

// A directory containing a `CACHEDIR.TAG` declares itself regenerable cache
// (freedesktop). This is the strongest reclaimable evidence there is — the
// directory is asserting its own disposability — so it carries weight 1.0.
struct CacheTagSignal: Signal {
    let name = "CACHEDIR.TAG"

    func evaluate(_ node: Node, owner: Owner?, context: SignalContext) -> [Evidence] {
        guard node.isDirectory else { return [] }
        let hasTag = node.children.contains {
            !$0.isDirectory && $0.url.lastPathComponent == StructuralMarkers.cacheTagName
        }
        guard hasTag else { return [] }
        return [Evidence(
            signal: name,
            polarity: .reclaimable,
            weight: 1.0,
            reason: "Contains a CACHEDIR.TAG file, which marks it as regenerable cache.",
            category: .cache)]
    }
}
