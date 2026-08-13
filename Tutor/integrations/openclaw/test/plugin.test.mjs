import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import fs from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import plugin from "../index.mjs";
import {
  appendNotes, MAX_NOTES_PER_FILE, MemoryRejection, readNotes, recallContext, takeToolCallSession,
} from "../src/memory.mjs";
import {handleTutorNodeHostCommand, invokeTutorHost} from "../src/node-host.mjs";
import {createBeforeToolCallPolicy} from "../src/policy.mjs";
import {buildCatalogueEnvelope, buildCourseRuntimeEnvelope, buildCourseStatusEnvelope, buildSessionStartEnvelope, buildTutorEnvelope, findForbiddenCoordinatePath, parsePluginConfig, TUTOR_TOOL_NAMES, validateNodeEnvelope, unwrapNodePayload} from "../src/protocol.mjs";

test("internal session_start accepts v2 fallback and compatible v3 range", () => {
  const handshake = buildSessionStartEnvelope({engineBuild: "boring-1", nodeContractHash: "contract-1"});
  assert.equal(handshake.protocol_version, 2);
  assert.equal(handshake.operation, "session_start");
  assert.doesNotThrow(() => validateNodeEnvelope({...handshake, protocol_version: 3}));
  assert.throws(() => validateNodeEnvelope({...handshake, protocol_version: 4}), /supported range/);
});

test("stable Gateway agent workspace is accepted as Calla-owned configuration", () => {
  const config = parsePluginConfig({
    role: "gateway",
    agentWorkspace: "~/.openclaw/apps/calla-tutor/current/agent-workspace",
  });
  assert.equal(config.agentWorkspace, path.join(os.homedir(), ".openclaw/apps/calla-tutor/current/agent-workspace"));
});
import {buildCourseRuntime} from "../src/course-runtime.mjs";
import {buildCourseCatalogue, lessonCard, retrieveLocalPacks} from "../src/local-retrieval.mjs";
import {CourseControlServer, CourseLifecycleService, CourseTaskFlowBridge, sanitizeCourseText} from "../src/course-lifecycle.mjs";
import {CallaMemoryGraph, FACT_RETENTION_DAYS} from "../src/calla-memory-graph.mjs";
import {LessonStateStore} from "../src/lesson-state.mjs";
import {PedagogyStore, PEDAGOGY_SESSION_LIMIT} from "../src/pedagogy.mjs";
import {TEACHING_PHRASE_REGISTRY} from "../src/teaching.mjs";

const TEST_STATE_DIRECTORY = path.join(os.tmpdir(), `calla-plugin-test-${process.pid}`);
test.after(async () => { await fs.rm(TEST_STATE_DIRECTORY, {recursive: true, force: true}); });
const courseAssets = Object.freeze([
  {asset_id: "fixture-starter", role: "starter", sha256: "a".repeat(64), bytes: 1},
  {asset_id: "fixture-proof", role: "proof", sha256: "b".repeat(64), bytes: 1},
]);

test("course lifecycle auto-publishes only after compile and Blender preflight", async () => {
  const stateDirectory = path.join(TEST_STATE_DIRECTORY, "courses-lifecycle");
  const service = new CourseLifecycleService({stateDirectory}, {
    prepare: async () => ({title: "Blender basics", lesson_count: 2, warnings: [], artifact: "staged"}), preflight: async () => {},
    install: async () => {},
  });
  const created = await service.import({outline: "course outline", asset_bundle: "fixture.zip", target_app: "org.blenderfoundation.blender", target_version: "5.2", target_frontmost: true, target_allowlisted: true});
  assert.equal(created.phase, "queued");
  // Import intentionally starts asynchronously: no menu install happens here.
  await new Promise((resolve) => setTimeout(resolve, 15));
  const published = await service.status(created.id);
  assert.equal(published.phase, "published");
  assert.equal(published.lesson_count, 2);
  await service.archive(created.id);
  assert.equal((await service.status(created.id)).phase, "archived");
  await service.restore(created.id);
  assert.equal((await service.status(created.id)).phase, "published");
});

test("course publish command is refused because strict lifecycle owns publication", async () => {
  const stateDirectory = path.join(TEST_STATE_DIRECTORY, "courses-stale-revision");
  const service = new CourseLifecycleService({stateDirectory}, {
    prepare: async () => ({title: "Blender basics", lesson_count: 1, warnings: [], artifact: "staged"}), preflight: async () => {}, install: async () => {},
  });
  const first = await service.import({outline: "first", asset_bundle: "fixture.zip", target_app: "org.blenderfoundation.blender", target_version: "5.2", target_frontmost: true, target_allowlisted: true});
  await new Promise((resolve) => setTimeout(resolve, 10));
  await assert.rejects(() => service.publish(first.id), /publish automatically/);
});

test("course control is owner-mode versioned JSON and rejects un-attested targets", async () => {
  const stateDirectory = path.join(TEST_STATE_DIRECTORY, "course-socket");
  await fs.mkdir(stateDirectory, {recursive: true, mode: 0o700});
  await fs.chmod(stateDirectory, 0o700);
  const service = new CourseLifecycleService({stateDirectory}, {prepare: async () => ({title: "Draft", lesson_count: 1, artifact: "staged"})});
  // macOS caps Unix-domain socket paths at 104 bytes. Keep this test's socket
  // near /tmp while state still exercises restrictive nested directories.
  const socketPath = path.join(os.tmpdir(), `calla-${process.pid}.sock`);
  const server = new CourseControlServer(service, socketPath);
  await server.start();
  assert.equal((await fs.stat(stateDirectory)).mode & 0o777, 0o700);
  assert.equal((await fs.stat(socketPath)).mode & 0o777, 0o600);
  const reply = await new Promise((resolve, reject) => {
    const client = net.createConnection(socketPath); let body = "";
    client.on("data", (chunk) => { body += chunk; }); client.once("error", reject);
    client.once("end", () => resolve(JSON.parse(body)));
    client.end(JSON.stringify({version: 1, command: "import", payload: {outline: "x", target_app: "org.blenderfoundation.blender", target_version: "5.2"}}));
  });
  assert.equal(reply.ok, false);
  assert.match(reply.error, /allowlisted frontmost/);
  await server.stop();
});

test("supported bound TaskFlow receives compact durable course state", () => {
  const calls = [];
  const bridge = new CourseTaskFlowBridge({taskFlow: {bindSession: ({sessionKey}) => ({
    createManaged: (input) => { calls.push(["create", sessionKey, input]); return {flowId: "flow-1", revision: 1}; },
    resume: (input) => { calls.push(["resume", input]); return {applied: true, flow: {revision: 2}}; },
  })}});
  const job = {id: "course-12345678", revision: 1, phase: "queued"};
  bridge.create(job); bridge.update(job);
  assert.equal(calls[0][0], "create");
  assert.equal(calls[0][1], "agent:calla:course-control");
  assert.equal(calls[0][2].stateJson, '{"course_id":"course-12345678","revision":1,"phase":"queued"}');
  assert.equal(job.task_flow_revision, 2);
});

test("course lifecycle resumes safely after restart and sanitizes authoring faults", async () => {
  const stateDirectory = path.join(TEST_STATE_DIRECTORY, "courses-restart");
  const first = new CourseLifecycleService({stateDirectory}, {prepare: async () => new Promise(() => {})});
  const created = await first.import({outline: "course outline", asset_bundle: "fixture.zip", target_app: "org.blenderfoundation.blender", target_version: "5.2", target_frontmost: true, target_allowlisted: true});
  await new Promise((resolve) => setTimeout(resolve, 5));
  const restarted = new CourseLifecycleService({stateDirectory});
  assert.equal((await restarted.status(created.id)).phase, "queued");
  assert.equal(sanitizeCourseText("compiler failed at /secret/path with https://example.test/token"), "compiler failed at [redacted] with [redacted]");
});

test("cancelled or stale course preparation cannot later become reviewable", async () => {
  const stateDirectory = path.join(TEST_STATE_DIRECTORY, "courses-cancel");
  let finish;
  const service = new CourseLifecycleService({stateDirectory}, {
    prepare: async () => await new Promise((resolve) => { finish = resolve; }),
  });
  const created = await service.import({outline: "course outline", asset_bundle: "fixture.zip", target_app: "org.blenderfoundation.blender", target_version: "5.2", target_frontmost: true, target_allowlisted: true});
  await new Promise((resolve) => setTimeout(resolve, 5));
  await service.cancel(created.id);
  finish({title: "must not publish", lesson_count: 1, artifact: "staged"});
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.equal((await service.status(created.id)).phase, "cancelled");
});

test("course-status ingress is bounded and has no coordinate authority", () => {
  const envelope = buildCourseStatusEnvelope([{id: "course-12345678", title: "Draft", phase: "compiling", error: null}]);
  assert.equal(envelope.operation, "course_status");
  assert.throws(() => buildCourseStatusEnvelope([{id: "course-12345678", title: "Draft", phase: "compiling", left: 1}]), /coordinate/);
});

test("course runtime is revision-pinned descriptor-only fast route", async () => {
  const stateDirectory = path.join(TEST_STATE_DIRECTORY, "course-runtime");
  await fs.mkdir(path.join(stateDirectory, "indexes"), {recursive: true});
  const lesson = {
    id: "blender.lesson.fast", kind: "lesson", title: "Fast Bevel",
    assets: courseAssets,
    steps: [{id: "open", instruction: "Open Modifiers.", target: targetDescriptor.id, success: {detector: detectorDescriptor.id}}],
    assessment: {prompt: "Do it again.", pass: {target: targetDescriptor.id, detector: detectorDescriptor.id}},
    transfer: {prompt: "Use another mesh.", pass: {target: targetDescriptor.id, detector: detectorDescriptor.id}},
  };
  await fs.writeFile(path.join(stateDirectory, "indexes", "fast.json"), JSON.stringify({
    format: "calla-local-pack-index", format_version: 1,
    pack: {id: "org.calla.fast", pack_version: "7.2.1", apps: [{platform: "macos", bundle_ids: ["org.blenderfoundation.blender"], versions: ">=5.2 <5.3"}]},
    entities: [targetDescriptor, detectorDescriptor, lesson, {id: "blender.course.fast", kind: "course", title: "Fast", lessons: [lesson.id]}],
  }), "utf8");
  const runtime = await buildCourseRuntime({stateDirectory});
  assert.equal(runtime.format, "calla-course-runtime");
  const course = runtime.courses[0];
  assert.equal(course.course_revision, "org.calla.fast@7.2.1");
  assert.deepEqual(course.lessons[0].steps.map((step) => step.phase), ["guided", "assessment", "transfer"]);
  const wire = JSON.stringify(runtime);
  assert.ok(!wire.includes("screenshot"));
  assert.ok(!wire.includes("transcript"));
  assert.equal(buildCourseRuntimeEnvelope(runtime).operation, "course_runtime");
  await fs.rm(stateDirectory, {recursive: true, force: true});
});

test("a course route carries why a step fails, and refuses an explanation it cannot check", async () => {
  const stateDirectory = path.join(TEST_STATE_DIRECTORY, "course-runtime-diagnosis");
  await fs.mkdir(path.join(stateDirectory, "indexes"), {recursive: true});
  const wrongTurn = {...detectorDescriptor, id: "blender.detector.mode_is_edit", title: "Blender is in Edit Mode"};
  const lesson = {
    id: "blender.lesson.diagnosed", kind: "lesson", title: "Diagnosed",
    assets: courseAssets,
    teaching_policy: {escalation: ["explain", "highlight", "point"]},
    prerequisites: [{detector: detectorDescriptor.id, say: "This lesson needs a mesh selected."}],
    steps: [{id: "open", instruction: "Open Modifiers.", target: targetDescriptor.id,
             success: {detector: detectorDescriptor.id},
             diagnose: [
               {when: wrongTurn.id, say: "You are in Edit Mode. Press Tab first."},
               // Names a detector this pack does not ship: dropped rather than
               // shipped as an explanation the Mac would have to take on trust.
               {when: "blender.detector.invented", say: "Never said."},
             ]}],
    assessment: {prompt: "Again.", pass: {target: targetDescriptor.id, detector: detectorDescriptor.id}},
    transfer: {prompt: "Elsewhere.", pass: {target: targetDescriptor.id, detector: detectorDescriptor.id}},
  };
  await fs.writeFile(path.join(stateDirectory, "indexes", "diagnosed.json"), JSON.stringify({
    format: "calla-local-pack-index", format_version: 1,
    pack: {id: "org.calla.diagnosed", pack_version: "1.0.0", apps: [{platform: "macos", bundle_ids: ["org.blenderfoundation.blender"], versions: ">=5.2 <5.3"}]},
    entities: [targetDescriptor, detectorDescriptor, wrongTurn, lesson,
               {id: "blender.course.diagnosed", kind: "course", title: "Diagnosed", lessons: [lesson.id]}],
  }), "utf8");
  const runtime = await buildCourseRuntime({stateDirectory});
  const route = runtime.courses[0].lessons[0];
  assert.deepEqual(route.escalation, ["explain", "highlight", "point"]);
  assert.equal(route.prerequisites.length, 1);
  assert.equal(route.prerequisites[0].when.kind, "detector");
  assert.equal(route.prerequisites[0].say, "This lesson needs a mesh selected.");
  const diagnose = route.steps[0].diagnose;
  assert.equal(diagnose.length, 1, "an unresolvable diagnosis must not ship");
  assert.equal(diagnose[0].when.id, wrongTurn.id);
  // And the whole thing still survives the ingress guard it will be sent through.
  assert.equal(buildCourseRuntimeEnvelope(runtime).operation, "course_runtime");
  await fs.rm(stateDirectory, {recursive: true, force: true});
});

test("a diagnosis reaching the Mac must be a real detector and a bounded sentence", () => {
  const route = (diagnose) => ({
    format: "calla-course-runtime", format_version: 1,
    courses: [{course_id: "c", course_revision: "p@1", app_bundle_id: "b", app_version: "1",
               lessons: [{id: "l", title: "L", assets: courseAssets, steps: [{text: "t", phase: "guided",
                                                        target_descriptor: targetDescriptor, diagnose}]}]}],
  });
  assert.equal(buildCourseRuntimeEnvelope(route([{when: detectorDescriptor, say: "ok"}])).operation, "course_runtime");
  // A sentence with nothing behind it is the failure mode worth refusing: the
  // learner believes an explanation whether or not anything checked it.
  assert.throws(() => buildCourseRuntimeEnvelope(route([{say: "trust me"}])), /diagnosis is malformed/);
  assert.throws(() => buildCourseRuntimeEnvelope(route([{when: targetDescriptor, say: "ok"}])), /diagnosis is malformed/);
  assert.throws(() => buildCourseRuntimeEnvelope(route([{when: detectorDescriptor, say: "x".repeat(241)}])), /diagnosis is malformed/);
});

const targetDescriptor = Object.freeze({
  id: "blender.ui.properties.modifiers_tab",
  kind: "ui_target",
  title: "Modifier Properties tab",
  aliases: ["Modifiers", "wrench icon", "Modifier Properties"],
  app_versions: ">=5.2 <5.3",
  source_refs: ["blender-manual"],
  region: "blender.ui.properties_editor",
  resolve: {
    accessibility: {
      candidates: [
        {role: "AXRadioButton", label_matcher: {pattern: "modifier", case_insensitive: true}},
        {role: "AXButton", description_matcher: {pattern: "modifier", case_insensitive: true}},
      ],
    },
    bridge: {selector: {editor_type: "PROPERTIES", context: "MODIFIER"}},
    visual: {icon: "wrench", relative_to: "properties_editor.vertical_context_tabs", constraints: ["visible", "enabled"]},
  },
  neighbor_constraints: {expected: ["object_data", "particles"]},
  minimum_confidence: {point: 0.72, act: 0.92},
  source_file: "ui/modifiers_tab.yaml",
});

const detectorDescriptor = Object.freeze({
  id: "blender.detector.properties_context_is_modifier",
  kind: "detector",
  title: "Modifier Properties context is open",
  app_versions: ">=5.2 <5.3",
  source_refs: ["open-tutor-authored"],
  provider: "accessibility",
  query: {target: "blender.ui.properties.modifiers_tab", attribute: "selected", equals: true},
  source_file: "detectors/core.yaml",
});

function actionLesson() {
  return {
    id: "blender.lesson.bevel_basics",
    kind: "lesson",
    title: "Bevel Basics",
    steps: [{
      target: targetDescriptor.id,
      allowed_assistance: [{action: "click", target: targetDescriptor.id}],
      success: {detector: detectorDescriptor.id},
    }],
  };
}

async function writeDescriptorIndex(stateDirectory) {
  await fs.mkdir(path.join(stateDirectory, "indexes"));
  await fs.writeFile(
    path.join(stateDirectory, "indexes", "blender.json"),
    JSON.stringify({
      format: "calla-local-pack-index",
      format_version: 1,
      pack: {
        id: "org.calla.tutor.blender",
        pack_version: "0.3.0",
        apps: [{platform: "macos", bundle_ids: ["org.blenderfoundation.blender"], versions: ">=5.2 <5.3", locales: ["en"]}],
      },
      entities: [targetDescriptor, detectorDescriptor, actionLesson()],
    }),
    "utf8",
  );
}

function fakeApi(overrides = {}) {
  const registrations = {
    tools: [],
    hooks: new Map(),
    nodeCommands: [],
    nodePolicies: [],
    commands: [],
  };
  const api = {
    pluginConfig: {
      nodeId: "paired-mac",
      requireOwnerIdentity: true,
      stateDirectory: TEST_STATE_DIRECTORY,
      ...overrides.pluginConfig,
    },
    runtime: {
      nodes: {
        invoke:
          overrides.invoke ??
          (async (request) => ({payload: {ok: true, echoed_operation: request.params.operation}})),
      },
    },
    registerTool(tool) {
      registrations.tools.push(tool);
    },
    on(name, handler) {
      registrations.hooks.set(name, handler);
    },
    registerNodeHostCommand(command) {
      registrations.nodeCommands.push(command);
    },
    registerNodeInvokePolicy(policy) {
      registrations.nodePolicies.push(policy);
    },
    registerCommand(command) {
      registrations.commands.push(command);
    },
  };
  return {api, registrations};
}


test("gateway role registers semantic tools and policy without a Mac node handler", () => {
  const {api, registrations} = fakeApi();
  plugin.register(api);
  assert.deepEqual(
    registrations.tools.map((tool) => tool.name).sort(),
    [
      // Eight, not ten. `tutor_retrieve` was bypassed in practice — the primer
      // is injected as context — and `tutor_await_change` was forbidden by the
      // prompt while still costing tool-schema tokens on every request.
      "tutor_guide",
      "tutor_narrate",
      "tutor_observe",
      "tutor_plan",
      "tutor_point",
      "tutor_propose_action",
      "tutor_remember",
      "tutor_verify",
    ],
  );
  assert.equal(registrations.nodeCommands.length, 0);
  assert.deepEqual(registrations.nodePolicies[0].defaultPlatforms, ["macos"]);
  assert.equal(typeof registrations.hooks.get("before_tool_call"), "function");
  // Memory kept from earlier lessons has to be put back in front of the model,
  // now that a lesson's own transcript no longer carries anything across.
  assert.equal(typeof registrations.hooks.get("before_prompt_build"), "function");

  // Every registered tool must be one the manifest declares, or it exists and
  // the agent cannot call it.
  const manifest = JSON.parse(readFileSync(new URL("../openclaw.plugin.json", import.meta.url), "utf8"));
  assert.deepEqual(registrations.tools.map((tool) => tool.name).sort(),
                   [...manifest.contracts.tools].sort());
});

test("the teaching contract rides on the tool descriptions", () => {
  // Command prompt guidance did not reach the model in practice: it answered
  // from memory with a written recipe while holding every tutor tool. Tool
  // descriptions are always sent, so the contract lives there too.
  const {api, registrations} = fakeApi();
  plugin.register(api);
  const observe = registrations.tools.find((t) => t.name === "tutor_observe");
  const guide = registrations.tools.find((t) => t.name === "tutor_guide");
  // The loop itself moved to the cached prefix. What has to stay here is the
  // part that is about this tool and cannot be inferred: that a crop is the
  // cheap path, and that a capture read from inside an exec cell is invisible.
  assert.match(observe.description, /a crop|Set region to crop/);
  assert.match(observe.description, /exec cell/);
  assert.match(guide.description, /prefer this over saying anything in chat/);
  assert.match(guide.description, /End your turn here/);
  assert.doesNotMatch(guide.description, /Leave wait_for_change/);
  // The descriptions are a per-request cost, so they are kept short on purpose.
  const total = registrations.tools.reduce((sum, tool) => sum + tool.description.length, 0);
  assert.ok(total < 4_000, `tool descriptions stay compact, got ${total} characters`);
});

test("the teaching loop has no generic entry", () => {
  const {api, registrations} = fakeApi();
  plugin.register(api);
  const teach = registrations.commands.find((command) => command.name === "teach");
  assert.equal(teach, undefined, "course-only Calla exposes no generic /teach");
  assert.equal(new Set(TEACHING_PHRASE_REGISTRY).size, TEACHING_PHRASE_REGISTRY.length, "teaching phrases have one canonical spelling");
});

test("before_prompt_build applies the teaching contract only to Calla", async () => {
  const {api, registrations} = fakeApi();
  plugin.register(api);
  const hook = registrations.hooks.get("before_prompt_build");
  assert.equal(await hook({}, {agentId: "main", sessionKey: "main-session"}), undefined);
  const calla = await hook({}, {agentId: "calla", sessionKey: "calla-session"});
  assert.match(calla.prependSystemContext, /is the route/);
});

test("Tutor tools use the active OpenClaw lesson id instead of a model-supplied id", async () => {
  const policy = createBeforeToolCallPolicy(parsePluginConfig({role: "gateway"}));
  // The hook validates and never edits. Rewriting the model's arguments here is
  // what made the Codex app-server refuse every tutor call once the tool surface
  // was exposed directly, so the session travels beside the call instead.
  const result = await policy(
    {toolCallId: "call-1", toolName: "tutor_observe", params: {include_capture: true}},
    {sessionId: "lesson-1234", sessionKey: "agent:calla:explicit:lesson-1234"},
  );
  assert.equal(result, undefined);
  assert.equal(takeToolCallSession("call-1"), "lesson-1234");
  // Read once and dropped, so a call that never executes cannot outlive its lesson.
  assert.equal(takeToolCallSession("call-1"), undefined);

  const missing = await policy(
    {toolName: "tutor_observe", params: {include_capture: true}},
    {sessionKey: "agent:calla:explicit:lesson-1234"},
  );
  assert.equal(missing.block, true);
  assert.match(missing.blockReason, /opaque OpenClaw lesson session id/);
});

test("node role exposes only the paired TutorHost command", () => {
  const {api, registrations} = fakeApi({pluginConfig: {role: "node", nodeId: ""}});
  plugin.register(api);
  assert.deepEqual(registrations.tools, []);
  assert.equal(registrations.hooks.size, 0);
  assert.deepEqual(registrations.nodePolicies, []);
  assert.equal(registrations.nodeCommands[0].command, "tutor.host");
  assert.equal(registrations.nodeCommands[0].dangerous, true);
});

test("both role requires explicit development mode", () => {
  assert.throws(() => parsePluginConfig({role: "both"}), /development-only/);
  assert.equal(parsePluginConfig({role: "both", developmentMode: true}).role, "both");
});

test("pedagogy keeps a 32-session LRU and only selects same-session lessons", () => {
  const pedagogy = new PedagogyStore();
  assert.throws(() => pedagogy.selectPlan("session-1234", "blender.lesson.bevel_basics", ["one", "two"]), /retrieved/);
  pedagogy.retrieved("session-1234", [{entity: {
    id: "blender.lesson.bevel_basics", kind: "lesson",
    assessment: {prompt: "assess", pass: {target: "blender.ui.properties.add_modifier_button", detector: "blender.detector.active_object_has_bevel_modifier"}},
    transfer: {prompt: "transfer", differs_by: "stack", pass: {target: "blender.ui.properties.add_modifier_button", detector: "blender.detector.bevel_precedes_subsurf"}},
    retention: {prompt: "retain", pass: {target: "blender.ui.properties.add_modifier_button", detector: "blender.detector.active_object_has_bevel_modifier"}},
  }}]);
  const selected = pedagogy.selectPlan("session-1234", "blender.lesson.bevel_basics", ["guided", "assessment", "transfer"]);
  assert.equal(selected.phase, "guided");
  pedagogy.completion("session-1234", "fail", {step: 2});
  const correction = pedagogy.guide("session-1234", {step_index: 2, text: "Try again."});
  assert.equal(correction.convertTransfer, true);
  assert.equal(correction.step, 2);
  for (let index = 0; index <= PEDAGOGY_SESSION_LIMIT; index += 1) pedagogy.state(`other-${index}-session`);
  assert.equal(pedagogy.sessions.size, PEDAGOGY_SESSION_LIMIT);
  assert.equal(pedagogy.sessions.has("session-1234"), false);
});


test("observe tool sends a semantic envelope through the configured paired node", async () => {
  const calls = [];
  const {api, registrations} = fakeApi({
    invoke: async (request) => {
      calls.push(request);
      return {payload: {ok: true, state: {mode: "OBJECT"}}};
    },
  });
  plugin.register(api);
  const tool = registrations.tools.find((candidate) => candidate.name === "tutor_observe");
  const result = await tool.execute("call-1", {
    session_id: "session-1234",
    requested_fields: ["mode", "active_object"],
    include_capture: true,
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].nodeId, "paired-mac");
  assert.equal(calls[0].command, "tutor.host");
  assert.equal(calls[0].params.operation, "observe");
  assert.equal(calls[0].params.session_id, "session-1234");
  assert.equal(calls[0].params.payload.include_capture, true);
  assert.equal(result.details.state.mode, "OBJECT");
});

test("a requested capture reaches the model as an image, not as base64 text", async () => {
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10]).toString("base64");
  const {api, registrations} = fakeApi({
    invoke: async () => ({
      payload: {
        status: "ok",
        snapshot_id: "snapshot-1",
        capture: {snapshot_id: "snapshot-1", mime_type: "image/jpeg", base64: jpeg},
      },
    }),
  });
  plugin.register(api);
  const tool = registrations.tools.find((candidate) => candidate.name === "tutor_observe");
  const result = await tool.execute("call-1", {session_id: "session-1234", include_capture: true});

  const image = result.content.find((block) => block.type === "image");
  assert.deepEqual(image, {type: "image", data: jpeg, mimeType: "image/jpeg"});
  const text = result.content.find((block) => block.type === "text").text;
  assert.ok(!text.includes(jpeg), "the base64 must not also be pasted into the text block");
  assert.equal(result.details.capture.delivered_as, "image_content_block");
  // `details` is what a model calling this from an exec cell is told to print,
  // because printing the whole result puts the JPEG into its own transcript as
  // text and gets truncated. That instruction is only safe while this holds.
  assert.ok(!JSON.stringify(result.details).includes(jpeg),
            "details must be safe to print: no base64 anywhere in it");
});

test("guide carries one normalized region and never a descriptor", async () => {
  const calls = [];
  const {api, registrations} = fakeApi({
    invoke: async (request) => {
      calls.push(request);
      return {payload: {status: "ok"}};
    },
  });
  plugin.register(api);
  const tool = registrations.tools.find((candidate) => candidate.name === "tutor_guide");
  await tool.execute("call-1", {
    session_id: "session-1234",
    snapshot_id: "snapshot-1",
    allowed_bundle_ids: ["com.figma.Desktop"],
    region: {left: 0.8, top: 0.2, width: 0.03, height: 0.03},
    step: "Step 1 of 3",
    text: "Open the Modifier Properties tab — the wrench icon.",
  });
  assert.equal(calls[0].params.operation, "guide");
  assert.deepEqual(calls[0].params.payload.region, {left: 0.8, top: 0.2, width: 0.03, height: 0.03});
  // The lesson names its own application; nothing here is Blender-specific.
  assert.deepEqual(calls[0].params.payload.allowed_bundle_ids, ["com.figma.Desktop"]);
  assert.equal(calls[0].params.payload.capture_after_change, false, "normal guides cannot trigger a replay capture");

  // A pixel rectangle wearing the region's clothes.
  assert.throws(
    () =>
      buildTutorEnvelope("tutor_guide", {
        session_id: "session-1234",
        snapshot_id: "snapshot-1",
        region: {left: 1420, top: 377, width: 24, height: 24},
        text: "click here",
      }),
    /must be in \[0,1\]/,
  );
  // Guiding is the pack-free path; a descriptor there would imply authority it
  // does not have.
  assert.throws(
    () =>
      buildTutorEnvelope("tutor_guide", {
        session_id: "session-1234",
        snapshot_id: "snapshot-1",
        region: {left: 0.1, top: 0.1, width: 0.1, height: 0.1},
        text: "click here",
        target_descriptor: targetDescriptor,
      }),
    /never carries a descriptor/,
  );
});

test("Tutor calls without a published lesson are blocked before approval", async () => {
  const {api, registrations} = fakeApi();
  plugin.register(api);
  const policy = registrations.hooks.get("before_tool_call");
  const requester = {senderIsOwner: true};

  const guide = await policy(
    {
      toolCallId: "guide-call",
      toolName: "tutor_guide",
      params: {
        snapshot_id: "snapshot-1",
        region: {left: 0.5, top: 0.5, width: 0.1, height: 0.1},
        text: "Look here.",
      },
    },
    {requester, sessionId: "session-1234"},
  );
  assert.equal(guide.block, true);
  assert.match(guide.blockReason, /published course/);

  const narrate = await policy(
    {toolName: "tutor_narrate", params: {session_id: "session-1234", text: "Still working that out."}},
    {requester, sessionId: "session-1234"},
  );
  assert.equal(narrate.block, true);

  const blocked = await policy(
    {
      toolName: "tutor_guide",
      params: {session_id: "session-1234", snapshot_id: "snapshot-1", region: {left: 0.5, top: 0.5, width: 0.9, height: 0.1}, text: "x"},
    },
    {requester, sessionId: "session-1234"},
  );
  assert.equal(blocked.block, true);
});

test("unconfigured plugin loads but tool execution explains the missing paired node", async () => {
  const {api, registrations} = fakeApi({pluginConfig: {nodeId: ""}});
  plugin.register(api);
  const tool = registrations.tools.find((candidate) => candidate.name === "tutor_observe");
  await assert.rejects(
    tool.execute("call-1", {session_id: "session-1234"}),
    /set plugins\.entries\.tutor\.config\.nodeId/,
  );
});

test("the course catalogue carries names and counts, and nothing that could teach", async () => {
  const stateDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "calla-catalogue-test-"));
  await fs.mkdir(path.join(stateDirectory, "indexes"));
  await fs.writeFile(
    path.join(stateDirectory, "indexes", "blender.json"),
    JSON.stringify({
      format: "calla-local-pack-index",
      format_version: 1,
      pack: {
        id: "org.calla.tutor.blender",
        pack_version: "0.3.0",
        apps: [{platform: "macos", bundle_ids: ["org.blenderfoundation.blender"], versions: ">=5.2 <5.3", locales: ["en"]}],
      },
      entities: [
        {
          id: "blender.course.modelling_basics", kind: "course", title: "Modelling basics",
          summary: "Change a mesh without destroying it.", icon: "cube.transparent",
          lessons: ["blender.lesson.bevel_basics", "blender.lesson.absent"],
        },
        {
          id: "blender.lesson.bevel_basics", kind: "lesson", title: "Add a Bevel modifier",
          text: "Long teaching prose that must not travel to the Mac.",
          steps: [{instruction: "Open the tab", target: "blender.ui.properties.modifiers_tab"}],
        },
        {id: "blender.detector.has_bevel", kind: "detector", title: "Has a Bevel modifier"},
      ],
    }),
    "utf8",
  );

  const catalogue = await buildCourseCatalogue({stateDirectory});
  assert.equal(catalogue.courses.length, 1);
  const [course] = catalogue.courses;
  assert.equal(course.title, "Modelling basics");
  assert.deepEqual(course.bundle_ids, ["org.blenderfoundation.blender"]);
  // A lesson the pack does not carry is dropped rather than listed: the
  // compiler refuses to build one, so an index containing it is older than the
  // rule and must not surface an entry that cannot be taught.
  assert.deepEqual(course.lessons, [{id: "blender.lesson.bevel_basics", title: "Add a Bevel modifier"}]);

  // Names and counts only. Steps, detectors and teaching prose stay on the
  // Gateway until a lesson actually starts.
  const wire = JSON.stringify(catalogue);
  assert.ok(!wire.includes("must not travel"), "lesson prose stays on the Gateway");
  assert.ok(!wire.includes("blender.detector."), "detectors stay on the Gateway");
  assert.ok(!wire.includes("modifiers_tab"), "targets stay on the Gateway");

  // And the envelope is an internal push, never a tool the model can reach.
  const envelope = buildCatalogueEnvelope(catalogue);
  assert.equal(envelope.operation, "catalogue");
  assert.ok(!TUTOR_TOOL_NAMES.includes("tutor_catalogue"), "the catalogue is not a model-visible tool");
  assert.throws(() => buildCatalogueEnvelope({courses: [{id: "x", title: "y", lessons: [{id: "a", title: "b", x: 12}]}]}),
                /coordinate field/);
});

test("retrieve reads a previously installed legacy App Pack on the gateway and never invokes the Mac", async () => {
  const stateDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "calla-retrieval-test-"));
  await fs.mkdir(path.join(stateDirectory, "indexes"));
  await fs.writeFile(
    path.join(stateDirectory, "indexes", "blender.json"),
    JSON.stringify({
      format: "calla-local-pack-index",
      format_version: 1,
      pack: {
        id: "org.open-desktop-tutor.blender",
        pack_version: "0.1.0",
        apps: [{platform: "macos", bundle_ids: ["org.blenderfoundation.blender"], versions: ">=5.2 <5.3", locales: ["en"]}],
      },
      entities: [{id: "blender.lesson.bevel_basics", kind: "lesson", title: "Bevel Basics", text: "Use the bevel modifier.", source_file: "lessons/bevel.yaml"}],
    }),
    "utf8",
  );
  let invokeCount = 0;
  const {api, registrations} = fakeApi({
    pluginConfig: {stateDirectory},
    invoke: async () => {
      invokeCount += 1;
      throw new Error("retrieve must not call the Mac node");
    },
  });
  try {
    plugin.register(api);
    const config = parsePluginConfig({stateDirectory});
    const result = await retrieveLocalPacks(config, {
      query: "bevel modifier",
      application: {bundle_id: "org.blenderfoundation.blender", version: "5.2.0", locale: "en"},
    });
    assert.equal(invokeCount, 0);
    assert.equal(result.source, "server-local");
    assert.deepEqual(result.results.map((item) => item.id), ["blender.lesson.bevel_basics"]);

    const incompatible = await retrieveLocalPacks(config, {
      query: "bevel",
      application: {bundle_id: "org.blenderfoundation.blender", version: "4.6"},
    });
    assert.deepEqual(incompatible.results, []);
  } finally {
    await fs.rm(stateDirectory, {recursive: true, force: true});
  }
});


test("protocol rejects coordinate-shaped authority", () => {
  assert.equal(findForbiddenCoordinatePath({target: {coordinates: [10, 20]}}), "target.coordinates");
  assert.throws(
    () =>
      buildTutorEnvelope("tutor_point", {
        session_id: "session-1234",
        target_descriptor: targetDescriptor,
        snapshot_id: "snapshot-1",
        x: 847,
        y: 291,
      }),
    /raw coordinate field x is forbidden/,
  );
});

test("a plan may carry one region per step, and a region nowhere else", () => {
  const region = {left: 0.1, top: 0.2, width: 0.05, height: 0.05};

  // The exemption exists so the Mac can point at a planned step without a model
  // round trip. Planning draws; it can never act.
  const planned = buildTutorEnvelope("tutor_plan", {
    session_id: "session-1234",
    snapshot_id: "snapshot-1",
    steps: ["Delete the cube", {title: "Add a bevel", region, text: "Click Add Modifier."}],
  });
  assert.equal(planned.payload.steps[1].region.left, 0.1);
  // A bare title still plans; it simply costs a turn when it comes around.
  assert.equal(planned.payload.steps[0], "Delete the cube");
  // Titles alone need no observation to hang off.
  assert.ok(buildTutorEnvelope("tutor_plan", {
    session_id: "session-1234", steps: ["Delete the cube", "Add a bevel"],
  }));
  // A region without one would be mapped onto whatever the Mac saw last.
  assert.throws(
    () => buildTutorEnvelope("tutor_plan", {
      session_id: "session-1234",
      steps: ["Delete the cube", {title: "Add a bevel", region, text: "Click Add Modifier."}],
    }),
    /snapshot_id must be a string/,
  );

  // The exemption is one named location, not a prefix and not a key name.
  assert.throws(
    () => buildTutorEnvelope("tutor_plan", {
      session_id: "session-1234",
      steps: ["Delete the cube", "Add a bevel"],
      region,
    }),
    /raw coordinate field region\.left is forbidden/,
  );
  assert.throws(
    () => buildTutorEnvelope("tutor_plan", {
      session_id: "session-1234",
      steps: ["Delete the cube", {title: "Add a bevel", region: {...region, x: 12}, text: "Click it."}],
    }),
    /steps\.1\.region must contain left, top, width, and height only/,
  );

  // A step that says something with nowhere to say it cannot be advanced
  // locally, and a region with no words would point in silence.
  assert.throws(
    () => buildTutorEnvelope("tutor_plan", {
      session_id: "session-1234",
      steps: ["Delete the cube", {title: "Add a bevel", region}],
    }),
    /steps\.1 needs region and text together/,
  );

  // A pixel rectangle dressed as a normalized one is still a pixel rectangle.
  assert.throws(
    () => buildTutorEnvelope("tutor_plan", {
      session_id: "session-1234",
      steps: ["Delete the cube",
              {title: "Add a bevel", region: {left: 1420, top: 377, width: 24, height: 24}, text: "x"}],
    }),
    /steps\.1\.region must be in \[0,1\]/,
  );
});

test("no exemption reaches an operation that can act", () => {
  const region = {left: 0.1, top: 0.2, width: 0.05, height: 0.05};
  // Whatever shape it arrives in, and wherever it sits, an action carries no
  // region. These are the calls that could move a real cursor.
  for (const [tool, params] of [
    ["tutor_propose_action", {
      action: "click", target_descriptor: targetDescriptor, snapshot_id: "snapshot-1",
      expected_state: detectorDescriptor, rationale: "because", region,
    }],
    ["tutor_verify", {
      target_descriptor: targetDescriptor, detector_descriptor: detectorDescriptor,
      snapshot_id: "snapshot-1", region,
    }],
    ["tutor_propose_action", {
      action: "click", target_descriptor: targetDescriptor, snapshot_id: "snapshot-1",
      expected_state: detectorDescriptor, rationale: "because",
      steps: [{title: "sneak", region, text: "x"}],
    }],
  ]) {
    assert.throws(
      () => buildTutorEnvelope(tool, {session_id: "session-1234", ...params}),
      /forbidden|never accepts/,
      `${tool} must refuse a region`,
    );
  }
});

test("memory refuses anything a learner would be surprised to read", async () => {
  const stateDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "calla-memory-test-"));
  const config = {stateDirectory};
  try {
    // What a note is for: teaching, not the screen.
    await appendNotes(config, "learner", "learner-abc123", [
      "Prefers keyboard shortcuts over menus.",
      "Already knows the basics; skip the tour.",
    ]);
    assert.deepEqual(await readNotes(config, "learner", "learner-abc123"), [
      "Prefers keyboard shortcuts over menus.",
      "Already knows the basics; skip the tour.",
    ]);

    // Everything the Mac deliberately keeps local stays local, even when the
    // model volunteers it.
    for (const [note, because] of [
      ["They were editing /Users/sam/taxes-2026", "a path"],
      ["The open file was budget.xlsx", "a file name"],
      ["Their window was titled “Q3 layoffs”", "a quoted title"],
      ["The screenshot showed a bank balance", "capture data"],
      ["They had Untitled 3 open", "a document name"],
      ["~/Desktop is where they keep it", "a home directory"],
    ]) {
      await assert.rejects(
        () => appendNotes(config, "learner", "learner-abc123", [note]),
        MemoryRejection,
        `must refuse ${because}`);
    }
    // A refusal refuses the whole call, so one bad note cannot smuggle itself
    // in beside good ones.
    assert.equal((await readNotes(config, "learner", "learner-abc123")).length, 2);

    // A bundle id is a file name here, so nothing that is not one may be used.
    for (const identifier of ["../../etc/passwd", "a/b", "", "."]) {
      await assert.rejects(
        () => appendNotes(config, "application", identifier, ["fine note"]),
        MemoryRejection);
    }

    // Bounded: a lesson cannot grow the next lesson's prompt without limit.
    for (let round = 0; round < 12; round += 1) {
      await appendNotes(config, "application", "org.blenderfoundation.blender",
                        Array.from({length: 5}, (_, i) => `Note ${round}-${i} about where a control sits.`));
    }
    const stored = await readNotes(config, "application", "org.blenderfoundation.blender");
    assert.equal(stored.length, MAX_NOTES_PER_FILE);
    // Oldest pruned, newest kept.
    assert.match(stored.at(-1), /Note 11-4/);
    await assert.rejects(
      () => appendNotes(config, "learner", "learner-abc123", ["a", "b", "c", "d", "e", "f"]),
      MemoryRejection);

    // Recall reaches the model as one block naming both scopes.
    const recalled = await recallContext(config, {
      learnerID: "learner-abc123", bundleID: "org.blenderfoundation.blender",
    });
    assert.match(recalled, /What you know about this learner/);
    assert.match(recalled, /Prefers keyboard shortcuts/);
    assert.match(recalled, /teaching org\.blenderfoundation\.blender/);
    // And says plainly that notes are memory, not observation.
    assert.match(recalled, /not what is\non screen now/);
    assert.equal(await recallContext(config, {learnerID: "learner-nothing"}), null);
  } finally {
    await fs.rm(stateDirectory, {recursive: true, force: true});
  }
});

test("Calla lesson state is transient, compact, and never persists screen data", async () => {
  const stateDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "calla-lesson-state-"));
  const store = new LessonStateStore({stateDirectory});
  try {
    await store.observe("lesson-1234", {
      app_bundle_id: "org.blenderfoundation.blender", app_version: "5.2.0",
      snapshot_id: "snapshot-private-123", capture: {base64: "SCREEN_BYTES", title: "Private file"},
    }, ["org.blenderfoundation.blender"]);
    await store.plan("lesson-1234", {goal: "Learn the modifier workflow", steps: ["first", {title: "second", text: "screen wording", region: {left: .1, top: .1, width: .1, height: .1}}]});
    const compacted = await store.compact("lesson-1234", {contextUsedTokens: 90_000});
    assert.equal(compacted.cache_key, "calla-lesson:lesson-1234");
    assert.equal(compacted.plan.steps, 2);
    assert.equal(compacted.plan.locally_advanceable, 1);
    assert.equal(compacted.goal, "Learn the modifier workflow");
    assert.ok(compacted.snapshot_fingerprint);
    const stored = await fs.readFile(path.join(stateDirectory, "lessons", (await fs.readdir(path.join(stateDirectory, "lessons")))[0]), "utf8");
    for (const forbidden of ["SCREEN_BYTES", "Private file", "snapshot-private-123", "screen wording"]) assert.doesNotMatch(stored, new RegExp(forbidden));
    assert.match((await store.context("lesson-1234")), /Do not replay prior images/);
    await store.end("lesson-1234");
    assert.equal((await fs.readdir(path.join(stateDirectory, "lessons"))).length, 0);
  } finally { await fs.rm(stateDirectory, {recursive: true, force: true}); }
});

test("Calla-only SQLite memory ranks bounded facts and expires them", async () => {
  const stateDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "calla-graph-"));
  let clock = 1_000;
  const graph = new CallaMemoryGraph({stateDirectory}, {now: () => clock});
  try {
    graph.remember("learner", "learner-abc", ["Prefers keyboard shortcuts."], {verified: true});
    graph.remember("application", "org.blenderfoundation.blender", ["Teach modifiers after the basics."], {packRevision: "blender@0.3.0", verified: true});
    assert.deepEqual(graph.recall({learnerID: "learner-abc", bundleID: "org.blenderfoundation.blender"}), ["- Prefers keyboard shortcuts.", "- Teach modifiers after the basics."]);
    graph.remember("application", "org.blenderfoundation.blender", ["Teach basics before modifier work."], {verified: true});
    assert.equal(graph.search("modifier")[0].text, "Teach basics before modifier work.");
    assert.throws(() => graph.remember("learner", "learner-abc", ["The screenshot showed private data"]), MemoryRejection);
    assert.throws(() => graph.remember("learner", "learner-abc", ["The window was Budget review"]), MemoryRejection);
    clock += FACT_RETENTION_DAYS * 86_400_000 + 1;
    assert.deepEqual(graph.recall({learnerID: "learner-abc"}), []);
  } finally { graph.close(); await fs.rm(stateDirectory, {recursive: true, force: true}); }
});

test("focused lesson path needs one visual turn, then local advances add none", async () => {
  const calls = [];
  const {api, registrations} = fakeApi({invoke: async (request) => {
    calls.push(request);
    return {payload: request.params.operation === "observe"
      ? {status: "ok", snapshot_id: "snapshot-1", app_bundle_id: "com.example.App", app_version: "1.0"}
      : {status: "ok"}};
  }});
  plugin.register(api);
  const observe = registrations.tools.find((tool) => tool.name === "tutor_observe");
  const plan = registrations.tools.find((tool) => tool.name === "tutor_plan");
  const guide = registrations.tools.find((tool) => tool.name === "tutor_guide");
  await observe.execute("one", {session_id: "lesson-1234", include_capture: true});
  await plan.execute("two", {session_id: "lesson-1234", snapshot_id: "snapshot-1", steps: [
    {title: "one", text: "do one", region: {left: .1, top: .1, width: .1, height: .1}},
    {title: "two", text: "do two", region: {left: .2, top: .2, width: .1, height: .1}},
  ]});
  await guide.execute("three", {session_id: "lesson-1234", snapshot_id: "snapshot-1", text: "do one", region: {left: .1, top: .1, width: .1, height: .1}, step_index: 0});
  assert.equal(calls.filter((call) => call.params.operation === "observe").length, 1);
  assert.equal(calls.length, 3, "the Mac owns normal multi-step advances without another model/tool turn");
});

test("a mismatch requests exactly one cropped visual turn", async () => {
  const calls = [];
  const {api, registrations} = fakeApi({invoke: async (request) => { calls.push(request); return {payload: {status: "ok", snapshot_id: "crop-1"}}; }});
  plugin.register(api);
  const observe = registrations.tools.find((tool) => tool.name === "tutor_observe");
  await observe.execute("crop", {session_id: "lesson-1234", include_capture: true, region: {left: .5, top: 0, width: .5, height: 1}});
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].params.payload.region, {left: .5, top: 0, width: .5, height: 1});
  assert.equal(calls[0].params.payload.include_capture, true);
});

test("observe may crop, but only when it is actually capturing", () => {
  const region = {left: 0.5, top: 0, width: 0.5, height: 1};
  const cropped = buildTutorEnvelope("tutor_observe", {
    session_id: "session-1234", include_capture: true, region,
  });
  assert.equal(cropped.payload.region.width, 0.5);

  assert.throws(
    () => buildTutorEnvelope("tutor_observe", {session_id: "session-1234", region}),
    /observe region only means something with include_capture true/,
  );
});

test("Gateway preserves exactly one canonical descriptor and normalized visual hint", async () => {
  const stateDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "calla-descriptor-test-"));
  await writeDescriptorIndex(stateDirectory);
  const calls = [];
  const {api, registrations} = fakeApi({
    pluginConfig: {stateDirectory},
    invoke: async (request) => {
      calls.push(request);
      return {payload: {ok: true}};
    },
  });
  try {
    plugin.register(api);
    const point = registrations.tools.find((candidate) => candidate.name === "tutor_point");
    await point.execute("call-1", {
      session_id: "session-1234",
      target_descriptor: structuredClone(targetDescriptor),
      snapshot_id: "snapshot-1",
      target_hint: {region: {left: 0.7, top: 0.1, width: 0.2, height: 0.4}},
    });
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0].params.payload.target_descriptor, targetDescriptor);
    assert.deepEqual(calls[0].params.payload.target_hint, {region: {left: 0.7, top: 0.1, width: 0.2, height: 0.4}});
    await assert.rejects(
      point.execute("call-2", {
        session_id: "session-1234",
        target_descriptor: {...targetDescriptor, title: "model replacement"},
        snapshot_id: "snapshot-1",
      }),
      /exactly one installed App-Pack/,
    );
    await assert.rejects(
      point.execute("call-3", {
        session_id: "session-1234",
        target_descriptor: targetDescriptor,
        snapshot_id: "snapshot-1",
        target_hint: {region: {left: 0.9, top: 0, width: 0.2, height: 0.2}},
      }),
      /remain inside the focused window/,
    );
  } finally {
    await fs.rm(stateDirectory, {recursive: true, force: true});
  }
});

test("actions reject visual hints and require canonical target plus detector descriptors", async () => {
  const stateDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "calla-action-descriptor-test-"));
  await writeDescriptorIndex(stateDirectory);
  const calls = [];
  const {api, registrations} = fakeApi({
    pluginConfig: {stateDirectory},
    invoke: async (request) => { calls.push(request); return {payload: {ok: true}}; },
  });
  try {
    plugin.register(api);
    const action = registrations.tools.find((candidate) => candidate.name === "tutor_propose_action");
    await assert.rejects(
      action.execute("call-1", {
        session_id: "session-1234", action: "click", target_descriptor: targetDescriptor, snapshot_id: "snapshot-1",
        expected_state: detectorDescriptor, rationale: "test", target_hint: {region: {left: 0, top: 0, width: 1, height: 1}},
      }),
      /never accepts target_hint/,
    );
    await action.execute("call-2", {
      session_id: "session-1234", action: "click", target_descriptor: structuredClone(targetDescriptor), snapshot_id: "snapshot-1",
      expected_state: structuredClone(detectorDescriptor), rationale: "test",
    });
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0].params.payload.expected_state, detectorDescriptor);
  } finally {
    await fs.rm(stateDirectory, {recursive: true, force: true});
  }
});

test("a malformed installed App-Pack index fails closed", async () => {
  const stateDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "calla-malformed-index-test-"));
  await fs.mkdir(path.join(stateDirectory, "indexes"));
  await fs.writeFile(path.join(stateDirectory, "indexes", "damaged.json"), "{not json", "utf8");
  const {api, registrations} = fakeApi({pluginConfig: {stateDirectory}});
  try {
    plugin.register(api);
    await assert.rejects(
      retrieveLocalPacks(parsePluginConfig({stateDirectory}), {
        query: "modifier",
        application: {bundle_id: "org.blenderfoundation.blender", version: "5.2.0", locale: "en"},
      }),
      /index damaged\.json is malformed/,
    );
  } finally {
    await fs.rm(stateDirectory, {recursive: true, force: true});
  }
});


test("optional owner gate and one-shot action approval are independent", async () => {
  const {api, registrations} = fakeApi({pluginConfig: {requireOwnerIdentity: true}});
  plugin.register(api);
  const hook = registrations.hooks.get("before_tool_call");

  const denied = await hook(
    {toolName: "tutor_observe", params: {session_id: "session-1234"}},
    {requester: {senderIsOwner: false}, sessionId: "session-1234"},
  );
  assert.equal(denied.block, true);

  const approval = await hook(
    {
      toolName: "tutor_propose_action",
      params: {
        session_id: "session-1234",
        action: "click",
        target_descriptor: targetDescriptor,
      },
    },
    {requester: {senderIsOwner: true}, sessionId: "session-1234"},
  );
  assert.equal(approval.block, true);
  assert.match(approval.blockReason, /published course/);

  const noOwnerGate = fakeApi({pluginConfig: {requireOwnerIdentity: false}});
  plugin.register(noOwnerGate.api);
  const unrestricted = await noOwnerGate.registrations.hooks.get("before_tool_call")(
    {toolName: "tutor_observe", params: {session_id: "session-1234"}},
    {requester: {senderIsOwner: false}, sessionId: "session-1234"},
  );
  assert.equal(unrestricted.block, true);
  assert.match(unrestricted.blockReason, /published course/);
});


test("node host IPC accepts one envelope and returns one response", async () => {
  const temporaryDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "open-tutor-node-test-"));
  const socketPath = path.join(temporaryDirectory, "host.sock");
  const server = net.createServer((client) => {
    let input = "";
    client.setEncoding("utf8");
    client.on("data", (chunk) => {
      input += chunk;
      if (!input.includes("\n")) return;
      const request = JSON.parse(input.slice(0, input.indexOf("\n")));
      client.end(`${JSON.stringify({ok: true, operation: request.operation})}\n`);
    });
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
  try {
    const envelope = buildTutorEnvelope("tutor_verify", {
      session_id: "session-1234",
      target_descriptor: targetDescriptor,
      detector_descriptor: detectorDescriptor,
      snapshot_id: "snapshot-1",
    });
    const response = await invokeTutorHost(envelope, {socketPath, timeoutMs: 2000});
    assert.deepEqual(response, {ok: true, operation: "verify"});
  } finally {
    await new Promise((resolve) => server.close(resolve));
    await fs.rm(temporaryDirectory, {recursive: true, force: true});
  }
});

test("node reports a typed unavailable result before TutorHost starts", async () => {
  const missingSocket = path.join(os.tmpdir(), `calla-missing-${process.pid}-${Date.now()}.sock`);
  const response = await handleTutorNodeHostCommand(
    buildTutorEnvelope("tutor_verify", {
      session_id: "session-1234",
      target_descriptor: targetDescriptor,
      detector_descriptor: detectorDescriptor,
      snapshot_id: "snapshot-1",
    }),
    {socketPath: missingSocket, timeoutMs: 500},
  );
  // The node transport takes a JSON string back, not an object. Returning an
  // object loses the whole response on the wire.
  assert.equal(typeof response, "string");
  assert.deepEqual(JSON.parse(response), {
    ok: false,
    code: "TUTOR_HOST_UNAVAILABLE",
    message: "Calla TutorHost is not running or is not accepting local requests.",
  });
});

test("a TutorHost response survives the node transport as JSON text", async () => {
  const socketPath = path.join(os.tmpdir(), `calla-node-${process.pid}-${Date.now()}.sock`);
  const hostResponse = {
    request_id: "probe",
    ok: true,
    payload: {status: "ok", snapshot_id: "snapshot-1", app_bundle_id: "com.example.app"},
  };
  const server = net.createServer((socket) => {
    socket.once("data", () => socket.end(`${JSON.stringify(hostResponse)}\n`));
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  try {
    const response = await handleTutorNodeHostCommand(
      buildTutorEnvelope("tutor_observe", {session_id: "session-1234"}),
      {socketPath, timeoutMs: 2000},
    );
    assert.equal(typeof response, "string");
    assert.deepEqual(JSON.parse(response), hostResponse);
    // And the Gateway side gets back to the Mac's own payload from there.
    assert.deepEqual(unwrapNodePayload({ok: true, payloadJSON: response}), hostResponse);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test("a lesson card carries the route and drops the scaffolding", () => {
  const lesson = {
    id: "blender.lesson.bevel_basics",
    kind: "lesson",
    title: "Add a non-destructive Bevel modifier",
    source_refs: ["blender-manual"],
    objective: {given: "A mesh.", behavior: "Add a bevel.", criterion: "The mesh has a Bevel modifier."},
    steps: [
      {id: "open", instruction: "Open the Modifier Properties tab.", target: "blender.ui.properties.modifiers_tab",
       allowed_assistance: [{action: "click", target: "blender.ui.properties.modifiers_tab"}],
       success: {detector: "blender.detector.properties_context_is_modifier"}},
      // A step with no detector still teaches: that is what lets a lesson for
      // an application nobody authored targets for be taught at all.
      {id: "add", instruction: "Choose Add Modifier and select Bevel."},
    ],
    checkpoint: {explain: "A modifier is non-destructive until applied."},
    assessment: {prompt: "Add one to another mesh."},
    transfer: {prompt: "Place it before Subdivision Surface."},
    misconceptions: [{belief: "Order is cosmetic.", correction: "Earlier modifiers change later input."}],
  };
  const card = lessonCard(lesson, new Map([["blender.detector.properties_context_is_modifier", "Modifier Properties context is open"]]));

  assert.match(card, /Open the Modifier Properties tab\./);
  assert.match(card, /done when: Modifier Properties context is open/);
  assert.match(card, /Choose Add Modifier and select Bevel\./);
  assert.match(card, /If they believe "Order is cosmetic\." — Earlier modifiers/);
  // A step without a detector simply has no "done when" line, rather than an
  // invented one.
  assert.equal(card.match(/done when:/g).length, 1);
  // None of the machinery the model never reads.
  assert.doesNotMatch(card, /allowed_assistance|source_refs|blender\.ui\.properties\.modifiers_tab/);
  assert.ok(card.length < JSON.stringify(lesson).length, "the card is smaller than the entity it replaces");
});

test("the picked lesson reaches the prompt before any tool call", async () => {
  const stateDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "calla-lesson-card-test-"));
  await fs.mkdir(path.join(stateDirectory, "indexes"));
  await fs.writeFile(
    path.join(stateDirectory, "indexes", "blender.json"),
    JSON.stringify({
      format: "calla-local-pack-index",
      format_version: 1,
      pack: {id: "org.calla.tutor.blender", pack_version: "0.3.0",
             apps: [{platform: "macos", bundle_ids: ["org.blenderfoundation.blender"], versions: ">=5.2 <5.3", locales: ["en"]}]},
      entities: [
        {id: "blender.detector.ctx", kind: "detector", title: "Modifier Properties context is open",
         provider: "accessibility", query: {}},
        {id: "blender.lesson.bevel_basics", kind: "lesson", title: "Add a Bevel modifier",
         objective: {given: "A mesh.", behavior: "Add a bevel.", criterion: "The mesh has a Bevel modifier."},
         steps: [{id: "open", instruction: "Open the Modifier Properties tab.", success: {detector: "blender.detector.ctx"}}],
         assessment: {prompt: "Do it unaided."}, transfer: {prompt: "Do it differently."},
         retention: {prompt: "Explain it."}, misconceptions: [{belief: "X", correction: "Y"}]},
      ],
    }),
    "utf8",
  );
  try {
    const {api, registrations} = fakeApi({pluginConfig: {stateDirectory}});
    plugin.register(api);
    const hook = registrations.hooks.get("before_prompt_build");

    // The id rides in the opening message. It cannot ride in the environment:
    // the Mac runs the CLI over ssh and this hook runs in the Gateway daemon,
    // a different process the CLI cannot set variables on.
    const taught = await hook(
      {prompt: "Teach Modelling basics — Add a Bevel modifier. [lesson:blender.lesson.bevel_basics]"},
      {agentId: "calla", sessionKey: "calla-lesson-1"});
    assert.match(taught.prependContext, /Open the Modifier Properties tab\./);
    assert.match(taught.prependContext, /done when: Modifier Properties context is open/);

    // Only the first message names it, so the rest of the lesson has to be
    // remembered rather than re-read.
    const later = await hook({prompt: "Step 1 done. Check it. (the window changed)"},
                             {agentId: "calla", sessionKey: "calla-lesson-1"});
    assert.match(later.prependContext, /Open the Modifier Properties tab\./);

    // A different session that named no lesson must not inherit one.
    const asked = await hook({prompt: "How do I bevel a cube?"},
                             {agentId: "calla", sessionKey: "calla-lesson-2"});
    assert.ok(!asked?.prependContext?.includes("Open the Modifier Properties tab."));
  } finally {
    await fs.rm(stateDirectory, {recursive: true, force: true});
  }
});

test("observe may ask for a cheaper capture, but never for a position", () => {
  const envelope = buildTutorEnvelope("tutor_observe", {include_capture: true, long_edge: 768}, "session-1234");
  assert.equal(envelope.payload.long_edge, 768);

  for (const bad of [256, 4096, 1024.5, "1024"]) {
    assert.throws(() => buildTutorEnvelope("tutor_observe", {include_capture: true, long_edge: bad}, "session-1234"),
                  /long_edge must be an integer/, `long_edge ${bad} is refused`);
  }
  // The coordinate guard still owns every name that could place something.
  for (const key of ["width", "height", "left", "top", "bounds", "frame"]) {
    assert.throws(() => buildTutorEnvelope("tutor_observe", {include_capture: true, [key]: 512}, "session-1234"),
                  /raw coordinate field/, `${key} remains forbidden`);
  }
});
