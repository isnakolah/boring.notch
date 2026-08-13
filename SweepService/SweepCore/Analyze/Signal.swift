import Foundation

// A signal is an independent detector. Given a node, its resolved owner, and the
// survey context, it emits zero or more `Evidence` values.
//
// The one rule that keeps the analysis auditable: **a signal may not read another
// signal's output.** Every signal derives its evidence only from the disk, the
// node, and the owner. Only the `Classifier` combines them. This is what lets each
// be tested in complete isolation.
protocol Signal: Sendable {
    var name: String { get }
    func evaluate(_ node: Node, owner: Owner?, context: SignalContext) -> [Evidence]
}

// Everything a signal is allowed to consult. Note what is *not* here: no other
// signal's output, no classifier, no KnownTools.
struct SignalContext: Sendable {
    let fileSystem: FileSystem
    /// Injected so staleness and activity are deterministic in tests rather than
    /// depending on the wall clock.
    let now: Date
    /// Prior-sweep history for the regrowth signal (Phase 09). nil disables it.
    let regrowth: RegrowthReading?

    init(fileSystem: FileSystem, now: Date, regrowth: RegrowthReading? = nil) {
        self.fileSystem = fileSystem
        self.now = now
        self.regrowth = regrowth
    }
}

// Age phrasing shared by the time-based signals, so "94 days ago" reads the same
// wherever it appears.
enum Age {
    static func days(from date: Date, to now: Date) -> Int {
        Int(now.timeIntervalSince(date) / 86_400)
    }
    static func hours(from date: Date, to now: Date) -> Int {
        Int(now.timeIntervalSince(date) / 3_600)
    }
    static func phrase(since date: Date, now: Date) -> String {
        let d = days(from: date, to: now)
        if d >= 1 { return "\(d) day\(d == 1 ? "" : "s") ago" }
        let h = hours(from: date, to: now)
        if h >= 1 { return "\(h) hour\(h == 1 ? "" : "s") ago" }
        return "less than an hour ago"
    }
}

// What the regrowth signal reads.
protocol RegrowthReading: Sendable {
    /// The regrowth history for a path, or nil when it has none.
    func regrowth(for url: URL) -> RegrowthObservation?
}

// How a path has behaved across sweeps: how many times it was reclaimed and then
// reappeared, and how long the most recent return took.
struct RegrowthObservation: Equatable, Sendable {
    let count: Int
    let lastIntervalDays: Int?
}
