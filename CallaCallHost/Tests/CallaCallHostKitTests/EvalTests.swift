import XCTest
@testable import CallaCallHostKit

/// The arithmetic the accuracy numbers rest on.
///
/// An eval harness that is quietly wrong is worse than none: it launders a
/// regression into a green number. Everything here is checked against a value
/// worked out by hand.
final class TextMetricsTests: XCTestCase {
    func testNormalizeStripsWhatTheTwoTranscriptsDisagreeAboutAnyway() {
        // The live and archive passes differ on casing and punctuation in almost
        // every line. Counting that as error would bury the real differences.
        XCTAssertEqual(
            TextMetrics.normalize("Hello, World! It's 2026."),
            ["hello", "world", "it's", "2026"])
        XCTAssertEqual(TextMetrics.normalize("   "), [])
    }

    func testEditDistanceMatchesHandWorkedCases() {
        XCTAssertEqual(TextMetrics.editDistance(["a", "b", "c"], ["a", "b", "c"]), 0)
        XCTAssertEqual(TextMetrics.editDistance(["a", "b", "c"], ["a", "x", "c"]), 1)
        XCTAssertEqual(TextMetrics.editDistance(["a", "b"], ["a", "b", "c"]), 1)
        XCTAssertEqual(TextMetrics.editDistance([], ["a", "b"]), 2)
        XCTAssertEqual(TextMetrics.editDistance(["a", "b"], []), 2)
    }

    func testEditDistanceIsSymmetric() {
        // The implementation iterates over the longer sequence to keep its rows
        // short, so the two orders take different paths through the same result.
        let long = ["the", "quick", "brown", "fox", "jumps"]
        let short = ["the", "brown", "fox"]
        XCTAssertEqual(
            TextMetrics.editDistance(long, short),
            TextMetrics.editDistance(short, long))
    }

    func testWordErrorRateIsErrorsOverReferenceLength() throws {
        // One substitution in four reference words.
        let rate = try XCTUnwrap(
            TextMetrics.wordErrorRate(hypothesis: "the cat sat here", reference: "the cat sat there"))
        XCTAssertEqual(rate, 0.25, accuracy: 0.0001)
    }

    func testEmptyReferenceScoresNilRatherThanZero() {
        // Zero would read as a perfect transcript for a call that has nothing to
        // be scored against — which is 63 of the first 66 calls on this machine.
        XCTAssertNil(TextMetrics.wordErrorRate(hypothesis: "anything", reference: ""))
        XCTAssertNil(TextMetrics.characterErrorRate(hypothesis: "anything", reference: "  "))
    }
}

final class ClaimGuardTests: XCTestCase {
    private func evidence(_ sources: String...) -> ClaimGuard.Evidence {
        ClaimGuard.Evidence(sources: sources)
    }

    func testTheFabricationThisExistsToCatch() {
        // The real one, from call-25132b71-a6aa-4e seq 106. The interviewer asked
        // about academic background; the user had said electrical engineering,
        // not to completion. The copilot offered a Computer Science degree.
        let known = evidence("I did electrical engineering though not to completion.")
        let verdict = ClaimGuard.check(
            "I hold a degree in Computer Science, focusing on software engineering and systems design.",
            against: known)
        XCTAssertFalse(verdict.isGrounded)
        XCTAssertTrue(verdict.unsupported.contains("computer"))
    }

    func testTheClaimTheUserActuallyMadeIsGrounded() {
        let known = evidence("Daniel studied electrical engineering at university, not to completion.")
        let verdict = ClaimGuard.check(
            "I did electrical engineering, though I did not complete the degree.",
            against: known)
        XCTAssertTrue(verdict.isGrounded, "unsupported: \(verdict.unsupported)")
    }

    func testAdviceIsNotAClaim() {
        // "Ask what their SLA is" names a term the user has never heard and is
        // still good advice. Only first-person assertions are checked.
        let verdict = ClaimGuard.check("Ask what their Kubernetes rollout looks like", against: evidence())
        XCTAssertTrue(verdict.isGrounded)
    }

    func testTheOtherPartysWordsAreNotEvidence() {
        // A leading question must not license the answer. The evidence set is
        // built from notes, profile and the user's own turns — never from `them`.
        var known = evidence("Nothing relevant.")
        known.add("I worked on billing.")
        let verdict = ClaimGuard.check("I led the Kubernetes migration", against: known)
        XCTAssertFalse(verdict.isGrounded)
        XCTAssertTrue(verdict.unsupported.contains("kubernetes"))
    }

    func testSentenceInitialCapitalsAreNotEntities() {
        // The first pass flagged `i'm`, `let's` and `sorry` across 54 real calls
        // because they follow a full stop and are therefore capitalised.
        let verdict = ClaimGuard.check("Yes. I'm happy to. Sorry, let's move on.", against: evidence())
        XCTAssertTrue(verdict.isGrounded, "unsupported: \(verdict.unsupported)")
    }

    func testNumbersMustBeSupported() {
        let known = evidence("We run about forty engineers across three teams.")
        XCTAssertFalse(ClaimGuard.check("I manage 250 engineers", against: known).isGrounded)
        XCTAssertTrue(ClaimGuard.check("I have 250 engineers", against: evidence("headcount is 250")).isGrounded)
    }

    func testMorphologyIsToleratedSoTheGuardIsSatisfiable() {
        // The note says "engineering", the claim says "engineer". Refusing that
        // would fire on nearly every real sentence.
        let known = evidence("Background in electrical engineering.")
        XCTAssertTrue(ClaimGuard.check("I trained as an electrical engineer", against: known).isGrounded)
    }

    func testShortWordsDoNotMatchByPrefix() {
        // "art" must not vouch for "arthur"; the prefix rule needs 5 characters
        // on the shorter side.
        let known = evidence("I like art.")
        XCTAssertFalse(ClaimGuard.check("I worked with Art Vandelay", against: known).isGrounded)
    }
}

final class CallEvaluatorTests: XCTestCase {
    private func turn(_ seq: Int, _ source: TurnSource, _ t0: Double, _ text: String) -> CallTurn {
        CallTurn(seq: seq, source: source, t0: t0, t1: t0 + 2, text: text)
    }

    func testEchoIsCountedWhenAMeTurnSitsOnTopOfAThemTurn() {
        // What speaker-mode calls look like: the microphone hears the speakers,
        // whisper renders it slightly differently, and the transcript doubles.
        let call = EvaluatedCall(
            id: "c", directory: URL(fileURLWithPath: "/tmp"), meta: nil,
            live: [
                turn(0, .them, 1.2, "the things that come out look like ships"),
                turn(1, .me, 1.4, "The things that come out look like ships."),
                turn(2, .me, 40.0, "That is a real thing I said."),
            ],
            archived: [], suggestions: [])
        let score = CallEvaluator.score(call, evidence: ClaimGuard.Evidence())
        XCTAssertEqual(score.meTurns, 2)
        XCTAssertEqual(score.echoOverlappingTurns, 1)
        XCTAssertEqual(score.echoExactDuplicates, 1, "normalisation should reconcile case and punctuation")
        XCTAssertEqual(score.echoLeakRate, 0.5, accuracy: 0.0001)
    }

    func testArtifactTurnsAreCounted() {
        XCTAssertTrue(CallEvaluator.isArtifact("[BLANK_AUDIO]"))
        XCTAssertTrue(CallEvaluator.isArtifact("(upbeat music)"))
        XCTAssertTrue(CallEvaluator.isArtifact("  (coughing) "))
        XCTAssertFalse(CallEvaluator.isArtifact("I said (roughly) forty"))
        XCTAssertFalse(CallEvaluator.isArtifact(""))
    }

    func testAClaimIsOnlyJudgedAgainstWhatWasKnownAtTheTime() {
        // A suggestion at seq 1 must not be justified by something the user said
        // at seq 9. Scoring against the whole call would hide every fabrication
        // the user later happened to correct.
        let call = EvaluatedCall(
            id: "c", directory: URL(fileURLWithPath: "/tmp"), meta: nil,
            live: [
                turn(0, .them, 0, "What is your background?"),
                turn(9, .me, 30, "I studied electrical engineering."),
            ],
            archived: [],
            suggestions: [earlyClaim])
        let score = CallEvaluator.score(call, evidence: ClaimGuard.Evidence())
        XCTAssertEqual(score.ungroundedSuggestions, 1)
    }

    private var earlyClaim: ArchivedSuggestion {
        let json = #"{"after_seq":0,"headline":"I hold a degree in Computer Science.","angles":[],"confirm":[],"latency_ms":10}"#
        return try! JSONDecoder().decode(ArchivedSuggestion.self, from: Data(json.utf8))
    }
}

final class WAVRepairTests: XCTestCase {
    /// A RIFF/WAVE header shaped like the one `AVAudioFile` leaves behind: a
    /// `JUNK` pad, a `fmt ` chunk, and a `data` chunk whose length is still zero.
    private func unfinalizedWAV(payloadBytes: Int) -> Data {
        var data = Data()
        func u32(_ value: UInt32) -> Data {
            Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                  UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
        }
        data.append(Data("RIFF".utf8))
        data.append(u32(0))                       // never patched
        data.append(Data("WAVE".utf8))
        data.append(Data("JUNK".utf8))
        data.append(u32(4))
        data.append(Data(repeating: 0, count: 4))
        data.append(Data("fmt ".utf8))
        data.append(u32(16))
        data.append(Data(repeating: 0, count: 16))
        data.append(Data("data".utf8))
        data.append(u32(0))                       // never patched
        data.append(Data(repeating: 0xAB, count: payloadBytes))
        return data
    }

    private func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavrepair-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    func testRepairsAHeaderThatUnderstatesItsPayload() throws {
        let url = try write(unfinalizedWAV(payloadBytes: 4000))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(try WAVRepair.repairIfNeeded(at: url))

        let repaired = try Data(contentsOf: url)
        let dataChunk = try XCTUnwrap(WAVRepair.findDataChunk(in: repaired))
        XCTAssertEqual(readUInt32(repaired, dataChunk + 4), 4000)
        XCTAssertEqual(readUInt32(repaired, 4), UInt32(repaired.count - 8))
    }

    func testASecondPassChangesNothing() throws {
        // Repair runs on every read, so it must be idempotent — and must never
        // shrink a file that is already correct.
        let url = try write(unfinalizedWAV(payloadBytes: 4000))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try WAVRepair.repairIfNeeded(at: url))
        XCTAssertFalse(try WAVRepair.repairIfNeeded(at: url))
    }

    func testATornFinalWriteIsTrimmedToWholeFrames() throws {
        // A killed host can leave a partial float on the end. Handing whisper
        // three bytes of a sample is worse than dropping them.
        let url = try write(unfinalizedWAV(payloadBytes: 4002))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try WAVRepair.repairIfNeeded(at: url))
        let repaired = try Data(contentsOf: url)
        let dataChunk = try XCTUnwrap(WAVRepair.findDataChunk(in: repaired))
        XCTAssertEqual(readUInt32(repaired, dataChunk + 4), 4000)
    }

    func testNonRIFFIsRejectedRatherThanCorrupted() throws {
        let url = try write(Data("this is not a wav file at all, not even close".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try WAVRepair.repairIfNeeded(at: url))
    }

    private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) | UInt32(data[base + 1]) << 8
            | UInt32(data[base + 2]) << 16 | UInt32(data[base + 3]) << 24
    }
}

/// The line between repeating a name and inventing a fact.
final class ClaimGuardHearsayTests: XCTestCase {
    func testANameTheOtherSideUsedMayBeSaidBack() {
        // "I'm drawn to Rainforest Alliance's work in East Africa" is the
        // ordinary shape of an interview answer, not a fabrication.
        var known = ClaimGuard.Evidence(sources: ["I build backend services."])
        known.addHeardNames("We're Rainforest Alliance and we work across East Africa.")
        XCTAssertTrue(
            ClaimGuard.check("I'm drawn to Rainforest Alliance's work in East Africa", against: known)
                .isGrounded)
    }

    func testAQuestionStillDoesNotLicenseACredential() {
        // The failure this guard exists for: the interviewer names the field,
        // the model claims the degree.
        var known = ClaimGuard.Evidence(sources: ["I did electrical engineering, not to completion."])
        known.addHeardNames("Do you have a degree in computer science?")
        let verdict = ClaimGuard.check("I have a degree in computer science", against: known)
        XCTAssertFalse(verdict.isGrounded)
        XCTAssertTrue(verdict.unsupported.contains("science"))
    }

    func testAQuestionDoesNotLicenseANumber() {
        var known = ClaimGuard.Evidence(sources: ["I have been doing this a while."])
        known.addHeardNames("We need someone with 10 years of experience.")
        XCTAssertFalse(ClaimGuard.check("I have 10 years of experience", against: known).isGrounded)
    }
}

/// Word error rate is computed in time-aligned windows; these pin what that
/// means at the edges.
final class WindowedWERTests: XCTestCase {
    private func turn(_ t0: Double, _ text: String) -> CallTurn {
        CallTurn(seq: 0, source: .them, t0: t0, t1: t0 + 1, text: text)
    }

    func testAPerfectTranscriptScoresZero() {
        let reference = [turn(0, "the cat sat"), turn(45, "on the mat")]
        XCTAssertEqual(CallEvaluator.wer(live: reference, archived: reference) ?? -1, 0, accuracy: 0.0001)
    }

    func testErrorsAndLengthsSumAcrossWindows() {
        // Window 0: one substitution in three words. Window 1: three correct.
        // Corpus WER is 1/6, not the average of 1/3 and 0.
        let reference = [turn(0, "the cat sat"), turn(45, "on the mat")]
        let live = [turn(0, "the dog sat"), turn(45, "on the mat")]
        XCTAssertEqual(CallEvaluator.wer(live: live, archived: reference) ?? -1,
                       1.0 / 6.0, accuracy: 0.0001)
    }

    func testHallucinationInAnEmptyWindowIsCounted() {
        // Whisper inventing a sentence over silence is the failure mode the
        // archive pass had before VAD. A WER that only walked the reference's
        // windows would score it as perfect.
        let reference = [turn(0, "the cat sat")]
        let live = [turn(0, "the cat sat"), turn(90, "thanks for watching")]
        XCTAssertEqual(CallEvaluator.wer(live: live, archived: reference) ?? -1,
                       3.0 / 3.0, accuracy: 0.0001)
    }

    func testNoReferenceScoresNil() {
        XCTAssertNil(CallEvaluator.wer(live: [turn(0, "anything")], archived: []))
    }
}

/// The metrics have to survive the fix, not punish it.
final class EchoAwareMetricTests: XCTestCase {
    private func turn(_ source: TurnSource, _ t0: Double, _ text: String) -> CallTurn {
        CallTurn(seq: 0, source: source, t0: t0, t1: t0 + 2, text: text)
    }

    func testMicrophoneWERIgnoresWindowsWhereTheOtherSideWasTalking() {
        // The archive reference transcribes everything the mic heard, speaker
        // bleed included. A pipeline that correctly drops the bleed must not be
        // scored as having failed to transcribe it.
        let reference = [
            turn(.me, 0, "this is me talking alone"),
            turn(.me, 60, "the other party echoing through my speakers"),
        ]
        let remote = [turn(.them, 60, "the other party echoing through my speakers")]
        // The pipeline kept the first and suppressed the second.
        let live = [turn(.me, 0, "this is me talking alone")]

        let naive = CallEvaluator.wer(live: live, archived: reference)
        let honest = CallEvaluator.wer(
            live: live, archived: reference, excludingWindowsFrom: remote)
        XCTAssertGreaterThan(naive ?? 0, 0.4, "the naive metric punishes suppression")
        XCTAssertEqual(honest ?? -1, 0, accuracy: 0.0001, "the honest one does not")
    }

    func testEchoSurvivorsPerMinuteFallsWhenSuppressionWorks() {
        // The leak *rate* cannot measure suppression: it shrinks its own
        // denominator, so removing nine of ten echo turns can raise it.
        let remote = (0..<10).map { turn(.them, Double($0) * 6, "them \($0)") }
        let before = EvaluatedCall(
            id: "before", directory: URL(fileURLWithPath: "/tmp"), meta: nil,
            live: remote + (0..<10).map { turn(.me, Double($0) * 6 + 0.2, "echo \($0)") },
            archived: [], replayed: [], suggestions: [])
        let after = EvaluatedCall(
            id: "after", directory: URL(fileURLWithPath: "/tmp"), meta: nil,
            live: remote + [turn(.me, 0.2, "echo 0")],
            archived: [], replayed: [], suggestions: [])

        let scoreBefore = CallEvaluator.score(before, evidence: ClaimGuard.Evidence())
        let scoreAfter = CallEvaluator.score(after, evidence: ClaimGuard.Evidence())

        XCTAssertEqual(scoreBefore.echoLeakRate, 1.0, accuracy: 0.001)
        XCTAssertEqual(scoreAfter.echoLeakRate, 1.0, accuracy: 0.001,
                       "the rate is blind to a 90% reduction")
        XCTAssertLessThan(scoreAfter.echoSurvivorsPerMinute,
                          scoreBefore.echoSurvivorsPerMinute / 5,
                          "the per-minute figure is not")
    }

    func testMicTurnsPerMinuteExposesOverSuppression() {
        // The guard against the opposite failure: a detector so eager it deletes
        // the user's half of the call.
        let base = (0..<10).map { turn(.me, Double($0) * 6, "something I said \($0)") }
        let healthy = EvaluatedCall(
            id: "healthy", directory: URL(fileURLWithPath: "/tmp"), meta: nil,
            live: base, archived: [], replayed: [], suggestions: [])
        let gutted = EvaluatedCall(
            id: "gutted", directory: URL(fileURLWithPath: "/tmp"), meta: nil,
            live: [base[0], base[9]], archived: [], replayed: [], suggestions: [])

        XCTAssertGreaterThan(
            CallEvaluator.score(healthy, evidence: ClaimGuard.Evidence()).meTurnsPerMinute,
            CallEvaluator.score(gutted, evidence: ClaimGuard.Evidence()).meTurnsPerMinute * 3)
    }
}

/// The end-to-end shape of the failure this work started from.
///
/// The retrieval fix and the claim guard are separate mechanisms and either one
/// alone leaves the hole open, so they are pinned together here.
final class FabricationRegressionTests: XCTestCase {
    /// The part of the real CV that answers the question, as retrieval returns it.
    private let cvChunk = """
    automated testing, CI validation and disciplined production support. EDUCATION \
    Bachelor of Science (BSc), Electrical and Electronics Engineering | University \
    of Nairobi, Kenya SELECTED TECHNICAL & COMMUNITY WORK
    """

    private var evidenceWithCV: ClaimGuard.Evidence {
        var evidence = ClaimGuard.Evidence(sources: [cvChunk])
        evidence.add("I did electrical engineering though not to completion.")
        evidence.addHeardNames("And what's your academic background? I don't see that in the CV, please.")
        return evidence
    }

    func testTheSentenceThatWasActuallyShownIsRefused() {
        let verdict = ClaimGuard.check(
            "I hold a degree in Computer Science, focusing on software engineering and systems design.",
            against: evidenceWithCV)
        XCTAssertFalse(verdict.isGrounded)
        // "computer" is the load-bearing one: it is the word that turns a true
        // statement about an electrical engineering background into a false one.
        XCTAssertTrue(verdict.unsupported.contains("computer"))
    }

    func testTheTrueAnswerFromTheCVIsAllowed() {
        XCTAssertTrue(ClaimGuard.check(
            "I studied Electrical and Electronics Engineering at the University of Nairobi.",
            against: evidenceWithCV).isGrounded)
    }

    func testTheHonestAdmissionIsAllowed() {
        XCTAssertTrue(ClaimGuard.check(
            "I did electrical engineering but did not complete it.",
            against: evidenceWithCV).isGrounded)
    }

    func testWithoutTheCVTheTrueAnswerIsAlsoRefused() {
        // Why the retrieval fix matters on its own: the guard can only vouch for
        // what it can see. With retrieval gated on a calendar meeting — as it was
        // — an ad-hoc interview had no CV in scope, and the *correct* answer
        // would have been withheld alongside the invented one.
        var withoutCV = ClaimGuard.Evidence()
        withoutCV.add("I did electrical engineering though not to completion.")
        XCTAssertFalse(ClaimGuard.check(
            "I studied Electrical and Electronics Engineering at the University of Nairobi.",
            against: withoutCV).isGrounded)
    }
}

/// The gates themselves, so a change that guts them fails rather than passes.
final class EvalGateTests: XCTestCase {
    private func score(
        echo: Double = 0.1,
        mic: Double = 0.95,
        short: Double = 0.1,
        artifacts: Int = 0,
        ungrounded: Int = 0,
        suggestions: Int = 100
    ) -> CallScore {
        CallScore(
            callID: "c", isReplay: true, turns: 100, durationSeconds: 600,
            werMe: nil, werThem: nil, cerOverall: nil,
            meTurns: 50, echoOverlappingTurns: 0, echoExactDuplicates: 0,
            echoLeakRate: 0, echoSurvivorsPerMinute: echo, meTurnsPerMinute: 3,
            micCoverage: mic,
            turnsPerMinute: 10, meanWordsPerTurn: 9, shortTurnRate: short,
            artifactTurns: artifacts, suggestions: suggestions,
            distinctHeadlines: suggestions, repeatRate: 0,
            ungroundedSuggestions: ungrounded,
            ungroundedRate: Double(ungrounded) / Double(max(1, suggestions)),
            unsupportedTokens: [])
    }

    func testAHealthyCorpusPasses() {
        XCTAssertEqual(EvalReport(calls: [score()]).failures(), [])
    }

    func testEchoSurvivingTheDetectorFails() {
        let failures = EvalReport(calls: [score(echo: 5)]).failures()
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("echo survivors"))
    }

    func testDeletingTheUsersSpeechFails() {
        // The failure mode the other gates cannot see: an over-eager echo
        // detector scores perfectly on echo, fragmentation and artifacts by
        // suppressing the entire microphone leg.
        let failures = EvalReport(calls: [score(echo: 0, mic: 0.1)]).failures()
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("being suppressed"))
    }

    func testCorrectSuppressionOnASpeakerModeCallIsNotAFailure() {
        // On a call taken through the speakers nearly every microphone turn is
        // echo, so almost none surviving is the *right* outcome. Gating on raw
        // microphone turns per minute failed exactly here — the measure has to
        // be coverage of the user's own words in windows where the remote leg
        // was silent, which a speaker-mode call barely has.
        XCTAssertEqual(EvalReport(calls: [score(echo: 0, mic: 0.95)]).failures(), [])
    }

    func testACallWithNoSoloStretchIsNotGatedOnCoverage() {
        // micCoverage is nil when the remote leg never went quiet. That is
        // "unmeasurable", not "zero".
        var unmeasurable = score()
        unmeasurable.micCoverage = nil
        XCTAssertEqual(EvalReport(calls: [unmeasurable]).failures(), [])
    }

    func testNonSpeechAnnotationsReachingTheTranscriptFail() {
        XCTAssertTrue(EvalReport(calls: [score(artifacts: 40)])
            .failures().contains { $0.contains("bracketed") })
    }

    func testFabricatedClaimsFail() {
        XCTAssertTrue(EvalReport(calls: [score(ungrounded: 30)])
            .failures().contains { $0.contains("ungrounded") })
    }

    func testAnEmptyCorpusDoesNotFailVacuously() {
        // No calls means nothing was measured, which must not read as a pass with
        // a perfect score or as a failure with no cause.
        XCTAssertEqual(EvalReport(calls: []).failures(), [])
    }
}
