import { randomUUID } from "node:crypto";
import os from "node:os";
import path from "node:path";

import {validateDetectorDescriptor, validateTargetDescriptor} from "./descriptors.mjs";

export const PROTOCOL_VERSION = 2;
/// New Gateway and Boring engine understand v2 and v3. Gateway keeps sending
/// v2 until a paired node's internal handshake proves v3 compatibility.
export const SUPPORTED_PROTOCOL_VERSIONS = Object.freeze([2, 3]);
export const NODE_COMMAND = "tutor.host";
export const CALLA_ROLES = Object.freeze(["gateway", "node", "both"]);
/// The tools a model can actually call.
///
/// Deliberately smaller than TOOL_TO_OPERATION below. `retrieve` and
/// `await_change` remain operations the host understands — the Mac still
/// dispatches them, and `guide` runs an await internally — but neither is
/// offered to the model any more. Retrieval already arrives as context ahead of
/// the first tool call, and waiting from the Gateway spends a round trip to
/// learn what the next message was going to say anyway. A name absent here is
/// not registered, so nothing can call it.
export const TUTOR_TOOL_NAMES = Object.freeze([
  "tutor_observe",
  "tutor_plan",
  "tutor_remember",
  "tutor_guide",
  "tutor_narrate",
  "tutor_point",
  "tutor_propose_action",
  "tutor_verify",
]);

/// The wire contract, which outlives the model surface above. Every operation
/// the Mac can be asked to perform is here so envelopes keep validating even
/// when no tool builds them.
const TOOL_TO_OPERATION = Object.freeze({
  tutor_observe: "observe",
  tutor_retrieve: "retrieve",
  tutor_plan: "plan",
  // Gateway-local, like retrieve: it never reaches the Mac, but it needs an
  // operation name so validation and the tool table stay in one shape.
  tutor_remember: "remember",
  tutor_guide: "guide",
  tutor_await_change: "await_change",
  tutor_narrate: "narrate",
  tutor_point: "point",
  tutor_propose_action: "propose_action",
  tutor_verify: "verify",
});
/// Operations the Gateway sends the Mac that no model can ask for.
///
/// Both are pushes rather than answers to a turn, and neither is a tool: adding
/// one here does not expose it to the model, and it must not be added to
/// TUTOR_TOOL_NAMES.
const INTERNAL_OPERATIONS = new Set(["session_start", "record_learning", "catalogue", "course_status", "course_runtime"]);

const FORBIDDEN_COORDINATE_KEYS = new Set([
  "x",
  "y",
  "coordinate",
  "coordinates",
  "screen_x",
  "screen_y",
  "left",
  "top",
  "width",
  "height",
  "bounds",
  "frame",
]);

function requireString(value, name, minimum = 1) {
  if (typeof value !== "string" || value.trim().length < minimum) {
    throw new TypeError(`${name} must be a string of at least ${minimum} characters`);
  }
  return value.trim();
}

/**
 * Whether one exact path is where a normalized region is allowed to sit.
 *
 * A `"#"` segment matches an array index and nothing else, which is what lets a
 * plan exempt `steps.0.region` through `steps.11.region` without exempting a
 * key called `steps` on some other object. Every other segment must match
 * literally, and the whole path must be the same length — an exemption is a
 * single named location, never a prefix.
 */
function matchesExemptPath(path, exempt) {
  if (path.length !== exempt.length) return false;
  return path.every((part, index) => {
    const expected = exempt[index];
    return expected === "#" ? /^\d+$/.test(part) : part === expected;
  });
}

/**
 * @param exemptRegionPaths the paths, relative to the payload, at which a
 *   normalized region may appear: `["target_hint", "region"]` for pointing,
 *   `["region"]` for guiding, and `["steps", "#", "region"]` for planning.
 *   Everywhere else a coordinate-shaped key is a rejection, and no exemption is
 *   ever granted to an operation that can act.
 */
export function findForbiddenCoordinatePath(value, path = [], exemptRegionPaths = null) {
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index += 1) {
      const found = findForbiddenCoordinatePath(value[index], [...path, String(index)], exemptRegionPaths);
      if (found) return found;
    }
    return null;
  }
  if (!value || typeof value !== "object") return null;
  for (const [key, child] of Object.entries(value)) {
    const next = [...path, key];
    if (exemptRegionPaths?.some((exempt) => matchesExemptPath(next, exempt))) continue;
    if (FORBIDDEN_COORDINATE_KEYS.has(key.toLowerCase())) return next.join(".");
    const found = findForbiddenCoordinatePath(child, next, exemptRegionPaths);
    if (found) return found;
  }
  return null;
}

/** Where each tool is allowed to carry a normalized region, if at all. */
export function exemptRegionPaths(toolName, params) {
  if (toolName === "tutor_point" && params?.target_hint !== undefined) return [["target_hint", "region"]];
  if (toolName === "tutor_guide") return [["region"]];
  // A plan carries one region per step so the Mac can advance the lesson
  // without a model round trip. Planning draws and nothing else — the same
  // authority guiding has, spread over steps that have not happened yet.
  if (toolName === "tutor_plan") return [["steps", "#", "region"]];
  if (toolName === "tutor_observe") return [["region"]];
  return null;
}

export function validateNormalizedRegion(region, name = "region") {
  if (!region || typeof region !== "object" || Array.isArray(region) || Object.keys(region).length !== 4) {
    throw new TypeError(`${name} must contain left, top, width, and height only`);
  }
  for (const field of ["left", "top", "width", "height"]) {
    if (typeof region[field] !== "number" || !Number.isFinite(region[field])) {
      throw new TypeError(`${name}.${field} must be a finite normalized number`);
    }
  }
  if (region.left < 0 || region.top < 0 || region.width <= 0 || region.height <= 0 || region.left + region.width > 1 || region.top + region.height > 1) {
    throw new TypeError(`${name} must be in [0,1], have positive size, and remain inside the focused window`);
  }
  return region;
}

export function validateNormalizedTargetHint(value) {
  if (!value || typeof value !== "object" || Array.isArray(value) || Object.keys(value).length !== 1) {
    throw new TypeError("target_hint must contain a region only");
  }
  validateNormalizedRegion(value.region, "target_hint.region");
  return value;
}

function validateSnapshot(value, name = "snapshot_id") {
  return requireString(value, name);
}

/** How much of a step's own guide the plan is allowed to carry in advance. */
const PLAN_STEP_KEYS = new Set(["title", "region", "text"]);

/**
 * One planned step: a bare title, or a title with the region and words that
 * would guide it.
 *
 * Carrying the region ahead of time is what lets the Mac point at the next step
 * the moment the learner finishes this one, with no model round trip. It grants
 * no new authority: a planned region can only ever draw, exactly like the one
 * `tutor_guide` already accepts, and the Mac re-checks it against the live
 * window and the Accessibility tree before the cursor moves.
 */
function validatePlanStep(step, index) {
  if (typeof step === "string") {
    requireString(step, `steps.${index}`);
    return step;
  }
  if (!step || typeof step !== "object" || Array.isArray(step)) {
    throw new TypeError(`steps.${index} must be a title or an object with title, region, and text`);
  }
  for (const key of Object.keys(step)) {
    if (!PLAN_STEP_KEYS.has(key)) {
      throw new TypeError(`steps.${index}.${key} is not a planned-step field`);
    }
  }
  requireString(step.title, `steps.${index}.title`);
  if (step.text !== undefined) requireString(step.text, `steps.${index}.text`);
  // A step with words but nowhere to put them cannot be advanced locally, and a
  // region with nothing to say would point in silence. Both or neither.
  if ((step.region === undefined) !== (step.text === undefined)) {
    throw new TypeError(`steps.${index} needs region and text together, or neither`);
  }
  if (step.region !== undefined) validateNormalizedRegion(step.region, `steps.${index}.region`);
  return step;
}

export function validateToolPayload(toolName, payload) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) throw new TypeError("tool parameters must be an object");
  if (toolName === "tutor_observe") {
    if (payload.include_capture !== undefined && typeof payload.include_capture !== "boolean") {
      throw new TypeError("include_capture must be a boolean");
    }
    if (Object.hasOwn(payload, "include_crop")) throw new TypeError("include_crop was replaced by include_capture in protocol v2");
    // Asking for one panel instead of the whole window. Same normalized region
    // the model is already trusted to read off a capture, used here to send
    // less of the screen rather than to point at part of it.
    if (payload.region !== undefined) {
      if (payload.include_capture !== true) {
        throw new TypeError("observe region only means something with include_capture true");
      }
      validateNormalizedRegion(payload.region);
    }
    // One scalar bound on the image, not a place on it. The Mac clamps this
    // down to the owner's own setting, so it can only ever ask for less.
    if (payload.long_edge !== undefined) {
      if (!Number.isInteger(payload.long_edge) || payload.long_edge < 512 || payload.long_edge > 2048) {
        throw new TypeError("long_edge must be an integer between 512 and 2048");
      }
    }
  }
  if (toolName === "tutor_guide") {
    validateNormalizedRegion(payload.region);
    validateSnapshot(payload.snapshot_id);
    requireString(payload.text, "text");
    if (Object.hasOwn(payload, "target_descriptor")) {
      throw new TypeError("tutor_guide never carries a descriptor; it points at what the model saw in the capture");
    }
  }
  if (toolName === "tutor_plan") {
    if (payload.goal !== undefined) requireString(payload.goal, "goal");
    if (!Array.isArray(payload.steps) || payload.steps.length < 2) {
      throw new TypeError("tutor_plan needs at least two steps; a one-step lesson does not need a plan");
    }
    payload.steps.forEach(validatePlanStep);
    // A region is a fraction of some particular picture. Without knowing which,
    // the Mac would map it onto whatever it happened to see last — which is how
    // a cursor lands confidently in the wrong place two steps later.
    const carriesRegion = payload.steps.some((step) => step && typeof step === "object" && step.region);
    if (carriesRegion) validateSnapshot(payload.snapshot_id);
    if (payload.lesson_id !== undefined) requireString(payload.lesson_id, "lesson_id");
  }
  if (toolName === "tutor_await_change") {
    validateSnapshot(payload.snapshot_id);
  }
  if (toolName === "tutor_narrate") {
    requireString(payload.text, "text");
  }
  if (toolName === "tutor_point") {
    validateTargetDescriptor(payload.target_descriptor);
    validateSnapshot(payload.snapshot_id);
    if (payload.target_hint !== undefined) validateNormalizedTargetHint(payload.target_hint);
  }
  if (toolName === "tutor_propose_action") {
    if (Object.hasOwn(payload, "target_hint")) throw new TypeError("tutor_propose_action never accepts target_hint");
    validateTargetDescriptor(payload.target_descriptor);
    validateDetectorDescriptor(payload.expected_state);
    validateSnapshot(payload.snapshot_id);
  }
  if (toolName === "tutor_verify") {
    validateTargetDescriptor(payload.target_descriptor);
    validateDetectorDescriptor(payload.detector_descriptor);
    validateSnapshot(payload.snapshot_id);
  }
  const forbidden = findForbiddenCoordinatePath(payload, [], exemptRegionPaths(toolName, payload));
  if (forbidden) throw new TypeError(`raw coordinate field ${forbidden} is forbidden; use an App-Pack descriptor`);
  return payload;
}

/// Build one node request.
///
/// The session is passed in rather than read off the model's parameters. It was
/// a parameter once, which meant the Gateway had to rewrite the model's
/// arguments in `before_tool_call` to put the right value there — and the Codex
/// app-server refuses a call whose approval params were rewritten, so the tool
/// surface could never be exposed directly. Nothing about the session is the
/// model's to choose, so it no longer travels with what the model wrote.
export function buildTutorEnvelope(toolName, params, session) {
  const operation = TOOL_TO_OPERATION[toolName];
  if (!operation) throw new TypeError(`unsupported tutor tool: ${toolName}`);
  if (!params || typeof params !== "object" || Array.isArray(params)) {
    throw new TypeError("tool parameters must be an object");
  }
  // A legacy caller may still carry it inside the parameters; the explicit
  // argument wins, and either way it never reaches the payload.
  const sessionId = requireString(session ?? params.session_id, "session_id", 8);
  const payload = {...params};
  delete payload.session_id;
  validateToolPayload(toolName, payload);
  return {
    protocol_version: PROTOCOL_VERSION,
    request_id: randomUUID(),
    operation,
    session_id: sessionId,
    payload,
  };
}

export function validateNodeEnvelope(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("node request must be an object");
  }
  if (!SUPPORTED_PROTOCOL_VERSIONS.includes(value.protocol_version)) {
    throw new TypeError("protocol_version must be in supported range 2...3");
  }
  requireString(value.request_id, "request_id", 8);
  requireString(value.session_id, "session_id", 8);
  if (!Object.values(TOOL_TO_OPERATION).includes(value.operation) && !INTERNAL_OPERATIONS.has(value.operation)) {
    throw new TypeError(`unsupported operation: ${String(value.operation)}`);
  }
  const toolName = Object.entries(TOOL_TO_OPERATION).find(([, operation]) => operation === value.operation)?.[0];
  if (toolName) validateToolPayload(toolName, value.payload);
  if (value.operation === "session_start") {
    const range = value.payload?.supported_protocol_range;
    if (!range || !Number.isInteger(range.min) || !Number.isInteger(range.max) || range.min > range.max ||
        range.min < 2 || range.max > 3 || typeof value.payload?.engine_build !== "string" ||
        typeof value.payload?.node_contract_hash !== "string") {
      throw new TypeError("session_start requires bounded protocol range, engine build, and node contract hash");
    }
  }
  if (value.operation === "record_learning") {
    const payload = value.payload;
    if (typeof payload?.lesson_id !== "string" || typeof payload?.bundle_id !== "string" || typeof payload?.succeeded !== "boolean") {
      throw new TypeError("record_learning requires bounded lesson_id, bundle_id, and succeeded fields");
    }
  }
  if (value.operation === "catalogue") {
    const courses = value.payload?.courses;
    if (!Array.isArray(courses) || courses.length > 200) {
      throw new TypeError("catalogue requires a bounded courses array");
    }
    for (const course of courses) {
      if (typeof course?.id !== "string" || typeof course?.title !== "string" || !Array.isArray(course?.lessons)) {
        throw new TypeError("each catalogue course requires an id, a title, and a lessons array");
      }
      if (course.lessons.length > 100) throw new TypeError("a catalogue course lists at most 100 lessons");
      for (const lesson of course.lessons) {
        if (typeof lesson?.id !== "string" || typeof lesson?.title !== "string") {
          throw new TypeError("each catalogue lesson requires an id and a title");
        }
      }
    }
    // Names and counts only. A catalogue is read by a menu, so anything that
    // could position or act has no business in it — and the same guard that
    // keeps coordinates out of a tool call keeps them out of here.
    const coordinatePath = findForbiddenCoordinatePath(value.payload, [], []);
    if (coordinatePath) {
      throw new TypeError(`catalogue must not carry coordinate field ${coordinatePath}`);
    }
  }
  if (value.operation === "course_status") {
    const courses = value.payload?.courses;
    if (!Array.isArray(courses) || courses.length > 200) throw new TypeError("course_status requires a bounded courses array");
    for (const course of courses) {
      if (typeof course?.id !== "string" || typeof course?.phase !== "string" || typeof course?.title !== "string") {
        throw new TypeError("each course status requires id, phase, and title");
      }
      if (!new Set(["queued", "compiling", "validating", "waiting_for_blender", "preflighting", "publishing", "published", "failed", "cancelled", "archived"]).has(course.phase)) {
        throw new TypeError("course status has an unsupported phase");
      }
      if (course.error !== null && course.error !== undefined && typeof course.error !== "string") throw new TypeError("course status error must be text");
      if (typeof course.error === "string" && course.error.length > 240) throw new TypeError("course status error exceeds bound");
    }
    const coordinatePath = findForbiddenCoordinatePath(value.payload, [], []);
    if (coordinatePath) throw new TypeError(`course_status must not carry coordinate field ${coordinatePath}`);
  }
  /**
   * A diagnosis is a canonical detector and a sentence, and it is bounded here
   * for the same reason the step beside it is: it reaches the learner as an
   * explanation, and an explanation the Mac cannot check is worse than none.
   */
  function assertDiagnoses(list, name) {
    if (list === undefined) return;
    if (!Array.isArray(list) || list.length > 8) throw new TypeError(`${name} list is malformed`);
    for (const entry of list) {
      if (!entry || typeof entry.say !== "string" || !entry.say || entry.say.length > 240 ||
          entry.when?.kind !== "detector") {
        throw new TypeError(`${name} is malformed`);
      }
    }
  }
  if (value.operation === "course_runtime") {
    const runtime = value.payload?.runtime;
    if (!runtime || runtime.format !== "calla-course-runtime" || runtime.format_version !== 1 ||
        !Array.isArray(runtime.courses) || runtime.courses.length > 200) {
      throw new TypeError("course_runtime requires a bounded v1 runtime manifest");
    }
    for (const course of runtime.courses) {
      if (typeof course?.course_id !== "string" || typeof course?.course_revision !== "string" ||
          typeof course?.app_bundle_id !== "string" || typeof course?.app_version !== "string" || !Array.isArray(course?.lessons)) {
        throw new TypeError("course_runtime course is malformed");
      }
      for (const lesson of course.lessons) {
        if (!Array.isArray(lesson?.assets) || lesson.assets.length !== 2 ||
            new Set(lesson.assets.map((asset) => asset?.role)).size !== 2 || lesson.assets.some((asset) =>
              typeof asset?.asset_id !== "string" || !/^[0-9a-f]{64}$/.test(asset?.sha256) ||
              !Number.isSafeInteger(asset?.bytes) || asset.bytes < 1 || !["starter", "proof"].includes(asset?.role))) {
          throw new TypeError("course_runtime lesson assets are malformed");
        }
        for (const step of lesson?.steps || []) {
          if (typeof step?.text !== "string" || typeof step?.phase !== "string" || step?.target_descriptor?.kind !== "ui_target") {
            throw new TypeError("course_runtime step is malformed");
          }
          assertDiagnoses(step.diagnose, "course_runtime diagnosis");
        }
        assertDiagnoses(lesson?.prerequisites, "course_runtime prerequisite");
        if (lesson?.escalation !== undefined &&
            (!Array.isArray(lesson.escalation) || lesson.escalation.length > 8 ||
             lesson.escalation.some((rung) => typeof rung !== "string" || rung.length > 40))) {
          throw new TypeError("course_runtime escalation is malformed");
        }
      }
    }
    const coordinatePath = findForbiddenCoordinatePath(value.payload, [], []);
    if (coordinatePath) throw new TypeError(`course_runtime must not carry coordinate field ${coordinatePath}`);
  }
  return value;
}

/// Internal-only capability negotiation. Never register this as a model tool.
/// `protocol_version` stays at v2 for old Gateway/new Mac migration safety.
export function buildSessionStartEnvelope({min = 2, max = 3, engineBuild, nodeContractHash}) {
  const envelope = {
    protocol_version: PROTOCOL_VERSION,
    request_id: randomUUID(),
    operation: "session_start",
    session_id: "calla-session-start",
    payload: {
      supported_protocol_range: {min, max},
      engine_build: requireString(engineBuild, "engine_build"),
      node_contract_hash: requireString(nodeContractHash, "node_contract_hash"),
    },
  };
  return validateNodeEnvelope(envelope);
}

/// Hand the Mac the list of courses it may offer.
///
/// `session_id` is required of every envelope and there is no lesson here, so it
/// carries a fixed, obviously-not-a-lesson value rather than minting a session
/// that would look like teaching in the logs.
export function buildCatalogueEnvelope(catalogue) {
  const courses = Array.isArray(catalogue?.courses) ? catalogue.courses : [];
  const envelope = {
    protocol_version: PROTOCOL_VERSION,
    request_id: randomUUID(),
    operation: "catalogue",
    session_id: "calla-catalogue",
    payload: {courses},
  };
  return validateNodeEnvelope(envelope);
}

/// Gateway lifecycle DTO. It is local UI state, never model-visible data.
export function buildCourseStatusEnvelope(courses) {
  return validateNodeEnvelope({
    protocol_version: PROTOCOL_VERSION,
    request_id: randomUUID(),
    operation: "course_status",
    session_id: "calla-courses",
    payload: {courses: Array.isArray(courses) ? courses : []},
  });
}

/** Revision-pinned fast lesson cache. Internal push, never model tool. */
export function buildCourseRuntimeEnvelope(runtime) {
  return validateNodeEnvelope({
    protocol_version: PROTOCOL_VERSION,
    request_id: randomUUID(),
    operation: "course_runtime",
    session_id: "calla-course-runtime",
    payload: {runtime},
  });
}

export function buildInternalLearningEnvelope(sessionID, {lesson_id, bundle_id, succeeded, delayed_review = false}) {
  const envelope = {protocol_version: PROTOCOL_VERSION, request_id: randomUUID(), operation: "record_learning", session_id: requireString(sessionID, "session_id", 8), payload: {lesson_id, bundle_id, succeeded, delayed_review}};
  return validateNodeEnvelope(envelope);
}

export function parsePluginConfig(raw) {
  const config = raw && typeof raw === "object" ? raw : {};
  const role = typeof config.role === "string" ? config.role.trim().toLowerCase() : "gateway";
  if (!CALLA_ROLES.includes(role)) {
    throw new TypeError("tutor role must be gateway, node, or both");
  }
  if (role === "both" && config.developmentMode !== true) {
    throw new TypeError("tutor role both is development-only; set developmentMode to true explicitly");
  }
  const nodeId =
    typeof config.nodeId === "string" && config.nodeId.trim() ? config.nodeId.trim() : null;
  const nodeContractHash =
    typeof config.nodeContractHash === "string" && /^[a-f0-9]{16,128}$/i.test(config.nodeContractHash)
      ? config.nodeContractHash.toLowerCase() : null;
  const engineBuild =
    typeof config.engineBuild === "string" && config.engineBuild.trim() && config.engineBuild.length <= 120
      ? config.engineBuild.trim() : "unknown";
  const timeoutMs = Number.isSafeInteger(config.timeoutMs) ? config.timeoutMs : 10_000;
  if (timeoutMs < 1_000 || timeoutMs > 30_000) {
    throw new TypeError("tutor timeoutMs must be between 1000 and 30000");
  }
  const configuredStateDirectory =
    typeof config.stateDirectory === "string" && config.stateDirectory.trim()
      ? config.stateDirectory.trim()
      : "~/.openclaw/tutor";
  const stateDirectory = expandHomeDirectory(configuredStateDirectory);
  const agentWorkspace =
    typeof config.agentWorkspace === "string" && config.agentWorkspace.trim()
      ? expandHomeDirectory(config.agentWorkspace.trim()) : null;
  return {
    role,
    nodeId,
    nodeContractHash,
    engineBuild,
    socketPath:
      typeof config.socketPath === "string" && config.socketPath.trim()
        ? config.socketPath.trim()
        : null,
    timeoutMs,
    requireOwnerIdentity: config.requireOwnerIdentity === true,
    stateDirectory,
    agentWorkspace,
    courseSocketPath: typeof config.courseSocketPath === "string" && config.courseSocketPath.trim()
      ? config.courseSocketPath.trim() : path.join(stateDirectory, "course-control.sock"),
    developmentMode: config.developmentMode === true,
  };
}

function expandHomeDirectory(value) {
  if (value === "~") return os.homedir();
  if (value.startsWith("~/")) return path.join(os.homedir(), value.slice(2));
  return path.resolve(value);
}

export function unwrapNodePayload(result) {
  if (result && typeof result === "object" && result.payload !== undefined) return result.payload;
  if (result && typeof result === "object" && typeof result.payloadJSON === "string") {
    return JSON.parse(result.payloadJSON);
  }
  return result;
}
