import Foundation

/// Small, deterministic presentation rules. Keep snapshot derivation testable
/// without granting tests or UI access to engine processes or user files.
enum CallaCoursePresentation {
    static let lifecyclePhases: Set<String> = ["queued", "compiling", "validating", "waiting_for_blender", "preflighting", "ready_for_review", "publishing", "published", "failed", "cancelled", "archived"]

    static func lifecyclePhase(_ value: String?) -> String? {
        guard let value, lifecyclePhases.contains(value) else { return nil }
        return value
    }

    /// Owner Settings may review an unpublished revision, but learner surfaces
    /// must never offer it.  A missing or transitional lifecycle fails closed.
    static func isLearnerVisible(lifecyclePhase phase: String?) -> Bool {
        lifecyclePhase(phase) == "published"
    }

    static func progress(_ lessons: [(completed: Bool, due: Bool)]) -> (completed: Int, due: Bool) {
        (lessons.filter(\.completed).count, lessons.contains { $0.due })
    }

    static func isHidden(courseID: String, hiddenIDs: Set<String>) -> Bool { hiddenIDs.contains(courseID) }
}
