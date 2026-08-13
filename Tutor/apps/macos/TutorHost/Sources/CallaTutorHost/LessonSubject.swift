import AppKit

/// Which application the learner actually meant.
///
/// Calla is asked for a lesson from somewhere — a chat window, a terminal — and
/// on the Mac it teaches, that somewhere is in front of the thing being taught.
/// Insisting the subject be frontmost is what made the product impossible to
/// start from the machine it runs on. This remembers the allowlisted
/// application the learner was last actually working in, so the request can
/// arrive from anywhere.
///
/// It grants nothing. Only applications already in the owner's allowlist are
/// ever recorded, and only ones the learner themselves brought forward.
@MainActor
final class LessonSubject: ObservableObject {
    static let shared = LessonSubject()

    private struct Seen {
        let bundleID: String
        let processID: pid_t
        let at: Date
    }

    /// Long enough to cover "switch to chat, type a sentence, send it", short
    /// enough that a lesson never attaches to something from this morning.
    private let memory: TimeInterval = 30 * 60
    private var recent: [Seen] = []

    @Published private(set) var lastSubjectName: String?

    func remember(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        recent.removeAll { $0.bundleID == bundleID }
        recent.insert(Seen(bundleID: bundleID, processID: app.processIdentifier, at: Date()), at: 0)
        recent = Array(recent.prefix(8))
        lastSubjectName = app.localizedName ?? bundleID
    }

    /// Watch what the learner brings forward, so the subject is known before
    /// any lesson is asked for rather than only once one starts.
    func startWatching(allowedBundleIDs: @escaping @Sendable () -> Set<String>) {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                guard allowedBundleIDs().contains(bundleID) else { return }
                LessonSubject.shared.remember(app)
            }
        }
        if let app = NSWorkspace.shared.frontmostApplication,
           let bundleID = app.bundleIdentifier,
           allowedBundleIDs().contains(bundleID) {
            remember(app)
        }
    }

    /// The most recently used allowlisted application that is still running and
    /// has not gone stale.
    func mostRecent(in allowed: Set<String>) -> NSRunningApplication? {
        let cutoff = Date().addingTimeInterval(-memory)
        for seen in recent where seen.at >= cutoff && allowed.contains(seen.bundleID) {
            if let app = NSRunningApplication(processIdentifier: seen.processID), !app.isTerminated {
                return app
            }
            // The application was restarted; find it again by identifier rather
            // than losing the lesson to a stale process id.
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == seen.bundleID && !$0.isTerminated
            }) {
                return app
            }
        }
        // Nothing remembered — the host may have only just started, and the
        // first lesson after a restart should not fail for that. An allowlisted
        // application that is open is unambiguous enough to teach.
        return running(in: allowed)
    }

    private func running(in allowed: Set<String>) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            guard let bundleID = $0.bundleIdentifier else { return false }
            return allowed.contains(bundleID) && !$0.isTerminated && $0.activationPolicy == .regular
        }
    }
}
