import Foundation

// Runs the analysis pipeline over a survey: attribute each candidate, gather
// evidence from every signal, classify, and produce targets — with descendant
// suppression so the same bytes are never offered twice.
//
// The signals are held as a plain list. The order does not matter: they are
// independent, and only the classifier combines them.
struct Analyzer {

    let attributor: Attributor
    let classifier: Classifier
    let context: SignalContext
    let signals: [Signal]

    init(attributor: Attributor,
         context: SignalContext,
         classifier: Classifier = Classifier(),
         signals: [Signal]? = nil) {
        self.attributor = attributor
        self.classifier = classifier
        self.context = context
        self.signals = signals ?? Analyzer.standardSignals
    }

    // The nine detectors of C3. Independent; order is irrelevant.
    static let standardSignals: [Signal] = [
        CacheTagSignal(), LockfileSignal(), RepositorySignal(), DiskImageSignal(),
        VersionSignal(), OwnershipSignal(), StalenessSignal(), ActivitySignal(),
        RegrowthSignal(),
    ]

    struct Analyzed {
        let candidate: Candidate
        let owner: Owner?
        let verdict: Verdict
    }

    /// Every candidate that reached a verdict, before suppression. Useful for the
    /// overview, which shows protected categories too.
    func analyze(_ candidates: [Candidate]) -> [Analyzed] {
        candidates.compactMap { candidate in
            // Attribution and several signals go through Spotlight, Bundle and
            // FileManager, all of which autorelease. Without a pool per candidate
            // that garbage accumulates for the whole pass — measured at 1.6 GB
            // over this machine's candidates, against 122 MB for the walk that
            // produced them.
            autoreleasepool {
                let owner = attributor.attribute(candidate.node)
                let evidence = signals.flatMap { $0.evaluate(candidate.node, owner: owner, context: context) }
                guard let verdict = classifier.classify(evidence) else { return nil }
                return Analyzed(candidate: candidate, owner: owner, verdict: verdict)
            }
        }
    }

    /// The offered targets: verdicts with descendants folded into ancestors, and
    /// bytes kept honest so a parent and child are never both counted.
    ///
    /// A folded descendant is not discarded. It is attached to the row that
    /// absorbed it as a *component*, so a large grouped target can be opened and
    /// reclaimed in parts. Components are never rows of their own; see
    /// `Target.components` for how that keeps C2's byte-counting rule intact.
    func targets(for candidates: [Candidate]) -> [Target] {
        let analyzed = analyze(candidates)
        let byPath = Dictionary(uniqueKeysWithValues: analyzed.map { ($0.candidate.id, $0) })

        // A candidate is suppressed when an ancestor also reached a verdict — its
        // bytes fold into that ancestor. A vetoed (danger) node is never
        // suppressed: a protected item must always surface on its own.
        var suppressed = Set<String>()
        for item in analyzed where item.verdict.risk != .danger {
            if nearestAnalyzedAncestor(of: item.candidate, in: byPath) != nil {
                suppressed.insert(item.candidate.id)
            }
        }

        let kept = analyzed.filter { !suppressed.contains($0.candidate.id) }

        // Components nest the way the filesystem does: a target's components are
        // the candidates *directly* beneath it in the analysis, and each of those
        // carries its own. Flattening every descendant into one list instead
        // would put a tree and the things inside it side by side — 907 entries
        // for one row on this machine, three of them the same bytes at different
        // depths.
        var childrenByParent: [String: [Analyzed]] = [:]
        for item in analyzed {
            guard let ancestor = nearestAnalyzedAncestor(of: item.candidate, in: byPath) else { continue }
            childrenByParent[ancestor.id, default: []].append(item)
        }

        func components(of id: String) -> [Target] {
            (childrenByParent[id] ?? [])
                // A vetoed descendant is a row of its own, never something the
                // user has to open a disclosure to discover.
                .filter { $0.verdict.risk != .danger }
                .map { makeTarget($0, kept: [], components: components(of: $0.id)) }
                .sorted { $0.bytes > $1.bytes }
        }

        return kept.map { makeTarget($0, kept: kept, components: components(of: $0.id)) }
    }

    // MARK: Internals

    private func nearestAnalyzedAncestor(of candidate: Candidate, in byPath: [String: Analyzed]) -> Analyzed? {
        var parentID = candidate.parentID
        while let id = parentID {
            if let ancestor = byPath[id] { return ancestor }
            parentID = ancestor(ofID: id, byPath: byPath)
        }
        return nil
    }

    private func ancestor(ofID id: String, byPath: [String: Analyzed]) -> String? {
        byPath[id]?.candidate.parentID
    }

    /// Builds a target. `kept` is the set of *other rows* whose bytes must not be
    /// counted here; it is empty for a component, whose size is simply what
    /// removing it would free.
    private func makeTarget(_ item: Analyzed, kept: [Analyzed], components: [Target] = []) -> Target {
        // Subtract any kept descendant's bytes, so a parent offered alongside a
        // vetoed child does not count the child's bytes twice.
        let node = item.candidate.node
        let selfPath = node.url.standardizedFileURL.path + "/"
        var bytes = node.totalAllocated
        var downgradeForVeto = false
        for other in kept where other.id != item.candidate.id {
            let otherPath = other.url.standardizedFileURL.path
            guard otherPath.hasPrefix(selfPath) else { continue }
            bytes -= other.bytes
            if other.risk == .danger { downgradeForVeto = true }
        }
        bytes = max(0, bytes)

        // A tree that contains a protected item cannot itself be cleanly
        // pre-selected, so an otherwise-safe ancestor drops to caution.
        var verdict = item.verdict
        if downgradeForVeto && verdict.risk == .safe {
            verdict = Verdict(
                risk: .caution,
                category: verdict.category,
                confidence: verdict.confidence,
                evidence: verdict.evidence,
                summary: verdict.summary)
        }

        return Target(
            id: item.candidate.id,
            title: item.owner?.displayName ?? node.url.lastPathComponent,
            url: node.url,
            owner: item.owner,
            verdict: verdict,
            defaultReclaim: Reclaim.default(forBytes: bytes),
            bytes: bytes,
            lastModified: node.modified,
            fingerprint: item.candidate.fingerprint,
            components: components)
    }
}

extension Analyzer.Analyzed {
    var id: String { candidate.id }
    var url: URL { candidate.node.url }
    var bytes: Int64 { candidate.node.totalAllocated }
    var risk: Risk { verdict.risk }
}
