import Foundation

// A classified, actionable node — the thing the user is offered (C3, C5). Only
// produced when there is reclaimable evidence; silence is the default.
struct Target: Identifiable, Codable, Equatable {
    let id: String
    let title: String           // owner display name, or the path when unattributed
    let url: URL
    let owner: Owner?
    let verdict: Verdict
    let defaultReclaim: Reclaim
    /// ALLOCATED bytes, including folded descendants (C1).
    let bytes: Int64
    let lastModified: Date?
    /// Structural nature descriptor, carried so a reclaim can be recorded against
    /// what the node *was* (C7 regrowth fingerprint). Empty for hand-built targets.
    var fingerprint: String = ""
    /// The analysed descendants folded into this target, largest first.
    ///
    /// They are a **disclosure of this row, never rows of their own**. That is the
    /// reading of C2's "never offer a parent and its descendant as separate
    /// targets" that lets a 36 GB group be reclaimed in parts: the same bytes are
    /// still counted once, because any selection containing both an ancestor and
    /// a descendant is reduced to the ancestor before it is totalled or planned
    /// (`SelectionModel.selectedTargets`).
    ///
    /// Each carries its own verdict and its own full subtree size — what removing
    /// *it* would free — so a component reads exactly like the target it would be
    /// if it stood alone.
    ///
    /// A vetoed descendant is never a component. It is not suppressed in the
    /// first place, so it keeps its own withheld row, where the veto and the
    /// evidence for it are the whole point.
    var components: [Target] = []

    var risk: Risk { verdict.risk }
    var category: Category { verdict.category }
}

// How a target is reclaimed (C5). The command case is populated from KnownTools
// after the verdict, never before it — enrichment, not input.
enum Reclaim: Codable, Equatable {
    case trash
    case hardDelete
    case command([String])

    /// C5: anything larger than 5 GB defaults to permanent deletion, because
    /// Trashing it frees no space and the reported figure would be false.
    static let permanentThreshold: Int64 = 5 * 1024 * 1024 * 1024

    static func `default`(forBytes bytes: Int64) -> Reclaim {
        bytes > permanentThreshold ? .hardDelete : .trash
    }

    var isPermanent: Bool {
        if case .hardDelete = self { return true }
        return false
    }
}
