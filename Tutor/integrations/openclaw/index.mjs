import {lessonFacts, tutorSessionFor} from "./src/memory.mjs";
import {CallaMemoryGraph} from "./src/calla-memory-graph.mjs";
import {LessonStateStore} from "./src/lesson-state.mjs";
import {handleTutorNodeHostCommand} from "./src/node-host.mjs";
import {createBeforeToolCallPolicy} from "./src/policy.mjs";
import {retrieveLessonByID} from "./src/local-retrieval.mjs";
import {markedLesson} from "./src/teaching.mjs";
import {NODE_COMMAND, parsePluginConfig} from "./src/protocol.mjs";
import {TEACHING_GUIDANCE} from "./src/teaching.mjs";
import {createTutorTools, pushCourseCatalogue, pushCourseRuntime, pushSessionStart} from "./src/tools.mjs";
import {pushCourseStatus} from "./src/tools.mjs";
import {PedagogyStore} from "./src/pedagogy.mjs";
import {CourseControlServer, CourseLifecycleService, CourseTaskFlowBridge} from "./src/course-lifecycle.mjs";

const plugin = {
  id: "tutor",
  name: "Calla",
  description: "Calla teaching assistant: semantic desktop guidance through a user-owned macOS TutorHost.",

  register(api) {
    const config = parsePluginConfig(api.pluginConfig);

    if (config.role === "gateway" || config.role === "both") {
      // Which authored lesson each teaching session is running, so the card
      // survives the turns after the opening message.
      const selectedLessons = new Map();
      const lessonState = new LessonStateStore(config);
      const memoryGraph = new CallaMemoryGraph(config);
      const pedagogy = new PedagogyStore();
      let courseService;
      // Supported OpenClaw API: taskFlow.bindSession(), not taskFlows.run().
      // The fixed owner session is not a teaching session and never holds the
      // outline, captures, prompts, or compiler output.
      const courseTaskFlow = new CourseTaskFlowBridge(api.runtime);
      courseService = new CourseLifecycleService(config, {
        taskFlow: courseTaskFlow,
        onChange: async (courses) => {
          await pushCourseStatus(api, config, courses);
          await pushCourseCatalogue(api, config);
          await pushCourseRuntime(api, config);
        },
      });
      // Owner-only local control plane. This binds no TCP port and keeps course
      // authoring outside teaching sessions and prompts.
      // Do not expose a control socket unless this Gateway has the supported
      // durable TaskFlow API. The worker itself remains Gateway-local.
      if (courseTaskFlow.flow) {
        const courseControl = new CourseControlServer(courseService, config.courseSocketPath);
        void courseControl.start().then(async () => {
          await courseService.resumePending();
          await pushCourseStatus(api, config, await courseService.list());
          await pushCourseRuntime(api, config);
        }).catch(() => {});
      }
      for (const tool of createTutorTools(api, config, {lessonState, memoryGraph, pedagogy})) {
        api.registerTool(tool, {name: tool.name});
      }

      // Hand the Mac the course list once the Gateway is actually running turns.
      //
      // Not during register: loading a plugin should wire things up and talk to
      // nobody, and the node is very often not connected that early anyway. The
      // first turn is the earliest moment the whole path is known to be up, and
      // it is still well before any menu could be opened in a lesson.
      let catalogueSent = false;

      const beforeToolCall = createBeforeToolCallPolicy(config, (context) =>
        selectedLessons.has(tutorSessionFor(context?.sessionId ?? context?.sessionKey)));
      api.on("before_tool_call", beforeToolCall);

      // What Calla remembered from earlier lessons, put back in front of it.
      //
      // A lesson gets its own session now, so the transcript no longer carries
      // anything across. These notes do. They go in per-turn context rather
      // than the system prompt on purpose: they change between lessons, and
      // anything that changes must sit after the cached prefix rather than
      // invalidating it on every turn.
      api.on("before_prompt_build", async (event, context) => {
        if (context?.agentId !== "calla") return undefined;
        if (!catalogueSent) {
          catalogueSent = true;
          void pushSessionStart(api, config);
          void pushCourseCatalogue(api, config);
          void pushCourseRuntime(api, config);
          void courseService.list().then((courses) => pushCourseStatus(api, config, courses));
        }
        const sessionID = tutorSessionFor(context?.sessionId ?? context?.sessionKey);
        // The lesson the learner picked, ahead of the first tool call.
        //
        // It used to arrive attached to an observation, which meant the model
        // had to spend a capture before it could learn the route — and then
        // planned the route itself, from the picture, having been handed the
        // authored one too late to use.
        //
        // The id rides in the opening message rather than the environment. The
        // Mac reaches the Gateway by running the CLI over ssh, and this hook
        // runs inside the Gateway daemon — a different process, whose
        // environment the CLI cannot set. Only the message crosses that gap.
        // Remembered per session because just the first message carries it.
        const named = markedLesson(event?.prompt);
        const card = await retrieveLessonByID(config, named || selectedLessons.get(sessionID));
        if (named && card) selectedLessons.set(sessionID, named);
        const state = await lessonState.context(sessionID);
        const pedagogyContext = pedagogy.context(sessionID);
        const facts = lessonFacts(sessionID);
        const notes = memoryGraph.recall({learnerID: facts.learnerID, bundleID: facts.bundleID});
        // One block, in the order it is read: what is being taught, where the
        // lesson has got to, then what was remembered from before.
        const blocks = [
          card,
          state,
          pedagogyContext,
          notes.length ? ["Remembered from earlier lessons — check it against the window you observe:", ...notes].join("\n") : null,
        ].filter(Boolean);
        return {
          // /teach is an entry point, not the only time Calla teaches.
          prependSystemContext: TEACHING_GUIDANCE.map((entry) => entry.text).join("\n"),
          ...(blocks.length ? {prependContext: blocks.join("\n\n")} : {}),
        };
      });

      // This hook receives normalized model-call usage without reading a raw
      // prompt or transcript. The same visible lesson/session survives the
      // host compaction; LessonState supplies the minimal recovery block.
      api.on("reply_payload_sending", async (event, context) => {
        const usage = event?.usageState;
        const sessionID = tutorSessionFor(context?.sessionId ?? context?.sessionKey);
        if (usage && sessionID) await lessonState.compact(sessionID, usage);
      });
      api.on("before_compaction", async (event, context) => {
        const sessionID = tutorSessionFor(context?.sessionId ?? context?.sessionKey);
        if (sessionID) await lessonState.compact(sessionID, {input: event?.tokenCount, force: true});
      });

      api.registerNodeInvokePolicy({
        commands: [NODE_COMMAND],
        defaultPlatforms: ["macos"],
        handle: async (context) => {
          try {
            return await context.invokeNode();
          } catch (error) {
            return {
              ok: false,
              code: "TUTOR_NODE_INVOKE_FAILED",
              message: error instanceof Error ? error.message : String(error),
            };
          }
        },
      });
    }

    if (config.role === "node" || config.role === "both") {
      api.registerNodeHostCommand({
        command: NODE_COMMAND,
        cap: "calla-tutor-host",
        dangerous: true,
        handle: async (params) =>
          await handleTutorNodeHostCommand(params, {
            socketPath: config.socketPath || undefined,
            timeoutMs: config.timeoutMs,
          }),
      });
    }
  },
};

export default plugin;
