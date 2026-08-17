import XCTest
@testable import IntelligenceCore

/// Guidance is sent once per conversation and never restated. That is the only
/// waste we can avoid, since the provider's own ~15k-token preamble is charged on
/// every request regardless.
final class PromptComposerTests: XCTestCase {
    private func request(
        contract: OutputContract = .sentinelJSON(keys: ["headline"], marker: "<<<END>>>"),
        system: PromptBlocks = .init(base: "BASE", role: "ROLE", about: "ABOUT", taskGuidance: "GUIDE")
    ) -> IntelligenceRequest {
        IntelligenceRequest(
            task: IntelligenceTask(
                id: "t",
                defaultTier: .fast,
                contract: contract,
                latencyBudget: 5,
                conversation: .perSession,
                batching: .manual,
                allowedProviders: [.localAgy]
            ),
            sessionKey: "s",
            system: system,
            input: "Them: what is your SLA?"
        )
    }

    func testBootstrapCarriesGuidanceContractAndInput() {
        let prompt = PromptComposer.bootstrap(for: request())
        XCTAssertTrue(prompt.contains("BASE"))
        XCTAssertTrue(prompt.contains("ROLE"))
        XCTAssertTrue(prompt.contains("ABOUT"))
        XCTAssertTrue(prompt.contains("GUIDE"))
        XCTAssertTrue(prompt.contains("`headline`"))
        XCTAssertTrue(prompt.contains("<<<END>>>"))
        XCTAssertTrue(prompt.contains("Them: what is your SLA?"))
        XCTAssertTrue(prompt.contains("Never call tools"))
    }

    func testDeltaCarriesOnlyTheNewInput() {
        XCTAssertEqual(PromptComposer.delta(for: request()), "Them: what is your SLA?")
    }

    func testFreeformContractAddsNoOutputSection() {
        let prompt = PromptComposer.bootstrap(for: request(contract: .freeform))
        XCTAssertFalse(prompt.contains("## Output"))
    }

    func testEmptyBlocksAreOmittedRatherThanLeavingEmptyHeadings() {
        let prompt = PromptComposer.bootstrap(for: request(system: .init(base: "BASE")))
        XCTAssertFalse(prompt.contains("## Role"))
        XCTAssertFalse(prompt.contains("## About the user"))
    }

    func testOversizeBlocksAreClampedOnAWordBoundary() {
        let long = String(repeating: "sentence ", count: 500)
        let prompt = PromptComposer.bootstrap(
            for: request(system: .init(base: long)),
            limits: .init(about: 10, role: 10, base: 40, taskGuidance: 10)
        )
        XCTAssertTrue(prompt.contains("[truncated]"))
        XCTAssertFalse(prompt.contains("sentencesentence"))
    }

    func testStatementRenderingLabelsSpeakerAndContinuation() {
        let statement = Statement(
            fromSeq: 1, toSeq: 3, speaker: .remote,
            text: "we need the contract", span: 4, truncated: true
        )
        let rendered = PromptComposer.render(statement)
        XCTAssertTrue(rendered.hasPrefix("Them: "))
        XCTAssertTrue(rendered.contains("statement continues"))

        let mine = Statement(fromSeq: 4, toSeq: 4, speaker: .local, text: "sure", span: 1, truncated: false)
        XCTAssertEqual(PromptComposer.render([statement, mine]).split(separator: "\n").count, 2)
    }
}
