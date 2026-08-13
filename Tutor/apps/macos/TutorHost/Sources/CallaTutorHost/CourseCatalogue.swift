import Foundation

/// What Calla could teach, as far as this Mac knows.
///
/// Packs live on the Gateway and retrieval never leaves it, so the Mac cannot
/// answer "what courses exist" by looking. The Gateway pushes the list instead,
/// on the same internal footing as a learning record, and this holds it.
///
/// Cached to disk because the push happens when the Gateway starts, which is
/// usually not when the learner opens the menu. Without a cache the menu would
/// be empty every time the Mac restarted first, which reads as "there are no
/// courses" rather than "nobody has said yet".
///
/// Names and counts only. Nothing here can teach: no steps, no targets, no
/// detectors. Those stay on the Gateway until a lesson actually starts.
@MainActor
final class CourseCatalogue: ObservableObject {
    static let shared = CourseCatalogue()

    struct Lesson: Codable, Identifiable, Equatable {
        let id: String
        let title: String
    }

    struct Course: Codable, Identifiable, Equatable {
        let id: String
        let title: String
        let summary: String
        /// SF Symbol name, or empty. The menu falls back to the application's
        /// own icon, so a course is never listed without a mark beside it.
        let icon: String
        let packID: String
        let bundleIDs: [String]
        let lessons: [Lesson]

        enum CodingKeys: String, CodingKey {
            case id, title, summary, icon
            case packID = "pack_id"
            case bundleIDs = "bundle_ids"
            case lessons
        }
    }

    @Published private(set) var courses: [Course] = []
    /// Hiding a course changes only what this Mac offers. App Packs remain on
    /// the Gateway, where authored lessons and their detectors are owned.
    @Published private(set) var hiddenCourseIDs: Set<String> {
        didSet { defaults.set(Array(hiddenCourseIDs), forKey: Self.hiddenCourseIDsKey) }
    }

    private let file: URL
    private let defaults: UserDefaults
    private static let hiddenCourseIDsKey = "hiddenCourseIDs"

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/CallaTutor", isDirectory: true)
        file = directory.appendingPathComponent("catalogue.json")
        courses = Self.read(from: file)
        hiddenCourseIDs = Set(defaults.stringArray(forKey: Self.hiddenCourseIDsKey) ?? [])
    }

    /// Replace the catalogue with what the Gateway just sent.
    ///
    /// A push with no courses is meaningful — a pack was removed — so it is
    /// stored rather than ignored.
    func replace(with courses: [Course]) {
        self.courses = courses
        write(courses)
    }

    /// The courses that apply to one application, in pack order.
    func courses(forBundleID bundleID: String) -> [Course] {
        courses.filter { !hiddenCourseIDs.contains($0.id) && $0.bundleIDs.contains(bundleID) }
    }

    /// Every course for any application the owner has allowed.
    func courses(forAllowed bundleIDs: [String]) -> [Course] {
        let allowed = Set(bundleIDs)
        return courses.filter { !hiddenCourseIDs.contains($0.id) && !allowed.isDisjoint(with: $0.bundleIDs) }
    }

    /// The bundle id a course is taught in, for starting it and for its icon.
    func bundleID(for course: Course, allowed: [String]) -> String? {
        course.bundleIDs.first { allowed.contains($0) } ?? course.bundleIDs.first
    }

    func isVisible(_ course: Course) -> Bool {
        !hiddenCourseIDs.contains(course.id)
    }

    func setVisible(_ visible: Bool, for course: Course) {
        if visible {
            hiddenCourseIDs.remove(course.id)
        } else {
            hiddenCourseIDs.insert(course.id)
        }
    }

    // MARK: - Disk

    private static func read(from file: URL) -> [Course] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Course].self, from: data)) ?? []
    }

    private func write(_ courses: [Course]) {
        let manager = FileManager.default
        try? manager.createDirectory(at: file.deletingLastPathComponent(),
                                     withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(courses) else { return }
        try? data.write(to: file, options: .atomic)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
