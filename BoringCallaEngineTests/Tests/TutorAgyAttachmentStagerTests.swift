import Foundation
import XCTest
@testable import CallaEngineValidation

final class TutorAgyAttachmentStagerTests: XCTestCase {
    func testSyntheticJPEGUsesPrivateRelativeAttachmentAndLeavesNoLoggableImage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tutor-agy-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stager = TutorAgyAttachmentStager(workspace: root)
        // Deliberately synthetic: test must never need a real screen capture.
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x00, 0xFF, 0xD9])
        let staged = try stager.stageJPEG(jpeg)
        let reference = try XCTUnwrap(stager.attachmentReference(for: staged))

        XCTAssertTrue(reference.hasPrefix("@capture-"))
        XCTAssertFalse(reference.contains("file://"))
        XCTAssertFalse(reference.contains(jpeg.base64EncodedString()))
        XCTAssertEqual(try Data(contentsOf: staged), jpeg)
        XCTAssertEqual(try XCTUnwrap(FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber).intValue & 0o777, 0o700)
        XCTAssertEqual(try XCTUnwrap(FileManager.default.attributesOfItem(atPath: staged.path)[.posixPermissions] as? NSNumber).intValue & 0o777, 0o600)
        XCTAssertFalse(TutorAgyAttachmentStager.safeInvocationDescription.lowercased().contains("base64"))
        XCTAssertFalse(TutorAgyAttachmentStager.safeInvocationDescription.contains(staged.lastPathComponent))

        stager.cleanup(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }
}
