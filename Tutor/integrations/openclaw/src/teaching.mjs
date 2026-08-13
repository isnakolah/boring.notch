/**
 * What the model is told about teaching, and the command that starts a lesson.
 *
 * The tools alone do not produce a lesson. Without this the model treats
 * `tutor_observe` as a status read, never asks for the capture, and never
 * discovers that pointing is something it is allowed to do.
 *
 * The contract used to be the whole loop — look, plan a route, point, look
 * again — because the model had to work the route out for itself. It does not
 * any more: an authored lesson arrives in context ahead of the first tool call
 * and already carries the steps, in order, in the words the learner reads. So
 * this says how to check and how to point, and nothing about what to teach.
 */

// This is the complete cacheable teaching contract. Durable retrieval and live
// lesson state are injected after this stable prefix, so they cannot invalidate
// its prompt-cache key or leak a general-agent workspace into the lesson.
const LESSON_LOOP = `Calla teaches by pointing at the learner's focused application. The lesson in
your context is the route: teach its steps in order, in its words. Do not
invent steps and never write a recipe.

Starting a lesson: observe the focused window once with include_capture, send
the whole route with tutor_plan, then guide step one.

Every time a step is reported done: observe with region set to the step you
just pointed at — a crop, never the whole window — and say whether it is done.
If it is, guide the next step. If it is not, say what is different and guide
the same step again. One instruction per tooltip; tutor_guide points and never
clicks. End the turn on the guide.

A message marked [aside] is a question outside the lesson. Answer it with
tutor_narrate. Do not plan, do not guide, do not advance the lesson.

If no picture of the window reaches you, say so and stop. Never measure a
region from metadata.`;

export const TEACHING_GUIDANCE = Object.freeze([
  Object.freeze({text: LESSON_LOOP, surfaces: Object.freeze(["openclaw_main", "codex_app_server", "cli_backend"])}),
]);

export const TEACHING_PHRASE_REGISTRY = Object.freeze([
  "focused application", "written recipe", "one instruction", "in its words",
  "a crop, never the whole window", "marked [aside]", "region from metadata",
]);

/// The lesson id the Mac names when the learner picks a course.
///
/// It travels in the message because that is the only thing that crosses from
/// the Mac, through ssh and the CLI, into the Gateway daemon where the prompt
/// is built. An environment variable set around the CLI never reaches here.
const LESSON_MARKER = /\[lesson:([a-z0-9][a-z0-9._-]{0,120})\]/i;

export function markedLesson(prompt) {
  return typeof prompt === "string" ? prompt.match(LESSON_MARKER)?.[1] ?? null : null;
}

export function createTeachCommand() {
  return {
    name: "teach",
    description: "Start a Calla lesson about whatever is on screen.",
    acceptsArgs: true,
    agentPromptGuidance: TEACHING_GUIDANCE,
    handler(context) {
      const goal = typeof context?.args === "string" ? context.args.trim() : "";
      // The command exists to seed the turn; the model runs the loop, and the
      // loop already says to observe first.
      return {
        text: goal
          ? `Teach me this, on my screen right now: ${goal}`
          : "Look at my focused window and teach me what to do next.",
        continueAgent: true,
      };
    },
  };
}
