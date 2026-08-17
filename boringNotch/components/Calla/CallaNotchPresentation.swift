import Foundation

/// The notch content area is a fixed ~488x130pt slab that never scrolls, so the
/// decision of *what* deserves that space is worth keeping pure and tested.
/// SwiftUI in `CallaTabView` only renders what this decides.
enum CallaNotchPresentation {
    /// Only one of these is ever on screen. Teaching wins over everything else:
    /// mid-lesson, catalogue browsing is noise.
    enum Mode: String, Equatable {
        case teaching
        case offline
        /// The host is up and can teach a cached course, but the Gateway is not
        /// answering. Distinct from `offline` because the local fast-lesson
        /// path needs no Gateway at all.
        case degraded
        case empty
        case idle
    }

    enum Tone: String, Equatable {
        case active
        case ready
        case warning
    }

    struct Pill: Equatable {
        let text: String
        let tone: Tone
    }

    /// `hostReady` is whether the Tutor host answers its socket; `gatewayReachable`
    /// is one HEAD against a fixed tailnet route. Folding the two together meant
    /// Tailscale being down, or the Serve route restarting, reported the whole
    /// feature as Offline on a Mac that was perfectly able to teach.
    static func mode(running: Bool, hostReady: Bool, gatewayReachable: Bool,
                     hasCourses: Bool, lessonActive: Bool) -> Mode {
        if lessonActive { return .teaching }
        if !running || !hostReady { return .offline }
        if !hasCourses { return .empty }
        if !gatewayReachable { return .degraded }
        return .idle
    }

    static func pill(for mode: Mode) -> Pill {
        switch mode {
        case .teaching: return Pill(text: "Teaching", tone: .active)
        case .offline: return Pill(text: "Offline", tone: .warning)
        case .degraded: return Pill(text: "Gateway offline", tone: .warning)
        case .empty: return Pill(text: "No courses", tone: .warning)
        case .idle: return Pill(text: "Ready", tone: .ready)
        }
    }

    static func primaryActionTitle(completedCount: Int) -> String {
        completedCount > 0 ? "Resume" : "Start"
    }

    /// A running lesson pins the notch to its own course; otherwise the user's
    /// pick survives catalogue refreshes, and only a vanished course resets it.
    static func resolveSelection(current: String, availableIDs: [String], activeCourseID: String?) -> String {
        if let activeCourseID, availableIDs.contains(activeCourseID) { return activeCourseID }
        if availableIDs.contains(current) { return current }
        return availableIDs.first ?? ""
    }

    /// One line of course thread fits under the title. Newlines would silently
    /// grow the slab past the notch, so they collapse to spaces.
    static func threadLine(_ thread: [String], limit: Int = 120) -> String? {
        guard let last = thread.last else { return nil }
        let flattened = last
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard !flattened.isEmpty else { return nil }
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Facts worth the one subtitle line, in the order they earn it.
    static func teachingSubtitle(courseTitle: String, completed: Int, total: Int, stepCount: Int) -> String {
        var parts = [courseTitle]
        if total > 0 { parts.append("\(completed)/\(total) lessons") }
        if stepCount > 0 { parts.append("\(stepCount) steps") }
        return parts.joined(separator: " · ")
    }

    static func canAsk(question: String, running: Bool) -> Bool {
        running && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
