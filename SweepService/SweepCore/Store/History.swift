import Foundation

// The resident record: how disk pressure has trended, and every sweep Sweep has
// performed. Local JSON under Application Support, alongside but separate from the
// regrowth store. It is what turns Sweep from a one-shot into a tool that can be
// audited after the fact — each reclaim keeps the verdict that justified it.
final class History: @unchecked Sendable {

    // A point on the used-space trend.
    struct SizeSample: Codable, Equatable {
        let date: Date
        let usedBytes: Int64
        let totalBytes: Int64
        var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    }

    // One completed sweep. `measuredFreedBytes` is the df delta, NEVER the sum of
    // the selected items — the log records what was actually freed.
    struct ReclaimLogEntry: Codable, Equatable, Identifiable {
        let id: String
        let date: Date
        let measuredFreedBytes: Int64
        let trashedBytes: Int64
        let items: [Item]

        // A reclaimed item and the verdict that justified removing it.
        struct Item: Codable, Equatable {
            let title: String
            let path: String
            let mechanism: String
            let allocatedBytes: Int64
            let risk: String
            let category: String
            let summary: String
        }
    }

    private struct Contents: Codable {
        var samples: [SizeSample] = []
        var log: [ReclaimLogEntry] = []
    }

    /// Trend samples older than this are pruned; the reclaim log is kept longer.
    static let sampleRetention: TimeInterval = 365 * 86_400
    static let maxLogEntries = 500

    private let url: URL
    private let lock = NSLock()
    private var contents: Contents

    init(fileURL: URL? = nil) {
        self.url = fileURL ?? History.defaultURL()
        self.contents = History.load(from: self.url)
    }

    static func defaultURL() -> URL {
        SweepStorage.url("history.json")
    }

    // MARK: Recording

    /// Records a used-space sample, at most one per hour so the trend does not
    /// fill with near-identical points on repeated opens.
    func recordSample(used: Int64, total: Int64, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        if let last = contents.samples.last, date.timeIntervalSince(last.date) < 3_600 { return }
        contents.samples.append(SizeSample(date: date, usedBytes: used, totalBytes: total))
        persist()
    }

    func recordSweep(_ entry: ReclaimLogEntry) {
        lock.lock(); defer { lock.unlock() }
        contents.log.append(entry)
        if contents.log.count > Self.maxLogEntries {
            contents.log.removeFirst(contents.log.count - Self.maxLogEntries)
        }
        persist()
    }

    // MARK: Reading

    var samples: [SizeSample] {
        lock.lock(); defer { lock.unlock() }
        return contents.samples
    }

    /// The reclaim log, most recent first.
    var log: [ReclaimLogEntry] {
        lock.lock(); defer { lock.unlock() }
        return contents.log.reversed()
    }

    /// Total bytes actually freed across every recorded sweep.
    var cumulativeFreedBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return contents.log.reduce(0) { $0 + $1.measuredFreedBytes }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        contents = Contents()
        persist()
    }

    // MARK: Persistence

    private func persist() {
        let cutoff = (contents.samples.map(\.date).max() ?? Date()).addingTimeInterval(-Self.sampleRetention)
        contents.samples = contents.samples.filter { $0.date >= cutoff }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(contents).write(to: url, options: .atomic)
        } catch {
            // Persisting must never crash a survey or a sweep.
        }
    }

    private static func load(from url: URL) -> Contents {
        guard let data = try? Data(contentsOf: url) else { return Contents() }
        // A corrupt file is recovered from, not fatal — the history is a record,
        // not a source of truth for a verdict.
        return (try? JSONDecoder().decode(Contents.self, from: data)) ?? Contents()
    }
}
