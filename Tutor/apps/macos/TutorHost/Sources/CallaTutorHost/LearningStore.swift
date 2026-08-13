import Foundation

/// Owner-only, capture-free learning records. This is intentionally separate
/// from lesson overlay state and never accepts a transcript, screen data, or
/// model-written notes. It is called only by TutorHost's internal operation.
@MainActor
final class LearningStore {
    static let shared = LearningStore()

    private let directory: URL

    private init(fileManager: FileManager = .default) {
        directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/CallaTutor/learning", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
    }

    func record(lessonID: String, bundleID: String, succeeded: Bool, delayedReview: Bool) {
        guard lessonID.range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) != nil,
              bundleID.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else { return }
        let file = directory.appendingPathComponent(Self.digest("\(bundleID)|\(lessonID)") + ".json")
        let old = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let successes = (old["successes"] as? Int ?? 0) + (succeeded ? 1 : 0)
        let intervalDays = delayedReview && succeeded ? min(max(old["interval_days"] as? Int ?? 1, 1) * 2, 90) : max(old["interval_days"] as? Int ?? 1, 1)
        let nextDue = Calendar.current.date(byAdding: .day, value: intervalDays, to: Date())!.timeIntervalSince1970
        let record: [String: Any] = [
            "format": "calla-learning-record", "format_version": 1,
            "lesson_id": lessonID, "bundle_id": bundleID, "successes": successes,
            "interval_days": intervalDays, "next_due_at": nextDue,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary,
                                                       backupItemName: nil, options: [])
        } catch {
            // `replaceItemAt` requires an existing file; first write uses move.
            try? FileManager.default.moveItem(at: temporary, to: file)
        }
    }

    /// Returns one due review for the focused bundle and records that it was
    /// offered, so an ordinary observe retry cannot repeat the same prompt.
    func dueReview(bundleID: String) -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let current = Date().timeIntervalSince1970
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            guard var record = (try? Data(contentsOf: file)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                  record["bundle_id"] as? String == bundleID,
                  (record["next_due_at"] as? Double ?? Double.greatestFiniteMagnitude) <= current,
                  current - (record["last_offered_at"] as? Double ?? 0) > 24 * 60 * 60,
                  let lessonID = record["lesson_id"] as? String else { continue }
            record["last_offered_at"] = current
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                try? data.write(to: file, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            return lessonID
        }
        return nil
    }

    /// How much of a course has been done, and whether any of it is due again.
    ///
    /// Read-only and derived from the same records `record` writes, so the menu
    /// bar's "2 of 5" is the same fact the pedagogy uses rather than a second
    /// tally kept somewhere else. A lesson counts as done once it has been
    /// passed at least once.
    func progress(lessonIDs: [String], bundleID: String) -> (done: Int, total: Int, dueForReview: Bool) {
        let current = Date().timeIntervalSince1970
        var done = 0
        var due = false
        for lessonID in lessonIDs {
            let file = directory.appendingPathComponent(Self.digest("\(bundleID)|\(lessonID)") + ".json")
            guard let record = (try? Data(contentsOf: file))
                .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { continue }
            if (record["successes"] as? Int ?? 0) > 0 { done += 1 }
            if (record["next_due_at"] as? Double ?? Double.greatestFiniteMagnitude) <= current { due = true }
        }
        return (done, lessonIDs.count, due)
    }

    /// Whether this lesson's spaced-repetition interval has come round again.
    ///
    /// Deliberately separate from `dueReview`, which records that the review was
    /// *offered* and suppresses it for a day. A settings window that drew its
    /// due marks with that one would quietly eat the prompt the next lesson
    /// would have given, and nobody would ever find out why reviews stopped.
    func isDue(lessonID: String, bundleID: String) -> Bool {
        let file = directory.appendingPathComponent(Self.digest("\(bundleID)|\(lessonID)") + ".json")
        guard let record = (try? Data(contentsOf: file))
            .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
            (record["successes"] as? Int ?? 0) > 0 else { return false }
        return (record["next_due_at"] as? Double ?? .greatestFiniteMagnitude) <= Date().timeIntervalSince1970
    }

    func isCompleted(lessonID: String, bundleID: String) -> Bool {
        let file = directory.appendingPathComponent(Self.digest("\(bundleID)|\(lessonID)") + ".json")
        guard let record = (try? Data(contentsOf: file))
            .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return false }
        return (record["successes"] as? Int ?? 0) > 0
    }

    /// Restart affects only records for selected local course. Course source,
    /// archive state, and compact thread live elsewhere and remain intact.
    func clear(lessonIDs: [String], bundleID: String) {
        for lessonID in lessonIDs {
            let file = directory.appendingPathComponent(Self.digest("\(bundleID)|\(lessonID)") + ".json")
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func digest(_ value: String) -> String {
        // Filename-safe opaque identifier. Records themselves retain only the
        // semantic lesson and bundle identifiers, never learner screen data.
        String(value.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }, radix: 16)
    }
}
