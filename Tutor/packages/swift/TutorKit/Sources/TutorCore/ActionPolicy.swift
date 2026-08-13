import Foundation
import TutorProtocol

public enum TutorCapabilityLevel: Int, Codable, Comparable, Sendable {
    case observeOnly = 0
    case visualGuidance = 1
    case moveCursor = 2
    case boundedInput = 3
    case demonstration = 4

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum SensitiveContext: String, Codable, Sendable {
    case none
    case secureInput
    case authentication
    case purchase
    case destructive
    case externalSubmission
    case terminalOrCodeExecution

    var blocksMutation: Bool { self != .none }
}

public enum LocalApproval: String, Codable, Sendable {
    case absent
    case allowOnce
    case sessionGrant
}

public struct ActionPolicyInput: Sendable {
    public let proposal: ProposedTutorAction
    public let capabilityLevel: TutorCapabilityLevel
    public let target: ResolvedTarget?
    public let targetIsFresh: Bool
    public let exactWindowIdentityVerified: Bool
    public let packAllowsAction: Bool
    public let pointMinimumConfidence: Double
    public let actionMinimumConfidence: Double
    public let hasIndependentLocalEvidence: Bool
    public let localApproval: LocalApproval
    public let sensitiveContext: SensitiveContext

    public init(
        proposal: ProposedTutorAction,
        capabilityLevel: TutorCapabilityLevel,
        target: ResolvedTarget?,
        targetIsFresh: Bool,
        exactWindowIdentityVerified: Bool,
        packAllowsAction: Bool,
        pointMinimumConfidence: Double,
        actionMinimumConfidence: Double,
        hasIndependentLocalEvidence: Bool,
        localApproval: LocalApproval,
        sensitiveContext: SensitiveContext)
    {
        self.proposal = proposal
        self.capabilityLevel = capabilityLevel
        self.target = target
        self.targetIsFresh = targetIsFresh
        self.exactWindowIdentityVerified = exactWindowIdentityVerified
        self.packAllowsAction = packAllowsAction
        self.pointMinimumConfidence = pointMinimumConfidence
        self.actionMinimumConfidence = actionMinimumConfidence
        self.hasIndependentLocalEvidence = hasIndependentLocalEvidence
        self.localApproval = localApproval
        self.sensitiveContext = sensitiveContext
    }
}

public enum ActionPolicyDecision: Equatable, Sendable {
    case allow
    case requireLocalApproval(reason: String)
    case deny(reason: String)
}

public struct ActionPolicy: Sendable {
    public init() {}

    public func evaluate(_ input: ActionPolicyInput) -> ActionPolicyDecision {
        let action = input.proposal.action
        let requiredLevel = self.requiredLevel(for: action)
        guard input.capabilityLevel >= requiredLevel else {
            return .deny(reason: "selected capability level does not permit \(action.rawValue)")
        }

        if action == .explain {
            return .allow
        }

        guard input.packAllowsAction else {
            return .deny(reason: "the active App Pack does not authorize this action")
        }
        guard let target = input.target else {
            return .deny(reason: "the semantic target has not been resolved")
        }
        guard target.semanticID == input.proposal.semanticTarget else {
            return .deny(reason: "resolved target does not match the proposed semantic target")
        }
        guard target.snapshotID == input.proposal.snapshotID else {
            return .deny(reason: "resolved target does not match the proposed snapshot")
        }
        guard input.targetIsFresh else {
            return .deny(reason: "target receipt is stale")
        }

        if action == .highlight || action == .aiPointer {
            guard target.confidence >= input.pointMinimumConfidence else {
                return .deny(reason: "target confidence is below the visual-guidance threshold")
            }
            return .allow
        }

        guard !input.sensitiveContext.blocksMutation else {
            return .deny(reason: "actions are prohibited in sensitive context: \(input.sensitiveContext.rawValue)")
        }
        guard input.exactWindowIdentityVerified else {
            return .deny(reason: "exact target window identity is not verified")
        }
        guard target.confidence >= input.actionMinimumConfidence else {
            return .deny(reason: "target confidence is below the mutation threshold")
        }
        guard input.hasIndependentLocalEvidence else {
            return .deny(reason: "action authority requires independent local evidence")
        }
        guard input.proposal.expectedState != nil else {
            return .deny(reason: "a consequential action requires an authored expected state")
        }

        switch action {
        case .moveCursor:
            return input.localApproval == .absent
                ? .requireLocalApproval(reason: "moving the system cursor requires local approval")
                : .allow
        case .click, .scroll, .keyboardShortcut, .typeText, .demonstration:
            return input.localApproval == .allowOnce
                ? .allow
                : .requireLocalApproval(reason: "this bounded input requires one-shot local approval")
        case .explain, .highlight, .aiPointer:
            return .allow
        }
    }

    private func requiredLevel(for action: TutorActionKind) -> TutorCapabilityLevel {
        switch action {
        case .explain:
            .observeOnly
        case .highlight, .aiPointer:
            .visualGuidance
        case .moveCursor:
            .moveCursor
        case .click, .scroll, .keyboardShortcut, .typeText:
            .boundedInput
        case .demonstration:
            .demonstration
        }
    }
}
