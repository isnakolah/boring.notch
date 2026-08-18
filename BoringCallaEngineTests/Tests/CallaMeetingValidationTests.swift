import XCTest
@testable import CallaEngineValidation

/// The new free text on `call_start`: the composed knowledge block, and the
/// calendar event a call belongs to.
///
/// Worth its own file. Everything here came out of a calendar invite someone else
/// wrote and ends up in a model prompt, so it is the least trusted input the
/// engine accepts — and unlike a persona or a tier it cannot be allowlisted.
final class CallaKnowledgeValidationTests: XCTestCase {
    func testKnowledgeRidesTheProfile() {
        let fields = CallaCopilotCommandValidation.profile(
            about: nil, personaGuidance: nil, baseGuidance: nil,
            knowledge: "Acme churned on latency in Q2.")
        XCTAssertEqual(fields?.knowledge, "Acme churned on latency in Q2.")
    }

    func testOverLongKnowledgeIsRefusedRatherThanTruncated() {
        // A silently shortened prompt is a different prompt than the one the user
        // was shown, and the engine treats a rejected profile as a hard start
        // failure precisely so that difference cannot go unnoticed.
        let fields = CallaCopilotCommandValidation.profile(
            about: nil, personaGuidance: nil, baseGuidance: nil,
            knowledge: String(repeating: "x", count: CallaCopilotCommandValidation.knowledgeLimit + 1))
        XCTAssertNil(fields)
    }

    func testKnowledgeAtTheLimitIsAccepted() {
        let fields = CallaCopilotCommandValidation.profile(
            about: nil, personaGuidance: nil, baseGuidance: nil,
            knowledge: String(repeating: "x", count: CallaCopilotCommandValidation.knowledgeLimit))
        XCTAssertNotNil(fields)
    }

    func testControlCharactersInKnowledgeAreRefused() {
        let fields = CallaCopilotCommandValidation.profile(
            about: nil, personaGuidance: nil, baseGuidance: nil,
            knowledge: "a terminal escape \u{1B}[31m has no business in a prompt")
        XCTAssertNil(fields)
    }

    func testNewlinesAndTabsSurviveBecauseAPromptHasThem() {
        let fields = CallaCopilotCommandValidation.profile(
            about: nil, personaGuidance: nil, baseGuidance: nil,
            knowledge: "line one\nline two\tindented")
        XCTAssertEqual(fields?.knowledge, "line one\nline two\tindented")
    }

    func testAMeetingAloneIsEnoughToMakeAProfile() {
        // A call can have an event and nothing written about it yet — the first
        // occurrence of a meeting is exactly that, and the title still has to
        // reach the host.
        let meeting = CallaCopilotCommandValidation.meeting(
            eventID: "event-1", seriesID: nil, title: "Weekly sync",
            startsAt: nil, endsAt: nil, location: nil, attendees: nil, notes: nil)
        let fields = CallaCopilotCommandValidation.profile(
            about: nil, personaGuidance: nil, baseGuidance: nil, knowledge: nil, meeting: meeting)
        XCTAssertEqual(fields?.meeting?.title, "Weekly sync")
    }

    func testAnEmptyProfileIsStillNil() {
        XCTAssertNil(CallaCopilotCommandValidation.profile(
            about: nil, personaGuidance: nil, baseGuidance: nil, knowledge: "   ", meeting: nil))
    }
}

final class CallaMeetingValidationTests: XCTestCase {
    private func meeting(
        eventID: String? = "event-1",
        seriesID: String? = nil,
        title: String? = nil,
        startsAt: Double? = nil,
        location: String? = nil,
        attendees: [String]? = nil,
        notes: String? = nil
    ) -> CallaCopilotCommandValidation.MeetingFields? {
        CallaCopilotCommandValidation.meeting(
            eventID: eventID, seriesID: seriesID, title: title,
            startsAt: startsAt, endsAt: nil, location: location,
            attendees: attendees, notes: notes)
    }

    func testCarriesEveryFieldWorthKnowing() {
        let fields = meeting(
            seriesID: "series-1", title: "Weekly Acme sync", startsAt: 1_700_000_000,
            location: "Meet", attendees: ["Dana", "Rae"], notes: "Renewal review")
        XCTAssertEqual(fields?.eventID, "event-1")
        XCTAssertEqual(fields?.seriesID, "series-1")
        XCTAssertEqual(fields?.title, "Weekly Acme sync")
        XCTAssertEqual(fields?.startsAt, 1_700_000_000)
        XCTAssertEqual(fields?.attendees, ["Dana", "Rae"])
        XCTAssertEqual(fields?.notes, "Renewal review")
    }

    func testOverLongTitleIsRefused() {
        XCTAssertNil(meeting(
            title: String(repeating: "t", count: CallaCopilotCommandValidation.meetingTitleLimit + 1)))
    }

    func testOverLongInviteNotesAreRefused() {
        XCTAssertNil(meeting(
            notes: String(repeating: "n", count: CallaCopilotCommandValidation.meetingNotesLimit + 1)))
    }

    func testControlCharactersInAnInviteAreRefused() {
        // The invite is written by whoever sent it, not by the user.
        XCTAssertNil(meeting(notes: "agenda\u{0}hidden"))
        XCTAssertNil(meeting(title: "sync\u{7}"))
    }

    func testAttendeeListIsCappedRatherThanRefused() {
        // A 500-person all-hands is a real invite, not an attack. Truncating the
        // list keeps the call working; refusing it would not.
        let many = (1 ... 500).map { "person\($0)@example.com" }
        XCTAssertEqual(meeting(attendees: many)?.attendees.count,
                       CallaCopilotCommandValidation.meetingAttendeeCount)
    }

    func testOneOverLongAttendeeIsRefused() {
        XCTAssertNil(meeting(attendees: [String(repeating: "a", count: 200)]))
    }

    func testControlCharactersInAnIdentifierAreRefused() {
        // The id is stored, joined on, and shown in Settings. A newline in it
        // corrupts all three.
        XCTAssertNil(meeting(eventID: "event\n1"))
        XCTAssertNil(meeting(seriesID: "series\u{1B}1"))
    }

    func testARejectedIdentifierIsNotSilentlyDropped() {
        // Absent and refused are different answers here too: an id that was sent
        // and quietly nulled would file the call's account under nothing, and the
        // next occurrence of the meeting would recall nothing.
        XCTAssertNil(meeting(eventID: String(repeating: "e", count: 300), title: "Sync"))
    }

    func testOpaqueEventKitIdentifiersPassThrough() {
        // `calendarItemIdentifier` is opaque, so this cannot be an allowlist.
        let identifier = "B4A4E2C0-1F3D-4A9B-9C2E-0A1B2C3D4E5F:20260818T090000Z"
        XCTAssertEqual(meeting(eventID: identifier)?.eventID, identifier)
    }

    func testNothingAtAllIsNoMeeting() {
        XCTAssertNil(CallaCopilotCommandValidation.meeting(
            eventID: nil, seriesID: nil, title: nil, startsAt: nil,
            endsAt: nil, location: nil, attendees: nil, notes: nil))
    }
}

final class CallaPrewarmActionTests: XCTestCase {
    func testPrewarmAndReleaseAreAllowed() {
        XCTAssertEqual(CallaCopilotCommandValidation.action("prewarm"), "prewarm")
        XCTAssertEqual(CallaCopilotCommandValidation.action("release"), "release")
    }

    func testUnknownActionsAreStillRefused() {
        XCTAssertNil(CallaCopilotCommandValidation.action("record_everything"))
        XCTAssertNil(CallaCopilotCommandValidation.action(""))
    }
}
