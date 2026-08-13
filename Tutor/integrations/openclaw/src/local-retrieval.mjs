import fs from "node:fs/promises";
import path from "node:path";

import {canonicalJSONString, validateDetectorDescriptor, validateTargetDescriptor} from "./descriptors.mjs";

const INDEX_FORMAT = "calla-local-pack-index";

function versionParts(version) {
  const match = String(version).trim().match(/^(\d+)(?:\.(\d+))?(?:\.(\d+))?/);
  if (!match) return null;
  return [Number(match[1]), Number(match[2] || 0), Number(match[3] || 0)];
}

function compareVersions(left, right) {
  const a = versionParts(left);
  const b = versionParts(right);
  if (!a || !b) return null;
  for (let index = 0; index < a.length; index += 1) {
    if (a[index] !== b[index]) return a[index] < b[index] ? -1 : 1;
  }
  return 0;
}

export function versionMatchesRange(version, range) {
  if (typeof range !== "string" || !range.trim()) return false;
  const comparisons = range.trim().split(/\s+/);
  return comparisons.every((comparison) => {
    const match = comparison.match(/^(>=|<=|>|<|=)?\s*(\d+(?:\.\d+){0,2})$/);
    if (!match) return false;
    const result = compareVersions(version, match[2]);
    if (result === null) return false;
    switch (match[1] || "=") {
      case ">=": return result >= 0;
      case "<=": return result <= 0;
      case ">": return result > 0;
      case "<": return result < 0;
      default: return result === 0;
    }
  });
}

function requireApplication(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("tutor_retrieve requires an application object");
  }
  for (const field of ["bundle_id", "version"]) {
    if (typeof value[field] !== "string" || !value[field].trim()) {
      throw new TypeError(`tutor_retrieve application.${field} must be a non-empty string`);
    }
  }
  return {
    bundle_id: value.bundle_id.trim(),
    version: value.version.trim(),
    platform: typeof value.platform === "string" && value.platform.trim() ? value.platform.trim() : "macos",
    locale: typeof value.locale === "string" && value.locale.trim() ? value.locale.trim() : null,
  };
}

function supportsApplication(pack, application) {
  const applications = pack?.apps;
  if (!Array.isArray(applications)) return false;
  return applications.some((candidate) => {
    if (!candidate || typeof candidate !== "object") return false;
    if (candidate.platform !== application.platform) return false;
    if (!Array.isArray(candidate.bundle_ids) || !candidate.bundle_ids.includes(application.bundle_id)) return false;
    if (!versionMatchesRange(application.version, candidate.versions)) return false;
    return !application.locale || (Array.isArray(candidate.locales) && candidate.locales.includes(application.locale));
  });
}

function searchableText(entity) {
  return JSON.stringify(entity).toLocaleLowerCase("en-US");
}

function scoreEntity(entity, terms) {
  const text = searchableText(entity);
  let score = 0;
  for (const term of terms) {
    const position = text.indexOf(term);
    if (position < 0) return null;
    score += position === 0 ? 4 : 1;
  }
  return score;
}

export async function readInstalledPackIndexes(config) {
  const indexes = await readIndexes(path.join(config.stateDirectory, "indexes"));
  const hidden = await archivedCoursePackIDs(config);
  return indexes.filter((index) => !hidden.has(index.pack?.id));
}

async function archivedCoursePackIDs(config) {
  try {
    const registry = JSON.parse(await fs.readFile(path.join(config.stateDirectory, "courses", "registry.json"), "utf8"));
    return new Set((registry?.jobs || []).filter((job) => job?.phase === "archived" && typeof job.pack_id === "string").map((job) => job.pack_id));
  } catch (error) {
    if (error?.code === "ENOENT" || error instanceof SyntaxError) return new Set();
    throw error;
  }
}

async function readIndexes(indexDirectory) {
  let names;
  try {
    names = await fs.readdir(indexDirectory);
  } catch (error) {
    if (error && error.code === "ENOENT") return [];
    throw error;
  }
  const indexes = [];
  for (const name of names.sort()) {
    if (!name.endsWith(".json")) continue;
    try {
      const value = JSON.parse(await fs.readFile(path.join(indexDirectory, name), "utf8"));
      if (value?.format !== INDEX_FORMAT || value.format_version !== 1 || !value.pack || !Array.isArray(value.entities)) {
        throw new TypeError(`installed App-Pack index ${name} has an unsupported structure`);
      }
      indexes.push(value);
    } catch (error) {
      if (error instanceof TypeError) throw error;
      throw new TypeError(`installed App-Pack index ${name} is malformed`);
    }
  }
  return indexes;
}

/// What courses exist, small enough to hand to the Mac.
///
/// The Mac has no packs — retrieval never leaves the Gateway — so it cannot
/// answer "what could I be taught" without being told. This is what it is told:
/// names, ordering and counts, and nothing that could be taught with. No step
/// text, no detectors, no targets, no prose. A learner picking from a menu needs
/// a title and a mark beside it; everything else stays here until a lesson
/// actually starts.
export async function buildCourseCatalogue(config) {
  const indexes = await readInstalledPackIndexes(config);
  const courses = [];
  for (const index of indexes) {
    const entities = index.entities ?? [];
    const lessons = new Map();
    for (const entity of entities) {
      if (entity?.kind === "lesson" && typeof entity.id === "string") lessons.set(entity.id, entity);
    }
    const bundleIDs = (index.pack?.apps ?? []).flatMap((app) => app?.bundle_ids ?? []);
    for (const entity of entities) {
      if (entity?.kind !== "course" || !Array.isArray(entity.lessons)) continue;
      // A course naming a lesson this pack does not carry is dropped rather
      // than listed: the compiler already refuses to build one, so reaching
      // here means the index is older than the rule.
      const contents = entity.lessons
        .map((id) => lessons.get(id))
        .filter(Boolean)
        .map((lesson) => ({id: lesson.id, title: lesson.title}));
      if (!contents.length) continue;
      courses.push({
        id: entity.id,
        title: entity.title,
        summary: typeof entity.summary === "string" ? entity.summary : "",
        icon: typeof entity.icon === "string" ? entity.icon : "",
        pack_id: index.pack?.id ?? "",
        bundle_ids: bundleIDs,
        lessons: contents,
      });
    }
  }
  courses.sort((left, right) => left.id.localeCompare(right.id));
  return {courses};
}

export async function retrieveLocalPacks(config, payload) {
  const application = requireApplication(payload.application);
  const query = typeof payload.query === "string" ? payload.query.trim() : "";
  if (!query) throw new TypeError("tutor_retrieve query must be a non-empty string");
  const limit = Number.isInteger(payload.limit) ? Math.min(Math.max(payload.limit, 1), 20) : 5;
  const allowedKinds = Array.isArray(payload.entity_types) ? new Set(payload.entity_types) : null;
  const terms = query.toLocaleLowerCase("en-US").match(/[\p{L}\p{N}_.-]+/gu) || [];
  if (!terms.length) throw new TypeError("tutor_retrieve query contains no searchable terms");

  const matches = [];
  for (const index of await readInstalledPackIndexes(config)) {
    if (!supportsApplication(index.pack, application)) continue;
    for (const entity of index.entities || []) {
      if (!entity || typeof entity !== "object") continue;
      if (allowedKinds && !allowedKinds.has(entity.kind)) continue;
      if (typeof entity.app_versions === "string" && !versionMatchesRange(application.version, entity.app_versions)) continue;
      const score = scoreEntity(entity, terms);
      if (score === null) continue;
      let descriptor = null;
      try {
        if (entity.kind === "ui_target") descriptor = validateTargetDescriptor(entity, `installed entity ${entity.id}`);
        if (entity.kind === "detector") descriptor = validateDetectorDescriptor(entity, `installed entity ${entity.id}`);
      } catch {
        // A manually damaged index must not make an invalid descriptor retrievable.
        continue;
      }
      matches.push({
        pack_id: index.pack.id,
        pack_version: index.pack.pack_version,
        id: entity.id,
        kind: entity.kind,
        title: entity.title,
        source_file: entity.source_file,
        score,
        entity,
        ...(entity.kind === "ui_target" ? {target_descriptor: descriptor} : {}),
        ...(entity.kind === "detector" ? {detector_descriptor: descriptor} : {}),
      });
    }
  }
  matches.sort((left, right) => right.score - left.score || left.id.localeCompare(right.id));
  return {
    ok: true,
    source: "server-local",
    application,
    results: matches.slice(0, limit),
  };
}

/**
 * Exact, bounded App-Pack context supplied with an observation. It is plugin
 * retrieval, not a model-visible retrieval turn; descriptors remain canonical
 * because they come straight from the installed index.
 */
export async function retrievePackPrimer(config, application) {
  const normalized = requireApplication(application);
  const results = [];
  for (const index of await readInstalledPackIndexes(config)) {
    if (!supportsApplication(index.pack, normalized)) continue;
    for (const entity of index.entities || []) {
      if (!entity || (entity.kind !== "ui_target" && entity.kind !== "detector")) continue;
      if (typeof entity.app_versions === "string" && !versionMatchesRange(normalized.version, entity.app_versions)) continue;
      try {
        const descriptor = entity.kind === "ui_target"
          ? validateTargetDescriptor(entity, `installed entity ${entity.id}`)
          : validateDetectorDescriptor(entity, `installed entity ${entity.id}`);
        results.push({id: entity.id, kind: entity.kind,
          ...(entity.kind === "ui_target" ? {target_descriptor: descriptor} : {detector_descriptor: descriptor})});
      } catch { /* damaged indexes never become prompt context */ }
    }
  }
  results.sort((left, right) => left.id.localeCompare(right.id));
  return results.slice(0, 4);
}

/// One authored lesson, small enough to put in front of the model every turn.
///
/// The whole entity is around seven hundred tokens of YAML-shaped JSON, most of
/// it structure the model never reads: detector ids, target ids, source refs,
/// allowed assistance. What is actually needed to teach is the ordered steps in
/// their own words, what finishing each one looks like, and the wrong beliefs
/// worth naming. That is this, at roughly a quarter of the size.
///
/// The "done when" line is the referenced detector's own title, resolved from
/// the same index — authored text, not a restatement. A step with no detector
/// simply has no such line, which is what lets a lesson for an application
/// nobody has written targets or detectors for still be taught: prose steps are
/// enough, and the model judges the rest by looking.
export function lessonCard(lesson, detectorTitles = new Map()) {
  if (!lesson || typeof lesson !== "object") return null;
  const lines = [`Lesson ${lesson.id} — ${lesson.title}`];
  if (lesson.objective?.criterion) lines.push(`Done when: ${lesson.objective.criterion}`);

  const steps = Array.isArray(lesson.steps) ? lesson.steps : [];
  if (steps.length) {
    lines.push("Steps, in order, one tooltip each:");
    steps.forEach((step, index) => {
      if (!step?.instruction) return;
      lines.push(` ${index + 1}. ${step.instruction}`);
      const done = detectorTitles.get(step?.success?.detector);
      if (done) lines.push(`    done when: ${done}`);
    });
  }

  if (lesson.checkpoint?.explain) lines.push(`The idea behind it: ${lesson.checkpoint.explain}`);
  if (lesson.assessment?.prompt) lines.push(`Then, unaided: ${lesson.assessment.prompt}`);
  if (lesson.transfer?.prompt) lines.push(`Then, transferred: ${lesson.transfer.prompt}`);
  for (const item of Array.isArray(lesson.misconceptions) ? lesson.misconceptions.slice(0, 3) : []) {
    if (item?.belief && item?.correction) lines.push(`If they believe "${item.belief}" — ${item.correction}`);
  }
  return lines.join("\n");
}

/// The card for the lesson the learner actually picked.
///
/// Selected on the Mac and carried in the environment, so it is known before
/// the first tool call rather than discovered by spending a capture on one.
export async function retrieveLessonByID(config, lessonID) {
  if (typeof lessonID !== "string" || !lessonID) return null;
  for (const index of await readInstalledPackIndexes(config)) {
    const entities = index.entities ?? [];
    const lesson = entities.find((entity) => entity?.kind === "lesson" && entity.id === lessonID);
    if (!lesson) continue;
    const detectorTitles = new Map();
    for (const entity of entities) {
      if (entity?.kind === "detector" && typeof entity.id === "string" && entity.title) {
        detectorTitles.set(entity.id, entity.title);
      }
    }
    return lessonCard(lesson, detectorTitles);
  }
  return null;
}

/** Lesson records are compact, local prompt context after the first grounded
 * observation. This is not a model-visible retrieval call. */
export async function retrieveLessonPrimer(config, application) {
  const normalized = requireApplication(application);
  const lessons = [];
  for (const index of await readInstalledPackIndexes(config)) {
    if (!supportsApplication(index.pack, normalized)) continue;
    for (const entity of index.entities || []) {
      if (entity?.kind !== "lesson" || typeof entity.id !== "string") continue;
      if (typeof entity.app_versions === "string" && !versionMatchesRange(normalized.version, entity.app_versions)) continue;
      lessons.push({
        pack_id: index.pack.id,
        pack_version: index.pack.pack_version,
        entity: entity,
      });
    }
  }
  return lessons.sort((left, right) => left.entity.id.localeCompare(right.entity.id)).slice(0, 4);
}

export async function requireCanonicalDescriptor(config, supplied, kind, name) {
  const validate = kind === "ui_target" ? validateTargetDescriptor : validateDetectorDescriptor;
  validate(supplied, name);
  const suppliedJSON = canonicalJSONString(supplied);
  const matches = [];
  for (const index of await readInstalledPackIndexes(config)) {
    for (const entity of index.entities || []) {
      if (!entity || typeof entity !== "object" || entity.kind !== kind) continue;
      try {
        validate(entity, `installed entity ${entity.id || "unknown"}`);
        if (canonicalJSONString(entity) === suppliedJSON) matches.push(entity);
      } catch {
        // Invalid installed records are not eligible authority.
      }
    }
  }
  if (matches.length !== 1) {
    throw new TypeError(`${name} must be byte-for-byte equivalent to exactly one installed App-Pack ${kind}`);
  }
  return matches[0];
}

/** Resolve one pack-authored descriptor without making it model-visible. */
export async function findCanonicalDescriptor(config, id, kind) {
  if (typeof id !== "string" || !id) return null;
  const validate = kind === "ui_target" ? validateTargetDescriptor : validateDetectorDescriptor;
  let match = null;
  for (const index of await readInstalledPackIndexes(config)) {
    for (const entity of index.entities || []) {
      if (entity?.id !== id || entity?.kind !== kind) continue;
      try { validate(entity, `installed entity ${id}`); } catch { continue; }
      if (match) return null;
      match = entity;
    }
  }
  return match;
}

export async function requirePackAuthorizedAction(config, action, target, detector) {
  let authorized = false;
  for (const index of await readInstalledPackIndexes(config)) {
    for (const lesson of index.entities || []) {
      if (lesson?.kind !== "lesson" || !Array.isArray(lesson.steps)) continue;
      for (const step of lesson.steps) {
        if (!step || step.target !== target.id || step?.success?.detector !== detector.id) continue;
        if (Array.isArray(step.allowed_assistance) && step.allowed_assistance.some((entry) => entry?.action === action && entry?.target === target.id)) {
          authorized = true;
        }
      }
    }
  }
  if (!authorized) throw new TypeError("the installed App Pack does not authorize this action and expected-state pair");
}
