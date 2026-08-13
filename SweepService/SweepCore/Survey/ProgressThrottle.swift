import Foundation

// Rate-limits progress callbacks. The sizer reports every few hundred entries
// because that is a cheap thing for it to count, but a progress bar redrawn a
// few thousand times a second costs more than the walk it is describing — and
// each report crosses onto the main actor.
//
// Time-based rather than count-based on purpose: the right rate is "often enough
// to look alive", which is a property of the display, not of how many files
// happen to sit in a directory.
final class ProgressThrottle: @unchecked Sendable {

    private let minimumInterval: TimeInterval
    private let lock = NSLock()
    private var lastEmit: Date?

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    /// True at most once per `minimumInterval`. Safe to call from the walk's
    /// threads, which are not the main actor and may be several.
    func shouldEmit(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let lastEmit, now.timeIntervalSince(lastEmit) < minimumInterval { return false }
        lastEmit = now
        return true
    }
}
