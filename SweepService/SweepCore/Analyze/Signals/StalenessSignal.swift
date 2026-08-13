import Foundation

// Age as evidence. Untouched for a long time is weak reclaimable evidence (0.3) —
// on its own it decides nothing, but it corroborates a cache or an orphan.
// Recently modified is protective (0.5): whatever it is, someone is using it, and
// that is reason for caution regardless of what the other signals concluded.
struct StalenessSignal: Signal {
    let name = "Staleness"

    static let staleDays = 30
    static let recentDays = 7

    func evaluate(_ node: Node, owner: Owner?, context: SignalContext) -> [Evidence] {
        guard let modified = node.modified else { return [] }
        let days = Age.days(from: modified, to: context.now)

        if days >= Self.staleDays {
            return [Evidence(
                signal: name,
                polarity: .reclaimable,
                weight: 0.3,
                reason: "Last modified \(Age.phrase(since: modified, now: context.now)).",
                category: nil)]
        }

        if days < Self.recentDays {
            return [Evidence(
                signal: name,
                polarity: .protective,
                weight: 0.5,
                reason: "Modified recently, \(Age.phrase(since: modified, now: context.now)).",
                category: nil)]
        }

        return []
    }
}
