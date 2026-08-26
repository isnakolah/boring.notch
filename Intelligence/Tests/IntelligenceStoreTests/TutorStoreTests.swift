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
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
