import Foundation

// Combines evidence into a verdict (C3). This is the only place evidence is
// combined; the signals that produced it never saw one another.
//
// The rules, in order:
//   1. No reclaimable evidence → no verdict at all. Silence is the default; a node
//      that is merely protected (a disk image, a running app's data) is not
//      offered, only surfaced in the overview.
//   2. Any protective veto (weight ≥ 1.0) → danger, regardless of how much
//      reclaimable weight accumulated. This is absolute.
//   3. Otherwise the risk falls out of the balance of weights, and confidence is
//      how strongly reclaimable evidence outweighs protective. Low confidence is
//      never safe — it becomes caution.
struct Classifier {

    let explainer: Explainer

    init(explainer: Explainer = Explainer()) {
        self.explainer = explainer
    }

    /// The weight of net reclaimable evidence at or above which a node with no
    /// protective evidence is safe to pre-select. One definitive signal
    /// (CACHEDIR.TAG at 1.0), or two corroborating ones, clears it.
    static let safeThreshold = 1.0

    func classify(_ evidence: [Evidence]) -> Verdict? {
        let reclaimable = evidence.filter { $0.polarity == .reclaimable }
        // A node with no reclaimable evidence is not offered (C3).
        guard !reclaimable.isEmpty else { return nil }

        let protective = evidence.filter { $0.polarity == .protective }
        let reclaimableWeight = reclaimable.reduce(0) { $0 + $1.weight }
        let protectiveWeight = protective.reduce(0) { $0 + $1.weight }
        let hasVeto = protective.contains { $0.isVeto }

        let ordered = evidence.sorted { $0.weight > $1.weight }
        let risk: Risk
        let confidence: Double

        if hasVeto {
            risk = .danger
            confidence = 1.0
        } else if protective.isEmpty && reclaimableWeight >= Self.safeThreshold {
            risk = .safe
            confidence = min(1.0, reclaimableWeight)
        } else {
            // Reclaimable evidence exists but is either not decisive or is opposed
            // by protective evidence short of a veto: offer it, but never
            // pre-selected. Safety over reclaim.
            risk = .caution
            let total = reclaimableWeight + protectiveWeight
            confidence = total > 0 ? max(0, reclaimableWeight - protectiveWeight) / total : 0
        }

        let category = dominantCategory(ordered, risk: risk)
        let summary = explainer.summary(risk: risk, confidence: confidence, evidence: ordered)

        return Verdict(
            risk: risk,
            category: category,
            confidence: confidence,
            evidence: ordered,
            summary: summary)
    }

    // The category is the one argued for by the strongest evidence that names one.
    // For a veto, the winning protective evidence names the category (a matched
    // version → duplicateVersion); otherwise the strongest reclaimable does.
    private func dominantCategory(_ ordered: [Evidence], risk: Risk) -> Category {
        if risk == .danger, let veto = ordered.first(where: { $0.isVeto }), let category = veto.category {
            return category
        }
        for evidence in ordered where evidence.category != nil {
            return evidence.category!
        }
        return .unknown
    }
}
