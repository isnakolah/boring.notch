import XCTest
@testable import CallaCallHostKit

/// What whisper is told before it decodes each fragment.
final class DecodingContextTests: XCTestCase {
    func testVocabularyReadsAsSpeechRatherThanAList() {
        // whisper decodes the prompt as if it were preceding speech, so a bare
        // comma list gets echoed into the transcript as an utterance.
        let rendered = DecodingContext.renderVocabulary(["Amaka", "Lojice", "Nairobi"])
        XCTAssertEqual(rendered, "This conversation mentions Amaka, Lojice, Nairobi.")
    }

    func testVocabularyIsDedupedCappedAndFiltered() {
        let terms = (0..<50).map { "Term\($0)" } + ["Amaka", "amaka", "x"]
        let rendered = DecodingContext.renderVocabulary(terms)
        XCTAssertEqual(
            rendered.components(separatedBy: ", ").count,
            DecodingContext.vocabularyTermLimit)
        XCTAssertFalse(rendered.contains(" x"), "one-character terms are noise")
    }

    func testEmptyVocabularyProducesNoPrompt() {
        let context = DecodingContext()
        XCTAssertNil(context.prompt(for: .me))
    }

    func testEachLegIsConditionedOnItsOwnHistoryOnly() {
        // Conditioning the microphone on what the other party just said would
        // pull the user's words toward theirs, which defeats the point of
        // capturing the two legs separately.
        var context = DecodingContext()
        context.record("we should migrate the billing service", for: .them)
        context.record("I own that service", for: .me)

        let mine = try? XCTUnwrap(context.prompt(for: .me))
        XCTAssertEqual(mine, "I own that service")
        XCTAssertFalse(mine?.contains("migrate") ?? true)
    }

    func testHistoryKeepsTheTailNotTheHead() {
        // The tail is what abuts the audio being decoded.
        var context = DecodingContext()
        context.record(String(repeating: "old ", count: 200), for: .me)
        context.record("the newest words", for: .me)
        let prompt = context.prompt(for: .me) ?? ""
        XCTAssertTrue(prompt.hasSuffix("the newest words"))
        XCTAssertLessThanOrEqual(prompt.count, DecodingContext.historyCharacterLimit)
    }

    func testResetForgetsHistoryButKeepsVocabulary() {
        var context = DecodingContext(vocabulary: ["Lojice"])
        context.record("something said earlier", for: .me)
        context.reset()
        let prompt = context.prompt(for: .me) ?? ""
        XCTAssertTrue(prompt.contains("Lojice"))
        XCTAssertFalse(prompt.contains("earlier"))
    }

    func testProperNounsAreLiftedFromProfileText() {
        let terms = DecodingContext.terms(fromProfileText:
            "Senior engineer at Acme. I own the Billing service. We left Stripe last quarter.")
        XCTAssertTrue(terms.contains("Acme"))
        XCTAssertTrue(terms.contains("Billing"))
        XCTAssertTrue(terms.contains("Stripe"))
        // "Senior" opens the text and "We" opens a sentence; neither is a name.
        XCTAssertFalse(terms.contains("Senior"))
        XCTAssertFalse(terms.contains("We"))
    }
}

final class AttendeeVocabularyTests: XCTestCase {
    func testAnEmailYieldsBothTheNameAndTheCompany() {
        XCTAssertEqual(
            CallSession.nameParts(of: "amaka.obi@rainforest-alliance.org"),
            ["Amaka", "Obi", "Rainforest-Alliance"])
    }

    func testAPlainNameIsSplitOnSpaces() {
        XCTAssertEqual(CallSession.nameParts(of: "Amaka Obi"), ["Amaka", "Obi"])
    }

    func testEmptyAndDegenerateEntriesAreDropped() {
        XCTAssertTrue(CallSession.nameParts(of: "   ").isEmpty)
        XCTAssertTrue(CallSession.nameParts(of: "a b").isEmpty, "single letters are not names")
    }
}
