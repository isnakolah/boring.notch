import Foundation

// Renders a verdict's evidence into the sentence the user reads. It writes a
// headline for the risk tier, then concatenates each `Evidence.reason` in weight
// order. **It contains no per-path copy and invents no sentence.** Every clause
// after the headline is verbatim from an `Evidence.reason`, which is what the
// explainer test asserts structurally: if Sweep cannot say why something is safe
// from the evidence, it does not get to say it at all.
struct Explainer {

    // Headlines are the only text the explainer authors, and they describe the
    // verdict tier, not any particular path.
    func headline(risk: Risk, confidence: Double) -> String {
        switch risk {
        case .safe:
            return "Safe to remove — \(confidenceWord(confidence)) confidence."
        case .caution:
            return "Review before removing."
        case .danger:
            return "Withheld — not safe to remove."
        }
    }

    func summary(risk: Risk, confidence: Double, evidence: [Evidence]) -> String {
        let reasons = evidence.map(\.reason)
        return ([headline(risk: risk, confidence: confidence)] + reasons).joined(separator: " ")
    }

    private func confidenceWord(_ confidence: Double) -> String {
        switch confidence {
        case ..<0.5: return "low"
        case 0.5..<0.85: return "moderate"
        default: return "high"
        }
    }

    /// The set of sentences a summary is allowed to contain: the headline plus the
    /// evidence reasons. The explainer test uses this to prove no summary carries a
    /// sentence that did not come from evidence.
    func permittedSentences(risk: Risk, confidence: Double, evidence: [Evidence]) -> Set<String> {
        Set([headline(risk: risk, confidence: confidence)] + evidence.map(\.reason))
    }
}
