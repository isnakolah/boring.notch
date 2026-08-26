import Foundation

/// Limits shared by Engine, Host and Gateway before data crosses a process
/// boundary. The receiving boundary must validate again after decoding.
public enum TutorProtocolLimits {
    public static let controlFrameBytes = 64 * 1024
    public static let questionCharacters = 800
    public static let answerCharacters = 800
    public static let structuredContextBytes = 16 * 1024
    public static let jpegBytes = 3 * 1024 * 1024
    public static let gatewayFeedbackEnvelopeBytes = 5 * 1024 * 1024
    public static let gatewayFeedbackReplyBytes = 16 * 1024
}

public enum TutorProtocolError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedVersion(Int)
    case invalidIdentity(String)
    case payloadTooLarge(limit: Int)
    case invalidCapture(String)
    case invalidFeedback(String)
    case unsafeText(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let value): "unsupported Tutor protocol version \(value)"
        case .invalidIdentity(let field): "invalid Tutor identity: \(field)"
        case .payloadTooLarge(let limit): "Tutor payload exceeds \(limit) bytes"
        case .invalidCapture(let reason): "invalid Tutor capture: \(reason)"
        case .invalidFeedback(let reason): "invalid Tutor feedback: \(reason)"
        case .unsafeText(let field): "unsafe Tutor text: \(field)"
        }
    }
}

public enum TutorRuntimeMode: String, Codable, Sendable {
    case engine
    case standalone
}

/// Identifier copied into every state-changing message. This makes stale Host
/// observations harmless: a valid message can still not mutate a different
/// run, generation, revision, lesson or step.
public struct TutorRunIdentity: Codable, Equatable, Sendable {
    public let runID: String
    public let generation: UInt64
    public let courseKey: String
    public let revision: String
    public let lessonID: String
    public let stepID: String

    public init(runID: String, generation: UInt64, courseKey: String, revision: String, lessonID: String, stepID: String) throws {
        try TutorProtocolValidation.requireID(runID, field: "run_id")
        try TutorProtocolValidation.requireID(courseKey, field: "course_key")
        try TutorProtocolValidation.requireID(revision, field: "revision")
        try TutorProtocolValidation.requireID(lessonID, field: "lesson_id")
        try TutorProtocolValidation.requireID(stepID, field: "step_id")
        self.runID = runID
        self.generation = generation
        self.courseKey = courseKey
        self.revision = revision
        self.lessonID = lessonID
        self.stepID = stepID
    }

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case generation
        case courseKey = "course_key"
        case revision
        case lessonID = "lesson_id"
        case stepID = "step_id"
    }
}

public enum TutorHostOperation: String, Codable, Sendable {
    case startRun = "start_run"
    case renderInstruction = "render_instruction"
    case observeStep = "observe_step"
    case captureFeedback = "capture_feedback"
    case stopRun = "stop_run"
    case capabilityHandshake = "capability_handshake"
}

/// Host commands deliberately contain no target selection, coordinates,
/// actions or advancement instruction. Engine gives Host authored state; Host
/// returns capture/verification receipts.
public struct TutorHostCommand: Codable, Equatable, Sendable {
    public let operation: TutorHostOperation
    public let instruction: String?
    public let expectedVerifierID: String?
    public let allowlistedBundleID: String?
    public let payload: [String: JSONValue]

    public init(operation: TutorHostOperation, instruction: String? = nil, expectedVerifierID: String? = nil, allowlistedBundleID: String? = nil, payload: [String: JSONValue] = [:]) throws {
        if let instruction { try TutorProtocolValidation.requireText(instruction, maximum: TutorProtocolLimits.structuredContextBytes, field: "instruction") }
        if let expectedVerifierID { try TutorProtocolValidation.requireID(expectedVerifierID, field: "expected_verifier_id") }
        if let allowlistedBundleID { try TutorProtocolValidation.requireBundleID(allowlistedBundleID) }
        self.operation = operation
        self.instruction = instruction
        self.expectedVerifierID = expectedVerifierID
        self.allowlistedBundleID = allowlistedBundleID
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case operation
        case instruction
        case expectedVerifierID = "expected_verifier_id"
        case allowlistedBundleID = "allowlisted_bundle_id"
        case payload
    }
}

public enum TutorHostEventKind: String, Codable, Sendable {
    case started
    case instructionRendered = "instruction_rendered"
    case verification
    case capture
    case stopped
    case refused
    case diagnostics
}

public struct TutorHostEvent: Codable, Equatable, Sendable {
    public let kind: TutorHostEventKind
    public let receipt: TutorVerificationReceipt?
    public let capture: TutorCaptureMetadata?
    public let diagnosticCode: String?
    public let facts: [String: String]

    public init(kind: TutorHostEventKind, receipt: TutorVerificationReceipt? = nil, capture: TutorCaptureMetadata? = nil, diagnosticCode: String? = nil, facts: [String: String] = [:]) throws {
        if let diagnosticCode { try TutorProtocolValidation.requireID(diagnosticCode, field: "diagnostic_code") }
        for (key, value) in facts {
            try TutorProtocolValidation.requireID(key, field: "fact_key")
            try TutorProtocolValidation.requireText(value, maximum: 1_024, field: "fact_value")
        }
        self.kind = kind
        self.receipt = receipt
        self.capture = capture
        self.diagnosticCode = diagnosticCode
        self.facts = facts
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case receipt
        case capture
        case diagnosticCode = "diagnostic_code"
        case facts
    }
}

/// Typed control frame. Payload remains generic so portable TutorKit has no
/// dependency on Boring's Store or XPC DTOs.
public struct TutorControlEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let identity: TutorRunIdentity
    public let operation: String
    public let payload: Payload
    public let issuedAt: Date

    public init(requestID: String = UUID().uuidString, identity: TutorRunIdentity, operation: String, payload: Payload, issuedAt: Date = Date()) throws {
        guard TutorProtocolVersion.current == 4 else { throw TutorProtocolError.unsupportedVersion(TutorProtocolVersion.current) }
        try TutorProtocolValidation.requireID(requestID, field: "request_id")
        try TutorProtocolValidation.requireID(operation, field: "operation")
        self.protocolVersion = 4
        self.requestID = requestID
        self.identity = identity
        self.operation = operation
        self.payload = payload
        self.issuedAt = issuedAt
    }

    public func encodedByteCount() throws -> Int { try JSONEncoder().encode(self).count }

    public func validateFrameLimit(_ limit: Int = TutorProtocolLimits.controlFrameBytes) throws {
        if try encodedByteCount() > limit { throw TutorProtocolError.payloadTooLarge(limit: limit) }
    }

    /// Decode one complete bounded JSON control frame. Callers must use this
    /// rather than decoding a stream fragment: protocol v4 has no trailing or
    /// multi-frame tolerance.
    public static func decodeFrame(_ data: Data) throws -> Self {
        guard data.count <= TutorProtocolLimits.controlFrameBytes else {
            throw TutorProtocolError.payloadTooLarge(limit: TutorProtocolLimits.controlFrameBytes)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue))
        else { throw TutorProtocolError.invalidIdentity("unexpected_control_field") }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else {
            throw TutorProtocolError.invalidIdentity("unexpected_control_field")
        }
        let protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        guard protocolVersion == 4 else { throw TutorProtocolError.unsupportedVersion(protocolVersion) }
        let requestID = try container.decode(String.self, forKey: .requestID)
        let identity = try container.decode(TutorRunIdentity.self, forKey: .identity)
        let operation = try container.decode(String.self, forKey: .operation)
        let payload = try container.decode(Payload.self, forKey: .payload)
        let issuedAt = try container.decode(Date.self, forKey: .issuedAt)
        try TutorProtocolValidation.requireID(requestID, field: "request_id")
        try TutorProtocolValidation.requireID(operation, field: "operation")
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.identity = identity
        self.operation = operation
        self.payload = payload
        self.issuedAt = issuedAt
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion = "protocol_version"
        case requestID = "request_id"
        case identity
        case operation
        case payload
        case issuedAt = "issued_at"
    }
}

public enum TutorCapturePurpose: String, Codable, Sendable {
    case learnerQuestion = "learner_question"
    case verifierFailure = "verifier_failure"
    case verifierUnknown = "verifier_unknown"
}

/// Image bytes are returned Host -> Engine only. Host never receives storage
/// paths and never writes a durable capture in engine mode.
public struct TutorCaptureMetadata: Codable, Equatable, Sendable {
    public let identifier: String
    public let mimeType: String
    public let jpeg: Data
    public let width: Int
    public let height: Int
    public let windowID: UInt32
    public let processID: Int32
    public let bundleID: String
    public let purpose: TutorCapturePurpose

    public init(identifier: String, mimeType: String, jpeg: Data, width: Int, height: Int, windowID: UInt32, processID: Int32, bundleID: String, purpose: TutorCapturePurpose) throws {
        try TutorProtocolValidation.requireID(identifier, field: "capture_id")
        guard mimeType == "image/jpeg", jpeg.count <= TutorProtocolLimits.jpegBytes, width > 0, height > 0, processID > 0 else { throw TutorProtocolError.invalidCapture("invalid image metadata") }
        guard TutorProtocolValidation.hasJPEGSignature(jpeg) else { throw TutorProtocolError.invalidCapture("JPEG signature") }
        try TutorProtocolValidation.requireBundleID(bundleID)
        self.identifier = identifier
        self.mimeType = mimeType
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.windowID = windowID
        self.processID = processID
        self.bundleID = bundleID
        self.purpose = purpose
    }

    enum CodingKeys: String, CodingKey {
        case identifier
        case mimeType = "mime_type"
        case jpeg
        case width
        case height
        case windowID = "window_id"
        case processID = "process_id"
        case bundleID = "bundle_id"
        case purpose
    }
}

public struct TutorVerificationReceipt: Codable, Equatable, Sendable {
    public let verifierID: String
    public let outcome: VerificationOutcome
    public let facts: [String: String]
    public let observedAt: Date

    public init(verifierID: String, outcome: VerificationOutcome, facts: [String: String] = [:], observedAt: Date = Date()) throws {
        try TutorProtocolValidation.requireID(verifierID, field: "verifier_id")
        for (key, value) in facts {
            try TutorProtocolValidation.requireID(key, field: "fact_key")
            try TutorProtocolValidation.requireText(value, maximum: 1_024, field: "fact_value")
        }
        self.verifierID = verifierID
        self.outcome = outcome
        self.facts = facts
        self.observedAt = observedAt
    }

    enum CodingKeys: String, CodingKey {
        case verifierID = "verifier_id"
        case outcome
        case facts
        case observedAt = "observed_at"
    }
}

public enum TutorFeedbackKind: String, Codable, Sendable {
    case learnerQuestion = "learner_question"
    case verifierFailure = "verifier_failure"
    case verifierUnknown = "verifier_unknown"
}

public struct TutorFeedbackRequest: Codable, Equatable, Sendable {
    public let kind: TutorFeedbackKind
    public let question: String?
    public let authoredContext: String
    public let attempt: Int
    public let capture: TutorCaptureMetadata
    public let verifier: TutorVerificationReceipt?

    public init(kind: TutorFeedbackKind, question: String? = nil, authoredContext: String, attempt: Int, capture: TutorCaptureMetadata, verifier: TutorVerificationReceipt? = nil) throws {
        if let question { try TutorProtocolValidation.requireText(question, maximum: TutorProtocolLimits.questionCharacters, field: "question") }
        try TutorProtocolValidation.requireText(authoredContext, maximum: TutorProtocolLimits.structuredContextBytes, field: "authored_context")
        guard attempt >= 0 else { throw TutorProtocolError.invalidFeedback("attempt") }
        self.kind = kind
        self.question = question
        self.authoredContext = authoredContext
        self.attempt = attempt
        self.capture = capture
        self.verifier = verifier
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case question
        case authoredContext = "authored_context"
        case attempt
        case capture
        case verifier
    }
}

public enum TutorAssessment: String, Codable, Sendable { case onTrack = "on_track", needsHelp = "needs_help", uncertain }
public enum TutorFeedbackBasis: String, Codable, Sendable { case screenshot, verifier, authored }

public struct TutorFeedbackReply: Codable, Equatable, Sendable {
    public let message: String
    public let assessment: TutorAssessment
    public let basis: TutorFeedbackBasis
    public let model: String

    public init(message: String, assessment: TutorAssessment, basis: TutorFeedbackBasis, model: String) throws {
        try TutorProtocolValidation.requireText(message, maximum: TutorProtocolLimits.answerCharacters, field: "message")
        try TutorProtocolValidation.requireText(model, maximum: 256, field: "model")
        self.message = message
        self.assessment = assessment
        self.basis = basis
        self.model = model
    }
}

public struct TutorRunSnapshot: Codable, Equatable, Sendable {
    public let identity: TutorRunIdentity
    public let state: String
    public let updatedAt: Date

    public init(identity: TutorRunIdentity, state: String, updatedAt: Date = Date()) throws {
        try TutorProtocolValidation.requireID(state, field: "state")
        self.identity = identity
        self.state = state
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case identity, state, updatedAt = "updated_at" }
}

public struct TutorGatewaySnapshot: Codable, Equatable, Sendable {
    public let sourceEpoch: String
    public let sequence: UInt64
    public let payloadDigest: String
    public let payload: Data

    public init(sourceEpoch: String, sequence: UInt64, payloadDigest: String, payload: Data) throws {
        try TutorProtocolValidation.requireID(sourceEpoch, field: "source_epoch")
        try TutorProtocolValidation.requireDigest(payloadDigest)
        guard payload.count <= TutorProtocolLimits.controlFrameBytes else { throw TutorProtocolError.payloadTooLarge(limit: TutorProtocolLimits.controlFrameBytes) }
        self.sourceEpoch = sourceEpoch
        self.sequence = sequence
        self.payloadDigest = payloadDigest
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case sourceEpoch = "source_epoch"
        case sequence
        case payloadDigest = "payload_digest"
        case payload
    }
}

public struct TutorCapabilityHandshake: Codable, Equatable, Sendable {
    public let runtimeMode: TutorRuntimeMode
    public let minimumProtocol: Int
    public let maximumProtocol: Int
    public let releaseDigest: String
    public let capabilityToken: String

    public init(runtimeMode: TutorRuntimeMode, minimumProtocol: Int, maximumProtocol: Int, releaseDigest: String, capabilityToken: String) throws {
        guard minimumProtocol <= maximumProtocol, (2...4).contains(minimumProtocol), (2...4).contains(maximumProtocol) else { throw TutorProtocolError.unsupportedVersion(maximumProtocol) }
        try TutorProtocolValidation.requireDigest(releaseDigest)
        try TutorProtocolValidation.requireID(capabilityToken, field: "capability_token")
        self.runtimeMode = runtimeMode
        self.minimumProtocol = minimumProtocol
        self.maximumProtocol = maximumProtocol
        self.releaseDigest = releaseDigest
        self.capabilityToken = capabilityToken
    }

    enum CodingKeys: String, CodingKey {
        case runtimeMode = "runtime_mode"
        case minimumProtocol = "minimum_protocol"
        case maximumProtocol = "maximum_protocol"
        case releaseDigest = "release_digest"
        case capabilityToken = "capability_token"
    }
}

public enum TutorProtocolValidation {
    static func requireID(_ value: String, field: String) throws {
        guard !value.isEmpty, value.utf8.count <= 256,
              value.unicodeScalars.allSatisfy(isSafeScalar)
        else { throw TutorProtocolError.invalidIdentity(field) }
    }

    static func requireBundleID(_ value: String) throws {
        try requireID(value, field: "bundle_id")
        guard value.contains("."), value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else {
            throw TutorProtocolError.invalidIdentity("bundle_id")
        }
    }

    static func requireDigest(_ value: String) throws {
        guard value.count == 64, value.allSatisfy({ $0.isHexDigit }) else { throw TutorProtocolError.invalidIdentity("digest") }
    }

    static func requireText(_ value: String, maximum: Int, field: String) throws {
        guard !value.isEmpty, value.count <= maximum, value.utf8.count <= maximum,
              value.unicodeScalars.allSatisfy(isSafeScalar)
        else { throw TutorProtocolError.unsafeText(field) }
    }

    static func hasJPEGSignature(_ data: Data) -> Bool {
        data.count >= 4 && data.starts(with: [0xFF, 0xD8, 0xFF]) && data.suffix(2) == Data([0xFF, 0xD9])
    }

    private static func isSafeScalar(_ scalar: Unicode.Scalar) -> Bool {
        !CharacterSet.controlCharacters.contains(scalar) && scalar.value != 0 && !unsafeBidi.contains(scalar.value)
    }

    private static let unsafeBidi: Set<UInt32> = [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
}
