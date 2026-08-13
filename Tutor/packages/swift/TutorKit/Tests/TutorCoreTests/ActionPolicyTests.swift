import Testing
import TutorCore
import TutorProtocol

private func target(confidence: Double = 0.99) -> ResolvedTarget {
    ResolvedTarget(
        semanticID: "blender.ui.properties.modifiers_tab",
        snapshotID: "snapshot-1",
        opaqueElementID: "B17",
        windowID: 42,
        bounds: TutorScreenRect(x: 100, y: 200, width: 24, height: 24),
        confidence: confidence,
        evidence: ["ax-role", "visual-icon"],
        validUntil: .nextWindowMutation)
}

private func proposal(_ action: TutorActionKind) -> ProposedTutorAction {
    ProposedTutorAction(
        action: action,
        semanticTarget: "blender.ui.properties.modifiers_tab",
        snapshotID: "snapshot-1",
        expectedState: "blender.detector.properties_context_is_modifier",
        rationale: "The learner explicitly asked for this step.")
}

private func input(
    action: TutorActionKind,
    level: TutorCapabilityLevel,
    target resolvedTarget: ResolvedTarget? = target(),
    fresh: Bool = true,
    exactWindow: Bool = true,
    approval: LocalApproval = .absent,
    sensitive: SensitiveContext = .none) -> ActionPolicyInput
{
    ActionPolicyInput(
        proposal: proposal(action),
        capabilityLevel: level,
        target: resolvedTarget,
        targetIsFresh: fresh,
        exactWindowIdentityVerified: exactWindow,
        packAllowsAction: true,
        pointMinimumConfidence: 0.72,
        actionMinimumConfidence: 0.92,
        hasIndependentLocalEvidence: true,
        localApproval: approval,
        sensitiveContext: sensitive)
}

@Test func aiPointerDoesNotRequireMutationApproval() {
    #expect(ActionPolicy().evaluate(input(action: .aiPointer, level: .visualGuidance)) == .allow)
}

@Test func clickRequiresOneShotApproval() {
    let decision = ActionPolicy().evaluate(input(action: .click, level: .boundedInput))
    #expect(decision == .requireLocalApproval(reason: "this bounded input requires one-shot local approval"))
    #expect(
        ActionPolicy().evaluate(input(action: .click, level: .boundedInput, approval: .allowOnce)) == .allow)
}

@Test func sessionGrantCannotAuthorizeClick() {
    #expect(
        ActionPolicy().evaluate(input(action: .click, level: .boundedInput, approval: .sessionGrant))
            == .requireLocalApproval(reason: "this bounded input requires one-shot local approval"))
}

@Test func staleOrAmbiguousTargetsFailClosed() {
    #expect(
        ActionPolicy().evaluate(input(action: .click, level: .boundedInput, fresh: false, approval: .allowOnce))
            == .deny(reason: "target receipt is stale"))
    #expect(
        ActionPolicy().evaluate(
            input(action: .click, level: .boundedInput, target: target(confidence: 0.7), approval: .allowOnce))
            == .deny(reason: "target confidence is below the mutation threshold"))
}

@Test func sensitiveContextsAlwaysBlockMutation() {
    #expect(
        ActionPolicy().evaluate(
            input(
                action: .click,
                level: .boundedInput,
                approval: .allowOnce,
                sensitive: .externalSubmission))
            == .deny(reason: "actions are prohibited in sensitive context: externalSubmission"))
}

@Test func modelHintAloneCannotAuthorizeAnAction() {
    let proposal = proposal(.click)
    let denied = ActionPolicy().evaluate(
        ActionPolicyInput(
            proposal: proposal,
            capabilityLevel: .boundedInput,
            target: target(),
            targetIsFresh: true,
            exactWindowIdentityVerified: true,
            packAllowsAction: true,
            pointMinimumConfidence: 0.72,
            actionMinimumConfidence: 0.92,
            hasIndependentLocalEvidence: false,
            localApproval: .allowOnce,
            sensitiveContext: .none))
    #expect(denied == .deny(reason: "action authority requires independent local evidence"))
}
