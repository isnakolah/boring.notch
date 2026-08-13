import Foundation
import Testing
import TutorProtocol
@testable import CallaTutorHost

private func digest(mode: String = "OBJECT", object: String = "Cube", type: String = "MESH",
                    modifiers: [String] = [], contexts: [String] = ["MODIFIER"],
                    objectCount: Int = 3) -> BlenderStateDigest {
    let value = JSONValue.object([
        "mode": .string(mode),
        "active_object": .object([
            "name": .string(object), "type": .string(type),
            "modifiers": .array(modifiers.map { .object(["type": .string($0)]) }),
        ]),
        "properties_contexts": .array(contexts.map { .string($0) }),
        "scene": .object(["object_count": .number(Double(objectCount))]),
    ])
    return BlenderStateDigest(value)!
}

@Suite("Saying what the learner actually did")
struct StepDiagnosisTests {
    @Test("nothing happening is said as nothing happening")
    func noChange() {
        let before = digest()
        #expect(StepDiagnosis.sentence(from: before, to: before) == "Nothing has changed yet — this step is still waiting.")
    }

    @Test("the wrong modifier is named, in the words on the screen")
    func namesTheWrongModifier() throws {
        let sentence = try #require(StepDiagnosis.sentence(from: digest(), to: digest(modifiers: ["SUBSURF"])))
        // "SUBSURF" is the API's name for it and appears nowhere in Blender's
        // interface. Telling a learner they added a SUBSURF tells them nothing.
        #expect(sentence == "You added a Subdivision Surface modifier.")
    }

    @Test("a mode change is named before anything else, because it explains everything else")
    func namesTheMode() throws {
        let sentence = try #require(StepDiagnosis.sentence(from: digest(), to: digest(mode: "EDIT_MESH", modifiers: ["BEVEL"])))
        #expect(sentence == "You are in Edit Mode now; this step happens in Object Mode.")
    }

    @Test("working on the wrong object is named with both objects")
    func namesTheObject() throws {
        let sentence = try #require(StepDiagnosis.sentence(from: digest(), to: digest(object: "Cube.001")))
        #expect(sentence.contains("Cube.001"))
        #expect(sentence.contains("this step is about Cube"))
    }

    @Test("removing a modifier is not the same as adding one")
    func namesARemoval() throws {
        let sentence = try #require(StepDiagnosis.sentence(from: digest(modifiers: ["BEVEL"]), to: digest()))
        #expect(sentence == "You removed the Bevel modifier.")
    }

    @Test("reordering the stack is its own event, since order is half the lesson")
    func namesAReorder() throws {
        let sentence = try #require(StepDiagnosis.sentence(from: digest(modifiers: ["SUBSURF", "BEVEL"]),
                                                           to: digest(modifiers: ["BEVEL", "SUBSURF"])))
        #expect(sentence == "The modifier order changed: it is now Bevel, Subdivision Surface.")
    }

    @Test("the wrong Properties tab is named by what is on its icon")
    func namesTheTab() throws {
        let sentence = try #require(StepDiagnosis.sentence(from: digest(contexts: []), to: digest(contexts: ["MATERIAL"])))
        #expect(sentence == "That opened Material Properties.")
    }

    @Test("a change nothing here accounts for produces no sentence at all")
    func staysSilentWhenItDoesNotKnow() {
        // Silence is a real answer: the caller repeats the instruction rather
        // than inventing a reason. A confident wrong explanation is worse than
        // none, because the learner believes it.
        #expect(StepDiagnosis.sentence(from: nil, to: digest()) == nil)
        #expect(StepDiagnosis.sentence(from: digest(), to: nil) == nil)
    }

    @Test("an unlisted name is made readable rather than dropped")
    func titleCasesTheUnknown() {
        #expect(StepDiagnosis.name("VOLUME_DISPLACE") == "Volume Displace")
        #expect(StepDiagnosis.name("BEVEL") == "Bevel")
    }
}
