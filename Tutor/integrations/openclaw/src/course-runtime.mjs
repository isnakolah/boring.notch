import {readInstalledPackIndexes} from "./local-retrieval.mjs";

export const COURSE_RUNTIME_FORMAT = "calla-course-runtime";
export const COURSE_RUNTIME_VERSION = 1;

function text(value, fallback = "") {
  return typeof value === "string" ? value.slice(0, 240) : fallback;
}

function scoredStep(value, phase, fallbackID) {
  if (!value || typeof value !== "object") return null;
  const target = value?.pass?.target || value.target;
  const detector = value?.pass?.detector || value?.success?.detector;
  if (typeof target !== "string") return null;
  return {id: text(value.id, fallbackID), phase, text: text(value.instruction || value.prompt, phase),
    target_id: target, detector_id: typeof detector === "string" ? detector : null,
    diagnose_refs: diagnoseRefs(value.diagnose)};
}

/**
 * The authored ways a step goes wrong.
 *
 * Each entry names an existing detector and a sentence. Nothing new can be said
 * here that the Mac cannot check: `when` is resolved against the pack's own
 * detector set exactly as a success condition is, and an entry naming a detector
 * that does not exist is dropped rather than shipped as an explanation the host
 * would have to take on trust.
 */
function diagnoseRefs(value) {
  if (!Array.isArray(value)) return [];
  return value
    .map((entry) => (entry && typeof entry === "object" && typeof entry.when === "string" && typeof entry.say === "string"
      ? {when: entry.when, say: text(entry.say)}
      : null))
    .filter(Boolean)
    .slice(0, 8);
}

function materializeDiagnoses(refs, byID) {
  return refs
    .map((ref) => {
      const detector = byID.get(ref.when);
      return detector?.kind === "detector" ? {when: detector, say: ref.say} : null;
    })
    .filter(Boolean);
}

function lessonAssets(value) {
  if (!Array.isArray(value) || value.length !== 2) return null;
  const assets = value.map((asset) => asset && typeof asset === "object" && typeof asset.asset_id === "string" &&
    /^(starter|proof)$/.test(asset.role) && /^[0-9a-f]{64}$/.test(asset.sha256) &&
    Number.isSafeInteger(asset.bytes) && asset.bytes > 0
    ? {asset_id: asset.asset_id, role: asset.role, sha256: asset.sha256, bytes: asset.bytes} : null);
  return assets.every(Boolean) && new Set(assets.map((asset) => asset.role)).size === 2 ? assets : null;
}

/** Compile installed App Packs into host-safe, revision-pinned lesson manifests. */
export async function buildCourseRuntime(config) {
  const courses = [];
  for (const index of await readInstalledPackIndexes(config)) {
    const byID = new Map((index.entities || []).filter((entry) => entry?.id).map((entry) => [entry.id, entry]));
    for (const course of index.entities || []) {
      if (course?.kind !== "course" || !Array.isArray(course.lessons)) continue;
      for (const app of index.pack?.apps || []) {
        if (app?.platform !== "macos" || !Array.isArray(app.bundle_ids) || typeof app.versions !== "string") continue;
        for (const bundleID of app.bundle_ids) {
          const lessons = [];
          for (const lessonID of course.lessons) {
            const lesson = byID.get(lessonID);
            if (lesson?.kind !== "lesson") continue;
            const assets = lessonAssets(lesson.assets);
            if (!assets) continue;
            const steps = (lesson.steps || []).map((step, position) => scoredStep(step, "guided", `step-${position + 1}`)).filter(Boolean);
            const assessment = scoredStep(lesson.assessment, "assessment", "assessment");
            const transfer = scoredStep(lesson.transfer, "transfer", "transfer");
            if (assessment) steps.push(assessment);
            if (transfer) steps.push(transfer);
            const materialized = steps.map((step) => ({...step, target_descriptor: byID.get(step.target_id) || null,
              detector_descriptor: step.detector_id ? byID.get(step.detector_id) || null : null,
              diagnose: materializeDiagnoses(step.diagnose_refs || [], byID)}));
            if (!materialized.length || materialized.some((step) => step.target_descriptor?.kind !== "ui_target" ||
                (step.detector_descriptor && step.detector_descriptor.kind !== "detector"))) continue;
            // What must already be true before the lesson makes sense, carried
            // with the route so the Mac can refuse *before* opening a lesson the
            // learner cannot finish, and say which condition failed.
            const prerequisites = materializeDiagnoses(
              (Array.isArray(lesson.prerequisites) ? lesson.prerequisites : [])
                .map((entry) => (entry && typeof entry.detector === "string"
                  ? {when: entry.detector, say: text(entry.say || entry.text, "This lesson needs the scene set up differently first.")}
                  : null))
                .filter(Boolean)
                .slice(0, 8),
              byID);
            const escalation = Array.isArray(lesson.teaching_policy?.escalation)
              ? lesson.teaching_policy.escalation.filter((rung) => typeof rung === "string").slice(0, 8)
              : null;
            lessons.push({id: lesson.id, title: text(lesson.title, lesson.id), assets, steps: materialized,
              prerequisites, ...(escalation?.length ? {escalation} : {})});
          }
          if (lessons.length) courses.push({course_id: course.id,
            course_revision: `${index.pack?.id || "pack"}@${index.pack?.pack_version || "unknown"}`,
            pack_id: index.pack?.id || "", app_bundle_id: bundleID, app_version: app.versions, lessons});
        }
      }
    }
  }
  courses.sort((left, right) => left.course_id.localeCompare(right.course_id) || left.app_bundle_id.localeCompare(right.app_bundle_id));
  return {format: COURSE_RUNTIME_FORMAT, format_version: COURSE_RUNTIME_VERSION, courses};
}
