import Foundation
import XCTest
@testable import CallaNotchPresentation

/// The notch slab cannot scroll, so these rules decide what survives into it.
final class CallaNotchPresentationTests: XCTestCase {
    func testTeachingOutranksEveryOtherNotchState() {
        XCTAssertEqual(
            CallaNotchPresentation.mode(running: false, hostReady: false, gatewayReachable: false,
                                        hasCourses: false, lessonActive: true),
            .teaching
        )
        XCTAssertEqual(
            CallaNotchPresentation.mode(running: true, hostReady: true, gatewayReachable: true,
                                        hasCourses: true, lessonActive: false),
            .idle
        )
        XCTAssertEqual(
            CallaNotchPresentation.mode(running: true, hostReady: true, gatewayReachable: true,
                                        hasCourses: false, lessonActive: false),
            .empty
        )
    }

    /// The host answering its socket is what decides Offline. A missing Gateway
    /// is a separate, lesser fact: courses are cached and the fast lesson path
    /// never talks to it, so reporting Offline there hid a Mac that could teach.
    func testGatewayLossIsDegradedButAHostThatIsNotListeningIsOffline() {
        XCTAssertEqual(
            CallaNotchPresentation.mode(running: true, hostReady: true, gatewayReachable: false,
                                        hasCourses: true, lessonActive: false),
            .degraded
        )
        XCTAssertEqual(
            CallaNotchPresentation.mode(running: true, hostReady: false, gatewayReachable: true,
                                        hasCourses: true, lessonActive: false),
            .offline
        )
        XCTAssertEqual(
            CallaNotchPresentation.mode(running: false, hostReady: true, gatewayReachable: true,
                                        hasCourses: true, lessonActive: false),
            .offline
        )
    }

    func testPillAndPrimaryActionMatchMode() {
        XCTAssertEqual(CallaNotchPresentation.pill(for: .teaching), .init(text: "Teaching", tone: .active))
        XCTAssertEqual(CallaNotchPresentation.pill(for: .idle).tone, .ready)
        XCTAssertEqual(CallaNotchPresentation.pill(for: .offline).tone, .warning)
        XCTAssertEqual(CallaNotchPresentation.pill(for: .degraded),
                       .init(text: "Gateway offline", tone: .warning))
        XCTAssertEqual(CallaNotchPresentation.primaryActionTitle(completedCount: 0), "Start")
        XCTAssertEqual(CallaNotchPresentation.primaryActionTitle(completedCount: 3), "Resume")
    }

    func testActiveLessonPinsSelectionAndVanishedCourseResetsIt() {
        XCTAssertEqual(
            CallaNotchPresentation.resolveSelection(current: "a", availableIDs: ["a", "b"], activeCourseID: "b"),
            "b"
        )
        XCTAssertEqual(
            CallaNotchPresentation.resolveSelection(current: "a", availableIDs: ["a", "b"], activeCourseID: nil),
            "a"
        )
        // A course hidden or archived under the notch must not strand selection.
        XCTAssertEqual(
            CallaNotchPresentation.resolveSelection(current: "gone", availableIDs: ["a", "b"], activeCourseID: nil),
            "a"
        )
        // An active course that is hidden from the notch never wins selection.
        XCTAssertEqual(
            CallaNotchPresentation.resolveSelection(current: "a", availableIDs: ["a"], activeCourseID: "hidden"),
            "a"
        )
        XCTAssertEqual(
            CallaNotchPresentation.resolveSelection(current: "", availableIDs: [], activeCourseID: nil),
            ""
        )
    }

    func testThreadLineCollapsesToOneBoundedLine() {
        XCTAssertNil(CallaNotchPresentation.threadLine([]))
        XCTAssertNil(CallaNotchPresentation.threadLine(["   "]))
        XCTAssertEqual(
            CallaNotchPresentation.threadLine(["first", "select\nthe  bevel\ttool"]),
            "select the bevel\ttool"
        )
        let long = CallaNotchPresentation.threadLine([String(repeating: "x", count: 300)], limit: 20)
        XCTAssertEqual(long?.count, 21)
        XCTAssertTrue(long?.hasSuffix("…") == true)
    }

    func testSubtitleDropsFactsThatWouldReadAsZero() {
        XCTAssertEqual(
            CallaNotchPresentation.teachingSubtitle(courseTitle: "Blender", completed: 2, total: 8, stepCount: 5),
            "Blender · 2/8 lessons · 5 steps"
        )
        XCTAssertEqual(
            CallaNotchPresentation.teachingSubtitle(courseTitle: "Blender", completed: 0, total: 0, stepCount: 0),
            "Blender"
        )
    }

    func testAskRequiresRunningEngineAndRealText() {
        XCTAssertFalse(CallaNotchPresentation.canAsk(question: "  ", running: true))
        XCTAssertFalse(CallaNotchPresentation.canAsk(question: "why?", running: false))
        XCTAssertTrue(CallaNotchPresentation.canAsk(question: "why?", running: true))
    }
}
