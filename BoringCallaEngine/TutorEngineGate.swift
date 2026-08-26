import Foundation

/// Deterministic Engine-side authority gate. It is deliberately pure so stale
/// or replayed Host/Gateway messages can be tested without a socket, model or
/// UI. A caller still decides authored next step; this type never derives one.
struct TutorEngineIdentity: Codable, Equatable, Sendable {
    let runID: String
    let generation: UInt64
    let courseKey: String
    let revision: String
    let lessonID: String
    let stepID: String
}

enum TutorEngineEventDecision: Equatable, Sendable {
    case accepted
    case duplicate
    case stale
    case future
    case mismatched
    case feedbackBusy
    case noPendingFeedback
}

struct TutorEngineGate: Sendable {
    private(set) var active: TutorEngineIdentity?
    private var handledRequestIDs: Set<String> = []
    private var pendingFeedbackRequestID: String?

    mutating func start(_ identity: TutorEngineIdentity) {
        active = identity
        handledRequestIDs.removeAll(keepingCapacity: true)
        pendingFeedbackRequestID = nil
    }

    mutating func stop() {
        active = nil
        pendingFeedbackRequestID = nil
    }

    /// Every Host event must carry current identity. Replay returns a stable
    /// duplicate decision; stale/future events are diagnostics and cannot mutate.
    mutating func acceptEvent(requestID: String, identity: TutorEngineIdentity) -> TutorEngineEventDecision {
        guard let active else { return .stale }
        if handledRequestIDs.contains(requestID) { return .duplicate }
        guard identity.runID == active.runID,
              identity.courseKey == active.courseKey,
              identity.revision == active.revision,
              identity.lessonID == active.lessonID,
              identity.stepID == active.stepID
        else { return .mismatched }
        guard identity.generation == active.generation else {
            return identity.generation < active.generation ? .stale : .future
        }
        handledRequestIDs.insert(requestID)
        return .accepted
    }

    mutating func beginFeedback(requestID: String, identity: TutorEngineIdentity) -> TutorEngineEventDecision {
        guard pendingFeedbackRequestID == nil else { return .feedbackBusy }
        let accepted = acceptEvent(requestID: requestID, identity: identity)
        guard accepted == .accepted else { return accepted }
        pendingFeedbackRequestID = requestID
        return .accepted
    }

    mutating func finishFeedback(requestID: String, identity: TutorEngineIdentity) -> TutorEngineEventDecision {
        guard acceptEvent(requestID: "finish-\(requestID)", identity: identity) == .accepted else { return .mismatched }
        guard pendingFeedbackRequestID == requestID else { return .noPendingFeedback }
        pendingFeedbackRequestID = nil
        return .accepted
    }

    mutating func advance(to next: TutorEngineIdentity) -> TutorEngineEventDecision {
        guard let active,
              next.runID == active.runID,
              next.generation == active.generation,
              next.courseKey == active.courseKey,
              next.revision == active.revision
        else { return .mismatched }
        pendingFeedbackRequestID = nil
        self.active = next
        return .accepted
    }
}
