import Foundation

// C7 — the memory that lets the analysis improve on this specific machine.
//
// It records what Sweep reclaimed, and on later surveys notices which of those
// paths came back. A path reclaimed and returned two or more times has
// demonstrated it rebuilds itself, which is what a cache is — so `RegrowthSignal`
// reads this and adds reclaimable evidence.
//
// Two disciplines it holds to:
//   - a reclaim that never returns is not evidence of anything, and is never
//     treated as such;
//   - regrowth is credited only when the returned path is structurally the *same
//     kind of thing* that was reclaimed (the fingerprint), so a cache directory
//     that is later replaced by something else does not inherit the cache's
//     history.
//
// It is local JSON under Application Support, never leaves the machine (there is
// no network to leave by, C8), and is inspectable and clearable from Settings.
final class RegrowthStore: RegrowthReading, @unchecked Sendable {

    // Per-path history. `awaitingReturn` is true after a reclaim, until the path is
    // next seen; each observed return increments `count`.
    struct History: Codable, Equatable {
        var fingerprint: String
        var count: Int
        var awaitingReturn: Bool
        var lastReclaimAt: Date?
        var lastReturnAt: Date?
        var lastIntervalDays: Int?
        var lastBytes: Int64
        /// When this record was last touched, for retention pruning.
        var updatedAt: Date
    }

    /// Entries untouched for longer than this are pruned on save.
    static let retention: TimeInterval = 180 * 86_400

    private let url: URL
    private let lock = NSLock()
    private var histories: [String: History]

    init(fileURL: URL? = nil) {
        self.url = fileURL ?? RegrowthStore.defaultURL()
        self.histories = RegrowthStore.load(from: self.url)
    }

    static func defaultURL() -> URL {
        SweepStorage.url("regrowth.json")
    }

    // MARK: Recording

    /// Records a reclaim. The path is now awaiting a possible return.
    func recordReclaim(path: String, fingerprint: String, bytes: Int64, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        var history = histories[path] ?? History(
            fingerprint: fingerprint, count: 0, awaitingReturn: false,
            lastReclaimAt: nil, lastReturnAt: nil, lastIntervalDays: nil,
            lastBytes: 0, updatedAt: date)
        // A different fingerprint means this is a different thing at the same path;
        // start its history fresh rather than crediting the old one's returns.
        if history.fingerprint != fingerprint {
            history = History(fingerprint: fingerprint, count: 0, awaitingReturn: false,
                              lastReclaimAt: nil, lastReturnAt: nil, lastIntervalDays: nil,
                              lastBytes: 0, updatedAt: date)
        }
        history.awaitingReturn = true
        history.lastReclaimAt = date
        history.lastBytes = bytes
        history.updatedAt = date
        histories[path] = history
        persist()
    }

    /// Observes the paths present in a survey. A path that was reclaimed, is
    /// awaiting a return, and now appears with a matching fingerprint is credited
    /// with a regrowth and the interval it took.
    func observePresence(_ present: [(path: String, fingerprint: String)], at date: Date) {
        lock.lock(); defer { lock.unlock() }
        for entry in present {
            guard var history = histories[entry.path], history.awaitingReturn else { continue }
            // Only credit a return of the same kind of thing.
            guard history.fingerprint == entry.fingerprint else { continue }
            history.count += 1
            history.awaitingReturn = false
            history.lastReturnAt = date
            if let reclaimedAt = history.lastReclaimAt {
                history.lastIntervalDays = max(0, Int(date.timeIntervalSince(reclaimedAt) / 86_400))
            }
            history.updatedAt = date
            histories[entry.path] = history
        }
        persist()
    }

    // MARK: Reading

    func regrowth(for url: URL) -> RegrowthObservation? {
        lock.lock(); defer { lock.unlock() }
        guard let history = histories[url.path], history.count > 0 else { return nil }
        return RegrowthObservation(count: history.count, lastIntervalDays: history.lastIntervalDays)
    }

    /// A snapshot for the Settings inspector.
    var entries: [(path: String, history: History)] {
        lock.lock(); defer { lock.unlock() }
        return histories
            .map { ($0.key, $0.value) }
            .sorted { $0.1.count > $1.1.count }
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return histories.isEmpty
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        histories = [:]
        persist()
    }

    // MARK: Persistence

    private func persist() {
        // Prune stale entries so the store cannot grow without bound. The window is
        // measured from the store's most recent activity rather than the wall
        // clock, so it is deterministic and independent of when it happens to be
        // saved.
        if let newest = histories.values.map(\.updatedAt).max() {
            let cutoff = newest.addingTimeInterval(-Self.retention)
            histories = histories.filter { $0.value.updatedAt >= cutoff }
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(histories)
            try data.write(to: url, options: .atomic)
        } catch {
            // A failure to persist must not crash a survey or a sweep; the in-memory
            // state stays correct for this run.
        }
    }

    private static func load(from url: URL) -> [String: History] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        // A corrupt store is recovered from, not fatal: start fresh rather than
        // crash, since the history is an optimisation, not a source of truth.
        return (try? JSONDecoder().decode([String: History].self, from: data)) ?? [:]
    }
}
