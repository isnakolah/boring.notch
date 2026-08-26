import Foundation
import CryptoKit
import XCTest
@testable import IntelligenceStore

final class TutorStoreTests: XCTestCase {
    func testTutorDefaultsToLocalAndPersistsGatewayPreference() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("calla-tutor-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CallaStore(path: root.appendingPathComponent("calla.sqlite"))

        let version = try await store.tutorSchemaVersion()
        let initial = try await store.tutorProviderPreference()
        XCTAssertEqual(version, 5)
        XCTAssertEqual(initial, .local)
        try await store.setTutorProviderPreference(.gateway)
        let persisted = try await store.tutorProviderPreference()
        XCTAssertEqual(persisted, .gateway)
    }

    func testNewerSchemaFailsClosed() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("calla-tutor-schema-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("calla.sqlite")
        _ = try CallaStore(path: path)
        let database = try SQLiteDatabase(path: path.path)
        try database.execute("PRAGMA user_version = 6")

        XCTAssertThrowsError(try CallaStore(path: path)) { error in
            XCTAssertEqual(error as? Schema.SchemaError, .unsupportedFutureVersion(6))
        }
    }

    func testCaptureVaultEncryptsAndRoundTripsWithoutPlaintextFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("calla-tutor-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try TutorCaptureVault(root: root, key: SymmetricKey(size: .bits256))
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0xFF, 0xD9])

        let stored = try vault.storeJPEG(jpeg, id: "a1b2c3d4e5f6a7b8")
        let ciphertext = try Data(contentsOf: root.appendingPathComponent(stored.relativePath))
        XCTAssertNotEqual(ciphertext, jpeg)
        XCTAssertEqual(try vault.readJPEG(relativePath: stored.relativePath), jpeg)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a1b2c3d4e5f6a7b8.jpg").path))
    }

    func testCaptureAndPendingFeedbackCommitTogetherThenBecomeSearchable() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("calla-tutor-feedback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("calla.sqlite")
        let store = try CallaStore(path: path)
        let database = try SQLiteDatabase(path: path.path)
        let now = Date().timeIntervalSince1970
        try database.run(
            "INSERT INTO tutor_course_revision(course_key, revision, lifecycle, title, target_bundle_id, artifact_digest, created_at, updated_at) VALUES('blender.lamp', 'rev-1', 'published', 'Lamp basics', 'org.blenderfoundation.blender', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', ?, ?)",
            [.double(now), .double(now)])

        try await store.createTutorRun(TutorRunRecord(
            runID: "run-1", courseKey: "blender.lamp", revision: "rev-1", generation: 0,
            status: .active, lessonID: "lesson-1", stepID: "step-1"))
        let capture = TutorCaptureRecord(
            id: "capture-1", relativePath: "a1b2c3d4e5f6a7b8.aesgcm",
            ciphertextDigest: String(repeating: "a", count: 64), width: 1024, height: 800, byteCount: 256)
        let pending = TutorFeedbackRecord(
            id: "feedback-1", runID: "run-1", generation: 0, kind: "question",
            question: "Where is lamp?", context: "step text", state: .pending,
            selectedProvider: .local, captureID: capture.id)
        try await store.commitTutorCaptureAndPendingFeedback(capture: capture, feedback: pending)
        let savedCapture = try await store.tutorCapture(id: capture.id)
        let pendingHistory = try await store.tutorFeedbackHistory()
        XCTAssertEqual(savedCapture, capture)
        XCTAssertEqual(pendingHistory.entries.single?.state, .pending)

        let complete = TutorFeedbackRecord(
            id: pending.id, runID: pending.runID, generation: 0, kind: pending.kind,
            question: pending.question, context: pending.context, state: .completed,
            answer: "Open Add menu for lamp.", selectedProvider: .local, actualProvider: .gateway,
            model: "feedback-model", latencyMilliseconds: 200, fallbackReason: "timed_out", captureID: capture.id)
        try await store.finishTutorFeedback(complete)
        let page = try await store.tutorFeedbackHistory(query: "lamp")
        XCTAssertEqual(page.entries.single?.id, pending.id)
        XCTAssertEqual(page.entries.single?.state, .completed)
        XCTAssertEqual(page.entries.single?.actualProvider, .gateway)
    }

    func testCaptureFailureIsRetainedWithoutBecomingPending() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("calla-tutor-terminal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("calla.sqlite")
        let store = try CallaStore(path: path)
        let database = try SQLiteDatabase(path: path.path)
        let now = Date().timeIntervalSince1970
        try database.run(
            "INSERT INTO tutor_course_revision(course_key, revision, lifecycle, title, target_bundle_id, artifact_digest, created_at, updated_at) VALUES('blender.lamp', 'rev-1', 'published', 'Lamp basics', 'org.blenderfoundation.blender', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', ?, ?)",
            [.double(now), .double(now)])
        try await store.createTutorRun(TutorRunRecord(
            runID: "run-1", courseKey: "blender.lamp", revision: "rev-1", generation: 0,
            status: .active, lessonID: "lesson-1", stepID: "step-1"))

        try await store.recordTerminalTutorFeedback(TutorFeedbackRecord(
            id: "feedback-1", runID: "run-1", generation: 0, kind: "verification_unknown",
            question: nil, context: "held step", state: .failed, selectedProvider: .local,
            errorCode: "target_not_frontmost"))
        let page = try await store.tutorFeedbackHistory()
        XCTAssertEqual(page.entries.single?.state, .failed)
        XCTAssertEqual(page.entries.single?.errorCode, "target_not_frontmost")
        XCTAssertEqual(page.entries.single?.captureID, nil)
    }

    func testExactRuntimeLookupNeverSelectsAnotherRevision() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("calla-tutor-runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CallaStore(path: root.appendingPathComponent("calla.sqlite"))
        let digest = String(repeating: "b", count: 64)
        let old = TutorRuntimeManifestRecord(courseKey: "blender.lamp", revision: "rev-1",
                                             manifestJSON: #"{"revision":"old"}"#, digest: digest,
                                             sourceEpoch: "gateway-1", sourceSequence: 1)
        let current = TutorRuntimeManifestRecord(courseKey: "blender.lamp", revision: "rev-2",
                                                 manifestJSON: #"{"revision":"current"}"#, digest: digest,
                                                 sourceEpoch: "gateway-1", sourceSequence: 2)
        try await store.upsertTutorRuntimeManifest(old)
        try await store.upsertTutorRuntimeManifest(current)

        let exact = try await store.tutorRuntimeManifest(courseKey: "blender.lamp", revision: "rev-2")
        let missing = try await store.tutorRuntimeManifest(courseKey: "blender.lamp", revision: "rev-3")
        let records = try await store.tutorRuntimeManifestRecords()
        XCTAssertEqual(exact, current)
        XCTAssertNil(missing)
        XCTAssertEqual(records.map(\.revision), ["rev-2", "rev-1"])
    }

    func testLegacyLearningAndRunImportPreserveExistingCanonicalRows() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("calla-tutor-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("calla.sqlite")
        let store = try CallaStore(path: path)
        let database = try SQLiteDatabase(path: path.path)
        let now = Date().timeIntervalSince1970
        try database.run(
            "INSERT INTO tutor_course_revision(course_key, revision, lifecycle, title, target_bundle_id, artifact_digest, published_at, created_at, updated_at) VALUES('blender.lamp', 'rev-1', 'published', 'Lamp basics', 'org.blenderfoundation.blender', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', ?, ?, ?)",
            [.double(now), .double(now), .double(now)])
        try database.run(
            "INSERT INTO tutor_learning(bundle_id, lesson_id, success_count, interval_days, updated_at) VALUES('org.blenderfoundation.blender', 'lesson-1', 9, 3, ?)", [.double(now)])

        let learning = TutorLearningImport(bundleID: "org.blenderfoundation.blender", lessonID: "lesson-1", successCount: 1, intervalDays: 1, dueAt: nil)
        let skippedLearning = try await store.importTutorLearning([learning])
        XCTAssertEqual(skippedLearning, 0)
        XCTAssertEqual(try database.scalarInt("SELECT success_count FROM tutor_learning WHERE bundle_id = 'org.blenderfoundation.blender' AND lesson_id = 'lesson-1'"), 9)

        let legacy = TutorLegacyRunImport(runID: "legacy-run-1", courseKey: "blender.lamp", checkpointLessonID: "lesson-1", eventCount: 3)
        let firstRunImport = try await store.importTutorLegacyRuns([legacy])
        let secondRunImport = try await store.importTutorLegacyRuns([legacy])
        XCTAssertEqual(firstRunImport, 1)
        XCTAssertEqual(secondRunImport, 0)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM tutor_run WHERE run_id = 'legacy-run-1'"), 1)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM tutor_run_event WHERE run_id = 'legacy-run-1' AND kind = 'legacy_import'"), 1)
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
