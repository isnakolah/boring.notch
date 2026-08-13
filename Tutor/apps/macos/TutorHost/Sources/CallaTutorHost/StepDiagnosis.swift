import Foundation
import TutorProtocol

/// The part of Blender's state a lesson can be wrong about.
///
/// A bounded reading of the read-only bridge's own snapshot — no pixels, no
/// history, nothing that is not already on the learner's screen. Two of these,
/// one from when the step was shown and one from when it was checked, are enough
/// to say what the learner actually did rather than only that it was not the
/// step.
struct BlenderStateDigest: Equatable {
    let mode: String
    let activeObjectName: String
    let activeObjectType: String
    /// Modifier types on the active object, in stack order. Order matters: half
    /// of what this lesson teaches is that it does.
    let modifiers: [String]
    let propertiesContexts: [String]
    let objectCount: Int

    init?(_ value: JSONValue) {
        guard let object = value.objectValue else { return nil }
        mode = object["mode"]?.stringValue ?? ""
        let active = object["active_object"]?.objectValue
        activeObjectName = active?["name"]?.stringValue ?? ""
        activeObjectType = active?["type"]?.stringValue ?? ""
        if case .array(let raw)? = active?["modifiers"] {
            modifiers = raw.compactMap { $0.objectValue?["type"]?.stringValue }
        } else {
            modifiers = []
        }
        if case .array(let raw)? = object["properties_contexts"] {
            propertiesContexts = raw.compactMap(\.stringValue)
        } else {
            propertiesContexts = []
        }
        objectCount = Int(object["scene"]?.objectValue?["object_count"]?.numberValue ?? 0)
    }
}

/// Says what the learner did, when what they did was not the step.
///
/// Every failure used to produce the same sentence — "Not yet", followed by the
/// instruction again — whether the learner had done nothing, done it to the
/// wrong object, added the wrong modifier, or wandered into Edit Mode. That is
/// the tutor's whole job going unanswered: a learner who cannot tell *how* they
/// are wrong cannot get less wrong.
///
/// Everything here is assembled from a fixed list of paths in the bridge's
/// snapshot. No model, no network, no free text from anywhere untrusted, and no
/// sentence that is not entailed by two readings taken seconds apart.
enum StepDiagnosis {
    /// Blender's names for things, in the learner's language.
    ///
    /// `SUBSURF` is on the screen as "Subdivision Surface" and in the API as
    /// neither, so telling a learner they added a SUBSURF is telling them
    /// nothing. Anything unlisted is title-cased rather than dropped: a slightly
    /// awkward real name beats a missing one.
    private static let readable: [String: String] = [
        "SUBSURF": "Subdivision Surface", "BEVEL": "Bevel", "SOLIDIFY": "Solidify",
        "ARRAY": "Array", "MIRROR": "Mirror", "BOOLEAN": "Boolean", "SCREW": "Screw",
        "REMESH": "Remesh", "DECIMATE": "Decimate", "WELD": "Weld", "SHRINKWRAP": "Shrinkwrap",
        "OBJECT": "Object", "EDIT_MESH": "Edit", "SCULPT": "Sculpt", "POSE": "Pose",
        "VERTEX_PAINT": "Vertex Paint", "WEIGHT_PAINT": "Weight Paint", "TEXTURE_PAINT": "Texture Paint",
        "MODIFIER": "Modifier", "PHYSICS": "Physics", "CONSTRAINT": "Object Constraint",
        "DATA": "Object Data", "MATERIAL": "Material", "PARTICLES": "Particle",
        "RENDER": "Render", "OUTPUT": "Output", "VIEW_LAYER": "View Layer", "SCENE": "Scene",
        "WORLD": "World", "TOOL": "Tool",
        "MESH": "mesh", "LIGHT": "light", "CAMERA": "camera", "EMPTY": "empty", "CURVE": "curve",
    ]

    static func name(_ raw: String) -> String {
        if let known = readable[raw] { return known }
        return raw.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    /// What changed between showing the step and checking it, in one sentence.
    ///
    /// Returns nil when nothing here can honestly account for the failure, so
    /// the caller falls back to repeating the instruction rather than inventing
    /// a reason.
    static func sentence(from before: BlenderStateDigest?, to after: BlenderStateDigest?) -> String? {
        guard let after else { return nil }
        guard let before else { return nil }
        if before == after {
            return "Nothing has changed yet — this step is still waiting."
        }
        if before.mode != after.mode, !after.mode.isEmpty {
            return "You are in \(name(after.mode)) Mode now; this step happens in \(name(before.mode)) Mode."
        }
        if before.activeObjectName != after.activeObjectName, !after.activeObjectName.isEmpty, !before.activeObjectName.isEmpty {
            return "You are working on \(after.activeObjectName) now — this step is about \(before.activeObjectName)."
        }
        if let gained = extras(over: before.modifiers, in: after.modifiers).first {
            return "You added a \(name(gained)) modifier."
        }
        if let lost = extras(over: after.modifiers, in: before.modifiers).first {
            return "You removed the \(name(lost)) modifier."
        }
        if before.modifiers != after.modifiers, before.modifiers.sorted() == after.modifiers.sorted() {
            return "The modifier order changed: it is now \(after.modifiers.map(name).joined(separator: ", "))."
        }
        let openedTabs = after.propertiesContexts.filter { !before.propertiesContexts.contains($0) }
        if let opened = openedTabs.first {
            return "That opened \(name(opened)) Properties."
        }
        if after.objectCount > before.objectCount {
            return "There is a new object in the scene; this step does not add one."
        }
        if after.objectCount < before.objectCount {
            return "An object was deleted; this step does not remove one."
        }
        return nil
    }

    /// Items in `later` that `earlier` does not account for, keeping duplicates
    /// honest: two Bevels is not the same as one.
    private static func extras(over earlier: [String], in later: [String]) -> [String] {
        var remaining = earlier
        var extra: [String] = []
        for item in later {
            if let index = remaining.firstIndex(of: item) { remaining.remove(at: index) } else { extra.append(item) }
        }
        return extra
    }
}
