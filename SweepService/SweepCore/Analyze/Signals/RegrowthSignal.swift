import Foundation

// Something that Sweep removed and that came back is, by demonstration, a cache:
// it rebuilds itself. A path that has regrown after two or more sweeps is strong
// reclaimable evidence (0.9).
//
// The signal is written now against the `RegrowthReading` protocol; the store that
// feeds it — recording what was reclaimed and observing what reappeared — is
// Phase 09. With no store wired in, it correctly emits nothing.
struct RegrowthSignal: Signal {
    let name = "Regrowth"

    static let confirmingSweeps = 2

    func evaluate(_ node: Node, owner: Owner?, context: SignalContext) -> [Evidence] {
        guard let regrowth = context.regrowth,
              let observation = regrowth.regrowth(for: node.url),
              observation.count >= Self.confirmingSweeps
        else { return [] }

        // The reason names the observed interval when it is known, so the user sees
        // the evidence Sweep actually earned rather than a bare count.
        let interval = observation.lastIntervalDays.map { " — last time within \($0) day\($0 == 1 ? "" : "s")" } ?? ""
        return [Evidence(
            signal: name,
            polarity: .reclaimable,
            weight: 0.9,
            reason: "Regrew after \(observation.count) previous sweeps\(interval); it rebuilds itself, so it is cache.",
            category: .cache)]
    }
}
