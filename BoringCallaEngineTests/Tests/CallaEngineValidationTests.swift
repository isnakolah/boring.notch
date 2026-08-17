import Foundation
import XCTest
@testable import CallaEngineValidation

final class CallaEngineValidationTests: XCTestCase {
    func testAcceptsBoundedIdentifiersAndOutline() {
        XCTAssertEqual(CallaCourseCommandValidation.identifier("course-01_lamp"), "course-01_lamp")
        XCTAssertNil(CallaCourseCommandValidation.identifier("../course"))
        XCTAssertEqual(CallaCourseCommandValidation.outline("  Make a lamp  "), "Make a lamp")
        XCTAssertNil(CallaCourseCommandValidation.outline(String(repeating: "x", count: 96 * 1024 + 1)))
    }

    func testRejectsInvalidTargetAndZipPath() throws {
        XCTAssertEqual(CallaCourseCommandValidation.bundleID("org.blenderfoundation.blender"), "org.blenderfoundation.blender")
        XCTAssertNil(CallaCourseCommandValidation.bundleID("org blender"))
        XCTAssertNil(CallaCourseCommandValidation.version("../../bad"))
        XCTAssertNil(CallaCourseCommandValidation.zipURL("/tmp/not-a-zip.txt"))
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("calla-validation-\(UUID().uuidString).zip")
        try Data([1]).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(CallaCourseCommandValidation.zipURL(file.path), file.standardizedFileURL)
    }

    func testDerivesProgressHiddenCoursesAndLifecycleState() {
        XCTAssertEqual(CallaCoursePresentation.progress([(true, false), (false, true), (true, true)]).completed, 2)
        XCTAssertTrue(CallaCoursePresentation.progress([(true, false), (false, true)]).due)
        XCTAssertTrue(CallaCoursePresentation.isHidden(courseID: "course-hidden", hiddenIDs: ["course-hidden"]))
        XCTAssertEqual(CallaCoursePresentation.lifecyclePhase("publishing"), "publishing")
        XCTAssertNil(CallaCoursePresentation.lifecyclePhase("model_output"))
    }
}
