import {buildCatalogueEnvelope, buildCourseRuntimeEnvelope, buildCourseStatusEnvelope, buildInternalLearningEnvelope, buildTutorEnvelope, unwrapNodePayload} from "./protocol.mjs";
import {buildCourseRuntime} from "./course-runtime.mjs";
import {buildCourseCatalogue, findCanonicalDescriptor, lessonCard, requireCanonicalDescriptor, requirePackAuthorizedAction, retrieveLessonPrimer, retrievePackPrimer} from "./local-retrieval.mjs";
import {
  lessonFacts, MAX_NOTE_LENGTH, MAX_NOTES_PER_CALL, MemoryRejection, noteLearner, takeToolCallSession,
} from "./memory.mjs";
import {CallaMemoryGraph} from "./calla-memory-graph.mjs";
import {LessonStateStore} from "./lesson-state.mjs";
import {PedagogyStore, pedagogyAudit} from "./pedagogy.mjs";

/// A rectangle of the observed window, each side a fraction of it.
///
/// The one shape a model is allowed to send about where something is. It can
/// place a drawing and narrow a capture; it can never place an action.
const normalizedRegionSchema = {
  type: "object",
  additionalProperties: false,
  required: ["left", "top", "width", "height"],
  properties: {
    left: {type: "number", minimum: 0, maximum: 1},
    top: {type: "number", minimum: 0, maximum: 1},
    width: {type: "number", exclusiveMinimum: 0, maximum: 1},
    height: {type: "number", exclusiveMinimum: 0, maximum: 1},
  },
};

/// Which applications this lesson is allowed to look at.
///
/// Without this the Mac falls back to its built-in default and only Blender can
/// ever be taught, which defeats the point of a path that needs no authored
/// pack. The Mac still requires one of these to be the focused window; naming an
/// application here grants no access to it.
const allowedBundleIDsProperty = {
  allowed_bundle_ids: {
    type: "array",
    items: {type: "string", minLength: 1, maxLength: 255},
    maxItems: 8,
    description: "Bundle ids this lesson may observe, e.g. [\"org.blenderfoundation.blender\"].",
  },
};

const definitions = {
  tutor_observe: {
    label: "Tutor Observe",
    description: [
      "Look at the learner's focused window. Returns the focused allowlisted window as an",
      "in-memory JPEG bound to a snapshot_id; never a display capture.",
      "",
      "Set region to crop. A whole window is the most expensive thing you can ask for, so",
      "on a step check send the region you just guided rather than the window.",
      "",
      "The capture reaches you as an image only when this is called as an ordinary tool.",
      "From inside an exec cell it comes back as base64 in a JSON string, which you cannot",
      "see. If you cannot see the window, say so; never measure a region off metadata.",
    ].join(" "),
    parameters: {
      type: "object",
      additionalProperties: false,
      required: [],
      properties: {
        ...allowedBundleIDsProperty,
        requested_fields: {type: "array", items: {type: "string"}, maxItems: 32},
        include_capture: {type: "boolean", default: false},
        region: {
          ...normalizedRegionSchema,
          description: "Capture only this part of the window, normalized to it.",
        },
        // Not a coordinate: one scalar bound on the longest side of the JPEG.
        // Named to avoid `width`/`height`, which the coordinate guard rejects
        // anywhere in a payload.
        long_edge: {
          type: "integer",
          minimum: 512,
          maximum: 2048,
          description: "Longest edge of the returned image in pixels. Smaller is cheaper and faster.",
        },
      },
    },
  },
  tutor_plan: {
    label: "Tutor Plan",
    description: [
      "The lesson's steps, in order, each with the region you measured for it. Titles come",
      "from the lesson; do not write new ones. Send it once at the start, and again only",
      "when the screen turns out different from what the lesson expected — keeping the",
      "steps already done, and correcting only what is ahead.",
    ].join(" "),
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["steps"],
      properties: {
        goal: {type: "string", minLength: 1, maxLength: 160, description: "A compact, non-sensitive lesson goal. Never a screen title, document name, or path."},
        steps: {
          type: "array",
          minItems: 2,
          maxItems: 12,
          description: "The lesson's steps in order. Give each one its region and words so the tooltip can show the route.",
          items: {
            anyOf: [
              {type: "string", minLength: 1, maxLength: 60},
              {
                type: "object",
                additionalProperties: false,
                required: ["title"],
                properties: {
                  title: {type: "string", minLength: 1, maxLength: 60},
                  region: {...normalizedRegionSchema, description: "Where this step's control is. Required together with text."},
                  text: {type: "string", minLength: 1, maxLength: 240, description: "The one instruction for this step. Required together with region."},
                },
              },
            ],
          },
        },
        index: {type: "integer", minimum: 0, description: "Which step the lesson is on now."},
        snapshot_id: {
          type: "string",
          minLength: 1,
          description: "The observation the regions were measured against. Required if any step carries a region.",
        },
        lesson_id: {type: "string", minLength: 1, description: "The installed lesson these steps come from."},
      },
    },
  },
  tutor_guide: {
    label: "Tutor Guide",
    description: [
      "Point at a region of the window you just observed and say what to do there. The text",
      "appears in a tooltip beside the control; prefer this over saying anything in chat.",
      "",
      "Keep region tight — a few percent per side lands on a button, a quarter of the window",
      "lands on nothing. One instruction, under about 140 characters. This never clicks: ask",
      "the learner to do it. End your turn here.",
    ].join(" "),
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["snapshot_id", "region", "text"],
      properties: {
        ...allowedBundleIDsProperty,
        snapshot_id: {type: "string", minLength: 1},
        region: normalizedRegionSchema,
        text: {type: "string", minLength: 1, maxLength: 240, description: "One instruction, in the learner's words."},
        status: {type: "string", maxLength: 80},
        step_index: {type: "integer", minimum: 0, description: "Which step of the lesson this is, counting from zero."},
        wait_for_change: {
          type: "boolean",
          default: false,
          description: "For an application the Mac cannot read locally. Off by default.",
        },
        timeout_seconds: {type: "number", minimum: 1, maximum: 25, default: 15},
      },
    },
  },
  tutor_narrate: {
    label: "Tutor Narrate",
    description: "Re-word the tooltip without moving the cursor. Use it to answer an [aside] question, or to add a beat about the control you already pointed at.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["text"],
      properties: {
        step: {type: "string", maxLength: 60},
        text: {type: "string", minLength: 1, maxLength: 240},
        status: {type: "string", maxLength: 80},
        thinking: {type: "boolean", default: false},
      },
    },
  },
  tutor_point: {
    label: "Tutor Point",
    description: "Point at a canonical App-Pack target_descriptor, resolved locally on the Mac. target_hint.region is a search prior only, never authority.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["target_descriptor", "snapshot_id"],
      properties: {
        target_descriptor: {type: "object"},
        snapshot_id: {type: "string", minLength: 1},
        target_hint: {
          type: "object",
          additionalProperties: false,
          required: ["region"],
          properties: {region: normalizedRegionSchema},
        },
        label: {type: "string", maxLength: 120},
      },
    },
  },
  tutor_propose_action: {
    label: "Tutor Propose Action",
    description: "Propose one bounded semantic action on a canonical target_descriptor with a canonical expected_state detector. Refuses target_hint and raw coordinates; the Mac requires local evidence and one-shot approval.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["action", "target_descriptor", "snapshot_id", "expected_state", "rationale"],
      properties: {
        action: {enum: ["move_cursor", "click", "scroll", "keyboard_shortcut", "type_text"]},
        target_descriptor: {type: "object"},
        snapshot_id: {type: "string", minLength: 1},
        expected_state: {type: "object"},
        rationale: {type: "string", minLength: 1, maxLength: 500},
        value: {type: "string", maxLength: 2000},
      },
    },
  },
  tutor_remember: {
    label: "Tutor Remember",
    description: [
      "At the end of a lesson, keep what would save time next time: how this person likes to",
      "be taught (scope \"learner\"), or where a named control turned out to be in one",
      "application (scope \"application\", with its bundle_id). This is the only thing that",
      "outlives the lesson.",
      "",
      "Never record what was on the screen — no window titles, file names, or paths. Notes",
      "carrying them are refused.",
    ].join(" "),
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["scope", "notes"],
      properties: {
        scope: {enum: ["learner", "application"]},
        bundle_id: {
          type: "string",
          minLength: 1,
          maxLength: 127,
          description: "Required for scope \"application\": the application these notes are about.",
        },
        notes: {
          type: "array",
          minItems: 1,
          maxItems: MAX_NOTES_PER_CALL,
          items: {type: "string", minLength: 1, maxLength: MAX_NOTE_LENGTH},
          description: "Short sentences about teaching, not about what was on screen.",
        },
      },
    },
  },
  tutor_verify: {
    label: "Tutor Verify",
    description: "Evaluate a canonical detector_descriptor against a freshly locally resolved canonical target_descriptor.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["target_descriptor", "detector_descriptor", "snapshot_id"],
      properties: {
        target_descriptor: {type: "object"},
        detector_descriptor: {type: "object"},
        snapshot_id: {type: "string", minLength: 1},
      },
    },
  },
};

function jsonResult(payload) {
  return {
    content: [{type: "text", text: JSON.stringify(payload, null, 2)}],
    details: payload,
  };
}

/**
 * An observation the model can actually look at.
 *
 * The window JPEG has to reach the model as an image block. Serialised into the
 * JSON text it is both invisible to vision and megabytes of base64 in the
 * transcript, which is why asking for a capture used to accomplish nothing. The
 * base64 is lifted out of the text half entirely and sent once, as an image.
 */
function observationResult(result) {
  // A guide result nests its fresh look under next_observation.
  if (result?.next_observation?.capture || result?.payload?.next_observation?.capture) {
    const holder = result.next_observation ? result : result.payload;
    const nested = observationResult(holder.next_observation);
    const {capture, ...rest} = holder.next_observation;
    const summary = {...result};
    if (result.next_observation) summary.next_observation = {...rest, capture: undefined};
    return {...nested, details: summary,
            content: [{type: "text", text: JSON.stringify(summary, null, 2)},
                      nested.content.find((block) => block.type === "image")].filter(Boolean)};
  }
  // One unwrap may leave either the host's payload or its whole response,
  // depending on how the node transport framed it, so find the capture either
  // way rather than guessing.
  const holder = result?.capture ? result : result?.payload?.capture ? result.payload : null;
  const capture = holder?.capture;
  if (typeof capture?.base64 !== "string") return jsonResult(result);
  const {base64, ...captureMetadata} = capture;
  const redacted = {...holder, capture: {...captureMetadata, delivered_as: "image_content_block"}};
  const summary = holder === result ? redacted : {...result, payload: redacted};
  return {
    content: [
      {type: "text", text: JSON.stringify(summary, null, 2)},
      {type: "image", data: base64, mimeType: capture.mime_type || "image/jpeg"},
    ],
    details: summary,
  };
}

async function verifyCompletion(api, config, sessionID, snapshotID, lesson, phase) {
  const scored = lesson?.[phase];
  const targetID = scored?.pass?.target;
  const detectorID = scored?.pass?.detector;
  if (!config.nodeId || typeof snapshotID !== "string" || !targetID || !detectorID) return {verdict: "unknown", verification_ms: 0};
  const [target, detector] = await Promise.all([
    findCanonicalDescriptor(config, targetID, "ui_target"),
    findCanonicalDescriptor(config, detectorID, "detector"),
  ]);
  if (!target || !detector) return {verdict: "unknown", verification_ms: 0};
  const started = Date.now();
  try {
    const envelope = buildTutorEnvelope("tutor_verify", {
      session_id: sessionID, snapshot_id: snapshotID,
      target_descriptor: target, detector_descriptor: detector,
    });
    const response = unwrapNodePayload(await api.runtime.nodes.invoke({nodeId: config.nodeId, command: "tutor.host", params: envelope, timeoutMs: 2_000}));
    const payload = response?.payload ?? response;
    return {
      verdict: payload?.outcome === "satisfied" ? "pass" : payload?.outcome === "unsatisfied" ? "fail" : "unknown",
      verification_ms: Date.now() - started,
    };
  } catch {
    return {verdict: "unknown", verification_ms: Date.now() - started};
  }
}

function recordLearning(api, config, sessionID, lessonID, bundleID, succeeded, delayedReview) {
  if (!config.nodeId || !lessonID || !bundleID) return;
  const envelope = buildInternalLearningEnvelope(sessionID, {
    lesson_id: lessonID, bundle_id: bundleID, succeeded, delayed_review: delayedReview,
  });
  // Persistence is owner-local and must never hold the feedback lane.
  void api.runtime.nodes.invoke({nodeId: config.nodeId, command: "tutor.host", params: envelope, timeoutMs: 2_000}).catch(() => {});
}

/// Tell the Mac what it may offer.
///
/// The Mac cannot ask: retrieval never leaves the Gateway, and the Gateway
/// invokes the node rather than the other way round. So this is a push, on the
/// same fire-and-forget footing as a learning record — a menu that is one
/// restart out of date is a far smaller problem than a startup that waits on a
/// node which may not be connected yet.
export async function pushCourseCatalogue(api, config) {
  if (!config.nodeId) return;
  try {
    const envelope = buildCatalogueEnvelope(await buildCourseCatalogue(config));
    void api.runtime.nodes.invoke({nodeId: config.nodeId, command: "tutor.host", params: envelope, timeoutMs: 2_000})
      .catch(() => {});
  } catch {
    // A malformed or absent index must not stop the plugin loading. The Mac
    // keeps whatever catalogue it cached last.
  }
}

/** Push cache on publish, Gateway start, and catalogue refresh. Cache miss is
 * safe: TutorHost falls back to its private course socket, never a model turn. */
export async function pushCourseRuntime(api, config) {
  if (!config.nodeId) return;
  try {
    const envelope = buildCourseRuntimeEnvelope(await buildCourseRuntime(config));
    void api.runtime.nodes.invoke({nodeId: config.nodeId, command: "tutor.host", params: envelope, timeoutMs: 2_000})
      .catch(() => {});
  } catch { /* Keep last atomic host cache. */ }
}

/// Lifecycle state travels independently from catalogue. A draft must never
/// become a learner-menu item merely because its authoring status changed.
export async function pushCourseStatus(api, config, courses) {
  if (!config.nodeId) return;
  try {
    const envelope = buildCourseStatusEnvelope(courses);
    void api.runtime.nodes.invoke({nodeId: config.nodeId, command: "tutor.host", params: envelope, timeoutMs: 2_000})
      .catch(() => {});
  } catch { /* Mac rehydrates its cached DTOs on next Settings open. */ }
}

export function createTutorTools(api, config, {
  lessonState = new LessonStateStore(config),
  memoryGraph = new CallaMemoryGraph(config),
  pedagogy = new PedagogyStore(),
} = {}) {
  return Object.entries(definitions).map(([name, definition]) => ({
    name,
    ...definition,
    async execute(toolCallId, params) {
      // Recorded by `before_tool_call`, which is the only place the lesson and
      // the call are both in scope. It is not a parameter, so the model can
      // neither supply it nor get it wrong.
      const session = takeToolCallSession(toolCallId);
      let envelope = buildTutorEnvelope(name, params, session);
      // Notes never leave the Gateway, the same way retrieval does not. The Mac
      // has no business storing what the Gateway remembered.
      if (name === "tutor_remember") {
        const {scope, bundle_id: bundleID, notes} = envelope.payload;
        const known = lessonFacts(envelope.session_id);
        const identifier = scope === "learner" ? known.learnerID : bundleID || known.bundleID;
        if (!identifier) {
          return jsonResult({
            status: "not_stored",
            reason: scope === "learner"
              ? "No learner is known for this lesson; observe once before remembering."
              : "scope application needs bundle_id.",
          });
        }
        try {
          const state = await lessonState.load(envelope.session_id);
          const stored = memoryGraph.remember(scope, identifier, notes, {packRevision: state.pack_revision, verified: true});
          await lessonState.end(envelope.session_id);
          return jsonResult({status: "ok", scope, ...stored});
        } catch (error) {
          if (error instanceof MemoryRejection) return jsonResult({status: "not_stored", reason: error.message});
          throw error;
        }
      }
      if (name === "tutor_point") {
        envelope.payload.target_descriptor = await requireCanonicalDescriptor(
          config, envelope.payload.target_descriptor, "ui_target", "target_descriptor");
      }
      if (name === "tutor_propose_action") {
        const target = await requireCanonicalDescriptor(
          config, envelope.payload.target_descriptor, "ui_target", "target_descriptor");
        const detector = await requireCanonicalDescriptor(
          config, envelope.payload.expected_state, "detector", "expected_state");
        await requirePackAuthorizedAction(config, envelope.payload.action, target, detector);
        envelope.payload.target_descriptor = target;
        envelope.payload.expected_state = detector;
      }
      if (name === "tutor_verify") {
        envelope.payload.target_descriptor = await requireCanonicalDescriptor(
          config, envelope.payload.target_descriptor, "ui_target", "target_descriptor");
        envelope.payload.detector_descriptor = await requireCanonicalDescriptor(
          config, envelope.payload.detector_descriptor, "detector", "detector_descriptor");
      }
      let invokedName = name;
      if (name === "tutor_plan") {
        const state = pedagogy.selectPlan(envelope.session_id, envelope.payload.lesson_id, envelope.payload.steps);
        if (Number.isInteger(state.held_step)) envelope.payload.index = state.held_step;
      }
      if (name === "tutor_guide") {
        const correction = pedagogy.guide(envelope.session_id, envelope.payload);
        envelope.payload.step_index = correction.step;
        if (correction.convertTransfer) {
          // Correct a failed transfer in place: no new target region and no
          // accidental advancement merely because the model reused a guide.
          envelope = buildTutorEnvelope("tutor_narrate", {
            step: envelope.payload.step,
            text: envelope.payload.text,
            status: envelope.payload.status,
            thinking: false,
          }, envelope.session_id);
          invokedName = "tutor_narrate";
        } else {
          // A guide must never pull a second full window into the same model turn.
          envelope.payload.capture_after_change = false;
        }
      }
      if (!config.nodeId) {
        throw new Error(
          "tutor is not configured: set plugins.entries.tutor.config.nodeId to the paired Mac node id",
        );
      }
      // Waiting for the learner is the one call that is meant to take a while,
      // so it gets a transport timeout longer than its own wait rather than
      // being cut off mid-wait by the default.
      const waitSeconds = invokedName === "tutor_await_change" ? Number(envelope.payload.timeout_seconds ?? 15) : 0;
      const timeoutMs = waitSeconds > 0
        ? Math.max(config.timeoutMs, Math.round(waitSeconds * 1000) + 5_000)
        : config.timeoutMs;
      const invoked = await api.runtime.nodes.invoke({
        nodeId: config.nodeId,
        command: "tutor.host",
        params: envelope,
        timeoutMs,
      });
      const result = unwrapNodePayload(invoked);
      // An observation is also where the Gateway finds out who it is teaching
      // and what — neither of which the model chooses, and neither of which
      // survives the lesson unless it is picked up here.
      const observed = result?.payload ?? result;
      if (name === "tutor_observe" && observed) {
        let lessons = [];
        noteLearner(envelope.session_id, {
          learnerID: observed.learner_id ?? process.env.CALLA_LEARNER,
          bundleID: observed.app_bundle_id,
        });
        await lessonState.observe(envelope.session_id, observed, envelope.payload.allowed_bundle_ids);
        if (typeof observed.app_bundle_id === "string" && typeof observed.app_version === "string") {
          const primer = await retrievePackPrimer(config, {bundle_id: observed.app_bundle_id, version: observed.app_version});
          lessons = await retrieveLessonPrimer(config, {bundle_id: observed.app_bundle_id, version: observed.app_version});
          pedagogy.retrieved(envelope.session_id, lessons);
          if (primer.length) observed.app_pack_context = {
            source: "gateway-local", instruction: "Use these exact descriptors verbatim; no retrieval tool call is needed.", results: primer,
          };
          // The lessons themselves are no longer attached here. They reached
          // the model as four whole entities on every single observation —
          // bulky, repeated, and too late to plan from. The one lesson being
          // taught is in the turn's context before any of this runs; retrieval
          // stays only to keep pedagogy's record of what is teachable.
          if (primer[0]) await lessonState.pack(envelope.session_id, `${primer[0].id}@installed`);
        }
        const completion = observed.completion ?? observed.pedagogy?.completion;
        if (completion && typeof completion === "object") {
          const state = pedagogy.completion(envelope.session_id, completion.verdict, {
            step: Number.isInteger(completion.step_index) ? completion.step_index : undefined,
            verificationMs: completion.verification_ms,
            dueReview: completion.due_review === true,
          });
          pedagogyAudit(config, {
            kind: "verdict", lesson_id: state.selectedLesson?.id, phase: state.phase, verdict: state.verdict,
            attempts: state.attempts[state.step], assistance_ceiling: state.phase === "retention" ? "explain" : "least-effective",
            transfer: state.phase === "transfer", retention: state.phase === "retention",
            verification_ms: completion.verification_ms,
            first_independent_success_ms: state.first_independent_success_at ? state.first_independent_success_at - state.started_at : null,
          });
        }
        if (observed.completion_pending === true && pedagogy.claimCompletion(envelope.session_id, observed.completion_id)) {
          const state = pedagogy.state(envelope.session_id);
          const verification = await verifyCompletion(api, config, envelope.session_id, observed.snapshot_id,
            state.selectedLesson, state.phase);
          const completed = pedagogy.completion(envelope.session_id, verification.verdict, {
            step: Number.isInteger(observed.step_index) ? observed.step_index : undefined,
            verificationMs: verification.verification_ms,
            dueReview: state.review.due,
          });
          observed.completion = {
            ...verification, step_index: completed.step, due_review: completed.phase === "retention",
          };
          const facts = lessonFacts(envelope.session_id);
          recordLearning(api, config, envelope.session_id, completed.selectedLesson?.id, facts.bundleID,
            completed.verdict === "pass", completed.phase === "retention");
          pedagogyAudit(config, {kind: "verdict", lesson_id: completed.selectedLesson?.id, phase: completed.phase,
            verdict: completed.verdict, attempts: completed.attempts[completed.step], verification_ms: verification.verification_ms,
            transfer: completed.phase === "transfer", retention: completed.phase === "retention"});
        }
        if (observed.learning?.due_review === true) {
          const dueLesson = observed.learning.lesson
            ?? lessons?.find((lesson) => lesson.entity?.id === observed.learning.lesson_id)?.entity;
          const due = pedagogy.reviewDue(envelope.session_id, dueLesson);
          if (due) observed.pedagogy_review = {phase: "retention", prompt: due.prompt, assistance_ceiling: "explain"};
        }
      }
      if (Number.isFinite(observed?.feedback_latency_ms)) {
        const state = pedagogy.state(envelope.session_id);
        pedagogyAudit(config, {kind: "feedback", lesson_id: state.selectedLesson?.id, phase: state.phase,
          verdict: state.verdict, attempts: state.attempts[state.step], feedback_latency_ms: observed.feedback_latency_ms});
      }
      if (name === "tutor_plan") await lessonState.plan(envelope.session_id, envelope.payload);
      if (name === "tutor_guide" && invokedName === "tutor_guide") await lessonState.guide(envelope.session_id, envelope.payload);
      if (observed?.status === "lesson_stopped" || observed?.code === "lesson_stopped") await lessonState.end(envelope.session_id);
      // guide comes back carrying the next observation, so it has an image in
      // it for exactly the same reason observe does.
      if (name === "tutor_observe") return observationResult(result);
      if (name === "tutor_guide") return observationResult(result);
      return jsonResult(result);
    },
  }));
}
