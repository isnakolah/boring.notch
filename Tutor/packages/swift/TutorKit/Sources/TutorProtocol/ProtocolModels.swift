import Foundation

public enum TutorProtocolVersion {
    public static let current = 2
    public static let supported = 2...3

    public static func accepts(_ value: Int) -> Bool {
        supported.contains(value)
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }
}

public enum TutorOperation: String, Codable, Sendable {
    case sessionStart = "session_start"
    case observe
    case retrieve
    case point
    case proposeAction = "propose_action"
    case verify
    case recordLearning = "record_learning"
}

public struct TutorRequestEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let operation: TutorOperation
    public let sessionID: String
    public let payload: Payload

    public init(
        requestID: String = UUID().uuidString,
        operation: TutorOperation,
        sessionID: String,
        payload: Payload)
    {
        self.protocolVersion = TutorProtocolVersion.current
        self.requestID = requestID
        self.operation = operation
        self.sessionID = sessionID
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestID = "request_id"
        case operation
        case sessionID = "session_id"
        case payload
    }
}

public struct TutorScreenRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        precondition(width > 0 && height > 0, "resolved target bounds must have positive size")
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum TargetValidity: String, Codable, Sendable {
    case nextWindowMutation = "next_window_mutation"
    case deadline
}

public struct ResolvedTarget: Codable, Equatable, Sendable {
    public let semanticID: String
    public let snapshotID: String
    public let opaqueElementID: String?
    public let windowID: UInt32
    public let bounds: TutorScreenRect
    public let confidence: Double
    public let evidence: [String]
    public let validUntil: TargetValidity
    public let deadline: Date?

    public init(
        semanticID: String,
        snapshotID: String,
        opaqueElementID: String?,
        windowID: UInt32,
        bounds: TutorScreenRect,
        confidence: Double,
        evidence: [String],
        validUntil: TargetValidity,
        deadline: Date? = nil)
    {
        precondition((0 ... 1).contains(confidence), "confidence must be between zero and one")
        precondition(!evidence.isEmpty, "a resolved target requires evidence")
        self.semanticID = semanticID
        self.snapshotID = snapshotID
        self.opaqueElementID = opaqueElementID
        self.windowID = windowID
        self.bounds = bounds
        self.confidence = confidence
        self.evidence = evidence
        self.validUntil = validUntil
        self.deadline = deadline
    }

    enum CodingKeys: String, CodingKey {
        case semanticID = "semantic_id"
        case snapshotID = "snapshot_id"
        case opaqueElementID = "opaque_element_id"
        case windowID = "window_id"
        case bounds
        case confidence
        case evidence
        case validUntil = "valid_until"
        case deadline
    }
}

public enum VerificationOutcome: String, Codable, Sendable {
    case satisfied
    case unsatisfied
    case unknown
}

public struct VerificationResult: Codable, Equatable, Sendable {
    public let expectationID: String
    public let outcome: VerificationOutcome
    public let stableSamples: Int
    public let evidence: [String]
    public let reason: String?

    public init(
        expectationID: String,
        outcome: VerificationOutcome,
        stableSamples: Int,
        evidence: [String],
        reason: String? = nil)
    {
        precondition(stableSamples >= 0)
        self.expectationID = expectationID
        self.outcome = outcome
        self.stableSamples = stableSamples
        self.evidence = evidence
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case expectationID = "expectation_id"
        case outcome
        case stableSamples = "stable_samples"
        case evidence
        case reason
    }
}

public enum TutorActionKind: String, Codable, CaseIterable, Sendable {
    case explain
    case highlight
    case aiPointer = "ai_pointer"
    case moveCursor = "move_cursor"
    case click
    case scroll
    case keyboardShortcut = "keyboard_shortcut"
    case typeText = "type_text"
    case demonstration
}

public struct ProposedTutorAction: Codable, Equatable, Sendable {
    public let action: TutorActionKind
    public let semanticTarget: String?
    public let snapshotID: String?
    public let expectedState: String?
    public let rationale: String

    public init(
        action: TutorActionKind,
        semanticTarget: String?,
        snapshotID: String?,
        expectedState: String?,
        rationale: String)
    {
        self.action = action
        self.semanticTarget = semanticTarget
        self.snapshotID = snapshotID
        self.expectedState = expectedState
        self.rationale = rationale
    }

    enum CodingKeys: String, CodingKey {
        case action
        case semanticTarget = "semantic_target"
        case snapshotID = "snapshot_id"
        case expectedState = "expected_state"
        case rationale
    }
}
