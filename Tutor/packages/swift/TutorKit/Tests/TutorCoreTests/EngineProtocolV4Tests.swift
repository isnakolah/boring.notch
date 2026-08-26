import Foundation
import Testing
import TutorProtocol

private let protocolDigest = String(repeating: "a", count: 64)

private func v4Identity() throws -> TutorRunIdentity {
    try TutorRunIdentity(
        runID: "run-1",
        generation: 4,
        courseKey: "blender-basics",
        revision: "rev-42",
        lessonID: "lesson-1",
        stepID: "step-1")
}

@Test func v4EnvelopeRoundTripsWithFullRunIdentity() throws {
    let envelope = try TutorControlEnvelope(
        requestID: "request-1",
        identity: v4Identity(),
        operation: "observe_step",
        payload: try TutorHostCommand(operation: .observeStep, expectedVerifierID: "detector-1"))
    try envelope.validateFrameLimit()
    let decoded = try TutorControlEnvelope<TutorHostCommand>.decodeFrame(JSONEncoder().encode(envelope))
    #expect(decoded.protocolVersion == 4)
    #expect(decoded.identity == envelope.identity)
    #expect(decoded.payload.operation == .observeStep)
}

@Test func v4EnvelopeRejectsUnknownOrOversizedFrames() throws {
    let json = """
    {"protocol_version":4,"request_id":"request-1","identity":{"run_id":"run-1","generation":4,"course_key":"blender-basics","revision":"rev-42","lesson_id":"lesson-1","step_id":"step-1"},"operation":"observe_step","payload":{"operation":"observe_step","payload":{}},"issued_at":0,"unexpected":true}
    """.data(using: .utf8)!
    #expect(throws: TutorProtocolError.self) {
        try TutorControlEnvelope<TutorHostCommand>.decodeFrame(json)
    }
    #expect(throws: TutorProtocolError.self) {
        try TutorControlEnvelope<TutorHostCommand>.decodeFrame(Data(repeating: 0, count: TutorProtocolLimits.controlFrameBytes + 1))
    }
}

@Test func v4CaptureRejectsNonJPEGAndUnsafeFeedback() throws {
    #expect(throws: TutorProtocolError.self) {
        try TutorCaptureMetadata(
            identifier: "capture-1",
            mimeType: "image/jpeg",
            jpeg: Data([0, 1, 2]),
            width: 20,
            height: 20,
            windowID: 1,
            processID: 1,
            bundleID: "org.blender.Blender",
            purpose: .learnerQuestion)
    }
    #expect(throws: TutorProtocolError.self) {
        try TutorFeedbackReply(message: "unsafe\u{202E}", assessment: .uncertain, basis: .authored, model: "test")
    }
}

@Test func v4GatewayHandshakeRequiresDigestAndProtocolRange() throws {
    let handshake = try TutorCapabilityHandshake(
        runtimeMode: .engine,
        minimumProtocol: 4,
        maximumProtocol: 4,
        releaseDigest: protocolDigest,
        capabilityToken: "token-1")
    #expect(handshake.runtimeMode == .engine)
    #expect(throws: TutorProtocolError.self) {
        try TutorCapabilityHandshake(
            runtimeMode: .engine,
            minimumProtocol: 4,
            maximumProtocol: 5,
            releaseDigest: protocolDigest,
            capabilityToken: "token-1")
    }
}
