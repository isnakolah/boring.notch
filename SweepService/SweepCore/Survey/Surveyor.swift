import Foundation

// The survey stage: walk the volume, then nominate candidates from the *shape* of
// what was found (C2). This stage reaches no conclusions and offers nothing — a
// nominated node with no reclaimable evidence is dropped downstream.
//
// The defining property, enforced by test: nomination consults no list of tools.
// A directory is nominated because it is large, or carries a structural marker,
// or sits directly under a container root — never because its name appears in a
// catalogue. That is what lets Sweep find a vendor's leftovers without anyone
// having told it that vendor exists.
struct Surveyor: Sendable {

    let sizer: Sizer
    let config: SurveyConfig
    let exclusions: Exclusions
    let home: URL

    init(config: SurveyConfig = .standard(),
         exclusions: Exclusions = Exclusions(),
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         fileSystem: FileSystem = RealFileSystem()) {
        self.config = config
        self.exclusions = exclusions
        self.home = home
        // The sizer keeps directories one level below the nomination depth,
        // because the signals that read a nominated node's children (a
        // CACHEDIR.TAG, a disk image) look exactly that far down.
        self.sizer = Sizer(fileSystem: fileSystem,
                           exclusions: exclusions,
                           retentionDepth: config.markerDepth + 1)
    }

    struct Survey: Equatable {
        var roots: [Node]
        var candidates: [Candidate]
        /// Roots present but unreadable — reported as needing permission, never as
        /// zero bytes (C8).
        var unreadableRoots: [URL]
    }

    /// Sizes every scan root and nominates candidates across all of them.
    func run(onProgress: (@Sendable (SurveyProgress) -> Void)? = nil) async throws -> Survey {
        let existingRoots = config.scanRoots.filter { sizer.fileSystem.fileExists(at: $0) }
        let roots = try await sizer.size(roots: existingRoots, onProgress: onProgress)
        return nominate(in: roots)
    }

    /// Nominates candidates in an already-sized tree. Split out so nomination is
    /// testable without re-walking, and so the logic is one pass over nodes —
    /// cost linear in nodes, a name test and a stat, never a verdict.
    func nominate(in roots: [Node]) -> Survey {
        let containerRoots = Set(config.containerRoots(home: home).map(\.path))
        var candidates: [Candidate] = []
        var unreadable: [URL] = []
        // Nominated paths seen so far, so a child can find its nearest nominated
        // ancestor in one downward pass (parents are visited before children).
        var nominatedAncestors: [String] = []

        for root in roots {
            if root.isUnreadable { unreadable.append(root.url) }
            walk(root,
                 depth: 0,
                 containerRoots: containerRoots,
                 ancestors: &nominatedAncestors,
                 into: &candidates,
                 unreadable: &unreadable)
        }

        return Survey(roots: roots, candidates: candidates, unreadableRoots: unreadable)
    }

    private func walk(
        _ node: Node,
        depth: Int,
        containerRoots: Set<String>,
        ancestors: inout [String],
        into candidates: inout [Candidate],
        unreadable: inout [URL]
    ) {
        if node.isUnreadable && !unreadable.contains(node.url) && depth > 0 {
            unreadable.append(node.url)
        }

        // The scan root itself is the origin of the walk, never a candidate: you
        // do not offer to delete the directory you are scanning from, and
        // nominating home would make every real candidate its descendant and
        // collapse the offer list. Its children are judged normally.
        let reasons = depth == 0
            ? []
            : reasonsForNominating(node, depth: depth, containerRoots: containerRoots)
        var pushedAncestor = false

        if !reasons.isEmpty {
            let parentID = ancestors.last
            candidates.append(Candidate(node: node, reasons: reasons, parentID: parentID))
            ancestors.append(node.url.path)
            pushedAncestor = true
        }

        // Descend for structural markers only to the configured depth; container
        // children and markers cluster near the top, and an unbounded descent
        // would stat the whole disk for nothing.
        if depth < config.markerDepth {
            for child in node.children {
                walk(child,
                     depth: depth + 1,
                     containerRoots: containerRoots,
                     ancestors: &ancestors,
                     into: &candidates,
                     unreadable: &unreadable)
            }
        }

        if pushedAncestor { ancestors.removeLast() }
    }

    /// Every reason this node qualifies. Empty means not nominated. Ordered so a
    /// structural reason is visible even when size also qualifies.
    private func reasonsForNominating(
        _ node: Node,
        depth: Int,
        containerRoots: Set<String>
    ) -> [Candidate.Reason] {
        // C4 is absolute: excluded paths are sized (already done) but never
        // nominated, no matter how large.
        if exclusions.contains(url: node.url) { return [] }

        var reasons: [Candidate.Reason] = []
        let name = node.url.lastPathComponent

        // Structural markers — independent of size.
        if node.isDirectory && containsCacheTag(node) {
            reasons.append(.cacheTag)
        }
        if StructuralMarkers.hasDiskImageExtension(node.url) {
            reasons.append(.diskImageExtension)
        }
        if node.isDirectory && StructuralMarkers.hasVersionSuffix(name) {
            reasons.append(.versionSuffixedName)
        }
        if node.isDirectory && StructuralMarkers.isBundleIdentifierShaped(name) {
            reasons.append(.bundleIdentifierName)
        }

        // Container membership — a direct child of a container root, or a dotfile
        // directory directly under home, is worth judging as a unit.
        let parentPath = node.url.deletingLastPathComponent().standardizedFileURL.path
        if containerRoots.contains(parentPath) {
            reasons.append(.containerChild)
        } else if config.isDotfileContainerChild(node.url, home: home) && node.isDirectory {
            reasons.append(.dotfileContainer)
        }

        // Size — last, so a structural reason is not masked by it.
        if node.totalAllocated >= config.candidateThreshold {
            reasons.append(.size(node.totalAllocated))
        }

        return reasons
    }

    /// A directory declares itself cache by containing a CACHEDIR.TAG file. Only
    /// the direct children are inspected — the sentinel lives at the directory's
    /// own root by the freedesktop spec.
    private func containsCacheTag(_ node: Node) -> Bool {
        node.children.contains {
            !$0.isDirectory && $0.url.lastPathComponent == StructuralMarkers.cacheTagName
        }
    }
}
