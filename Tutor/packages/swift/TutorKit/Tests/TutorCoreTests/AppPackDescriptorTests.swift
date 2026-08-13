import Testing
import TutorProtocol

private func modifierTargetDescriptor() -> JSONValue {
    .object([
        "id": .string("blender.ui.properties.modifiers_tab"),
        "kind": .string("ui_target"),
        "title": .string("Modifier Properties tab"),
        "aliases": .array([.string("Modifiers")]),
        "resolve": .object([
            "accessibility": .object([
                "candidates": .array([
                    .object([
                        "role": .string("AXRadioButton"),
                        "label_matcher": .object(["pattern": .string("modifier"), "case_insensitive": .bool(true)]),
                    ]),
                ]),
            ]),
            "visual": .object(["icon": .string("wrench")]),
        ]),
        "minimum_confidence": .object(["point": .number(0.72), "act": .number(0.92)]),
        "source_file": .string("ui/modifiers_tab.yaml"),
    ])
}

@Test func matcherGrammarIsBoundedAndPortable() throws {
    let matcher = try SafeMatcher(pattern: "^modifier|wrench$", caseInsensitive: true)
    #expect(matcher.matches("Modifier Properties"))
    #expect(matcher.matches("toolbar wrench"))
    #expect(throws: DescriptorValidationError.self) { try SafeMatcher(pattern: "modifier.*") }
    #expect(throws: DescriptorValidationError.self) { try SafeMatcher(pattern: String(repeating: "m", count: 129)) }
}

@Test func targetDescriptorRejectsCoordinatesAndInvalidConfidence() throws {
    let target = try UITargetDescriptor(raw: modifierTargetDescriptor())
    #expect(target.id == "blender.ui.properties.modifiers_tab")
    #expect(target.pointMinimumConfidence == 0.72)

    var coordinate = modifierTargetDescriptor().objectValue!
    coordinate["left"] = .number(0.2)
    #expect(throws: DescriptorValidationError.self) { try UITargetDescriptor(raw: .object(coordinate)) }

    var invalidConfidence = modifierTargetDescriptor().objectValue!
    invalidConfidence["minimum_confidence"] = .object(["point": .number(0), "act": .number(0.92)])
    #expect(throws: DescriptorValidationError.self) { try UITargetDescriptor(raw: .object(invalidConfidence)) }
}

@Test func normalizedHintRejectsOverflowInsteadOfClamping() throws {
    _ = try NormalizedRegion(left: 0, top: 0, width: 1, height: 1)
    #expect(throws: DescriptorValidationError.self) { try NormalizedRegion(left: 0.9, top: 0, width: 0.2, height: 0.2) }
    #expect(throws: DescriptorValidationError.self) { try NormalizedRegion(left: .nan, top: 0, width: 0.2, height: 0.2) }
}
