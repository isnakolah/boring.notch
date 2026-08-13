/**
 * Deterministic, capture-free lesson control.  This deliberately has no model
 * calls: the model teaches, while this store enforces attempts, phase, and the
 * assistance ceiling from evidence returned by TutorHost.
 */
import fs from "node:fs/promises";
import path from "node:path";

export const PEDAGOGY_SESSION_LIMIT = 32;
export const PEDAGOGY_PHASES = Object.freeze(["guided", "assessment", "transfer", "retention"]);

function now() { return Date.now(); }
function clone(value) { return JSON.parse(JSON.stringify(value)); }
function lessonItem(lesson, phase) { return lesson?.[phase] ?? null; }
function phaseForStep(state, step) {
  const count = state.plan.length;
  if (state.review?.due && state.selectedLesson?.retention) return "retention";
  if (count >= 2 && step === count - 1) return "transfer";
  if (count >= 2 && step === count - 2) return "assessment";
  return "guided";
}

export class PedagogyStore {
  constructor({limit = PEDAGOGY_SESSION_LIMIT, clock = now} = {}) {
    this.limit = limit;
    this.clock = clock;
    this.sessions = new Map();
  }

  state(sessionID) {
    if (!sessionID) return null;
    const existing = this.sessions.get(sessionID);
    if (existing) {
      this.sessions.delete(sessionID);
      this.sessions.set(sessionID, existing);
      return existing;
    }
    const next = {
      session_id: sessionID,
      retrieved_lessons: new Map(),
      selectedLesson: null,
      plan: [],
      step: 0,
      attempts: {},
      phase: "guided",
      verdict: "unknown",
      held_step: null,
      review: {due: false, recorded: false},
      deltas: [],
      started_at: this.clock(),
      first_independent_success_at: null,
      completion_ids: new Set(),
    };
    this.sessions.set(sessionID, next);
    while (this.sessions.size > this.limit) this.sessions.delete(this.sessions.keys().next().value);
    return next;
  }

  delta(sessionID, kind, detail = {}) {
    const state = this.state(sessionID);
    if (!state) return null;
    state.deltas.push({at: this.clock(), kind, ...detail});
    if (state.deltas.length > 12) state.deltas.shift();
    return state;
  }

  retrieved(sessionID, results) {
    const state = this.state(sessionID);
    for (const result of results || []) {
      const lesson = result?.entity ?? result;
      if (lesson?.kind === "lesson" && typeof lesson.id === "string") state.retrieved_lessons.set(lesson.id, clone(lesson));
    }
    return state;
  }

  selectPlan(sessionID, lessonID, steps) {
    const state = this.state(sessionID);
    if (lessonID !== undefined) {
      if (typeof lessonID !== "string" || !state.retrieved_lessons.has(lessonID)) {
        throw new TypeError("tutor_plan.lesson_id must match a lesson retrieved in this teaching session");
      }
      state.selectedLesson = state.retrieved_lessons.get(lessonID);
      state.review = {...state.review, due: false};
      this.delta(sessionID, "lesson_start", {lesson_id: lessonID});
    }
    state.plan = Array.isArray(steps) ? steps : [];
    state.step = Math.max(0, Math.min(Number.isInteger(state.held_step) ? state.held_step : 0, Math.max(state.plan.length - 1, 0)));
    state.phase = phaseForStep(state, state.step);
    return state;
  }

  reviewDue(sessionID, lesson) {
    const state = this.state(sessionID);
    if (lesson?.kind === "lesson") state.selectedLesson = clone(lesson);
    if (!state.selectedLesson?.retention) return null;
    state.review = {due: true, recorded: false};
    state.phase = "retention";
    this.delta(sessionID, "retention_due", {lesson_id: state.selectedLesson.id});
    return lessonItem(state.selectedLesson, "retention");
  }

  completion(sessionID, verdict, {step, verificationMs, dueReview = false} = {}) {
    const state = this.state(sessionID);
    const index = Number.isInteger(step) ? step : state.step;
    state.step = index;
    state.phase = dueReview ? "retention" : phaseForStep(state, index);
    state.verdict = ["pass", "fail", "unknown"].includes(verdict) ? verdict : "unknown";
    state.attempts[index] = (state.attempts[index] || 0) + 1;
    if (state.verdict === "fail") state.held_step = index;
    if (state.verdict === "pass") {
      state.held_step = null;
      if ((state.phase === "assessment" || state.phase === "transfer" || state.phase === "retention") && !state.first_independent_success_at) {
        state.first_independent_success_at = this.clock();
      }
      if (state.phase === "retention") state.review.recorded = true;
    }
    this.delta(sessionID, "verdict", {step: index, phase: state.phase, verdict: state.verdict, verification_ms: verificationMs ?? null});
    return state;
  }

  claimCompletion(sessionID, completionID) {
    const state = this.state(sessionID);
    const id = typeof completionID === "string" && completionID ? completionID : `implicit-${state.deltas.length}`;
    if (state.completion_ids.has(id)) return false;
    state.completion_ids.add(id);
    while (state.completion_ids.size > 8) state.completion_ids.delete(state.completion_ids.values().next().value);
    return true;
  }

  guide(sessionID, params) {
    const state = this.state(sessionID);
    const requested = Number.isInteger(params?.step_index) ? params.step_index : state.step;
    const step = Number.isInteger(state.held_step) ? state.held_step : requested;
    state.step = Math.max(0, step);
    state.phase = phaseForStep(state, state.step);
    const convertTransfer = state.phase === "transfer" && state.verdict === "fail";
    this.delta(sessionID, convertTransfer ? "transfer_corrected" : "guide", {step: state.step, phase: state.phase});
    return {state, step: state.step, convertTransfer};
  }

  context(sessionID) {
    const state = this.sessions.get(sessionID);
    if (!state || !state.selectedLesson) return null;
    const item = state.review.due ? lessonItem(state.selectedLesson, "retention") : lessonItem(state.selectedLesson, state.phase);
    return [
      "Calla pedagogy state (deterministic; do not expose it as a recipe):",
      `- lesson: ${state.selectedLesson.id}; phase: ${state.phase}; step: ${state.step}; verdict: ${state.verdict}`,
      `- assistance ceiling: ${state.phase === "retention" ? "explain" : state.verdict === "fail" ? "narrate correction" : "least effective assistance"}`,
      item?.prompt ? `- current scored prompt: ${item.prompt}` : null,
      state.held_step !== null ? `- hold step ${state.held_step}; correct it before advancing.` : null,
    ].filter(Boolean).join("\n");
  }
}

export function pedagogyAudit(config, event) {
  const safe = {
    at: new Date().toISOString(),
    lesson_id: typeof event.lesson_id === "string" ? event.lesson_id : null,
    kind: typeof event.kind === "string" ? event.kind : "event",
    phase: PEDAGOGY_PHASES.includes(event.phase) ? event.phase : null,
    verdict: ["pass", "fail", "unknown"].includes(event.verdict) ? event.verdict : null,
    attempts: Number.isInteger(event.attempts) ? event.attempts : null,
    assistance_ceiling: typeof event.assistance_ceiling === "string" ? event.assistance_ceiling : null,
    transfer: event.transfer === true,
    retention: event.retention === true,
    verification_ms: Number.isFinite(event.verification_ms) ? event.verification_ms : null,
    feedback_latency_ms: Number.isFinite(event.feedback_latency_ms) ? event.feedback_latency_ms : null,
    first_independent_success_ms: Number.isFinite(event.first_independent_success_ms) ? event.first_independent_success_ms : null,
  };
  const file = path.join(config.stateDirectory, "audit", "pedagogy.jsonl");
  // Intentionally fire-and-forget: learner feedback must not wait for telemetry.
  void fs.mkdir(path.dirname(file), {recursive: true, mode: 0o700})
    .then(() => fs.appendFile(file, `${JSON.stringify(safe)}\n`, {mode: 0o600}))
    .catch(() => {});
}
