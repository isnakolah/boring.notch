import XCTest
@testable import CallaEngineValidation
@testable import CallaNotchPresentation

/// A copilot command names a process to spawn and a host to stream a live call
/// transcript to. Every rule here fails open into something worse than a crash
/// if it is wrong, so each is pinned.
final class CallaCopilotCommandValidationTests: XCTestCase {
    func testOnlyTheKnownActionsAreAccepted() {
        for action in ["start", "stop", "set_persona", "set_provider", "archive", "fetch_model",
                      "login", "test_login", "sign_out", "restore_login"] {
            XCTAssertEqual(CallaCopilotCommandValidation.action(action), action)
        }
        for action in ["", "  ", "restart", "start;rm -rf /", "START"] {
            XCTAssertNil(CallaCopilotCommandValidation.action(action), "accepted \(action)")
        }
        XCTAssertNil(CallaCopilotCommandValidation.action(nil))
    }

    // MARK: - Intelligence provider

    func testOnlyTheTwoProvidersAreAccepted() {
        XCTAssertEqual(CallaCopilotCommandValidation.provider("local"), "local")
        XCTAssertEqual(CallaCopilotCommandValidation.provider("gateway"), "gateway")
        XCTAssertEqual(CallaCopilotCommandValidation.provider(" LOCAL "), "local")
        // Not a provider name, a vendor, a URL, or a binary path. Each of these
        // would end up as an argument to a spawned process.
        for value in ["", "  ", "openai", "anthropic", "ollama", "local;id",
                      "wss://elsewhere/stream", "/usr/bin/agy", "localhost"] {
            XCTAssertNil(CallaCopilotCommandValidation.provider(value), "accepted \(value)")
        }
        XCTAssertNil(CallaCopilotCommandValidation.provider(nil))
    }

    func testTiersAreTheThreeTheFastTransportUnderstands() {
        for tier in ["fast", "balanced", "deep"] {
            XCTAssertEqual(CallaCopilotCommandValidation.tier(tier), tier)
        }
        // A model *name* is not a tier: the transport quick enough for a live call
        // only accepts the coarse ones.
        for value in ["", "flash", "pro", "gemini-3.7-flash-low", "fastest"] {
            XCTAssertNil(CallaCopilotCommandValidation.tier(value), "accepted \(value)")
        }
    }

    func testSummaryModelsAreAllowlistedAndExcludeTheLiveTier() {
        XCTAssertEqual(
            CallaCopilotCommandValidation.summaryModel("gemini-3.1-pro-high"),
            "gemini-3.1-pro-high")
        XCTAssertEqual(
            CallaCopilotCommandValidation.summaryModel("claude-sonnet-4-6"),
            "claude-sonnet-4-6")
        // The summary pass exists to be better than the live tier, so a flash
        // model here is a mistake rather than a preference.
        for value in ["gemini-3.7-flash-low", "gemini-3.7-flash-medium", "gpt-4o", "",
                      "gemini-3.1-pro-high; rm -rf /"] {
            XCTAssertNil(CallaCopilotCommandValidation.summaryModel(value), "accepted \(value)")
        }
        XCTAssertNil(CallaCopilotCommandValidation.summaryModel(nil))
    }

    func testTiersStayInStepWithTheAllowlistThatSpawnsThem() {
        // These three names are also `IntelligenceCore.ModelTier`'s cases; the
        // host maps them onto agentapi's tier tokens. Drift here means a call
        // starts with an argument the host rejects.
        XCTAssertEqual(CallaCopilotCommandValidation.allowedTiers, ["fast", "balanced", "deep"])
    }

    func testTheGatewayRouteIsStillTheOnlyRemoteOneAllowed() {
        // Adding a local provider must not have loosened this: a transcript still
        // must not be steerable to another host.
        XCTAssertNotNil(CallaCopilotCommandValidation.gatewayURL(
            "wss://nomonhomelab.tailec0dca.ts.net/call-copilot/stream"))
        for url in ["wss://evil.example/call-copilot/stream",
                    "ws://nomonhomelab.tailec0dca.ts.net/call-copilot/stream",
                    "https://nomonhomelab.tailec0dca.ts.net/call-copilot/stream",
                    "wss://nomonhomelab.tailec0dca.ts.net/other"] {
            XCTAssertNil(CallaCopilotCommandValidation.gatewayURL(url), "accepted \(url)")
        }
    }

    func testPersonasAreTheGatewaySeedsOrAnIdentifierShapedName() {
        // The four seeded ones must stay in lockstep with PERSONAS in the
        // gateway's protocol.mjs.
        for persona in ["generic", "interview", "sales", "support"] {
            XCTAssertEqual(CallaCopilotCommandValidation.persona(persona), persona)
        }
        XCTAssertEqual(CallaCopilotCommandValidation.persona("Interview"), "interview")

        // A user-defined persona is accepted, because its guidance travels with
        // it — but it stays identifier-shaped, since an id can end up naming a
        // session key or a path.
        XCTAssertEqual(CallaCopilotCommandValidation.persona("board-review"), "board-review")
        for rejected in ["", "  ", "board review", "board/review", "../etc", "a<24 chars?>",
                         String(repeating: "a", count: 25)] {
            XCTAssertNil(CallaCopilotCommandValidation.persona(rejected), "accepted \(rejected)")
        }
    }

    // MARK: - Prompt profile

    func testProfileAcceptsOrdinaryPromptTextAndTrimsIt() {
        let profile = CallaCopilotCommandValidation.profile(
            about: "  Senior engineer at Acme.\nI own billing.  ",
            personaGuidance: nil,
            baseGuidance: nil)
        XCTAssertEqual(profile?.about, "Senior engineer at Acme.\nI own billing.")
        XCTAssertNil(profile?.personaGuidance)
        XCTAssertNil(profile?.baseGuidance)
    }

    func testAnEmptyProfileIsNoProfileRatherThanAnEmptyOne() {
        XCTAssertNil(CallaCopilotCommandValidation.profile(about: nil, personaGuidance: nil, baseGuidance: nil))
        XCTAssertNil(CallaCopilotCommandValidation.profile(about: "   ", personaGuidance: "\n", baseGuidance: ""))
    }

    func testOverLengthPromptTextIsRefusedRatherThanTruncated() {
        // Truncating would run the call on a different prompt than the one
        // Settings shows, which is worse than refusing outright.
        let tooLong = String(repeating: "a", count: CallaCopilotCommandValidation.aboutLimit + 1)
        XCTAssertNil(CallaCopilotCommandValidation.profile(about: tooLong, personaGuidance: nil, baseGuidance: nil))

        let atLimit = String(repeating: "a", count: CallaCopilotCommandValidation.aboutLimit)
        XCTAssertEqual(
            CallaCopilotCommandValidation.profile(about: atLimit, personaGuidance: nil, baseGuidance: nil)?.about,
            atLimit)
    }

    func testControlCharactersAreRefusedButNewlinesAreNot() {
        XCTAssertNotNil(CallaCopilotCommandValidation.profile(
            about: "line one\nline two\tindented", personaGuidance: nil, baseGuidance: nil))
        for hostile in ["null\u{0}byte", "escape\u{1B}[2Jsequence", "bell\u{7}"] {
            XCTAssertNil(
                CallaCopilotCommandValidation.profile(about: hostile, personaGuidance: nil, baseGuidance: nil),
                "accepted \(hostile.debugDescription)")
        }
    }

    func testOneRefusedFieldRefusesTheWholeProfile() {
        // Otherwise a rejected paragraph reads as an unset one, and the call
        // silently runs on the gateway's default wording instead.
        let profile = CallaCopilotCommandValidation.profile(
            about: "fine",
            personaGuidance: String(repeating: "b", count: CallaCopilotCommandValidation.personaGuidanceLimit + 1),
            baseGuidance: nil)
        XCTAssertNil(profile)
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
