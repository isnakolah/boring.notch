import Foundation

/// Store values intentionally contain no screenshot bytes, raw model payload or
/// host coordinates. Images are encrypted files addressed by capture ID.
public enum TutorProviderPreference: String, Codable, Sendable { case local, gateway }
public enum TutorRunStatus: String, Codable, Sendable { case starting, active, feedbackPending = "feedback_pending", completing, completed, stopped, failed, blockedRuntime = "blocked_runtime", blockedTarget = "blocked_target" }
public enum TutorFeedbackState: String, Codable, Sendable { case pending, completed, failed, cancelled, timedOut = "timed_out", stale, interrupted }
public enum TutorRevisionLifecycle: String, Codable, Sendable {
    case queued, compiling, validating, waitingForBlender = "waiting_for_blender", preflighting
    case readyForReview = "ready_for_review", publishing, published, failed, cancelled, archived
}

/// Normalized, revision-pinned course facts. Runtime bytes remain opaque to the
/// Store; the Engine validates them before this record is committed.
public struct TutorCourseRevisionRecord: Sendable, Equatable {
    public let courseKey: String
    public let revision: String
    public let lifecycle: TutorRevisionLifecycle
    public let title: String
    public let targetBundleID: String
    public let targetVersion: String?
    public let artifactDigest: String
    public let compilerVersion: String?
    public let packContractVersion: Int?
    public let validationReceipt: String?
    public let preflightReceipt: String?

    public init(courseKey: String, revision: String, lifecycle: TutorRevisionLifecycle, title: String,
                targetBundleID: String, targetVersion: String? = nil, artifactDigest: String,
                compilerVersion: String? = nil, packContractVersion: Int? = nil,
                validationReceipt: String? = nil, preflightReceipt: String? = nil) {
        self.courseKey = courseKey; self.revision = revision; self.lifecycle = lifecycle; self.title = title
        self.targetBundleID = targetBundleID; self.targetVersion = targetVersion; self.artifactDigest = artifactDigest
        self.compilerVersion = compilerVersion; self.packContractVersion = packContractVersion
        self.validationReceipt = validationReceipt; self.preflightReceipt = preflightReceipt
    }
}

public struct TutorLessonRecord: Sendable, Equatable {
    public let lessonID: String
    public let ordinal: Int
    public let title: String
    public let stepCount: Int
    public let metadata: String?

    public init(lessonID: String, ordinal: Int, title: String, stepCount: Int, metadata: String? = nil) {
        self.lessonID = lessonID; self.ordinal = ordinal; self.title = title; self.stepCount = stepCount; self.metadata = metadata
    }
}

public struct TutorRuntimeManifestRecord: Sendable, Equatable {
    public let courseKey: String
    public let revision: String
    public let manifestJSON: String
    public let digest: String
    public let sourceEpoch: String
    public let sourceSequence: Int

    public init(courseKey: String, revision: String, manifestJSON: String, digest: String,
                sourceEpoch: String, sourceSequence: Int) {
        self.courseKey = courseKey; self.revision = revision; self.manifestJSON = manifestJSON; self.digest = digest
        self.sourceEpoch = sourceEpoch; self.sourceSequence = sourceSequence
    }
}

public struct TutorRunRecord: Sendable, Equatable, Codable {
    public let runID: String
    public let courseKey: String
    public let revision: String
    public let generation: Int
    public let status: TutorRunStatus
    public let lessonID: String?
    public let stepID: String?
    public let startedAt: Date
    public let updatedAt: Date

    public init(runID: String, courseKey: String, revision: String, generation: Int, status: TutorRunStatus, lessonID: String?, stepID: String?, startedAt: Date = Date(), updatedAt: Date = Date()) {
        self.runID = runID
        self.courseKey = courseKey
        self.revision = revision
        self.generation = generation
        self.status = status
        self.lessonID = lessonID
        self.stepID = stepID
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

public struct TutorFeedbackRecord: Sendable, Equatable, Codable {
    public let id: String
    public let runID: String
    public let generation: Int
    public let kind: String
    public let question: String?
    public let context: String
    public let state: TutorFeedbackState
    public let answer: String?
    public let selectedProvider: TutorProviderPreference?
    public let actualProvider: TutorProviderPreference?
    public let model: String?
    public let latencyMilliseconds: Int?
    public let fallbackReason: String?
    public let errorCode: String?
    public let captureID: String?
    public let createdAt: Date
    public let completedAt: Date?

    public init(id: String, runID: String, generation: Int, kind: String, question: String?, context: String, state: TutorFeedbackState, answer: String? = nil, selectedProvider: TutorProviderPreference? = nil, actualProvider: TutorProviderPreference? = nil, model: String? = nil, latencyMilliseconds: Int? = nil, fallbackReason: String? = nil, errorCode: String? = nil, captureID: String? = nil, createdAt: Date = Date(), completedAt: Date? = nil) {
        self.id = id
        self.runID = runID
        self.generation = generation
        self.kind = kind
        self.question = question
        self.context = context
        self.state = state
        self.answer = answer
        self.selectedProvider = selectedProvider
        self.actualProvider = actualProvider
        self.model = model
        self.latencyMilliseconds = latencyMilliseconds
        self.fallbackReason = fallbackReason
        self.errorCode = errorCode
        self.captureID = captureID
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

public struct TutorHistoryPage: Sendable, Equatable, Codable {
    public let entries: [TutorFeedbackRecord]
    /// Stable opaque cursor: `created_at|id`. Nil means final page.
    public let nextCursor: String?
}

public struct TutorHistoryQuery: Sendable, Equatable, Codable {
    public let cursor: String?
    public let query: String?
    public let pageSize: Int

    public init(cursor: String? = nil, query: String? = nil, pageSize: Int = 50) {
        self.cursor = cursor; self.query = query; self.pageSize = pageSize
    }
}

/// Bounded aggregate for status surfaces. Screenshot plaintext never enters
/// this projection; only retention volume and item count are disclosed.
public struct TutorHistoryStats: Sendable, Equatable, Codable {
    public let feedbackCount: Int
    public let captureCount: Int
    public let captureByteCount: Int
}

/// One-time Boring projection imports deliberately contain only durable
/// progression facts. Raw legacy entry text never becomes Tutor history.
public struct TutorLearningImport: Sendable, Equatable {
    public let bundleID: String
    public let lessonID: String
    public let successCount: Int
    public let intervalDays: Double
    public let dueAt: Date?

    public init(bundleID: String, lessonID: String, successCount: Int, intervalDays: Double, dueAt: Date?) {
        self.bundleID = bundleID; self.lessonID = lessonID; self.successCount = successCount
        self.intervalDays = intervalDays; self.dueAt = dueAt
    }
}

public struct TutorLegacyRunImport: Sendable, Equatable {
    public let runID: String
    public let courseKey: String
    public let checkpointLessonID: String?
    public let eventCount: Int

    public init(runID: String, courseKey: String, checkpointLessonID: String?, eventCount: Int) {
        self.runID = runID; self.courseKey = courseKey; self.checkpointLessonID = checkpointLessonID; self.eventCount = eventCount
    }
}

public struct TutorCaptureRecord: Sendable, Equatable, Codable {
    public let id: String
    public let relativePath: String
    public let ciphertextDigest: String
    public let mimeType: String
    public let width: Int
    public let height: Int
    public let byteCount: Int
    public let keyVersion: Int
    public let createdAt: Date

    public init(id: String, relativePath: String, ciphertextDigest: String, mimeType: String = "image/jpeg", width: Int, height: Int, byteCount: Int, keyVersion: Int = 1, createdAt: Date = Date()) {
        self.id = id; self.relativePath = relativePath; self.ciphertextDigest = ciphertextDigest; self.mimeType = mimeType
        self.width = width; self.height = height; self.byteCount = byteCount; self.keyVersion = keyVersion
        // SQLite REAL round-trips microseconds reliably across supported macOS
        // SQLite builds. Normalize before storage so Equatable metadata is
        // stable and never claims a capture changed after a read.
        self.createdAt = Date(timeIntervalSince1970: (createdAt.timeIntervalSince1970 * 1_000_000).rounded() / 1_000_000)
    }
}

public enum TutorStoreError: Error, Equatable, Sendable, LocalizedError {
    case invalidValue(String)
    case activeFeedbackExists(runID: String)
    case missingRun(String)
    case invalidCursor

    public var errorDescription: String? {
        switch self {
        case .invalidValue(let field): "invalid Tutor value: \(field)"
        case .activeFeedbackExists: "a Tutor feedback request is already pending"
        case .missingRun: "Tutor run does not exist"
        case .invalidCursor: "invalid Tutor history cursor"
        }
    }
}

public extension CallaStore {
    /// Atomically replaces normalized lesson metadata for one authored revision.
    /// Publication remains explicit: receiving a runtime can never turn a draft
    /// into a learner-visible course.
    func upsertTutorCourseRevision(_ record: TutorCourseRevisionRecord, lessons: [TutorLessonRecord]) throws {
        try validate(record, lessons: lessons)
        try database.transaction {
            let existing = try database.query(
                "SELECT lifecycle, artifact_digest FROM tutor_course_revision WHERE course_key = ? AND revision = ?",
                [.text(record.courseKey), .text(record.revision)]) { ($0.string(0), $0.string(1)) }.first
            // A published artifact is immutable. Gateway must mint a new
            // revision rather than silently changing what an active run pins.
            if let existing, existing.0 == TutorRevisionLifecycle.published.rawValue,
               existing.1 != record.artifactDigest {
                throw TutorStoreError.invalidValue("published_artifact_digest")
            }
            let now = Date()
            try database.run(
                """
                INSERT INTO tutor_course_revision(course_key, revision, lifecycle, title, target_bundle_id, target_version, artifact_digest, compiler_version, pack_contract_version, validation_receipt, preflight_receipt, published_at, created_at, updated_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CASE WHEN ? = 'published' THEN ? ELSE NULL END, ?, ?)
                ON CONFLICT(course_key, revision) DO UPDATE SET lifecycle = excluded.lifecycle, title = excluded.title, target_bundle_id = excluded.target_bundle_id, target_version = excluded.target_version, artifact_digest = excluded.artifact_digest, compiler_version = excluded.compiler_version, pack_contract_version = excluded.pack_contract_version, validation_receipt = excluded.validation_receipt, preflight_receipt = excluded.preflight_receipt, published_at = COALESCE(tutor_course_revision.published_at, excluded.published_at), updated_at = excluded.updated_at
                """,
                [.text(record.courseKey), .text(record.revision), .text(record.lifecycle.rawValue), .text(record.title), .text(record.targetBundleID), .text(record.targetVersion), .text(record.artifactDigest), .text(record.compilerVersion), record.packContractVersion.map(SQLiteValue.int) ?? .null, .text(record.validationReceipt), .text(record.preflightReceipt), .text(record.lifecycle.rawValue), .date(now), .date(now), .date(now)])
            try database.run("DELETE FROM tutor_lesson WHERE course_key = ? AND revision = ?", [.text(record.courseKey), .text(record.revision)])
            for lesson in lessons {
                try database.run(
                    "INSERT INTO tutor_lesson(course_key, revision, lesson_id, ord, title, step_count, metadata) VALUES(?, ?, ?, ?, ?, ?, ?)",
                    [.text(record.courseKey), .text(record.revision), .text(lesson.lessonID), .int(lesson.ordinal), .text(lesson.title), .int(lesson.stepCount), .text(lesson.metadata)])
            }
        }
    }

    /// Rejects stale or conflicting Gateway snapshots before replacing the
    /// exact runtime that new runs may use.
    func upsertTutorRuntimeManifest(_ record: TutorRuntimeManifestRecord) throws {
        try validate(record)
        try database.transaction {
            let current = try database.query(
                "SELECT source_epoch, source_sequence, digest FROM tutor_runtime_manifest WHERE course_key = ? AND revision = ?",
                [.text(record.courseKey), .text(record.revision)]) { ($0.string(0), $0.int(1), $0.string(2)) }.first
            if let current {
                if current.0 == record.sourceEpoch && current.1 > record.sourceSequence {
                    throw TutorStoreError.invalidValue("stale_gateway_sequence")
                }
                if current.0 == record.sourceEpoch && current.1 == record.sourceSequence && current.2 != record.digest {
                    throw TutorStoreError.invalidValue("gateway_digest_conflict")
                }
            }
            try database.run(
                """
                INSERT INTO tutor_runtime_manifest(course_key, revision, manifest_json, digest, source_epoch, source_sequence, synced_at)
                VALUES(?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(course_key, revision) DO UPDATE SET manifest_json = excluded.manifest_json, digest = excluded.digest, source_epoch = excluded.source_epoch, source_sequence = excluded.source_sequence, synced_at = excluded.synced_at
                """,
                [.text(record.courseKey), .text(record.revision), .text(record.manifestJSON), .text(record.digest), .text(record.sourceEpoch), .int(record.sourceSequence), .date(Date())])
        }
    }

    /// Exact runtime lookup for an Engine-pinned run. Compatibility JSON files
    /// are projections only; lesson execution must read this committed record.
    func tutorRuntimeManifest(courseKey: String, revision: String) throws -> TutorRuntimeManifestRecord? {
        try validateID(courseKey, "course_key")
        try validateRevision(revision)
        return try database.query(
            "SELECT course_key, revision, manifest_json, digest, source_epoch, source_sequence FROM tutor_runtime_manifest WHERE course_key = ? AND revision = ?",
            [.text(courseKey), .text(revision)]) { row in
                TutorRuntimeManifestRecord(courseKey: row.string(0), revision: row.string(1),
                                           manifestJSON: row.string(2), digest: row.string(3),
                                           sourceEpoch: row.string(4), sourceSequence: row.int(5))
            }.first
    }

    /// Bounded status projection for Boring UI. This never exposes runtime
    /// bytes and cannot be used to select a revision for execution.
    func tutorRuntimeManifestRecords(limit: Int = 200) throws -> [TutorRuntimeManifestRecord] {
        let boundedLimit = min(max(limit, 1), 200)
        return try database.query(
            "SELECT course_key, revision, manifest_json, digest, source_epoch, source_sequence FROM tutor_runtime_manifest ORDER BY synced_at DESC, source_sequence DESC, course_key ASC, revision ASC LIMIT ?",
            [.int(boundedLimit)]) { row in
                TutorRuntimeManifestRecord(courseKey: row.string(0), revision: row.string(1),
                                           manifestJSON: row.string(2), digest: row.string(3),
                                           sourceEpoch: row.string(4), sourceSequence: row.int(5))
            }
    }

    func publishedTutorRevision(courseKey: String) throws -> TutorCourseRevisionRecord? {
        try validateID(courseKey, "course_key")
        return try database.query(
            "SELECT course_key, revision, lifecycle, title, target_bundle_id, target_version, artifact_digest, compiler_version, pack_contract_version, validation_receipt, preflight_receipt FROM tutor_course_revision WHERE course_key = ? AND lifecycle = 'published' ORDER BY published_at DESC LIMIT 1",
            [.text(courseKey)]) { row in
                TutorCourseRevisionRecord(courseKey: row.string(0), revision: row.string(1), lifecycle: TutorRevisionLifecycle(rawValue: row.string(2)) ?? .failed, title: row.string(3), targetBundleID: row.string(4), targetVersion: row.text(5), artifactDigest: row.string(6), compilerVersion: row.text(7), packContractVersion: row.text(8).flatMap(Int.init), validationReceipt: row.text(9), preflightReceipt: row.text(10))
            }.first
    }

    /// Lifecycle snapshots may arrive separately from runtime snapshots. Update
    /// existing revisions only; a status frame can never invent a runnable
    /// course without an exact validated runtime record.
    func setTutorRevisionLifecycle(courseKey: String, lifecycle: TutorRevisionLifecycle) throws {
        try validateID(courseKey, "course_key")
        let count = try database.scalarInt(
            "SELECT COUNT(*) FROM tutor_course_revision WHERE course_key = ?", [.text(courseKey)]) ?? 0
        guard count > 0 else { return }
        if lifecycle == .published {
            let ready = try database.scalarInt(
                "SELECT COUNT(*) FROM tutor_course_revision WHERE course_key = ? AND lifecycle IN ('ready_for_review','published')",
                [.text(courseKey)]) ?? 0
            guard ready > 0 else { throw TutorStoreError.invalidValue("publish_without_review") }
        }
        try database.run(
            "UPDATE tutor_course_revision SET lifecycle = ?, published_at = CASE WHEN ? = 'published' THEN COALESCE(published_at, ?) ELSE published_at END, updated_at = ? WHERE course_key = ? AND updated_at = (SELECT MAX(updated_at) FROM tutor_course_revision WHERE course_key = ?)",
            [.text(lifecycle.rawValue), .text(lifecycle.rawValue), .date(Date()), .date(Date()), .text(courseKey), .text(courseKey)])
    }

    /// Source copies are immutable audit inputs. Import state permits individual
    /// malformed domains to retry without suppressing healthy domains.
    func recordTutorImport(sourceFile: String, digest: String, status: String, importedCount: Int, errorCode: String? = nil) throws {
        guard sourceFile.range(of: "^[A-Za-z0-9._/-]{1,240}$", options: .regularExpression) != nil,
              digest.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil,
              status.range(of: "^[A-Za-z_]{1,40}$", options: .regularExpression) != nil,
              importedCount >= 0 else { throw TutorStoreError.invalidValue("import") }
        try database.run(
            "INSERT INTO tutor_import(source_file, source_digest, status, imported_count, error_code, updated_at) VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(source_file) DO UPDATE SET source_digest = excluded.source_digest, status = excluded.status, imported_count = excluded.imported_count, error_code = excluded.error_code, updated_at = excluded.updated_at",
            [.text(sourceFile), .text(digest), .text(status), .int(importedCount), .text(errorCode.map { String($0.prefix(128)) }), .date(Date())])
    }

    /// Inserts Boring-owned learning projections only when no canonical row is
    /// present. Legacy data has no trustworthy modification time, so replacing
    /// an existing Store row would violate canonical-state precedence.
    func importTutorLearning(_ imports: [TutorLearningImport]) throws -> Int {
        guard imports.count <= 2_000 else { throw TutorStoreError.invalidValue("learning_import_count") }
        var inserted = 0
        try database.transaction {
            for value in imports {
                try validateID(value.bundleID, "bundle_id")
                try validateID(value.lessonID, "lesson_id")
                guard value.successCount >= 0, value.successCount <= 1_000_000,
                      value.intervalDays >= 0, value.intervalDays <= 36_500 else {
                    throw TutorStoreError.invalidValue("learning_import")
                }
                try database.run(
                    "INSERT OR IGNORE INTO tutor_learning(bundle_id, lesson_id, success_count, interval_days, due_at, updated_at) VALUES(?, ?, ?, ?, ?, ?)",
                    [.text(value.bundleID), .text(value.lessonID), .int(value.successCount), .double(value.intervalDays), .date(value.dueAt), .date(Date())])
                if (try database.scalarInt("SELECT changes()")) == 1 { inserted += 1 }
            }
        }
        return inserted
    }

    /// Converts a legacy continuity projection into a bounded stopped record
    /// after an exact published revision is available. Entry text is discarded;
    /// only checkpoint and count survive. Existing Engine records always win.
    func importTutorLegacyRuns(_ imports: [TutorLegacyRunImport]) throws -> Int {
        guard imports.count <= 200 else { throw TutorStoreError.invalidValue("run_import_count") }
        var inserted = 0
        try database.transaction {
            for value in imports {
                try validateID(value.runID, "run_id")
                try validateID(value.courseKey, "course_key")
                if let checkpoint = value.checkpointLessonID { try validateID(checkpoint, "lesson_id") }
                guard value.eventCount >= 0, value.eventCount <= 40 else { throw TutorStoreError.invalidValue("run_import") }
                guard let revision = try database.query(
                    "SELECT revision FROM tutor_course_revision WHERE course_key = ? AND lifecycle = 'published' ORDER BY published_at DESC LIMIT 1",
                    [.text(value.courseKey)], row: { $0.string(0) }).first else { continue }
                let now = Date()
                try database.run(
                    "INSERT OR IGNORE INTO tutor_run(run_id, course_key, revision, generation, status, lesson_id, started_at, ended_at, updated_at) VALUES(?, ?, ?, 0, 'stopped', ?, ?, ?, ?)",
                    [.text(value.runID), .text(value.courseKey), .text(revision), .text(value.checkpointLessonID), .date(now), .date(now), .date(now)])
                guard (try database.scalarInt("SELECT changes()")) == 1 else { continue }
                try database.run(
                    "INSERT INTO tutor_run_event(run_id, generation, ord, kind, note, created_at) VALUES(?, 0, 0, 'legacy_import', ?, ?)",
                    [.text(value.runID), .text("Imported \(value.eventCount) legacy continuity event(s)"), .date(now)])
                inserted += 1
            }
        }
        return inserted
    }

    func tutorProviderPreference() throws -> TutorProviderPreference {
        let stored = try database.scalarText("SELECT value FROM tutor_setting WHERE key = 'provider_preference'")
        return TutorProviderPreference(rawValue: stored ?? "local") ?? .local
    }

    func setTutorProviderPreference(_ preference: TutorProviderPreference) throws {
        try database.run(
            "INSERT INTO tutor_setting(key, value, updated_at) VALUES('provider_preference', ?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
            [.text(preference.rawValue), .date(Date())])
    }

    /// Engine creates a run before Host receives `start_run`. The unique partial
    /// index is a second process-safe defence against conflicting active runs.
    func createTutorRun(_ record: TutorRunRecord) throws {
        try validate(record)
        try database.transaction {
            let published = try database.scalarInt(
                "SELECT COUNT(*) FROM tutor_course_revision WHERE course_key = ? AND revision = ? AND lifecycle = 'published'",
                [.text(record.courseKey), .text(record.revision)]) ?? 0
            guard published == 1 else { throw TutorStoreError.invalidValue("published_revision") }
            try database.run(
                "INSERT INTO tutor_run(run_id, course_key, revision, generation, status, lesson_id, step_id, started_at, updated_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [.text(record.runID), .text(record.courseKey), .text(record.revision), .int(record.generation), .text(record.status.rawValue), .text(record.lessonID), .text(record.stepID), .date(record.startedAt), .date(record.updatedAt)])
            try database.run(
                "INSERT INTO tutor_run_event(run_id, generation, ord, kind, created_at) VALUES(?, ?, 0, 'run_created', ?)",
                [.text(record.runID), .int(record.generation), .date(record.createdAtOrNow)])
        }
    }

    func updateTutorRun(runID: String, generation: Int, status: TutorRunStatus, lessonID: String? = nil, stepID: String? = nil, event: String, verifierOutcome: String? = nil, note: String? = nil) throws {
        try validateID(runID, "run_id")
        try validateID(event, "event")
        try database.transaction {
            let count = try database.scalarInt("SELECT COUNT(*) FROM tutor_run WHERE run_id = ? AND generation = ?", [.text(runID), .int(generation)]) ?? 0
            guard count == 1 else { throw TutorStoreError.missingRun(runID) }
            let next = (try database.scalarInt("SELECT COALESCE(MAX(ord), -1) + 1 FROM tutor_run_event WHERE run_id = ? AND generation = ?", [.text(runID), .int(generation)]) ?? 0)
            let now = Date()
            try database.run(
                "UPDATE tutor_run SET status = ?, lesson_id = COALESCE(?, lesson_id), step_id = COALESCE(?, step_id), updated_at = ?, ended_at = CASE WHEN ? IN ('completed','stopped','failed','blocked_runtime','blocked_target') THEN ? ELSE ended_at END WHERE run_id = ? AND generation = ?",
                [.text(status.rawValue), .text(lessonID), .text(stepID), .date(now), .text(status.rawValue), .date(now), .text(runID), .int(generation)])
            try database.run(
                "INSERT INTO tutor_run_event(run_id, generation, ord, kind, verifier_outcome, note, created_at) VALUES(?, ?, ?, ?, ?, ?, ?)",
                [.text(runID), .int(generation), .int(next), .text(event), .text(verifierOutcome), .text(note.map { String($0.prefix(1024)) }), .date(now)])
        }
    }

    /// Pending row is committed before any provider call. One row per run has a
    /// pending state at a time; duplicate UI submits fail closed.
    func createPendingTutorFeedback(_ record: TutorFeedbackRecord) throws {
        try validate(record)
        try database.transaction {
            try insertPendingTutorFeedback(record)
        }
    }

    /// Capture/permission failures are durable diagnostics too, but they never
    /// enter `pending` and therefore can never be routed after a restart.
    func recordTerminalTutorFeedback(_ record: TutorFeedbackRecord) throws {
        try validate(record)
        guard record.state != .pending else { throw TutorStoreError.invalidValue("feedback_state") }
        try database.transaction {
            let run = try database.scalarInt("SELECT COUNT(*) FROM tutor_run WHERE run_id = ? AND generation = ?", [.text(record.runID), .int(record.generation)]) ?? 0
            guard run == 1 else { throw TutorStoreError.missingRun(record.runID) }
            try database.run(
                "INSERT INTO tutor_feedback(id, run_id, generation, kind, question, context, state, answer, selected_provider, actual_provider, model, latency_ms, fallback_reason, error_code, capture_id, created_at, completed_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [.text(record.id), .text(record.runID), .int(record.generation), .text(record.kind), .text(record.question), .text(record.context), .text(record.state.rawValue), .text(record.answer.map { String($0.prefix(800)) }), .text(record.selectedProvider?.rawValue), .text(record.actualProvider?.rawValue), .text(record.model.map { String($0.prefix(256)) }), record.latencyMilliseconds.map(SQLiteValue.int) ?? .null, .text(record.fallbackReason.map { String($0.prefix(128)) }), .text(record.errorCode.map { String($0.prefix(128)) }), .text(record.captureID), .date(record.createdAt), .date(record.completedAt ?? record.createdAt)])
            try updateTutorFeedbackIndex(feedbackID: record.id)
        }
    }

    /// Commits metadata and the pending request in one SQLite transaction. The
    /// caller may route the image only after this returns. If it throws, caller
    /// must remove the already-atomically-written ciphertext through
    /// `TutorCaptureVault.removeUncommitted(relativePath:)`.
    func commitTutorCaptureAndPendingFeedback(
        capture: TutorCaptureRecord,
        feedback: TutorFeedbackRecord
    ) throws {
        guard feedback.captureID == capture.id else {
            throw TutorStoreError.invalidValue("feedback_capture_id")
        }
        try validate(capture)
        try validate(feedback)
        try database.transaction {
            try insertTutorCapture(capture)
            try insertPendingTutorFeedback(feedback)
        }
    }

    /// Called only after `TutorCaptureVault` atomically renamed ciphertext.
    /// Caller removes the file if this insert fails, so no provider can see an
    /// image until capture row and pending feedback request both commit.
    func recordTutorCapture(_ record: TutorCaptureRecord) throws {
        try validate(record)
        try insertTutorCapture(record)
    }

    func tutorCapture(id: String) throws -> TutorCaptureRecord? {
        try validateID(id, "capture_id")
        return try database.query(
            "SELECT id, relative_path, ciphertext_digest, mime_type, width, height, byte_count, key_version, created_at FROM tutor_capture WHERE id = ?",
            [.text(id)]) { row in
                TutorCaptureRecord(id: row.string(0), relativePath: row.string(1), ciphertextDigest: row.string(2), mimeType: row.string(3), width: row.int(4), height: row.int(5), byteCount: row.int(6), keyVersion: row.int(7), createdAt: row.date(8) ?? .distantPast)
            }.first
    }

    func finishTutorFeedback(_ record: TutorFeedbackRecord) throws {
        guard record.state != .pending else { throw TutorStoreError.invalidValue("feedback_state") }
        let answer = record.answer.map { String($0.prefix(800)) }
        let model = record.model.map { String($0.prefix(256)) }
        let fallback = record.fallbackReason.map { String($0.prefix(128)) }
        let error = record.errorCode.map { String($0.prefix(128)) }
        let bindings: [SQLiteValue] = [
            .text(record.state.rawValue), .text(answer), .text(record.actualProvider?.rawValue), .text(model),
            record.latencyMilliseconds.map(SQLiteValue.int) ?? .null, .text(fallback), .text(error), .date(record.completedAt ?? Date()),
            .text(record.id), .int(record.generation),
        ]
        try database.transaction {
            let pending = try database.scalarInt(
                "SELECT COUNT(*) FROM tutor_feedback WHERE id = ? AND generation = ? AND state = 'pending'",
                [.text(record.id), .int(record.generation)]) ?? 0
            guard pending == 1 else { throw TutorStoreError.invalidValue("feedback_not_pending") }
            try database.run(
                "UPDATE tutor_feedback SET state = ?, answer = ?, actual_provider = ?, model = ?, latency_ms = ?, fallback_reason = ?, error_code = ?, completed_at = ? WHERE id = ? AND generation = ?",
                bindings)
            try database.run(
                "UPDATE tutor_run SET status = CASE WHEN status = 'feedback_pending' THEN 'active' ELSE status END, updated_at = ? WHERE run_id = (SELECT run_id FROM tutor_feedback WHERE id = ?)",
                [.date(record.completedAt ?? Date()), .text(record.id)])
            try updateTutorFeedbackIndex(feedbackID: record.id)
        }
    }

    /// Cancellation/timeout does not delete a committed request. Late provider
    /// replies can be classified stale by Engine but cannot return it to pending.
    func transitionTutorFeedback(id: String, generation: Int, state: TutorFeedbackState, errorCode: String? = nil) throws {
        guard state != .pending else { throw TutorStoreError.invalidValue("feedback_state") }
        try validateID(id, "feedback_id")
        try database.transaction {
            let changed = try database.scalarInt(
                "SELECT COUNT(*) FROM tutor_feedback WHERE id = ? AND generation = ? AND state = 'pending'",
                [.text(id), .int(generation)]) ?? 0
            guard changed == 1 else { throw TutorStoreError.invalidValue("feedback_not_pending") }
            let now = Date()
            try database.run(
                "UPDATE tutor_feedback SET state = ?, error_code = ?, completed_at = ? WHERE id = ? AND generation = ?",
                [.text(state.rawValue), .text(errorCode.map { String($0.prefix(128)) }), .date(now), .text(id), .int(generation)])
            try database.run(
                "UPDATE tutor_run SET status = CASE WHEN status = 'feedback_pending' THEN 'active' ELSE status END, updated_at = ? WHERE run_id = (SELECT run_id FROM tutor_feedback WHERE id = ?)",
                [.date(now), .text(id)])
            try updateTutorFeedbackIndex(feedbackID: id)
        }
    }

    func tutorFeedbackHistory(cursor: String? = nil, query text: String? = nil, pageSize: Int = 50) throws -> TutorHistoryPage {
        let limit = min(max(pageSize, 1), 50)
        var whereParts = ["1 = 1"]
        var bindings: [SQLiteValue] = []
        if let cursor {
            let parts = cursor.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let timestamp = Double(parts[0]), !parts[1].isEmpty else { throw TutorStoreError.invalidCursor }
            whereParts.append("(f.created_at < ? OR (f.created_at = ? AND f.id < ?))")
            bindings += [.double(timestamp), .double(timestamp), .text(parts[1])]
        }
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
           let match = CallaStore.ftsQuery(text)
        {
            whereParts.append("f.id IN (SELECT feedback_id FROM tutor_fts WHERE tutor_fts MATCH ?)")
            bindings.append(.text(match))
        }
        bindings.append(.int(limit + 1))
        let rows = try database.query(
            "SELECT f.id, f.run_id, f.generation, f.kind, f.question, f.context, f.state, f.answer, f.selected_provider, f.actual_provider, f.model, f.latency_ms, f.fallback_reason, f.error_code, f.capture_id, f.created_at, f.completed_at FROM tutor_feedback f WHERE \(whereParts.joined(separator: " AND ")) ORDER BY f.created_at DESC, f.id DESC LIMIT ?",
            bindings, row: Self.tutorFeedback)
        let page = Array(rows.prefix(limit))
        let next = rows.count > limit ? page.last.map { "\($0.createdAt.timeIntervalSince1970)|\($0.id)" } : nil
        return TutorHistoryPage(entries: page, nextCursor: next)
    }

    func tutorHistoryStats() throws -> TutorHistoryStats {
        let feedbackCount = try database.scalarInt("SELECT COUNT(*) FROM tutor_feedback") ?? 0
        let capture = try database.query(
            "SELECT COUNT(*), COALESCE(SUM(byte_count), 0) FROM tutor_capture") {
                ($0.int(0), $0.int(1))
            }.first ?? (0, 0)
        return TutorHistoryStats(feedbackCount: feedbackCount, captureCount: capture.0, captureByteCount: capture.1)
    }

    func tutorSchemaVersion() throws -> Int { try database.scalarInt("PRAGMA user_version") ?? 0 }

    private func validate(_ record: TutorRunRecord) throws {
        try validateID(record.runID, "run_id"); try validateID(record.courseKey, "course_key"); try validateRevision(record.revision)
        if let lessonID = record.lessonID { try validateID(lessonID, "lesson_id") }
        if let stepID = record.stepID { try validateID(stepID, "step_id") }
        guard record.generation >= 0 else { throw TutorStoreError.invalidValue("generation") }
    }

    private func validate(_ record: TutorCourseRevisionRecord, lessons: [TutorLessonRecord]) throws {
        try validateID(record.courseKey, "course_key"); try validateRevision(record.revision)
        try validateID(record.targetBundleID, "target_bundle_id")
        guard !record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              record.title.count <= 240,
              record.artifactDigest.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil,
              record.packContractVersion == nil || record.packContractVersion! > 0,
              lessons.count <= 200 else { throw TutorStoreError.invalidValue("course_revision") }
        var identifiers = Set<String>()
        for (ordinal, lesson) in lessons.enumerated() {
            try validateID(lesson.lessonID, "lesson_id")
            guard identifiers.insert(lesson.lessonID).inserted,
                  lesson.ordinal == ordinal, !lesson.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  lesson.title.count <= 240, lesson.stepCount > 0, lesson.stepCount <= 1_000,
                  (lesson.metadata?.utf8.count ?? 0) <= 16 * 1024 else {
                throw TutorStoreError.invalidValue("lesson")
            }
        }
    }

    private func validate(_ record: TutorRuntimeManifestRecord) throws {
        try validateID(record.courseKey, "course_key"); try validateRevision(record.revision)
        guard record.manifestJSON.utf8.count <= 5 * 1024 * 1024,
              record.digest.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil,
              record.sourceEpoch.range(of: "^[A-Za-z0-9._-]{1,160}$", options: .regularExpression) != nil,
              record.sourceSequence >= 0 else { throw TutorStoreError.invalidValue("runtime_manifest") }
    }

    private func validate(_ record: TutorFeedbackRecord) throws {
        try validateID(record.id, "feedback_id"); try validateID(record.runID, "run_id"); try validateID(record.kind, "kind")
        guard record.question?.count ?? 0 <= 800, record.context.utf8.count <= 16 * 1024 else { throw TutorStoreError.invalidValue("feedback_text") }
    }

    private func validate(_ record: TutorCaptureRecord) throws {
        try validateID(record.id, "capture_id")
        guard record.mimeType == "image/jpeg", record.width > 0, record.height > 0,
              record.byteCount > 0, record.keyVersion > 0,
              record.relativePath.range(of: "^[A-Za-z0-9]+\\.aesgcm$", options: .regularExpression) != nil,
              record.ciphertextDigest.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil
        else { throw TutorStoreError.invalidValue("capture") }
    }

    private func insertTutorCapture(_ record: TutorCaptureRecord) throws {
        try database.run(
            "INSERT INTO tutor_capture(id, relative_path, ciphertext_digest, mime_type, width, height, byte_count, key_version, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [.text(record.id), .text(record.relativePath), .text(record.ciphertextDigest), .text(record.mimeType), .int(record.width), .int(record.height), .int(record.byteCount), .int(record.keyVersion), .date(record.createdAt)])
    }

    private func insertPendingTutorFeedback(_ record: TutorFeedbackRecord) throws {
        let run = try database.scalarInt("SELECT COUNT(*) FROM tutor_run WHERE run_id = ? AND generation = ?", [.text(record.runID), .int(record.generation)]) ?? 0
        guard run == 1 else { throw TutorStoreError.missingRun(record.runID) }
        let pending = try database.scalarInt("SELECT COUNT(*) FROM tutor_feedback WHERE run_id = ? AND state = 'pending'", [.text(record.runID)]) ?? 0
        guard pending == 0 else { throw TutorStoreError.activeFeedbackExists(runID: record.runID) }
        try database.run(
            "INSERT INTO tutor_feedback(id, run_id, generation, kind, question, context, state, selected_provider, capture_id, created_at) VALUES(?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)",
            [.text(record.id), .text(record.runID), .int(record.generation), .text(record.kind), .text(record.question), .text(record.context), .text(record.selectedProvider?.rawValue), .text(record.captureID), .date(record.createdAt)])
        try database.run("UPDATE tutor_run SET status = 'feedback_pending', updated_at = ? WHERE run_id = ?", [.date(record.createdAt), .text(record.runID)])
    }

    private func updateTutorFeedbackIndex(feedbackID: String) throws {
        let rows = try database.query(
            "SELECT cr.title, COALESCE(l.title, ''), COALESCE(f.question, ''), COALESCE(f.answer, '') FROM tutor_feedback f JOIN tutor_run r ON r.run_id = f.run_id JOIN tutor_course_revision cr ON cr.course_key = r.course_key AND cr.revision = r.revision LEFT JOIN tutor_lesson l ON l.course_key = r.course_key AND l.revision = r.revision AND l.lesson_id = r.lesson_id WHERE f.id = ?",
            [.text(feedbackID)]) { row in
                (row.string(0), row.string(1), row.string(2), row.string(3))
            }
        guard let row = rows.first else { return }
        try database.run("DELETE FROM tutor_fts WHERE feedback_id = ?", [.text(feedbackID)])
        try database.run(
            "INSERT INTO tutor_fts(feedback_id, course_title, lesson_title, question, answer) VALUES(?, ?, ?, ?, ?)",
            [.text(feedbackID), .text(row.0), .text(row.1), .text(row.2), .text(row.3)])
    }

    private func validateID(_ value: String, _ field: String) throws {
        guard value.range(of: "^[A-Za-z0-9._-]{1,160}$", options: .regularExpression) != nil else { throw TutorStoreError.invalidValue(field) }
    }

    /// Compiler revisions are opaque release identifiers. Current authored
    /// packs use `pack@version`; accepting that separator here does not widen
    /// run IDs, filenames, or SQL identifiers.
    private func validateRevision(_ value: String) throws {
        guard value.range(of: "^[A-Za-z0-9._@+-]{1,160}$", options: .regularExpression) != nil else {
            throw TutorStoreError.invalidValue("revision")
        }
    }

    private static func tutorFeedback(_ row: SQLiteRow) -> TutorFeedbackRecord {
        TutorFeedbackRecord(
            id: row.string(0), runID: row.string(1), generation: row.int(2), kind: row.string(3), question: row.text(4), context: row.string(5), state: TutorFeedbackState(rawValue: row.string(6)) ?? .failed, answer: row.text(7), selectedProvider: row.text(8).flatMap(TutorProviderPreference.init(rawValue:)), actualProvider: row.text(9).flatMap(TutorProviderPreference.init(rawValue:)), model: row.text(10), latencyMilliseconds: row.text(11).flatMap(Int.init), fallbackReason: row.text(12), errorCode: row.text(13), captureID: row.text(14), createdAt: row.date(15) ?? .distantPast, completedAt: row.date(16))
    }
}

private extension TutorRunRecord {
    var createdAtOrNow: Date { startedAt }
}
