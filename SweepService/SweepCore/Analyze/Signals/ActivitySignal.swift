import Foundation

// Something written in the last 24 hours is in active use, and that is a
// protective veto: no accumulated reclaimable weight may override it. This is the
// last line of defence against removing a file a process is mid-way through
// writing.
//
// Open file handles are the other half of "in use". Detecting them needs a live
// query (lsof) that no fake filesystem can answer and that would break the
// isolation every signal is tested under; that enrichment is deferred to a
// real-disk pass rather than faked here. The 24-hour write window is the portion
// that is decidable from the node's own metadata.
struct ActivitySignal: Signal {
    let name = "Activity"

    static let activeHours = 24

    func evaluate(_ node: Node, owner: Owner?, context: SignalContext) -> [Evidence] {
        guard let modified = node.modified else { return [] }
        guard Age.hours(from: modified, to: context.now) < Self.activeHours else { return [] }

        return [Evidence(
            signal: name,
            polarity: .protective,
            weight: 1.0,        // veto
            reason: "Written \(Age.phrase(since: modified, now: context.now)) — it is in active use.",
            category: nil)]
    }
}
