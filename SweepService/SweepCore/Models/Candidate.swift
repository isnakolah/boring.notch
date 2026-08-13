import Foundation

// A node the surveyor judged worth judging (C2). A candidate is not a verdict and
// not an offer — it is only "this is worth the analysis pipeline's attention".
// A candidate with no reclaimable evidence is dropped later; silence is the
// default.
struct Candidate: Identifiable, Equatable {

    // Why a node was nominated. Recorded so the pipeline can see *how* something
    // surfaced, and so tests can assert nomination happened on structure vs size.
    // None of these is a verdict; they are shapes.
    enum Reason: Equatable {
        case size(Int64)                    // at or above the candidate threshold
        case cacheTag                       // contains CACHEDIR.TAG
        case diskImageExtension             // .dmg/.raw/.sparsebundle/…
        case versionSuffixedName            // Foo2026.1
        case bundleIdentifierName           // com.docker.docker
        case containerChild                 // direct child of a container root
        case dotfileContainer               // ~/.something
    }

    let node: Node
    let reasons: [Reason]
    /// The id of the nearest nominated ancestor, if any. The classifier suppresses
    /// a candidate whose ancestor is also a candidate and folds its bytes into the
    /// ancestor, so the same bytes are never offered twice.
    let parentID: String?

    var id: String { node.url.path }
    var url: URL { node.url }
    var allocated: Int64 { node.totalAllocated }

    var isDescendantOfCandidate: Bool { parentID != nil }

    /// A stable descriptor of what this candidate structurally *is* — its marker
    /// kinds, not its size. Regrowth history is keyed to this, so a path that was a
    /// cache when reclaimed and comes back as a version directory is not credited
    /// with the cache's history (C7).
    var fingerprint: String {
        Candidate.fingerprint(for: reasons)
    }

    static func fingerprint(for reasons: [Reason]) -> String {
        // Only the structural marker kinds; size is not part of a node's nature.
        var kinds: Set<String> = []
        for reason in reasons {
            switch reason {
            case .size: continue
            case .cacheTag: kinds.insert("cacheTag")
            case .diskImageExtension: kinds.insert("diskImage")
            case .versionSuffixedName: kinds.insert("versionSuffix")
            case .bundleIdentifierName: kinds.insert("bundleId")
            case .containerChild: kinds.insert("containerChild")
            case .dotfileContainer: kinds.insert("dotfileContainer")
            }
        }
        return kinds.sorted().joined(separator: "+")
    }
}
