import XCTest
@testable import IntelligenceCore

/// Model output is never as clean as the prompt asked for. These are the shapes
/// actually seen coming out of `agy`: prose around the object, a ```json fence, a
/// sentinel line after it, and — when a budget bites — a truncated object.
final class ContractParserTests: XCTestCase {
    private let contract = OutputContract.sentinelJSON(
        keys: ["headline", "angles"],
        marker: "<<<CALLA_END>>>"
    )

    private func decode(_ payload: Data?) -> [String: Any] {
        guard let payload,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return [:] }
        return object
    }

    func testParsesCleanObjectWithSentinel() throws {
        let raw = """
        {"headline": "Ask about the SLA", "angles": ["uptime", "credits"]}
        <<<CALLA_END>>>
        """
        let parsed = try ContractParser.parse(raw, contract: contract)
        XCTAssertEqual(decode(parsed.payload)["headline"] as? String, "Ask about the SLA")
        XCTAssertFalse(parsed.text.contains("CALLA_END"), "the sentinel is harness bookkeeping")
    }

    func testParsesObjectWrappedInProse() throws {
        let raw = """
        Sure — here is what I would say next:

        {"headline": "Confirm scope", "angles": ["timeline"]}

        Let me know if you want it softer.
        <<<CALLA_END>>>
        """
        let parsed = try ContractParser.parse(raw, contract: contract)
        XCTAssertEqual(decode(parsed.payload)["headline"] as? String, "Confirm scope")
    }

    func testParsesFencedObject() throws {
        let raw = """
        ```json
        {"headline": "Push for a date", "angles": ["urgency", "budget"]}
        ```
        <<<CALLA_END>>>
        """
        let parsed = try ContractParser.parse(raw, contract: contract)
        XCTAssertEqual((decode(parsed.payload)["angles"] as? [String])?.count, 2)
    }

    func testIgnoresANSINoise() throws {
        let raw = "\u{1B}[2K\u{1B}[36m{\"headline\": \"Slow down\", \"angles\": []}\u{1B}[0m\n<<<CALLA_END>>>"
        let parsed = try ContractParser.parse(raw, contract: contract)
        XCTAssertEqual(decode(parsed.payload)["headline"] as? String, "Slow down")
    }

    func testPrefersTheLastCompleteObject() throws {
        let raw = """
        {"headline": "first pass", "angles": []}
        On reflection:
        {"headline": "second pass", "angles": ["scope"]}
        <<<CALLA_END>>>
        """
        let parsed = try ContractParser.parse(raw, contract: contract)
        XCTAssertEqual(decode(parsed.payload)["headline"] as? String, "second pass")
    }

    func testNestedBracesAndBracesInStringsDoNotConfuseTheScanner() throws {
        let raw = """
        {"headline": "use {curly} carefully", "angles": ["a"], "meta": {"nested": {"deep": true}}}
        <<<CALLA_END>>>
        """
        let parsed = try ContractParser.parse(raw, contract: contract)
        XCTAssertEqual(decode(parsed.payload)["headline"] as? String, "use {curly} carefully")
    }

    func testTruncatedObjectFails() {
        let raw = #"{"headline": "cut off", "angles": ["#
        XCTAssertThrowsError(try ContractParser.parse(raw, contract: contract)) { error in
            guard case IntelligenceFailure.unparseable = error else {
                return XCTFail("expected .unparseable, got \(error)")
            }
        }
    }

    func testObjectMissingARequiredKeyFails() {
        let raw = #"{"headline": "no angles here"}"# + "\n<<<CALLA_END>>>"
        XCTAssertThrowsError(try ContractParser.parse(raw, contract: contract))
    }

    func testFreeformKeepsWhateverWasSaid() throws {
        let parsed = try ContractParser.parse("  just talk  ", contract: .freeform)
        XCTAssertEqual(parsed.text, "just talk")
        XCTAssertNil(parsed.payload)
    }

    func testCompletenessUsesTheSentinelWhenThereIsOne() {
        XCTAssertFalse(ContractParser.isComplete(#"{"headline": "x", "angles": []}"#, contract: contract))
        XCTAssertTrue(ContractParser.isComplete(
            #"{"headline": "x", "angles": []}"# + "\n<<<CALLA_END>>>",
            contract: contract
        ))
    }

    func testCompletenessFallsBackToKeyPresenceWithoutASentinel() {
        let plain = OutputContract.json(keys: ["headline"])
        XCTAssertFalse(ContractParser.isComplete("thinking…", contract: plain))
        XCTAssertTrue(ContractParser.isComplete(#"{"headline": "x"}"#, contract: plain))
    }
}
