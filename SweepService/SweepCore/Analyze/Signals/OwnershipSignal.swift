import Foundation

// Reads the owner attribution (C6) as evidence:
//   - an owner that resolves but is not installed is an orphan — its data is
//     reclaimable (0.6). This is the orphaned-leftovers case.
//   - an owner that is currently running makes its data protective: a live
//     application's state is not Sweep's to remove out from under it (0.8).
//
// A node with no resolved owner produces nothing here — absence of attribution is
// not evidence either way.
struct OwnershipSignal: Signal {
    let name = "Ownership"

    func evaluate(_ node: Node, owner: Owner?, context: SignalContext) -> [Evidence] {
        guard let owner else { return [] }

        if !owner.isInstalled {
            return [Evidence(
                signal: name,
                polarity: .reclaimable,
                weight: 0.6,
                reason: "Owner \(owner.displayName) is not installed on this Mac.",
                category: .orphan)]
        }

        if owner.isRunning {
            return [Evidence(
                signal: name,
                polarity: .protective,
                weight: 0.8,
                reason: "Owner \(owner.displayName) is currently running.",
                category: nil)]
        }

        return []
    }
}
