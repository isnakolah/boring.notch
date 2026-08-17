import XCTest
@testable import CallaEngineValidation
@testable import CallaNotchPresentation

/// A copilot command names a process to spawn and a host to stream a live call
/// transcript to. Every rule here fails open into something worse than a crash
/// if it is wrong, so each is pinned.
final class CallaCopilotCommandValidationTests: XCTestCase {
    func testOnlyTheThreeKnownActionsAreAccepted() {
        for action in ["start", "stop", "set_persona"] {
            XCTAssertEqual(CallaCopilotCommandValidation.action(action), action)
        }
        for action in ["", "  ", "restart", "start;rm -rf /", "START"] {
            XCTAssertNil(CallaCopilotCommandValidation.action(action), "accepted \(action)")
        }
        XCTAssertNil(CallaCopilotCommandValidation.action(nil))
    }

    func testPersonasMatchTheGatewayAllowlist() {
        // Must stay in lockstep with PERSONAS in the gateway's protocol.mjs; a
        // value the gateway rejects should never leave this machine.
        for persona in ["generic", "interview", "sales", "support"] {
            XCTAssertEqual(CallaCopilotCommandValidation.persona(persona), persona)
        }
        XCTAssertEqual(CallaCopilotCommandValidation.persona("Interview"), "interview")
        XCTAssertNil(CallaCopilotCommandValidation.persona("therapist"))
        XCTAssertNil(CallaCopilotCommandValidation.persona(""))
    }

    func testTheArchiveModelIsNotOfferedForLiveTranscription() {
        XCTAssertEqual(CallaCopilotCommandValidation.liveModel("whisper-small-en"), "whisper-small-en")
        XCTAssertEqual(CallaCopilotCommandValidation.liveModel("whisper-base-en"), "whisper-base-en")
        // Its CoreML encoder forces whisper's full 30s context per utterance,
        // which makes the live leg unusable.
        XCTAssertNil(CallaCopilotCommandValidation.liveModel("whisper-large-v3-turbo"))
        XCTAssertNil(CallaCopilotCommandValidation.liveModel("../../etc/passwd"))
    }

    func testCallIdentifiersMatchTheWireFormat() {
        XCTAssertNotNil(CallaCopilotCommandValidation.callID("call-0123456789ab"))
        XCTAssertNotNil(CallaCopilotCommandValidation.callID("call-" + String(repeating: "a", count: 72)))
        // Anything that could escape the calls directory when joined to a path.
        XCTAssertNil(CallaCopilotCommandValidation.callID("call-../../secrets"))
        XCTAssertNil(CallaCopilotCommandValidation.callID("call-short"))
        XCTAssertNil(CallaCopilotCommandValidation.callID("nope-0123456789ab"))
        XCTAssertNil(CallaCopilotCommandValidation.callID("call-" + String(repeating: "a", count: 73)))
        XCTAssertNil(CallaCopilotCommandValidation.callID(""))
    }

    func testOnlyTheBoringOwnedGatewayRouteIsAccepted() {
        // A live call transcript is the most sensitive thing this feature
        // touches. A command carrying an arbitrary URL would be enough to send
        // it somewhere else entirely.
        XCTAssertNotNil(CallaCopilotCommandValidation.gatewayURL(
            "wss://nomonhomelab.tailec0dca.ts.net/call-copilot/stream"))

        for rejected in [
            "ws://nomonhomelab.tailec0dca.ts.net/call-copilot/stream",   // not TLS
            "wss://evil.example.com/call-copilot/stream",                // other host
            "wss://nomonhomelab.tailec0dca.ts.net/tutor/stream",         // other route
            "https://nomonhomelab.tailec0dca.ts.net/call-copilot/stream",
            "",
        ] {
            XCTAssertNil(CallaCopilotCommandValidation.gatewayURL(rejected), "accepted \(rejected)")
        }
    }
}

/// The notch slab is fixed and unscrollable, and this surface is read in the
/// second before the user has to speak.
final class CallaCopilotPresentationTests: XCTestCase {
    func testMissingHostOutranksEverythingElse() {
        let mode = CallaCopilotPresentation.mode(
            available: false, running: true, systemAudioActive: true, hasSuggestion: true)
        XCTAssertEqual(mode, .unavailable)
    }

    func testMicOnlyCallsSaySoRatherThanLookingHealthy() {
        // The pointers are built almost entirely from what the other party
        // said, so a mic-only call silently produces near-useless output.
        let mode = CallaCopilotPresentation.mode(
            available: true, running: true, systemAudioActive: false, hasSuggestion: true)
        XCTAssertEqual(mode, .halfDeaf)
        XCTAssertEqual(CallaCopilotPresentation.pill(for: mode).tone, .warning)
    }

    func testSuggestionAndListeningStates() {
        XCTAssertEqual(
            CallaCopilotPresentation.mode(available: true, running: true, systemAudioActive: true, hasSuggestion: true),
            .suggesting)
        XCTAssertEqual(
            CallaCopilotPresentation.mode(available: true, running: true, systemAudioActive: true, hasSuggestion: false),
            .listening)
        XCTAssertEqual(
            CallaCopilotPresentation.mode(available: true, running: false, systemAudioActive: false, hasSuggestion: false),
            .ready)
    }

    func testPrimaryActionFollowsCallState() {
        XCTAssertEqual(CallaCopilotPresentation.primaryActionTitle(running: false), "Start call")
        XCTAssertEqual(CallaCopilotPresentation.primaryActionTitle(running: true), "End call")
    }

    func testElapsedGrowsAnHourFieldOnlyWhenEarned() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(CallaCopilotPresentation.elapsed(since: start, now: start.addingTimeInterval(9)), "0:09")
        XCTAssertEqual(CallaCopilotPresentation.elapsed(since: start, now: start.addingTimeInterval(75)), "1:15")
        XCTAssertEqual(CallaCopilotPresentation.elapsed(since: start, now: start.addingTimeInterval(3675)), "1:01:15")
        // A clock that ran backwards must not render as a negative duration.
        XCTAssertEqual(CallaCopilotPresentation.elapsed(since: start, now: start.addingTimeInterval(-30)), "0:00")
        XCTAssertNil(CallaCopilotPresentation.elapsed(since: nil, now: start))
    }

    func testSubtitleReportsOnlyWhatIsTrue() {
        XCTAssertEqual(
            CallaCopilotPresentation.subtitle(turnCount: 4, elapsed: "1:15", gatewayConnected: true),
            "1:15 · 4 turns")
        XCTAssertEqual(
            CallaCopilotPresentation.subtitle(turnCount: 1, elapsed: nil, gatewayConnected: true),
            "1 turn")
        XCTAssertEqual(
            CallaCopilotPresentation.subtitle(turnCount: 0, elapsed: "0:03", gatewayConnected: false),
            "0:03 · gateway offline")
    }

    func testHeadlineCollapsesNewlinesAndTruncates() {
        // A newline would grow the slab past the notch shape.
        XCTAssertEqual(CallaCopilotPresentation.headlineLine("what is\nthe timeline?"), "what is the timeline?")
        let long = String(repeating: "word ", count: 60)
        let line = CallaCopilotPresentation.headlineLine(long)
        // The 90-character cut lands mid-space here, and the trailing
        // whitespace is trimmed before the ellipsis is appended.
        XCTAssertEqual(line?.count, 90)
        XCTAssertLessThanOrEqual(line?.count ?? 0, 91, "must never exceed the cap plus the ellipsis")
        XCTAssertTrue(line?.hasSuffix("…") == true)
        XCTAssertNil(CallaCopilotPresentation.headlineLine(nil))
        XCTAssertNil(CallaCopilotPresentation.headlineLine("   "))
    }

    func testOnlyTwoAnglesReachTheNotch() {
        // A third angle is real content, but reading it mid-sentence costs more
        // than it saves — it belongs in the window.
        let angles = ["first way", "second way", "third way"]
        XCTAssertEqual(CallaCopilotPresentation.angleLines(angles), ["first way", "second way"])
        XCTAssertTrue(CallaCopilotPresentation.angleLines([]).isEmpty)
        XCTAssertTrue(CallaCopilotPresentation.angleLines(["", "   "]).isEmpty)
    }

    func testAngleLinesTruncateRatherThanWrap() {
        let long = String(repeating: "a", count: 200)
        let lines = CallaCopilotPresentation.angleLines([long])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].count, 79, "78 characters plus the ellipsis")
    }
}
