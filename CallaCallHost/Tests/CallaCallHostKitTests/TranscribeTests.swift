import XCTest
@testable import CallaCallHostKit

/// The arithmetic in this package that is wrong *silently*.
///
/// A bad `audio_ctx` returns zero segments in 0.2s, which is indistinguishable
/// from silence. A bad gain makes speech look like noise. A misparsed CoreML
/// log flips the truncation policy. None of them throw.
final class WhisperEngineMathTests: XCTestCase {
    func testAudioCtxUsesOnlyTheTwoValuesThatAreSafe() {
        let rate = WhisperAudioFormat.sampleRate

        // Short VAD-bounded utterances: 750, the validated fast value.
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: Int(rate * 1)), 750)
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: Int(rate * 5)), 750)
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: Int(rate * 14.9)), 750)

        // At/past 750's 15s capacity, fall back to whisper's default rather than
        // silently truncating the clip.
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: Int(rate * 15)), 0)
        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: Int(rate * 30)), 0)

        XCTAssertEqual(WhisperEngine.computeAudioCtx(sampleCount: 0), 0)
    }

    func testDetectLanguageIsNeverSet() {
        // `detect_language` means "stop after detection, skip transcription".
        // Setting it yields zero segments and no error, so it must stay false
        // even in the auto case.
        XCTAssertEqual(WhisperEngine.languageParams(for: "en").language, "en")
        XCTAssertFalse(WhisperEngine.languageParams(for: "en").detectLanguage)

        XCTAssertEqual(WhisperEngine.languageParams(for: "").language, "auto")
        XCTAssertFalse(WhisperEngine.languageParams(for: "").detectLanguage)
    }

    func testNormalizeLiftsQuietAudioTowardTheTargetPeak() {
        // Peak 0.1 needs 5x to reach the 0.5 target, which is inside the cap.
        let quiet: [Float] = [0.1, -0.1, 0.05, -0.05]
        let boosted = WhisperEngine.normalize(quiet)
        XCTAssertEqual(AudioSignal.peak(boosted), 0.5, accuracy: 0.001)
        XCTAssertTrue(boosted.allSatisfy { abs($0) <= 1 })
    }

    func testNormalizeLeavesHealthyAudioAlone() {
        // Gain under 1.05 is not worth a full copy of the buffer.
        let healthy: [Float] = [0.5, -0.49, 0.48]
        XCTAssertEqual(WhisperEngine.normalize(healthy), healthy)
    }

    func testNormalizeHandlesDegenerateInput() {
        XCTAssertEqual(WhisperEngine.normalize([]), [])
        // All-zero has no peak to normalize against; it must not divide by zero.
        XCTAssertEqual(WhisperEngine.normalize([0, 0, 0]), [0, 0, 0])
    }

    func testNormalizeCapsGainSoRoomNoiseIsNotAmplifiedIntoSpeech() {
        let veryQuiet = [Float](repeating: 0.0001, count: 16)
        let boosted = WhisperEngine.normalize(veryQuiet)
        // 0.5 / 0.0001 would be 5000x; the cap is 20x.
        XCTAssertEqual(AudioSignal.peak(boosted), 0.0001 * 20, accuracy: 0.00001)
    }

    func testCoreMLStatusReportsLoadedWithItsPath() {
        let status = WhisperEngine.parseCoreMLStatus(from: [
            "whisper_init: loading Core ML model from '/models/x-encoder.mlmodelc'",
            "whisper_init: Core ML model loaded",
        ])
        XCTAssertEqual(status, .loaded(path: "/models/x-encoder.mlmodelc"))
    }

    func testMissingSiblingIsUnavailableRatherThanFailed() {
        // whisper emits a "failed to load" line even when no sibling exists.
        // Reporting that as a failure would turn "you did not install CoreML
        // weights" into an error the user cannot act on.
        let status = WhisperEngine.parseCoreMLStatus(from: [
            "whisper_init: loading Core ML model from '/definitely/not/here-encoder.mlmodelc'",
            "whisper_init: failed to load Core ML model from '/definitely/not/here-encoder.mlmodelc'",
        ])
        XCTAssertEqual(status, .unavailable)
    }

    func testSilenceProducesUnavailable() {
        XCTAssertEqual(WhisperEngine.parseCoreMLStatus(from: []), .unavailable)
        XCTAssertEqual(WhisperEngine.parseCoreMLStatus(from: ["whisper_init: loading model"]), .unavailable)
    }

    func testCoreMLSiblingPathMatchesWhisperConvention() {
        let model = URL(fileURLWithPath: "/models/whisper-small-en.bin")
        XCTAssertEqual(
            WhisperEngine.coreMLSiblingPath(for: model),
            "/models/whisper-small-en-encoder.mlmodelc")
    }
}

final class ModelCatalogTests: XCTestCase {
    func testLiveModelHasNoCoreMLSibling() {
        // The live leg's whole latency argument depends on this. A CoreML
        // encoder ignores audio_ctx, so attaching one would silently force every
        // short utterance through a full 30s encode.
        XCTAssertNil(WhisperModel.smallEn.coreMLURL)
        XCTAssertNil(WhisperModel.baseEn.coreMLURL)
    }

    func testArchiveModelKeepsItsCoreMLEncoder() {
        XCTAssertNotNil(WhisperModel.largeV3Turbo.coreMLURL)
        XCTAssertNotNil(WhisperModel.largeV3Turbo.coreMLSHA256)
    }

    func testEveryModelPinsAFullSha256() {
        for model in WhisperModel.all {
            XCTAssertEqual(model.sha256.count, 64, "\(model.name) sha256 is not a full digest")
            XCTAssertTrue(
                model.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                "\(model.name) sha256 must be lowercase hex")
            XCTAssertGreaterThan(model.sizeBytes, 0, "\(model.name) has no pinned size")
            XCTAssertEqual(model.languageHint, "en")
        }
    }

    func testModelsAreLookedUpByName() {
        XCTAssertEqual(WhisperModel.named("whisper-small-en"), WhisperModel.smallEn)
        XCTAssertNil(WhisperModel.named("whisper-nonexistent"))
    }

    func testLocalPathsFollowWhisperSiblingConvention() {
        let store = ModelStore(directory: URL(fileURLWithPath: "/tmp/models"))
        XCTAssertEqual(
            store.localURL(for: .smallEn).path,
            "/tmp/models/whisper-small-en.bin")
        // A model with no CoreML build must not claim a sibling directory.
        XCTAssertNil(store.coreMLDirectory(for: .smallEn))
        XCTAssertEqual(
            store.coreMLDirectory(for: .largeV3Turbo)?.lastPathComponent,
            "whisper-large-v3-turbo-encoder.mlmodelc")
    }

    func testSha256MismatchIsRejected() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("callhost-test-\(UUID().uuidString)")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        // Correct digest passes.
        XCTAssertNoThrow(try ModelStore.verifySHA256(
            at: file,
            expected: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"))

        XCTAssertThrowsError(try ModelStore.verifySHA256(at: file, expected: String(repeating: "0", count: 64)))
    }
}
