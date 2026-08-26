import {randomUUID} from "node:crypto";
import {spawn} from "node:child_process";
import fs from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import {fileURLToPath} from "node:url";

const REGISTRY_FORMAT = "calla-course-registry";
const REGISTRY_VERSION = 1;
const PHASES = new Set([
  "queued", "compiling", "validating", "waiting_for_blender", "preflighting", "publishing",
  "ready_for_review", "published", "failed", "cancelled", "archived",
]);
const ACTIVE_PHASES = new Set(["queued", "compiling", "validating", "waiting_for_blender", "preflighting", "publishing"]);
const TERMINAL_PHASES = new Set(["published", "failed", "cancelled", "archived"]);
const MAX_OUTLINE_BYTES = 96 * 1024;
const MAX_THREAD_ENTRIES = 40;
const MAX_THREAD_TEXT = 240;
const TUTOR_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const TUTOR_TOOLING_ROOT = process.env.CALLA_TOOLING_ROOT || path.join(TUTOR_ROOT, "migrations", "tools");

function now() { return new Date().toISOString(); }
function safeID(value, name = "course_id") {
  if (typeof value !== "string" || !/^[a-z0-9][a-z0-9-]{7,80}$/i.test(value)) {
    throw new TypeError(`${name} must be an opaque identifier`);
  }
  return value;
}

/** No compiler errors, paths, prompts, captures, or terminal output leave here. */
export function sanitizeCourseText(value, fallback = "Course preparation failed.") {
  if (typeof value !== "string") return fallback;
  const text = value.replace(/[\r\n\t]+/g, " ").replace(/(?:https?:\/\/[^ ]+|~\/[^ ]+|\/[^ ]+)/g, "[redacted]")
    .replace(/\s+/g, " ").trim();
  return text ? Array.from(text).slice(0, MAX_THREAD_TEXT).join("") : fallback;
}

function publicJob(job) {
  const elapsed = Math.max(0, Date.now() - Date.parse(job.updated_at || job.created_at || now()));
  return {
    id: job.id, revision: job.revision, phase: job.phase, title: job.title || "Untitled course",
    target_app: job.target_app || null, target_version: job.target_version || null,
    lesson_count: Number.isSafeInteger(job.lesson_count) ? job.lesson_count : 0,
    warnings: Array.isArray(job.warnings) ? job.warnings.map((value) => sanitizeCourseText(value)).slice(0, 8) : [],
    error: job.error ? sanitizeCourseText(job.error) : null,
    created_at: job.created_at, updated_at: job.updated_at, elapsed_ms: elapsed,
    archived: job.phase === "archived", published: job.phase === "published",
    source_revision: job.source_revision || null,
    next_action: job.phase === "waiting_for_blender" ? "Install and open Blender 5.2, then retry."
      : job.phase === "failed" ? "Fix reported course or asset bundle and retry."
      : job.phase === "ready_for_review" ? "Review validation and preflight facts, then publish."
      : job.phase === "published" ? "Ready to start from Courses."
      : null,
  };
}

function runPython(script, args, signal) {
  return new Promise((resolve, reject) => {
    const child = spawn("/usr/bin/python3", [script, ...args], {stdio: ["ignore", "pipe", "pipe"]});
    let stdout = ""; let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    const abort = () => child.kill("SIGTERM");
    signal?.addEventListener("abort", abort, {once: true});
    child.once("error", reject);
    child.once("close", (code) => {
      signal?.removeEventListener("abort", abort);
      if (signal?.aborted) return reject(new Error("course preparation cancelled"));
      if (code !== 0) return reject(new Error(stderr || "course compiler failed"));
      resolve(stdout);
    });
  });
}

async function atomicJSON(file, value) {
  await fs.mkdir(path.dirname(file), {recursive: true, mode: 0o700});
  const temp = path.join(path.dirname(file), `.${path.basename(file)}.${randomUUID()}`);
  await fs.writeFile(temp, `${JSON.stringify(value)}\n`, {mode: 0o600});
  await fs.rename(temp, file);
}

/**
 * OpenClaw TaskFlow persists owner-scoped work but intentionally does not run
 * callbacks. The lifecycle service runs its Gateway-local worker and mirrors
 * compact state through this supported bound runtime.
 */
export class CourseTaskFlowBridge {
  constructor(runtime, sessionKey = "agent:calla:course-control") {
    this.flow = runtime?.taskFlow?.bindSession?.({sessionKey}) || null;
  }
  state(job) { return JSON.stringify({course_id: job.id, revision: job.revision, phase: job.phase}); }
  create(job) {
    if (!this.flow || job.task_flow_id) return;
    const flow = this.flow.createManaged({controllerId: "calla-course-control", status: "running", notifyPolicy: "silent", goal: `Prepare course ${job.id}`, currentStep: job.phase, stateJson: this.state(job)});
    job.task_flow_id = flow.flowId; job.task_flow_revision = flow.revision;
  }
  update(job, terminal = null) {
    if (!this.flow || !job.task_flow_id) return;
    const input = {flowId: job.task_flow_id, expectedRevision: job.task_flow_revision, stateJson: this.state(job), currentStep: job.phase};
    const result = terminal === "finish" ? this.flow.finish(input)
      : terminal === "fail" ? this.flow.fail(input)
      : terminal === "cancel" ? this.flow.requestCancel(input)
      : this.flow.resume({...input, status: "running"});
    if (result?.applied && result.flow) job.task_flow_revision = result.flow.revision;
  }
}

/**
 * Owner-only durable course registry. Sources stay in per-revision files; this
 * registry is intentionally a compact status catalogue, never agent history.
 */
export class CourseLifecycleService {
  constructor(config, {onChange = () => {}, prepare = null, preflight = null, install = null, taskFlow = null} = {}) {
    this.directory = path.join(config.stateDirectory, "courses");
    this.registryFile = path.join(this.directory, "registry.json");
    this.sourceDirectory = path.join(this.directory, "sources");
    this.artifactDirectory = path.join(this.directory, "artifacts");
    this.onChange = onChange;
    this.prepare = prepare;
    this.preflight = preflight;
    this.install = install;
    this.taskFlow = taskFlow;
    this.registry = null;
    this.running = new Map();
  }

  async load() {
    if (this.registry) return this.registry;
    try {
      const parsed = JSON.parse(await fs.readFile(this.registryFile, "utf8"));
      if (parsed?.format !== REGISTRY_FORMAT || parsed.format_version !== REGISTRY_VERSION || !Array.isArray(parsed.jobs)) throw new TypeError("invalid registry");
      this.registry = parsed;
    } catch (error) {
      if (error?.code !== "ENOENT" && !(error instanceof SyntaxError) && !(error instanceof TypeError)) throw error;
      this.registry = {format: REGISTRY_FORMAT, format_version: REGISTRY_VERSION, jobs: []};
    }
    // Gateway restart does not silently lose in-flight authoring. A task can be
    // resumed by owner, but stale execution cannot publish after a restart.
    let changed = false;
    for (const job of this.registry.jobs) {
      if (ACTIVE_PHASES.has(job.phase)) {
        job.phase = "queued"; job.error = null; job.updated_at = now(); changed = true;
      }
    }
    if (changed) await this.persist();
    return this.registry;
  }

  async persist() { await atomicJSON(this.registryFile, this.registry); }
  async list() { await this.load(); return this.registry.jobs.map(publicJob).sort((a, b) => b.updated_at.localeCompare(a.updated_at)); }
  async status(id) { return (await this.list()).find((job) => job.id === safeID(id)) || null; }

  async import({outline, asset_bundle = null, target_app = null, target_version = null, target_frontmost = false, target_allowlisted = false, title = null} = {}) {
    if (typeof outline !== "string" || !outline.trim()) throw new TypeError("outline must not be empty");
    if (Buffer.byteLength(outline, "utf8") > MAX_OUTLINE_BYTES) throw new TypeError("outline exceeds 96 KiB");
    if (!target_app || typeof target_version !== "string" || target_frontmost !== true || target_allowlisted !== true) {
      throw new TypeError("an allowlisted frontmost target application is required");
    }
    if (typeof asset_bundle !== "string" || !asset_bundle.endsWith(".zip")) throw new TypeError("a preverified course asset bundle is required");
    await this.load();
    const id = `course-${randomUUID()}`;
    const created_at = now();
    const job = {id, revision: 1, phase: "queued", created_at, updated_at: created_at,
      title: typeof title === "string" && title.trim() ? sanitizeCourseText(title, "Untitled course") : "Untitled course",
      target_app: typeof target_app === "string" ? target_app : null, target_version: typeof target_version === "string" ? target_version : null,
      lesson_count: 0, warnings: [], error: null, source_revision: 1, course_key: id, superseded_by: null, asset_bundle};
    this.registry.jobs.push(job);
    await fs.mkdir(this.sourceDirectory, {recursive: true, mode: 0o700});
    await atomicJSON(path.join(this.sourceDirectory, `${id}-r1.json`), {format: "calla-course-source", format_version: 1, outline, target_app, target_version});
    await this.persist(); await this.changed();
    void this.start(id);
    return publicJob(job);
  }

  async command(command, payload = {}) {
    if (command === "refresh-runtime") {
      await this.changed();
      return {status: "refreshing"};
    }
    const id = payload.course_id ? safeID(payload.course_id) : null;
    switch (command) {
      case "import": return this.import(payload);
      case "list": return {courses: await this.list()};
      case "status": return {course: id ? await this.status(id) : null};
      case "start": case "resume": return this.start(id, payload);
      case "restart": return this.restart(id);
      case "cancel": return this.cancel(id);
      case "retry": return this.retry(id);
      case "edit-as-new-revision": return this.revise(id, payload);
      case "publish": return this.publish(id);
      case "archive": return this.archive(id);
      case "restore": return this.restore(id);
      default: throw new TypeError("unsupported course command");
    }
  }

  find(id) { const job = this.registry.jobs.find((item) => item.id === id); if (!job) throw new TypeError("course not found"); return job; }
  async set(job, phase, extra = {}) {
    if (!PHASES.has(phase)) throw new TypeError("invalid course phase");
    Object.assign(job, extra, {phase, updated_at: now()});
    this.taskFlow?.update(job, phase === "published" ? "finish" : phase === "failed" ? "fail" : phase === "cancelled" ? "cancel" : null);
    await this.persist(); await this.changed(); return publicJob(job);
  }
  async cancel(id) { const job = this.find(id); if (!ACTIVE_PHASES.has(job.phase)) throw new TypeError("only active courses can be cancelled"); this.running.get(id)?.abort?.(); return this.set(job, "cancelled", {error: null}); }
  async retry(id) { const job = this.find(id); if (!["failed", "cancelled", "waiting_for_blender"].includes(job.phase)) throw new TypeError("course cannot be retried"); await this.set(job, "queued", {error: null}); void this.start(id); return publicJob(job); }
  async revise(id, payload) {
    const old = this.find(id); if (!["published", "archived", "failed", "cancelled"].includes(old.phase)) throw new TypeError("course is not ready for a new revision");
    const source = payload.outline;
    if (typeof source !== "string" || !source.trim()) throw new TypeError("outline must not be empty");
    const revision = old.revision + 1;
    const created = await this.import({outline: source, asset_bundle: payload.asset_bundle || old.asset_bundle, target_app: payload.target_app || old.target_app, target_version: payload.target_version || old.target_version, target_frontmost: true, target_allowlisted: true, title: payload.title || old.title});
    const job = this.find(created.id);
    job.revision = revision; job.source_revision = 1; job.course_key = old.course_key || old.id;
    old.superseded_by = job.id;
    await this.persist(); await this.changed(); return publicJob(job);
  }
  async archive(id) { const job = this.find(id); if (job.phase !== "published") throw new TypeError("only published courses can be archived"); return this.set(job, "archived"); }
  async restore(id) { const job = this.find(id); if (job.phase !== "archived") throw new TypeError("only archived courses can be restored"); return this.set(job, "published"); }
  async restart(id) { const job = this.find(id); if (job.phase !== "published") throw new TypeError("only published courses can restart"); return publicJob(job); }

  async start(id) {
    await this.load(); const job = this.find(id);
    if (!["queued", "failed", "cancelled"].includes(job.phase)) return publicJob(job);
    if (this.running.has(id)) return publicJob(job);
    const controller = new AbortController(); this.running.set(id, controller);
    const revision = job.revision;
    try {
      this.taskFlow?.create(job); await this.persist();
      await this.set(job, "compiling", {error: null});
      const result = await this.prepareRevision(job, controller.signal);
      if (controller.signal.aborted || job.revision !== revision || job.phase === "cancelled") return publicJob(job);
      await this.set(job, "validating");
      // Preparation output is deliberately an internal boundary. It can expose
      // only reviewed summary fields, never a tool trace or filesystem path.
      if (!result || !Number.isSafeInteger(result.lesson_count) || result.lesson_count < 1) throw new Error("Compiler produced no lessons");
      if (Array.isArray(result.warnings) && result.warnings.length) throw new Error("course compiler returned warnings");
      await this.set(job, "waiting_for_blender");
      await this.set(job, "preflighting");
      await this.preflightRevision(job, result, controller.signal);
      if (controller.signal.aborted || job.revision !== revision || job.phase === "cancelled") return publicJob(job);
      await this.set(job, "ready_for_review", {title: sanitizeCourseText(result.title || job.title, "Untitled course"), lesson_count: result.lesson_count,
        warnings: [], artifact: result.artifact || null, pack_id: typeof result.pack_id === "string" ? result.pack_id : null});
    } catch (error) {
      if (!controller.signal.aborted && job.revision === revision && job.phase !== "cancelled") await this.set(job, "failed", {error: sanitizeCourseText(error instanceof Error ? error.message : String(error))});
    } finally { this.running.delete(id); }
    return publicJob(job);
  }

  async prepareRevision(job, signal) {
    if (this.prepare) return this.prepare(job, signal);
    const source = path.join(this.sourceDirectory, `${job.id}-r${job.source_revision}.json`);
    const artifact = path.join(this.artifactDirectory, `${job.id}-r${job.revision}.otpack`);
    await fs.mkdir(this.artifactDirectory, {recursive: true, mode: 0o700});
    const output = await runPython(path.join(TUTOR_TOOLING_ROOT, "calla_course_compiler.py"), ["--source", source, "--artifact", artifact, "--course-key", job.course_key || job.id, "--asset-bundle", job.asset_bundle], signal);
    const result = JSON.parse(output);
    return {...result, artifact};
  }

  async preflightRevision(job, result, signal) {
    if (this.preflight) return this.preflight(job, result, signal);
    // Compiler already validates each scene's hash and packs them. Runtime hosts
    // can inject an actual Blender 5.2 probe; absence must fail closed there.
    if (!result?.artifact || signal?.aborted) throw new Error("Blender preflight did not complete");
  }
  async publish(id) {
    await this.load();
    const job = this.find(id);
    if (job.phase !== "ready_for_review") throw new TypeError("only a reviewed-ready course can publish");
    if (!job.artifact) throw new TypeError("review-ready course has no exact artifact");
    const revision = job.revision;
    await this.set(job, "publishing");
    try {
      if (this.install) await this.install(job);
      else await runPython(path.join(TUTOR_TOOLING_ROOT, "calla_pack_store.py"), [job.artifact, "--state-directory", path.dirname(this.directory)]);
      if (job.revision !== revision || job.phase !== "publishing") throw new Error("course changed while publishing");
      return await this.set(job, "published", {error: null});
    } catch (error) {
      // Artifact stays reviewable. A failed install never replaces a prior
      // published pointer and never makes an unreviewed revision learner-live.
      return await this.set(job, "ready_for_review", {error: sanitizeCourseText(error instanceof Error ? error.message : String(error))});
    }
  }
  async changed() { await this.onChange(await this.list()); }
  async resumePending() {
    await this.load();
    for (const job of this.registry.jobs) if (job.phase === "queued") void this.start(job.id);
  }
}

/** Versioned JSON over owner-mode local Unix socket. No HTTP surface. */
export class CourseControlServer {
  constructor(service, socketPath) { this.service = service; this.socketPath = socketPath; this.server = null; }
  async start() {
    await fs.mkdir(path.dirname(this.socketPath), {recursive: true, mode: 0o700});
    try { await fs.unlink(this.socketPath); } catch (error) { if (error?.code !== "ENOENT") throw error; }
    this.server = net.createServer({allowHalfOpen: true}, async (socket) => {
      let input = ""; socket.setEncoding("utf8");
      socket.on("data", (chunk) => { input += chunk; if (Buffer.byteLength(input) > 128 * 1024) socket.destroy(); });
      socket.on("end", async () => {
        try {
          const request = JSON.parse(input); if (request?.version !== 1 || typeof request.command !== "string") throw new TypeError("invalid course request");
          socket.end(`${JSON.stringify({ok: true, result: await this.service.command(request.command, request.payload || {})})}\n`);
        } catch (error) { socket.end(`${JSON.stringify({ok: false, error: sanitizeCourseText(error instanceof Error ? error.message : String(error))})}\n`); }
      });
    });
    await new Promise((resolve, reject) => this.server.once("error", reject).listen(this.socketPath, () => resolve()));
    await fs.chmod(this.socketPath, 0o600);
  }
  async stop() { if (!this.server) return; await new Promise((resolve) => this.server.close(resolve)); this.server = null; try { await fs.unlink(this.socketPath); } catch {} }
}
