import {bindSession, noteToolCallSession} from "./memory.mjs";
import {
  exemptRegionPaths,
  findForbiddenCoordinatePath,
  TUTOR_TOOL_NAMES,
  validateNormalizedRegion,
  validateNormalizedTargetHint,
} from "./protocol.mjs";

const TUTOR_TOOLS = new Set(TUTOR_TOOL_NAMES);

function serverSessionID(context) {
  const sessionID = context?.sessionId;
  return typeof sessionID === "string" && sessionID.length >= 8 ? sessionID : null;
}

export function createBeforeToolCallPolicy(config, hasPublishedLesson = () => true) {
  return async (event, context) => {
    if (!TUTOR_TOOLS.has(event.toolName)) return undefined;

    const sessionID = serverSessionID(context);
    if (!sessionID) {
      return {
        block: true,
        blockReason: "Tutor tools require an opaque OpenClaw lesson session id.",
      };
    }
    if (!hasPublishedLesson(context)) {
      return {block: true, blockReason: "Tutor tools require an active published course lesson."};
    }
    // The model never chooses which TutorHost lesson receives a request, and it
    // is no longer asked to: the session travels beside the call rather than
    // inside the model's arguments. Rewriting those arguments here is what made
    // the Codex app-server refuse every tutor call the moment the tool surface
    // was exposed directly, so this hook now reads and never edits them.
    const params = event.params || {};
    noteToolCallSession(event.toolCallId, sessionID);

    // The only place both names for this lesson are in scope. Recording it is
    // what lets memory kept under the model's session id be found again when
    // the next turn's prompt is built under OpenClaw's.
    bindSession(context?.sessionKey ?? context?.sessionId, sessionID);

    if (config.requireOwnerIdentity && context?.requester?.senderIsOwner !== true) {
      return {
        block: true,
        blockReason: "Tutor tools require a host-verified owner requester identity.",
      };
    }

    try {
      if (event.toolName === "tutor_point" && params.target_hint !== undefined) {
        validateNormalizedTargetHint(params.target_hint);
      }
      if (event.toolName === "tutor_guide") {
        validateNormalizedRegion(params.region);
      }
      if (event.toolName === "tutor_observe" && params.region !== undefined) {
        validateNormalizedRegion(params.region);
      }
      // Re-checked here independently of the tool, because a planned region is
      // drawn later — possibly several steps later, with no model in the loop
      // to notice it was nonsense.
      if (event.toolName === "tutor_plan" && Array.isArray(params.steps)) {
        params.steps.forEach((step, index) => {
          if (step && typeof step === "object" && step.region !== undefined) {
            validateNormalizedRegion(step.region, `steps.${index}.region`);
          }
        });
      }
    } catch (error) {
      return {block: true, blockReason: error.message};
    }
    const coordinatePath = findForbiddenCoordinatePath(
      params,
      [],
      exemptRegionPaths(event.toolName, params),
    );
    if (coordinatePath) {
      return {
        block: true,
        blockReason: `Raw coordinate field ${coordinatePath} is forbidden; resolve a semantic target locally.`,
      };
    }

    if (event.toolName === "tutor_propose_action") {
      if (Object.hasOwn(params, "target_hint")) {
        return {
          block: true,
          blockReason: "tutor_propose_action never accepts a model target_hint; local evidence is required.",
        };
      }
      const action = typeof params.action === "string" ? params.action : "unknown";
      const target =
        typeof params.target_descriptor?.id === "string" ? params.target_descriptor.id : "unknown target";
      return {
        requireApproval: {
          title: `Tutor action: ${action}`,
          description: `Allow one bounded ${action} on semantic target ${target}. TutorHost will resolve and approve it again locally.`,
          severity: action === "move_cursor" ? "info" : "warning",
          timeoutMs: 30_000,
          timeoutReason: "Tutor action approval timed out; no action was sent to the Mac.",
          allowedDecisions: ["allow-once", "deny"],
        },
      };
    }

    // Nothing is returned on the ordinary path: this hook validates, and a
    // validating hook that also edits cannot be told apart from tampering.
    return undefined;
  };
}
