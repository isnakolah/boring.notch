import Foundation

public struct DescriptorValidationError: Error, Equatable, Sendable, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

private let forbiddenCoordinateKeys: Set<String> = [
    "x", "y", "left", "top", "width", "height", "coordinate", "coordinates", "screen_x", "screen_y", "bounds", "frame",
]

private func requireObject(_ value: JSONValue?, _ name: String) throws -> [String: JSONValue] {
    guard let object = value?.objectValue else { throw DescriptorValidationError("\(name) must be an object") }
    return object
}

private func requireString(_ value: JSONValue?, _ name: String, maximum: Int = 256) throws -> String {
    guard let string = value?.stringValue, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          string.lengthOfBytes(using: .utf8) <= maximum else {
        throw DescriptorValidationError("\(name) must be a non-empty UTF-8 string of at most \(maximum) bytes")
    }
    return string
}

private func requireID(_ value: JSONValue?, _ name: String) throws -> String {
    let identifier = try requireString(value, name)
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
    guard let first = identifier.unicodeScalars.first,
          CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains(first),
          identifier.unicodeScalars.allSatisfy(allowed.contains) else {
        throw DescriptorValidationError("\(name) must be a stable semantic identifier")
    }
    return identifier
}

private func requireOnlyKeys(_ object: [String: JSONValue], _ allowed: Set<String>, _ name: String) throws {
    for key in object.keys where !allowed.contains(key) {
        throw DescriptorValidationError("\(name) contains unsupported field \(key)")
    }
}

private func rejectCoordinates(_ value: JSONValue, path: String) throws {
    switch value {
    case .object(let object):
        for (key, child) in object {
            let next = "\(path).\(key)"
            if forbiddenCoordinateKeys.contains(key.lowercased()) {
                throw DescriptorValidationError("\(next) is coordinate-bearing and forbidden")
            }
            try rejectCoordinates(child, path: next)
        }
    case .array(let values):
        for (index, child) in values.enumerated() { try rejectCoordinates(child, path: "\(path).\(index)") }
    default: break
    }
}

public struct SafeMatcher: Codable, Equatable, Sendable {
    public let pattern: String
    public let caseInsensitive: Bool

    public init(pattern: String, caseInsensitive: Bool = false) throws {
        try Self.validate(pattern)
        self.pattern = pattern
        self.caseInsensitive = caseInsensitive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            pattern: container.decode(String.self, forKey: .pattern),
            caseInsensitive: container.decodeIfPresent(Bool.self, forKey: .caseInsensitive) ?? false)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pattern, forKey: .pattern)
        if caseInsensitive { try container.encode(caseInsensitive, forKey: .caseInsensitive) }
    }

    public func matches(_ text: String) -> Bool {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, options: [], range: range) != nil
    }

    private enum CodingKeys: String, CodingKey { case pattern; case caseInsensitive = "case_insensitive" }

    private static func validate(_ pattern: String) throws {
        guard !pattern.isEmpty, pattern.lengthOfBytes(using: .utf8) <= 128 else {
            throw DescriptorValidationError("matcher.pattern must be 1..128 UTF-8 bytes")
        }
        let unsafe = CharacterSet(charactersIn: "\\\\?*+(){}")
        guard pattern.unicodeScalars.allSatisfy({ !unsafe.contains($0) }) else {
            throw DescriptorValidationError("matcher.pattern contains a forbidden regex operator")
        }
        for alternativePart in pattern.split(separator: "|", omittingEmptySubsequences: false) {
            let alternative = String(alternativePart)
            guard !alternative.isEmpty else { throw DescriptorValidationError("matcher.pattern alternation branches must not be empty") }
            guard alternative.filter({ $0 == "^" }).count <= 1, alternative.filter({ $0 == "$" }).count <= 1 else {
                throw DescriptorValidationError("matcher.pattern anchors may appear at most once per alternation branch")
            }
            guard !alternative.contains("^") || alternative.hasPrefix("^") else {
                throw DescriptorValidationError("matcher.pattern ^ is permitted only at the start of an alternation branch")
            }
            guard !alternative.contains("$") || alternative.hasSuffix("$") else {
                throw DescriptorValidationError("matcher.pattern $ is permitted only at the end of an alternation branch")
            }
            var index = alternative.startIndex
            while index < alternative.endIndex {
                let character = alternative[index]
                if character == "[" {
                    let after = alternative.index(after: index)
                    guard let closing = alternative[after...].firstIndex(of: "]"), closing != after else {
                        throw DescriptorValidationError("matcher.pattern character classes must be non-empty and closed")
                    }
                    let contents = alternative[after..<closing]
                    guard !contents.contains("["), !contents.contains("^"), !contents.contains("$"), !contents.contains("|") else {
                        throw DescriptorValidationError("matcher.pattern character class contains an unsupported token")
                    }
                    index = alternative.index(after: closing)
                } else if character == "]" {
                    throw DescriptorValidationError("matcher.pattern character class is not opened")
                } else {
                    index = alternative.index(after: index)
                }
            }
        }
    }
}

public struct NormalizedRegion: Equatable, Sendable {
    public let left: Double
    public let top: Double
    public let width: Double
    public let height: Double

    public init(left: Double, top: Double, width: Double, height: Double) throws {
        guard [left, top, width, height].allSatisfy(\.isFinite), left >= 0, top >= 0, width > 0, height > 0,
              left + width <= 1, top + height <= 1 else {
            throw DescriptorValidationError("target_hint.region must be in [0,1], have positive size, and remain inside the focused window")
        }
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }
}

public struct AccessibilityCandidate: Sendable {
    public let role: String
    public let labelMatcher: SafeMatcher?
    public let descriptionMatcher: SafeMatcher?
    public let helpMatcher: SafeMatcher?
}

/// What an application's own bridge should be asked for, when it has one.
///
/// Deliberately not coordinates: these are the names an application uses for the
/// parts of its own interface. Where the rectangle is, is the application's
/// answer to give and this Mac's to convert — never anything the wire carries.
public struct BridgeSelector: Sendable, Equatable {
    public let fields: [String: String]

    public init(fields: [String: String]) { self.fields = fields }

    public var editorType: String? { fields["editor_type"] }
    /// Blender's Timeline is a Dope Sheet editor wearing a different `ui_type`,
    /// so the area type alone names the wrong thing for several editors.
    public var uiType: String? { fields["ui_type"] }
    public var context: String? { fields["context"] }
    public var regionType: String? { fields["region_type"] }
    /// The Properties context this tab selects — `MODIFIER` for the wrench.
    ///
    /// Not the same as `context`, which asks what the editor is *currently*
    /// showing. This asks which row of the tab strip switches it to that, which
    /// is a question worth asking precisely when the answer is "not the one open
    /// right now".
    public var tab: String? { fields["tab"] }
    public var control: String? { fields["control"] }
}

public struct VisualBranch: Sendable {
    public let textMatcher: SafeMatcher?
    public let icon: String?
    public let relativeTo: String?
}

public struct UITargetDescriptor: Sendable {
    public let raw: JSONValue
    public let id: String
    public let title: String
    public let aliases: [String]
    public let accessibilityCandidates: [AccessibilityCandidate]
    public let bridgeSelector: BridgeSelector?
    public let visual: VisualBranch?
    public let neighborConstraints: [String]
    public let pointMinimumConfidence: Double
    public let actionMinimumConfidence: Double

    public init(raw: JSONValue) throws {
        let target = try requireObject(raw, "target_descriptor")
        try requireOnlyKeys(target, ["id", "kind", "title", "aliases", "app_versions", "source_refs", "region", "resolve", "neighbor_constraints", "minimum_confidence", "source_file"], "target_descriptor")
        id = try requireID(target["id"], "target_descriptor.id")
        guard target["kind"]?.stringValue == "ui_target" else { throw DescriptorValidationError("target_descriptor.kind must be ui_target") }
        title = try requireString(target["title"], "target_descriptor.title")
        if let aliasesValue = target["aliases"] {
            guard case .array(let values) = aliasesValue, values.count <= 32 else { throw DescriptorValidationError("target_descriptor.aliases must contain at most 32 strings") }
            aliases = try values.enumerated().map { try requireString($0.element, "target_descriptor.aliases.\($0.offset)") }
        } else { aliases = [] }
        if let region = target["region"] { _ = try requireID(region, "target_descriptor.region") }
        let resolve = try requireObject(target["resolve"], "target_descriptor.resolve")
        try requireOnlyKeys(resolve, ["accessibility", "bridge", "visual"], "target_descriptor.resolve")
        guard !resolve.isEmpty else { throw DescriptorValidationError("target_descriptor.resolve requires a resolver branch") }
        accessibilityCandidates = try Self.parseAccessibility(resolve["accessibility"])
        bridgeSelector = try resolve["bridge"].map { try Self.parseBridge($0) }
        visual = try resolve["visual"].map { try Self.parseVisual($0) }
        neighborConstraints = try target["neighbor_constraints"].map { try Self.parseNeighbors($0) } ?? []
        let confidence = try requireObject(target["minimum_confidence"], "target_descriptor.minimum_confidence")
        guard Set(confidence.keys) == Set(["point", "act"]), let point = confidence["point"]?.numberValue, let act = confidence["act"]?.numberValue,
              point.isFinite, act.isFinite, point > 0, point <= 1, act > 0, act <= 1 else {
            throw DescriptorValidationError("target_descriptor.minimum_confidence must contain finite point and act values in (0, 1]")
        }
        pointMinimumConfidence = point
        actionMinimumConfidence = act
        try rejectCoordinates(raw, path: "target_descriptor")
        self.raw = raw
    }

    private static func parseAccessibility(_ value: JSONValue?) throws -> [AccessibilityCandidate] {
        guard let value else { return [] }
        let resolver = try requireObject(value, "target_descriptor.resolve.accessibility")
        guard Set(resolver.keys) == Set(["candidates"]), case .array(let values)? = resolver["candidates"], !values.isEmpty, values.count <= 16 else {
            throw DescriptorValidationError("target_descriptor.resolve.accessibility must contain 1..16 candidates only")
        }
        return try values.enumerated().map { index, rawCandidate in
            let candidate = try requireObject(rawCandidate, "target_descriptor.resolve.accessibility.candidates.\(index)")
            try requireOnlyKeys(candidate, ["role", "label_matcher", "description_matcher", "help_matcher"], "target_descriptor.resolve.accessibility.candidates.\(index)")
            let role = try requireString(candidate["role"], "target_descriptor.resolve.accessibility.candidates.\(index).role", maximum: 80)
            let label = try candidate["label_matcher"].map { try decodeMatcher($0, "target_descriptor.resolve.accessibility.candidates.\(index).label_matcher") }
            let description = try candidate["description_matcher"].map { try decodeMatcher($0, "target_descriptor.resolve.accessibility.candidates.\(index).description_matcher") }
            let help = try candidate["help_matcher"].map { try decodeMatcher($0, "target_descriptor.resolve.accessibility.candidates.\(index).help_matcher") }
            guard label != nil || description != nil || help != nil else {
                throw DescriptorValidationError("target_descriptor.resolve.accessibility.candidates.\(index) requires an authored matcher")
            }
            return AccessibilityCandidate(role: role, labelMatcher: label, descriptionMatcher: description, helpMatcher: help)
        }
    }

    private static func decodeMatcher(_ value: JSONValue, _ name: String) throws -> SafeMatcher {
        let object = try requireObject(value, name)
        guard Set(object.keys).isSubset(of: Set(["pattern", "case_insensitive"])), let pattern = object["pattern"]?.stringValue else {
            throw DescriptorValidationError("\(name) must contain pattern and optional case_insensitive only")
        }
        let insensitive: Bool
        if let supplied = object["case_insensitive"] {
            guard let decoded = supplied.boolValue else { throw DescriptorValidationError("\(name).case_insensitive must be a boolean") }
            insensitive = decoded
        } else {
            insensitive = false
        }
        return try SafeMatcher(pattern: pattern, caseInsensitive: insensitive)
    }

    private static func parseBridge(_ value: JSONValue) throws -> BridgeSelector {
        let branch = try requireObject(value, "target_descriptor.resolve.bridge")
        guard Set(branch.keys) == Set(["selector"]) else { throw DescriptorValidationError("target_descriptor.resolve.bridge must contain selector only") }
        let selector = try requireObject(branch["selector"], "target_descriptor.resolve.bridge.selector")
        guard !selector.isEmpty, selector.count <= 16 else { throw DescriptorValidationError("target_descriptor.resolve.bridge.selector must contain 1..16 fields") }
        var fields: [String: String] = [:]
        for (key, value) in selector {
            _ = try requireString(.string(key), "target_descriptor.resolve.bridge.selector key", maximum: 64)
            switch value {
            case .string(let item):
                _ = try requireString(.string(item), "target_descriptor.resolve.bridge.selector.\(key)", maximum: 128)
                fields[key] = item
            case .number(let item) where item.isFinite: fields[key] = String(item)
            case .bool(let item): fields[key] = item ? "true" : "false"
            default: throw DescriptorValidationError("target_descriptor.resolve.bridge.selector.\(key) must be a finite scalar")
            }
        }
        return BridgeSelector(fields: fields)
    }

    private static func parseVisual(_ value: JSONValue) throws -> VisualBranch {
        let visual = try requireObject(value, "target_descriptor.resolve.visual")
        try requireOnlyKeys(visual, ["icon", "relative_to", "layout_hint", "constraints", "text_matcher"], "target_descriptor.resolve.visual")
        guard !visual.isEmpty else { throw DescriptorValidationError("target_descriptor.resolve.visual must not be empty") }
        for field in ["icon", "relative_to", "layout_hint"] where visual[field] != nil { _ = try requireString(visual[field], "target_descriptor.resolve.visual.\(field)", maximum: 128) }
        if let constraints = visual["constraints"] {
            guard case .array(let values) = constraints, values.count <= 8, values.allSatisfy({ $0.stringValue == "visible" || $0.stringValue == "enabled" }) else {
                throw DescriptorValidationError("target_descriptor.resolve.visual.constraints must contain known constraints")
            }
        }
        let matcher = try visual["text_matcher"].map { try decodeMatcher($0, "target_descriptor.resolve.visual.text_matcher") }
        return VisualBranch(textMatcher: matcher, icon: visual["icon"]?.stringValue, relativeTo: visual["relative_to"]?.stringValue)
    }

    private static func parseNeighbors(_ value: JSONValue) throws -> [String] {
        let neighbors = try requireObject(value, "target_descriptor.neighbor_constraints")
        guard Set(neighbors.keys) == Set(["expected"]), case .array(let expected)? = neighbors["expected"], !expected.isEmpty, expected.count <= 8 else {
            throw DescriptorValidationError("target_descriptor.neighbor_constraints must contain 1..8 expected labels only")
        }
        return try expected.enumerated().map { try requireID($0.element, "target_descriptor.neighbor_constraints.expected.\($0.offset)") }
    }
}

public enum DetectorProvider: String, Sendable { case blenderBridge = "blender_bridge"; case accessibility }

public struct DetectorDescriptor: Sendable {
    public let raw: JSONValue
    public let id: String
    public let provider: DetectorProvider
    public let query: [String: JSONValue]

    public init(raw: JSONValue) throws {
        let detector = try requireObject(raw, "detector_descriptor")
        try requireOnlyKeys(detector, ["id", "kind", "title", "aliases", "app_versions", "source_refs", "provider", "query", "source_file"], "detector_descriptor")
        id = try requireID(detector["id"], "detector_descriptor.id")
        guard detector["kind"]?.stringValue == "detector" else { throw DescriptorValidationError("detector_descriptor.kind must be detector") }
        _ = try requireString(detector["title"], "detector_descriptor.title")
        guard let rawProvider = detector["provider"]?.stringValue, let provider = DetectorProvider(rawValue: rawProvider) else {
            throw DescriptorValidationError("detector_descriptor.provider must be blender_bridge or accessibility")
        }
        self.provider = provider
        query = try requireObject(detector["query"], "detector_descriptor.query")
        switch provider {
        case .accessibility:
            guard Set(query.keys) == Set(["target", "attribute", "equals"]),
                  ["selected", "enabled", "visible"].contains(query["attribute"]?.stringValue ?? ""), query["equals"]?.boolValue != nil else {
                throw DescriptorValidationError("detector_descriptor.query accessibility detectors require target, attribute, and boolean equals")
            }
            _ = try requireID(query["target"], "detector_descriptor.query.target")
        case .blenderBridge:
            try requireOnlyKeys(query, ["path", "equals", "contains", "any", "ordered"], "detector_descriptor.query")
            let path = try requireString(query["path"], "detector_descriptor.query.path", maximum: 128)
            let segments = path.split(separator: ".")
            guard !segments.isEmpty, segments.count <= 8, segments.allSatisfy({ segment in
                guard let first = segment.first, first.isLetter || first == "_" else { return false }
                return segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            }) else {
                throw DescriptorValidationError("detector_descriptor.query.path must contain 1..8 bounded object-path segments")
            }
            // Bind locally: referencing the stored `query` inside a closure would
            // capture self before `raw` is initialised.
            let resolvedQuery = query
            let operators = ["equals", "contains", "any", "ordered"].filter { resolvedQuery[$0] != nil }
            guard operators.count == 1 else { throw DescriptorValidationError("detector_descriptor.query requires exactly one operator") }
            if operators[0] == "ordered" {
                guard let ordered = resolvedQuery["ordered"]?.objectValue,
                      Set(ordered.keys) == Set(["before", "after"]),
                      (try? requireString(ordered["before"], "detector_descriptor.query.ordered.before", maximum: 128)) != nil,
                      (try? requireString(ordered["after"], "detector_descriptor.query.ordered.after", maximum: 128)) != nil else {
                    throw DescriptorValidationError("detector_descriptor.query.ordered requires bounded before and after values")
                }
            }
        }
        try rejectCoordinates(raw, path: "detector_descriptor")
        self.raw = raw
    }
}
