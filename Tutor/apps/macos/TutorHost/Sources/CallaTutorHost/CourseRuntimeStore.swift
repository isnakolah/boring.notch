import Foundation
import TutorProtocol

/// Owner-only cache pushed by Gateway. It is intentionally executable only as
/// local UI guidance: authored text plus canonical descriptors, never captures,
/// coordinates, model output, or learner history.
@MainActor
final class CourseRuntimeStore: ObservableObject {
    static let shared = CourseRuntimeStore()

    /// One named way this step goes wrong, and what to say about it.
    ///
    /// `when` is a whole canonical detector, not an id: the Mac evaluates it the
    /// same way it evaluates a success condition, so a diagnosis is exactly as
    /// trustworthy as the check it sits beside and introduces no new authority.
    struct Diagnosis: Codable {
        let when: JSONValue
        let say: String
    }

    struct Step: Codable {
        let id: String
        let phase: String
        let text: String
        let targetDescriptor: JSONValue
        let detectorDescriptor: JSONValue?
        /// Checked in order when the step's own check fails. First match wins.
        let diagnose: [Diagnosis]?

        enum CodingKeys: String, CodingKey {
            case id, phase, text, diagnose
            case targetDescriptor = "target_descriptor"
            case detectorDescriptor = "detector_descriptor"
        }
    }
    struct Lesson: Codable {
        let id: String
        let title: String
        let assets: [Asset]
        let steps: [Step]
        /// What must already be true before this lesson makes sense. Authored
        /// since the first pack and, until now, enforced nowhere: a learner with
        /// a Light selected started a lesson about meshes and was told "Not yet"
        /// at every step without ever being told why.
        let prerequisites: [Diagnosis]?
        /// How far Calla may go when a step is failed repeatedly.
        let escalation: [String]?
    }
    struct Asset: Codable {
        let assetID: String
        let role: String
        let sha256: String
        let bytes: Int
        enum CodingKeys: String, CodingKey { case assetID = "asset_id", role, sha256, bytes }
    }
    struct Course: Codable {
        let courseID: String
        let courseRevision: String
        let appBundleID: String
        let appVersion: String
        let lessons: [Lesson]

        enum CodingKeys: String, CodingKey {
            case courseID = "course_id"
            case courseRevision = "course_revision"
            case appBundleID = "app_bundle_id"
            case appVersion = "app_version"
            case lessons
        }
    }
    struct Manifest: Codable {
        let format: String
        let formatVersion: Int
        let courses: [Course]

        enum CodingKeys: String, CodingKey { case format; case formatVersion = "format_version"; case courses }
    }

    @Published private(set) var manifest: Manifest?
    private let file: URL

    private init() {
        file = CallaRuntime.file("course-runtime.json")
        manifest = Self.read(file)
    }

    func replace(_ candidate: Manifest) throws {
        guard candidate.format == "calla-course-runtime", candidate.formatVersion == 1,
              candidate.courses.count <= 200 else {
            throw TutorHostFailure(code: "invalid_course_runtime", message: "Course runtime manifest is unsupported")
        }
        for course in candidate.courses {
            guard !course.courseID.isEmpty, !course.courseRevision.isEmpty, !course.appBundleID.isEmpty,
                  !course.appVersion.isEmpty, !course.lessons.isEmpty else {
                throw TutorHostFailure(code: "invalid_course_runtime", message: "Course runtime entry is incomplete")
            }
            for lesson in course.lessons {
                guard lesson.assets.count == 2,
                      Set(lesson.assets.map(\.role)) == Set(["starter", "proof"]),
                      lesson.assets.allSatisfy({ !$0.assetID.isEmpty && $0.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil && $0.bytes > 0 }) else {
                    throw TutorHostFailure(code: "invalid_course_runtime", message: "Course runtime assets are invalid")
                }
                for step in lesson.steps {
                    guard !step.text.isEmpty, ["guided", "assessment", "transfer"].contains(step.phase) else {
                        throw TutorHostFailure(code: "invalid_course_runtime", message: "Course runtime step is invalid")
                    }
                    _ = try UITargetDescriptor(raw: step.targetDescriptor)
                    if let detector = step.detectorDescriptor { _ = try DetectorDescriptor(raw: detector) }
                    // A diagnosis carries a detector and a sentence, and both are
                    // validated the same way the step's own check is: an
                    // explanation the Mac cannot verify is worse than no
                    // explanation, because the learner believes it.
                    for diagnosis in (step.diagnose ?? []).prefix(8) {
                        guard !diagnosis.say.isEmpty, diagnosis.say.count <= 240 else {
                            throw TutorHostFailure(code: "invalid_course_runtime", message: "Course runtime diagnosis is invalid")
                        }
                        _ = try DetectorDescriptor(raw: diagnosis.when)
                    }
                }
                for prerequisite in (lesson.prerequisites ?? []).prefix(8) {
                    guard !prerequisite.say.isEmpty, prerequisite.say.count <= 240 else {
                        throw TutorHostFailure(code: "invalid_course_runtime", message: "Course runtime prerequisite is invalid")
                    }
                    _ = try DetectorDescriptor(raw: prerequisite.when)
                }
            }
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(candidate)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        manifest = candidate
    }

    func run(courseID: String, lessonID: String, bundleID: String, version: String) -> FastLessonRun? {
        guard let course = manifest?.courses.first(where: { $0.courseID == courseID && $0.appBundleID == bundleID && versionMatches(version, $0.appVersion) }),
              let lesson = course.lessons.first(where: { $0.id == lessonID }) else { return nil }
        return FastLessonRun(courseID: course.courseID, revision: course.courseRevision, bundleID: bundleID, lesson: lesson)
    }

    /// The cached entry for a course, whichever revision is held.
    ///
    /// Read-only, and deliberately not version-matched: a library that shows
    /// nothing when the installed application is the wrong version cannot say
    /// *that* is why, which is the one thing worth telling the learner.
    func course(id: String) -> Course? {
        manifest?.courses.first { $0.courseID == id }
    }

    /// What the cache knows about one lesson — how many steps it has, what has
    /// to be true first. The catalogue carries only names and counts, so this is
    /// the only local answer to "how long is this".
    func lesson(courseID: String, lessonID: String) -> Lesson? {
        course(id: courseID)?.lessons.first { $0.id == lessonID }
    }

    func declaredBundleID(courseID: String, allowed: Set<String>) -> String? {
        manifest?.courses.first(where: { $0.courseID == courseID && allowed.contains($0.appBundleID) })?.appBundleID
    }

    private static func read(_ file: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: file), let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.format == "calla-course-runtime", manifest.formatVersion == 1 else { return nil }
        return manifest
    }
}

/// One local run, pinned to cache revision and declared application. This type
/// owns route position only; target resolution and detectors stay in existing
/// App Pack contracts.
@MainActor
final class FastLessonRun {
    let courseID: String
    let revision: String
    let bundleID: String
    let lesson: CourseRuntimeStore.Lesson
    private(set) var index = 0
    private(set) var generation = UUID()
    /// How many times this step has been checked and found unfinished. Drives
    /// how much help the next attempt gets.
    private(set) var attempts = 0
    /// The application's state when this step was put on screen, so "what did
    /// the learner actually do" can be answered without asking anyone.
    var stateAtStep: BlenderStateDigest?

    init(courseID: String, revision: String, bundleID: String, lesson: CourseRuntimeStore.Lesson) {
        self.courseID = courseID; self.revision = revision; self.bundleID = bundleID; self.lesson = lesson
    }
    var current: CourseRuntimeStore.Step? { lesson.steps.indices.contains(index) ? lesson.steps[index] : nil }
    var isFinalTransfer: Bool { current?.phase == "transfer" && index == lesson.steps.count - 1 }
    func advance() { index += 1; attempts = 0; stateAtStep = nil; generation = UUID() }
    func noteAttempt() { attempts += 1 }

    /// How much help this attempt earns.
    ///
    /// The ladder is the lesson's — `teaching_policy.escalation` has been
    /// authored since the first pack and walked by nothing — so a lesson that
    /// says it will only ever explain is never going to highlight.
    var assistance: String {
        let ladder = lesson.escalation ?? ["explain", "highlight", "point"]
        guard !ladder.isEmpty else { return "explain" }
        return ladder[min(max(attempts - 1, 0), ladder.count - 1)]
    }
}

/// Whether an installed application version satisfies a course's declared range,
/// in the `>=5.2 <5.3` shape App Packs use.
///
/// Not private any more: the library shows a course pinned to a version this Mac
/// is not running as pinned, rather than letting the learner press Start and be
/// told by a runtime error.
func versionMatches(_ version: String, _ range: String) -> Bool {
    func parts(_ value: String) -> [Int]? {
        let source = value.split(separator: ".").prefix(3)
        guard !source.isEmpty else { return nil }
        let output = source.map { Int($0) }
        guard !output.contains(where: { $0 == nil }) else { return nil }
        return output.compactMap { $0 } + Array(repeating: 0, count: 3 - output.count)
    }
    guard let actual = parts(version) else { return false }
    for term in range.split(whereSeparator: \.isWhitespace) {
        let text = String(term)
        let op = [">=", "<=", ">", "<", "="].first(where: { text.hasPrefix($0) }) ?? "="
        guard let expected = parts(String(text.dropFirst(op.count))) else { return false }
        let comparison = zip(actual, expected).first(where: { $0 != $1 }).map { $0 < $1 ? -1 : 1 } ?? 0
        if (op == ">=" && comparison < 0) || (op == "<=" && comparison > 0) ||
            (op == ">" && comparison <= 0) || (op == "<" && comparison >= 0) || (op == "=" && comparison != 0) { return false }
    }
    return true
}
