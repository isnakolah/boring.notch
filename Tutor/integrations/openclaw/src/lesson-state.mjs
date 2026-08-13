/**
 * Minimal, short-lived recovery state for one Calla lesson.
 *
 * This is deliberately not a transcript cache. It contains only stable lesson
 * identity and a non-reversible snapshot fingerprint; window titles, document
 * names, paths, capture bytes, regions, and guide text never reach this file.
 */
import {createHash} from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

export const LESSON_IDLE_MS = 30 * 60 * 1000;
export const CONTEXT_COMPACTION_TOKENS = 90_000;
const SESSION_ID = /^[A-Za-z0-9-]{8,128}$/;
const BUNDLE_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,126}$/;

function hash(value) {
  return createHash("sha256").update(String(value)).digest("hex").slice(0, 24);
}

function now() { return Date.now(); }

function statePath(config, sessionID) {
  if (!SESSION_ID.test(sessionID || "")) throw new TypeError("lesson session id must be opaque letters, digits, or hyphens");
  return path.join(config.stateDirectory, "lessons", `${hash(sessionID)}.json`);
}

function cleanApplication(observation, requested = []) {
  const bundleID = typeof observation?.app_bundle_id === "string" && BUNDLE_ID.test(observation.app_bundle_id)
    ? observation.app_bundle_id : null;
  const version = typeof observation?.app_version === "string" && observation.app_version.length <= 80
    ? observation.app_version : null;
  const allowed = Array.isArray(requested) ? requested.filter((item) => BUNDLE_ID.test(item)).slice(0, 8) : [];
  return {bundle_id: bundleID, version, allowed_bundle_ids: allowed};
}

function safeGoal(value) {
  if (typeof value !== "string") return null;
  const goal = value.trim().replace(/\s+/g, " ");
  if (!goal || goal.length > 160) return null;
  if (/[/\\]|\.[A-Za-z0-9]{1,5}\b|["“”]|\b(?:screenshot|capture|transcript|window|document|untitled)\b/i.test(goal)) return null;
  return goal;
}

function emptyState(sessionID) {
  const timestamp = now();
  return {
    format: "calla-lesson-state",
    format_version: 1,
    lesson_id: sessionID,
    cache_key: `calla-lesson:${sessionID}`,
    goal: null,
    application: {bundle_id: null, version: null, allowed_bundle_ids: []},
    pack_revision: null,
    plan: {revision: null, steps: 0, current_step: 0, locally_advanceable: 0},
    snapshot_fingerprint: null,
    recovery_summary: null,
    compactions: 0,
    created_at: timestamp,
    updated_at: timestamp,
  };
}

function safeState(value, sessionID) {
  if (!value || value.format !== "calla-lesson-state" || value.lesson_id !== sessionID) return emptyState(sessionID);
  return {...emptyState(sessionID), ...value, application: {...emptyState(sessionID).application, ...value.application}, plan: {...emptyState(sessionID).plan, ...value.plan}};
}

export class LessonStateStore {
  constructor(config, {clock = now} = {}) {
    this.config = config;
    this.clock = clock;
  }

  async cleanup() {
    const directory = path.join(this.config.stateDirectory, "lessons");
    let names = [];
    try { names = await fs.readdir(directory); } catch (error) { if (error?.code === "ENOENT") return 0; throw error; }
    let removed = 0;
    for (const name of names) {
      if (!/^[a-f0-9]{24}\.json$/.test(name)) continue;
      const file = path.join(directory, name);
      try {
        const value = JSON.parse(await fs.readFile(file, "utf8"));
        if (this.clock() - Number(value.updated_at || 0) > LESSON_IDLE_MS) {
          await fs.unlink(file); removed += 1;
        }
      } catch { await fs.unlink(file).catch(() => {}); }
    }
    return removed;
  }

  async load(sessionID) {
    const file = statePath(this.config, sessionID);
    try { return safeState(JSON.parse(await fs.readFile(file, "utf8")), sessionID); }
    catch (error) { if (error?.code === "ENOENT") return emptyState(sessionID); throw error; }
  }

  async save(state) {
    const file = statePath(this.config, state.lesson_id);
    const directory = path.dirname(file);
    await fs.mkdir(directory, {recursive: true, mode: 0o700});
    const next = {...state, updated_at: this.clock()};
    const temporary = path.join(directory, `.${path.basename(file)}.${process.pid}.${Date.now()}`);
    await fs.writeFile(temporary, `${JSON.stringify(next)}\n`, {mode: 0o600});
    await fs.rename(temporary, file);
    return next;
  }

  async update(sessionID, change) {
    await this.cleanup();
    const state = await this.load(sessionID);
    return this.save({...state, ...change});
  }

  async observe(sessionID, observation, requested) {
    const application = cleanApplication(observation, requested);
    return this.update(sessionID, {
      application,
      // The receipt is opaque, but still never persisted verbatim. It lets us
      // detect that recovery belongs to the same observation without retaining
      // any visual content or a reusable host capability.
      snapshot_fingerprint: typeof observation?.snapshot_id === "string" ? hash(observation.snapshot_id) : null,
    });
  }

  async plan(sessionID, payload) {
    const steps = Array.isArray(payload?.steps) ? payload.steps : [];
    const locallyAdvanceable = steps.filter((step) => step && typeof step === "object" && step.region && step.text).length;
    // Hash only: neither instructional wording nor UI labels enter lesson state.
    const state = await this.load(sessionID);
    return this.save({...state, goal: safeGoal(payload?.goal) ?? state.goal, plan: {
      revision: hash(JSON.stringify(steps)), steps: steps.length,
      current_step: Math.max(0, Math.min(Number(payload?.index) || 0, Math.max(steps.length - 1, 0))),
      locally_advanceable: locallyAdvanceable,
    }});
  }

  async guide(sessionID, payload) {
    const state = await this.load(sessionID);
    const index = Number.isInteger(payload?.step_index) ? payload.step_index : state.plan.current_step;
    return this.save({...state, plan: {...state.plan, current_step: Math.max(0, Math.min(index, Math.max(state.plan.steps - 1, 0)))}});
  }

  async pack(sessionID, revision) {
    return this.update(sessionID, {pack_revision: typeof revision === "string" && revision.length <= 160 ? revision : null});
  }

  async compact(sessionID, usage = {}) {
    const state = await this.load(sessionID);
    const used = Number(usage.contextUsedTokens ?? usage.input ?? usage.total ?? 0);
    if (used < CONTEXT_COMPACTION_TOKENS && !usage.force) return state;
    const summary = [
      `Lesson recovery: app=${state.application.bundle_id || "unknown"} ${state.application.version || ""}`.trim(),
      `goal=${state.goal || "unknown"}`,
      `plan=${state.plan.steps} current_step=${state.plan.current_step} local_steps=${state.plan.locally_advanceable}`,
      `snapshot=${state.snapshot_fingerprint || "none"} pack=${state.pack_revision || "none"}`,
      "Do not replay prior images. Continue from this state; ask for one targeted crop only when a mismatch needs visual evidence.",
    ].join("\n");
    return this.save({...state, recovery_summary: summary.slice(0, 700), compactions: state.compactions + 1});
  }

  async context(sessionID) {
    const state = await this.load(sessionID);
    if (!state.snapshot_fingerprint && !state.plan.steps) return null;
    return state.recovery_summary || [
      "Active Calla lesson state (not screen content):",
      `- application: ${state.application.bundle_id || "unknown"} ${state.application.version || ""}`.trim(),
      `- goal: ${state.goal || "unknown"}`,
      `- plan: ${state.plan.steps} steps; current step ${state.plan.current_step}; ${state.plan.locally_advanceable} locally advanceable`,
      "- preserve this lesson session and cache key; do not replay prior captures.",
    ].join("\n");
  }

  async end(sessionID) { await fs.unlink(statePath(this.config, sessionID)).catch(() => {}); }
}
