/**
 * What Calla is allowed to remember once a lesson's transcript is gone.
 *
 * A lesson now gets its own session, which is what stops step eight from
 * re-sending steps one through seven. The cost of that is continuity: without
 * somewhere else to put it, everything Calla worked out about a learner dies
 * with the session that learned it. These files are that somewhere.
 *
 * Two scopes, because they age differently. `learner` is how this person likes
 * to be taught and survives everything. `application` is where the controls are
 * in one program, and is wrong the moment that program is redesigned.
 *
 * The hard rule, from SECURITY.md: these files must contain nothing a learner
 * would be surprised to read. No pixel data, no window titles, no document
 * names, no paths. A note is a sentence about teaching, and `sanitiseNote`
 * refuses everything else rather than trusting the model to have been careful.
 */
import fs from "node:fs/promises";
import path from "node:path";

/** Per call, so one lesson cannot dump an essay into the prompt of the next. */
export const MAX_NOTES_PER_CALL = 5;
/** Per file, oldest pruned first. Roughly a screenful, which is all a turn can use. */
export const MAX_NOTES_PER_FILE = 40;
export const MAX_NOTE_LENGTH = 160;

/**
 * A bundle id is a file name here, so it has to be one — and only one.
 * Rejecting rather than sanitising: a bundle id that needed cleaning up is not
 * a bundle id, and guessing what it meant is how a write escapes its directory.
 */
const BUNDLE_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,126}$/;
const LEARNER_ID = /^[A-Za-z0-9-]{1,64}$/;

/**
 * Shapes that mean a note has stopped being about teaching.
 *
 * Each of these is something the Mac deliberately keeps local — a file the
 * learner has open, where it lives, what the screen looked like. A note is
 * meant to say "prefers the keyboard" or "the modifier list is on the right",
 * and none of that needs any of this.
 */
const FORBIDDEN_NOTE_PATTERNS = [
  {pattern: /[/\\]/, reason: "a path"},
  {pattern: /~\//, reason: "a home directory"},
  // Deliberately blunt: this rejects "e.g." and "4.2" as well as "budget.xlsx".
  // A note is a sentence about how to teach someone, and none of those belong
  // in one either. Over-refusing costs a rephrase; under-refusing writes a
  // learner's file names into a file they never asked for.
  {pattern: /\.[A-Za-z0-9]{1,5}\b/, reason: "a file name"},
  {pattern: /\b(?:base64|data:image|jpeg|png|screenshot|capture)\b/i, reason: "capture data"},
  {pattern: /\b(?:untitled|document\s*\d)\b/i, reason: "a document name"},
  {pattern: /\b(?:window|dialog|tab)\s+(?:title|titled|was|is)\b/i, reason: "a screen title"},
  {pattern: /\b(?:raw\s+)?transcript\b/i, reason: "a transcript"},
  {pattern: /["“”]/, reason: "a quoted title"},
];

export class MemoryRejection extends Error {
  constructor(message) {
    super(message);
    this.name = "MemoryRejection";
  }
}

/**
 * Who is being taught, and what, for each live lesson.
 *
 * Neither fact can be asked for directly. The learner id belongs to the Mac —
 * it is the one identifier that outlives a lesson — and the application is
 * whatever the Mac decided was the lesson's subject, which the model does not
 * choose. Both arrive in the observation, so they are picked up from there and
 * remembered against the session for as long as it runs.
 *
 * Bounded because a Gateway is long-lived and a map keyed by session id is a
 * slow leak otherwise.
 */
const MAX_TRACKED_LESSONS = 64;
const lessons = new Map();
/**
 * Two identifiers name the same lesson and neither side sees both.
 *
 * The model passes its own `session_id` to every tutor tool, and that is all a
 * tool execution ever learns. The prompt is built somewhere else entirely,
 * where only OpenClaw's own session key exists. `before_tool_call` is the one
 * place both are in scope, so that is where they are tied together.
 */
const sessionAliases = new Map();

/**
 * Which lesson one pending tool call belongs to.
 *
 * `before_tool_call` knows the session; `execute` receives only a tool call id
 * and the model's own arguments. The session used to be handed over by
 * rewriting those arguments, which the Codex app-server treats as tampering
 * with an approved call and refuses outright. So it travels beside the call
 * instead, keyed by the id both sides already share.
 */
const toolCallSessions = new Map();

export function noteToolCallSession(toolCallId, sessionID) {
  if (!toolCallId || !sessionID) return;
  toolCallSessions.delete(toolCallId);
  toolCallSessions.set(toolCallId, sessionID);
  while (toolCallSessions.size > MAX_TRACKED_LESSONS) {
    toolCallSessions.delete(toolCallSessions.keys().next().value);
  }
}

/// Read once and drop: a call is executed exactly once, and a pending entry
/// that is never claimed must not outlive the lesson it names.
export function takeToolCallSession(toolCallId) {
  if (!toolCallId) return undefined;
  const sessionID = toolCallSessions.get(toolCallId);
  toolCallSessions.delete(toolCallId);
  return sessionID;
}

export function bindSession(openclawSessionKey, tutorSessionID) {
  if (!openclawSessionKey || !tutorSessionID) return;
  sessionAliases.delete(openclawSessionKey);
  sessionAliases.set(openclawSessionKey, tutorSessionID);
  while (sessionAliases.size > MAX_TRACKED_LESSONS) {
    sessionAliases.delete(sessionAliases.keys().next().value);
  }
}

/** Resolve the host session key back to Calla's stable lesson id. */
export function tutorSessionFor(openclawSessionKey) {
  return sessionAliases.get(openclawSessionKey) ?? openclawSessionKey;
}

export function noteLearner(sessionID, {learnerID, bundleID}) {
  if (!sessionID) return;
  const known = lessons.get(sessionID) || {};
  const next = {
    learnerID: LEARNER_ID.test(learnerID || "") ? learnerID : known.learnerID,
    bundleID: BUNDLE_ID.test(bundleID || "") ? bundleID : known.bundleID,
  };
  // Re-inserted so the map stays in least-recently-used order.
  lessons.delete(sessionID);
  lessons.set(sessionID, next);
  while (lessons.size > MAX_TRACKED_LESSONS) lessons.delete(lessons.keys().next().value);
}

export function lessonFacts(sessionID) {
  return lessons.get(sessionID) || {};
}

export function forgetLesson(sessionID) {
  lessons.delete(sessionID);
}

/**
 * One note, or a refusal explaining which rule it broke.
 *
 * The reason is handed back to the model rather than swallowed, because a note
 * silently dropped is a lesson silently not learned.
 */
export function sanitiseNote(value) {
  if (typeof value !== "string") throw new MemoryRejection("a note must be a string");
  const note = value.trim().replace(/\s+/g, " ");
  if (!note) throw new MemoryRejection("a note must not be empty");
  if (note.length > MAX_NOTE_LENGTH) {
    throw new MemoryRejection(`a note must be at most ${MAX_NOTE_LENGTH} characters`);
  }
  for (const {pattern, reason} of FORBIDDEN_NOTE_PATTERNS) {
    if (pattern.test(note)) {
      throw new MemoryRejection(
        `a note may not contain ${reason}; say what you learned about teaching, not what was on screen`);
    }
  }
  return note;
}

function memoryFile(config, scope, identifier) {
  const root = path.join(config.stateDirectory, "learners");
  if (scope === "learner") {
    if (!LEARNER_ID.test(identifier)) throw new MemoryRejection("learner id must match ^[A-Za-z0-9-]+$");
    return path.join(root, `${identifier}.md`);
  }
  if (scope === "application") {
    if (!BUNDLE_ID.test(identifier)) throw new MemoryRejection("bundle id is not a bundle id");
    return path.join(root, "apps", `${identifier}.md`);
  }
  throw new MemoryRejection("scope must be learner or application");
}

/** Existing notes, newest last. A missing or unreadable file is simply no notes. */
export async function readNotes(config, scope, identifier) {
  let file;
  try {
    file = memoryFile(config, scope, identifier);
  } catch {
    return [];
  }
  try {
    const text = await fs.readFile(file, "utf8");
    return text.split("\n")
      .map((line) => line.replace(/^-\s*/, "").trim())
      .filter(Boolean)
      .slice(-MAX_NOTES_PER_FILE);
  } catch {
    return [];
  }
}

/**
 * Append what this lesson learned, keeping the file bounded.
 *
 * Written whole rather than appended to, so the cap is enforced on every write
 * instead of drifting past it; and de-duplicated, because a model that has
 * noticed the same thing in four lessons should not say it four times in the
 * fifth one's prompt.
 */
export async function appendNotes(config, scope, identifier, notes) {
  if (!Array.isArray(notes) || notes.length === 0) throw new MemoryRejection("notes must be a non-empty array");
  if (notes.length > MAX_NOTES_PER_CALL) {
    throw new MemoryRejection(`at most ${MAX_NOTES_PER_CALL} notes per call`);
  }
  const file = memoryFile(config, scope, identifier);
  const clean = notes.map(sanitiseNote);
  const existing = await readNotes(config, scope, identifier);
  const merged = [...existing.filter((note) => !clean.includes(note)), ...clean].slice(-MAX_NOTES_PER_FILE);

  await fs.mkdir(path.dirname(file), {recursive: true, mode: 0o700});
  await fs.writeFile(file, `${merged.map((note) => `- ${note}`).join("\n")}\n`, {encoding: "utf8", mode: 0o600});
  return {stored: clean.length, total: merged.length};
}

/**
 * What Calla knows before this lesson starts, as one block of prompt context.
 *
 * Deliberately per-turn context rather than system-prompt context: it changes
 * between lessons, and anything that changes must sit after the cached prefix
 * rather than invalidating it.
 */
export async function recallContext(config, {learnerID, bundleID}) {
  const sections = [];
  if (learnerID) {
    const notes = await readNotes(config, "learner", learnerID);
    if (notes.length) sections.push(`What you know about this learner:\n${notes.map((n) => `- ${n}`).join("\n")}`);
  }
  if (bundleID) {
    const notes = await readNotes(config, "application", bundleID);
    if (notes.length) {
      sections.push(`What you know about teaching ${bundleID}:\n${notes.map((n) => `- ${n}`).join("\n")}`);
    }
  }
  if (!sections.length) return null;
  return [
    "Notes you kept from earlier lessons. They are what you remember, not what is",
    "on screen now — check anything they claim about where a control is against",
    "the window you observe.",
    "",
    ...sections,
  ].join("\n");
}
