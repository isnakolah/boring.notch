import XCTest
@testable import IntelligenceCore

/// Prompts live in files now, so the things that used to be guaranteed by the
/// compiler have to be guaranteed here.
final class PromptPackTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("promptpack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ body: String, to path: String) throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    func testTheBundledPackSuppliesEveryPrompt() {
        // If the resource ever stops being copied, everything silently falls back
        // to the terse compiled-in wording. This is what notices.
        let pack = PromptPack()
        for id in PromptPack.ID.allCases {
            let text = pack.text(id)
            XCTAssertFalse(text.isEmpty, "\(id.rawValue) is empty")
            XCTAssertEqual(text, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        XCTAssertTrue(pack.personaIDs().contains("interview"))
    }

    func testTheBundledPackPassesItsOwnLint() {
        XCTAssertEqual(
            PromptPack().lint(requiredPersonas: ["generic", "interview", "sales", "support"]),
            [])
    }

    func testAUserFileWinsOverTheBundledOne() throws {
        try write("MY OWN BASE", to: "live/base.md")
        XCTAssertEqual(PromptPack(overrideDirectory: directory).text(.liveBase), "MY OWN BASE")
    }

    func testAnAbsentFileFallsThroughToTheBundle() throws {
        // A partial copy is a supported state: overriding one persona must not
        // blank out every prompt the user did not copy.
        try write("MY OWN SALES", to: "live/personas/sales.md")
        let pack = PromptPack(overrideDirectory: directory)
        XCTAssertEqual(pack.persona("sales"), "MY OWN SALES")
        XCTAssertTrue(pack.text(.liveBase).contains("live call"))
    }

    func testAnEmptiedFileIsTreatedAsAMistake() throws {
        // Editing a prompt down to nothing takes the output contract with it and
        // the notch just goes quiet. Falling through is the kinder reading.
        try write("   \n\n", to: "live/base.md")
        XCTAssertTrue(PromptPack(overrideDirectory: directory).text(.liveBase).contains("live call"))
    }

    func testAnUnknownPersonaFallsBackToGeneric() {
        let pack = PromptPack()
        XCTAssertEqual(pack.persona("board-review"), pack.persona("generic"))
    }

    func testANewPersonaIsJustAFile() throws {
        try write("This is a board review.", to: "live/personas/board-review.md")
        let pack = PromptPack(overrideDirectory: directory)
        XCTAssertEqual(pack.persona("board-review"), "This is a board review.")
        XCTAssertTrue(pack.personaIDs().contains("board-review"))
    }

    func testContractPlaceholdersAreFilled() {
        let pack = PromptPack()
        let json = pack.contractInstruction(.json(keys: ["points", "open_questions"]))
        XCTAssertEqual(json?.contains("`points`, `open_questions`"), true)
        XCTAssertEqual(json?.contains("{{"), false)

        let sentinel = pack.contractInstruction(
            .sentinelJSON(keys: ["headline"], marker: "<<<END>>>"))
        XCTAssertEqual(sentinel?.contains("<<<END>>>"), true)
        XCTAssertEqual(sentinel?.contains("{{"), false)

        XCTAssertNil(pack.contractInstruction(.freeform))
    }

    func testLintCatchesTheEditThatWouldSilenceEverySuggestion() throws {
        // Dropping the sentinel from the contract file leaves a prompt that still
        // reads fine and whose output never parses.
        try write("Reply with JSON. Keys: {{keys}}.", to: "composer/contract-sentinel.md")
        let problems = PromptPack(overrideDirectory: directory).lint()
        XCTAssertEqual(problems.count, 1)
        XCTAssertEqual(problems.first?.path, "composer/contract-sentinel.md")
        XCTAssertTrue(problems.first?.detail.contains("{{marker}}") ?? false)
    }

    func testLintReportsAMissingRequiredPersona() throws {
        let problems = PromptPack(overrideDirectory: directory)
            .lint(requiredPersonas: ["nonexistent"])
        XCTAssertEqual(problems.first?.path, "live/personas/nonexistent.md")
    }

    func testExportRoundTripsAndRefusesToClobber() throws {
        let pack = PromptPack()
        let written = try pack.export(to: directory)
        XCTAssertTrue(written.contains("live/base.md"))
        XCTAssertTrue(written.contains("live/personas/interview.md"))

        // Everything exported must reload identically...
        let reloaded = PromptPack(overrideDirectory: directory)
        for id in PromptPack.ID.allCases {
            XCTAssertEqual(reloaded.text(id), pack.text(id), "\(id.rawValue) did not round-trip")
        }
        XCTAssertEqual(reloaded.lint(requiredPersonas: ["interview"]), [])

        // ...and a second export must not overwrite an edit made since.
        try write("EDITED SINCE", to: "live/base.md")
        XCTAssertTrue(try pack.export(to: directory).isEmpty)
        XCTAssertEqual(PromptPack(overrideDirectory: directory).text(.liveBase), "EDITED SINCE")
    }

    func testForcedExportRestoresTheBundledTextRatherThanRewritingTheUsersOwn() throws {
        // Export resolves from the bundle, not from what is in force. Writing
        // the effective text would read the user's directory and write it back,
        // so a file left by an older version would perpetuate itself and
        // `--force` could never restore anything. Found in a real deploy: the
        // shipped prompt had a new paragraph, the exported copy shadowed it, and
        // re-exporting reproduced the stale copy exactly.
        try write("STALE FROM AN OLDER VERSION", to: "live/base.md")
        let stale = PromptPack(overrideDirectory: directory)
        XCTAssertEqual(stale.text(.liveBase), "STALE FROM AN OLDER VERSION")

        _ = try stale.export(to: directory, overwrite: true)
        XCTAssertEqual(
            PromptPack(overrideDirectory: directory).text(.liveBase),
            PromptPack().text(.liveBase))
    }

    func testEveryPromptStillCarriesItsContractVocabulary() {
        // The prompts and the decoders have to agree on key names. Renaming a key
        // in one place and not the other produces confident, unparseable output.
        let pack = PromptPack()
        XCTAssertTrue(pack.text(.liveBase).contains("`headline`"))
        XCTAssertTrue(pack.text(.liveBase).contains("`angles`"))
        XCTAssertTrue(pack.text(.liveBase).contains("`confirm`"))
        XCTAssertTrue(pack.text(.laneBrief).contains("`points`"))
        XCTAssertTrue(pack.text(.laneBrief).contains("`open_questions`"))
        XCTAssertTrue(pack.text(.laneExec).contains("`standing`"))
        XCTAssertTrue(pack.text(.laneSummary).contains("`summary`"))
    }
}
