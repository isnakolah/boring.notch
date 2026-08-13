import Foundation
import UserNotifications

/// One notification per meaningful lifecycle transition. Gateway sends frequent
/// compact status refreshes, so notifying every push would turn elapsed-time
/// updates into noise and hide the important ready/failed/published events.
@MainActor
enum CourseNotifications {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    /// Only the transitions worth interrupting someone for.
    ///
    /// The intermediate build phases — compiling, preflighting, publishing —
    /// deliberately post nothing. A course walks through all of them in under a
    /// minute, and six banners for one import is how notifications get turned
    /// off for good. The pane shows them live; a banner is for when the pane is
    /// closed and the answer has changed.
    static func post(for course: CourseLifecycleStore.Course, previous: CourseLifecycleStore.Course?) {
        guard previous?.phase != course.phase else { return }
        let message: (title: String, body: String)?
        switch course.phase {
        case "queued": message = ("Course queued", "\(course.title) is being prepared.")
        case "waiting_for_blender": message = ("Course needs Blender", course.nextAction ?? "Open \(course.targetApp ?? "the target application") to continue \(course.title).")
        case "published": message = ("Course published", "\(course.title) is now available in Calla.")
        case "failed": message = ("Course needs attention", course.error ?? "\(course.title) could not be prepared.")
        case "cancelled": message = ("Course cancelled", "\(course.title) stopped preparing.")
        case "archived": message = ("Course archived", "\(course.title) is hidden from the learner menu.")
        default: message = nil
        }
        guard let message else { return }
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "calla-course-\(course.id)-\(course.revision)-\(course.phase)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

/// Compact Gateway-pushed course state. It deliberately has no logs, prompts,
/// captures, paths, or tool output: Settings needs status, not authoring traces.
@MainActor
final class CourseLifecycleStore: ObservableObject {
    static let shared = CourseLifecycleStore()

    struct Course: Codable, Identifiable, Hashable {
        let id: String
        let revision: Int
        let phase: String
        let title: String
        let targetApp: String?
        let targetVersion: String?
        let lessonCount: Int
        let warnings: [String]
        let error: String?
        let elapsedMS: Int?
        let nextAction: String?

        enum CodingKeys: String, CodingKey {
            case id, revision, phase, title, warnings, error
            case targetApp = "target_app", targetVersion = "target_version"
            case lessonCount = "lesson_count", elapsedMS = "elapsed_ms", nextAction = "next_action"
        }

        /// Calla is getting on with it and nothing is being asked of the owner.
        ///
        /// This list is the Gateway's, and it has to stay the Gateway's: it read
        /// `waiting_for_app, preparing` for a while — names the Gateway has
        /// never sent — so a course vanished from the pane during compiling,
        /// preflighting and publishing and reappeared for validating. One import
        /// looked like it had failed twice and recovered twice.
        var isActive: Bool {
            ["queued", "compiling", "validating", "preflighting", "publishing"].contains(phase)
        }

        /// Stopped, and waiting on a person. Exactly the phases the Gateway will
        /// accept a `retry` for, so the button this shows always works.
        var needsAttention: Bool {
            ["failed", "cancelled", "waiting_for_blender"].contains(phase)
        }

        var isPublished: Bool { phase == "published" }
        var isArchived: Bool { phase == "archived" }

        /// The phase in words.
        ///
        /// There is no review step and there never was one on the Gateway: it
        /// publishes as soon as preflight passes. The pane spent a long time
        /// offering a Publish button for a phase that is never sent.
        var phaseLabel: String {
            switch phase {
            case "queued": return "Queued"
            case "compiling": return "Writing the lessons"
            case "validating": return "Checking the lessons"
            case "waiting_for_blender": return "Waiting for Blender"
            case "preflighting": return "Trying it in Blender"
            case "publishing": return "Publishing"
            case "published": return "Published"
            case "failed": return "Failed"
            case "cancelled": return "Cancelled"
            case "archived": return "Archived"
            default: return phase.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        var elapsedLabel: String {
            let seconds = max(0, (elapsedMS ?? 0) / 1_000)
            return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
        }
    }

    @Published private(set) var courses: [Course] = []
    private let file: URL

    private init() {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/CallaTutor", isDirectory: true)
        file = directory.appendingPathComponent("course-status.json")
        courses = Self.read(file)
    }

    func replace(with courses: [Course]) {
        let old = Dictionary(uniqueKeysWithValues: self.courses.map { ($0.id, $0) })
        self.courses = courses.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        for course in self.courses { CourseNotifications.post(for: course, previous: old[course.id]) }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder().encode(self.courses) { try? data.write(to: file, options: .atomic) }
    }

    private static func read(_ file: URL) -> [Course] {
        guard let data = try? Data(contentsOf: file), let result = try? JSONDecoder().decode([Course].self, from: data) else { return [] }
        return result
    }
}

/// Bounded, local course continuity. It is intentionally not a transcript and
/// never accepts screen data, titles, paths, raw model text, or tool payloads.
@MainActor
final class CourseRunStore: ObservableObject {
    static let shared = CourseRunStore()
    private static let cap = 40
    private static let textCap = 240

    struct Entry: Codable, Identifiable, Hashable {
        let id: UUID
        let kind: String
        let text: String
        let at: Date
    }
    struct Run: Codable {
        var checkpointLessonID: String?
        var entries: [Entry]
    }
    @Published private(set) var runs: [String: Run] = [:]
    private let file: URL

    private init() {
        file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/CallaTutor/course-runs.json")
        runs = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Run].self, from: $0) } ?? [:]
    }

    func entries(for courseID: String) -> [Entry] { runs[courseID]?.entries ?? [] }
    func checkpoint(for courseID: String) -> String? { runs[courseID]?.checkpointLessonID }

    /// The course the learner was last working on, so "resume" has something to
    /// resume without asking them which one.
    var mostRecentCourseID: String? {
        runs.compactMap { id, run in run.entries.last.map { (id, $0.at) } }
            .max { $0.1 < $1.1 }?.0
    }
    func record(courseID: String, kind: String, text: String, checkpoint: String? = nil) {
        let clean = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !clean.isEmpty else { return }
        var run = runs[courseID] ?? Run(checkpointLessonID: nil, entries: [])
        run.entries.append(Entry(id: UUID(), kind: kind, text: String(clean.prefix(Self.textCap)), at: Date()))
        run.entries = Array(run.entries.suffix(Self.cap))
        if let checkpoint { run.checkpointLessonID = checkpoint }
        runs[courseID] = run; persist()
    }
    func restart(courseID: String) { var run = runs[courseID] ?? Run(checkpointLessonID: nil, entries: []); run.checkpointLessonID = nil; runs[courseID] = run; persist() }
    private func persist() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder().encode(runs) { try? data.write(to: file, options: .atomic) }
    }
}

/// Mac side invokes bundled SSH helper only. Gateway socket and lifecycle stay
/// private; Settings never parses command output or agent logs.
@MainActor
final class CourseControlRelay: ObservableObject {
    static let shared = CourseControlRelay()
    @Published private(set) var note: String?
    @Published private(set) var busy = false

    func send(_ command: String, payload: [String: Any], accepted: String) {
        guard let script = Self.scriptURL() else { note = "Could not find calla-course.sh beside Calla."; return }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { note = "Course request was invalid."; return }
        busy = true; note = nil
        let task = Process(); task.executableURL = script; task.arguments = [command]
        let input = Pipe(); let output = Pipe(); task.standardInput = input; task.standardOutput = output; task.standardError = output
        task.terminationHandler = { process in
            let reply = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Task { @MainActor in
                CourseControlRelay.shared.busy = false
                CourseControlRelay.shared.note = process.terminationStatus == 0 ? accepted : Self.safeReply(reply)
            }
        }
        do {
            try task.run(); input.fileHandleForWriting.write(data); input.fileHandleForWriting.closeFile()
        } catch { busy = false; note = "Course request could not start." }
    }

    private static func safeReply(_ value: String) -> String {
        // Gateway already sanitizes its error. Keep endpoint/output details out
        // of settings even if SSH itself fails.
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? String else { return "Course request did not reach Calla." }
        return String(error.prefix(240))
    }
    private static func scriptURL() -> URL? {
        if let resource = Bundle.main.url(forResource: "calla-course", withExtension: "sh") { return resource }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<7 { let candidate = directory.appendingPathComponent("scripts/calla-course.sh"); if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }; directory = directory.deletingLastPathComponent() }
        return nil
    }
}

/// Where a course should pick up.
///
/// One definition, because the menu bar and the Settings pane both offer to
/// resume and two answers to "which lesson is next" is one answer too many.
/// Preference order: the first lesson not yet passed, then the checkpoint the
/// last run recorded, then the beginning.
@MainActor
enum CourseResume {
    static func nextLesson(in course: CourseCatalogue.Course,
                           bundleID: String) -> CourseCatalogue.Lesson? {
        let checkpoint = CourseRunStore.shared.checkpoint(for: course.id)
        return course.lessons.first { !LearningStore.shared.isCompleted(lessonID: $0.id, bundleID: bundleID) }
            ?? course.lessons.first { $0.id == checkpoint }
            ?? course.lessons.first
    }

    /// Pick a course up where it was left, and say why if it cannot.
    ///
    /// The menu bar and the Settings library both offer this and both used to
    /// carry their own copy of these six lines, differing only in which `@State`
    /// the failure landed in. Returns the reason it could not start.
    @discardableResult
    static func resume(_ course: CourseCatalogue.Course,
                       allowed: [String],
                       note: String = "Lesson resumed") async -> String? {
        guard let bundleID = CourseCatalogue.shared.bundleID(for: course, allowed: allowed),
              allowed.contains(bundleID) else {
            return "Allow this course's application before resuming."
        }
        guard let lesson = nextLesson(in: course, bundleID: bundleID) else {
            return "This course has no lessons yet."
        }
        return await start(course, lesson: lesson, note: note)
    }

    /// Start it, recording the checkpoint so the next resume knows where it got
    /// to even if nothing was passed. Returns the reason it could not start.
    @discardableResult
    static func start(_ course: CourseCatalogue.Course,
                      lesson: CourseCatalogue.Lesson,
                      note: String) async -> String? {
        CourseRunStore.shared.record(courseID: course.id, kind: "milestone", text: note, checkpoint: lesson.id)
        return await TutorHostController.shared.startCourse(courseID: course.id, lessonID: lesson.id,
                                                            courseTitle: course.title,
                                                            lessonTitle: lesson.title)
    }
}
