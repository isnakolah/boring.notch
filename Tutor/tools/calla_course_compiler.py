#!/usr/bin/env python3
"""Conservative, deterministic Gateway worker for a researched Calla course.

A researched outline is prose. It names controls the way a person would — "the
wrench icon in the vertical strip of property icons" — because the model that
wrote it cannot see the screen and is forbidden from inventing identifiers or
coordinates. This worker turns that prose into a real App Pack by resolving each
`look_for` and `done_when` against the descriptor set already checked in and
validated, and nothing else.

What it will not do is as important as what it does. It never invents a selector,
a coordinate, or a descriptor; it never lowers a confidence threshold; and it
never substitutes a control the outline did not ask for. A phrase that does not
resolve to exactly one shipped entity is reported by name and its lesson is
dropped, because a course that silently teaches something other than what was
written is worse than a course that fails review.

This is a rewrite of a version that took the outline's lessons, counted them for
the progress card, and then compiled the same hardcoded bevel lesson every time —
so every course anyone ever imported was the same course, wearing the title they
gave it.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
import zipfile
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]
PACKCTL = ROOT / "tools" / "packctl" / "src"
sys.path.insert(0, str(PACKCTL))
from calla_tutor_pack.compiler import PackError, compile_pack  # noqa: E402

TARGET = "org.blenderfoundation.blender"
MAX_LESSONS = 24
MAX_STEPS = 24
MAX_ASSET_BYTES = 128 * 1024 * 1024

# Words that appear in every description of every control and so carry no
# information about which one is meant. Left out of scoring rather than out of
# the text, so a phrase made only of these resolves to nothing rather than to
# whichever entity happens to be first.
STOPWORDS = frozenset(
    """a an and are as at be button by click clicking control down for from icon
    in into is it its of on onto open opens or panel press select selecting show
    showing that the then there this to top up use using where which with your""".split()
)


def reject_unsafe(value: Any) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if re.search(r"(?:coord|pixel|screen[_-]?(?:x|y)|\bx\b|\by\b)", str(key), re.I):
                raise ValueError("outline contains unsupported target data")
            reject_unsafe(child)
    elif isinstance(value, list):
        for child in value:
            reject_unsafe(child)


def load_asset_bundle(bundle: Path) -> dict[str, dict[str, Any]]:
    """Validate owner-supplied opaque Blender scenes before authoring starts."""
    if not bundle.is_file() or bundle.stat().st_size > MAX_ASSET_BYTES * 24:
        raise ValueError("asset bundle is missing or too large")
    try:
        with zipfile.ZipFile(bundle) as archive:
            manifest = yaml.safe_load(archive.read("manifest.yaml"))
            if not isinstance(manifest, dict) or manifest.get("format") != "calla-course-assets" or manifest.get("format_version") != 1:
                raise ValueError("asset bundle manifest is unsupported")
            declared = manifest.get("assets")
            if not isinstance(declared, list) or not declared:
                raise ValueError("asset bundle has no assets")
            result: dict[str, dict[str, Any]] = {}
            for item in declared:
                if not isinstance(item, dict): raise ValueError("asset bundle asset is malformed")
                asset_id, role, digest, size = item.get("asset_id"), item.get("role"), item.get("sha256"), item.get("bytes")
                if (not isinstance(asset_id, str) or not re.fullmatch(r"[a-z0-9][a-z0-9._-]{2,120}", asset_id)
                        or role not in {"starter", "proof"} or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)
                        or not isinstance(size, int) or not 0 < size <= MAX_ASSET_BYTES or asset_id in result):
                    raise ValueError("asset bundle has duplicate or invalid asset metadata")
                member = f"{role}/{asset_id}.blend"
                payload = archive.read(member)
                if len(payload) != size or hashlib.sha256(payload).hexdigest() != digest:
                    raise ValueError("asset bundle asset hash does not match manifest")
                result[asset_id] = {"asset_id": asset_id, "role": role, "sha256": digest, "bytes": size, "payload": payload}
    except (KeyError, zipfile.BadZipFile, OSError, yaml.YAMLError) as error:
        raise ValueError("asset bundle is invalid") from error
    return result


def require_course_contract(outline: dict[str, Any], assets: dict[str, dict[str, Any]]) -> None:
    """No partial lessons, implied pedagogy, or unbound binaries reach a learner."""
    for index, lesson in enumerate(outline.get("lessons", []), 1):
        if not isinstance(lesson, dict): raise ValueError(f"lesson {index} is malformed")
        required = {"title", "objective", "prerequisites", "misconceptions", "steps", "assessment", "transfer", "retention", "assets"}
        missing = required - set(lesson)
        if missing: raise ValueError(f"lesson {index} omits required course fields: {', '.join(sorted(missing))}")
        if not isinstance(lesson["objective"], dict) or not all(isinstance(lesson["objective"].get(k), str) and lesson["objective"][k].strip() for k in ("given", "behavior", "criterion")):
            raise ValueError(f"lesson {index} objective is incomplete")
        if not isinstance(lesson["prerequisites"], list) or not lesson["prerequisites"]:
            raise ValueError(f"lesson {index} needs a prerequisite")
        if not isinstance(lesson["misconceptions"], list) or not lesson["misconceptions"]:
            raise ValueError(f"lesson {index} needs a misconception")
        if not isinstance(lesson["steps"], list) or not lesson["steps"]:
            raise ValueError(f"lesson {index} needs at least one action")
        for step in lesson["steps"]:
            if not isinstance(step, dict) or not all(isinstance(step.get(k), str) and step[k].strip() for k in ("do", "look_for", "done_when")):
                raise ValueError(f"lesson {index} has an incomplete action")
        for name in ("assessment", "transfer", "retention"):
            item = lesson[name]
            if not isinstance(item, dict) or not isinstance(item.get("prompt"), str) or not item["prompt"].strip() or not isinstance(item.get("done_when"), str) or not item["done_when"].strip():
                raise ValueError(f"lesson {index} {name} is incomplete")
        selected = lesson["assets"]
        if not isinstance(selected, list) or len(selected) != 2 or any(not isinstance(x, str) for x in selected):
            raise ValueError(f"lesson {index} must name starter and proof asset ids")
        records = [assets.get(asset_id) for asset_id in selected]
        if any(record is None for record in records) or {record["role"] for record in records if record} != {"starter", "proof"}:
            raise ValueError(f"lesson {index} has missing or wrong-role asset")


def text(value: Any, fallback: str) -> str:
    value = value if isinstance(value, str) else fallback
    return " ".join(value.split())[:240] or fallback


def sentence(value: Any, fallback: str) -> str:
    value = value if isinstance(value, str) else fallback
    return " ".join(value.split())[:500] or fallback


def slugify(value: str, fallback: str = "item") -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")[:48] or fallback


def tokens(value: str) -> set[str]:
    return {word for word in re.findall(r"[a-z0-9]+", value.lower()) if word not in STOPWORDS}


class Resolver:
    """Maps a phrase onto one entity the pack already ships, or onto nothing.

    Scoring is deliberately blunt and explainable: an entity's own title and each
    of its aliases are compared with the phrase, and the best overlap wins only if
    it beats every other entity outright. Two entities that fit equally well is an
    ambiguity the author has to settle — picking one would be the compiler
    deciding what the lesson teaches.
    """

    def __init__(self, entities: list[dict[str, Any]], kind: str):
        self.kind = kind
        self.entries: list[tuple[str, list[set[str]]]] = []
        for entity in entities:
            if entity.get("kind") != kind:
                continue
            names = [entity.get("title", "")] + list(entity.get("aliases") or [])
            self.entries.append((entity["id"], [tokens(name) for name in names if name]))
        # How much each word narrows things down. "Properties" appears in half
        # this pack and settles nothing; "wrench" appears in one entity and
        # settles everything. Without this, "the wrench icon in the properties
        # column" matched the Properties editor and the Modifier tab equally
        # well and the whole lesson was refused for an ambiguity a reader would
        # not see.
        self.weights: dict[str, float] = {}
        appearances: dict[str, int] = {}
        for _identifier, name_tokens in self.entries:
            for word in {word for name in name_tokens for word in name}:
                appearances[word] = appearances.get(word, 0) + 1
        total = max(len(self.entries), 1)
        for word, count in appearances.items():
            self.weights[word] = 1.0 + (total / count) ** 0.5

    def weight(self, words: set[str]) -> float:
        return sum(self.weights.get(word, 1.0) for word in words)

    def resolve(self, phrase: str) -> tuple[str | None, str]:
        wanted = tokens(phrase)
        if not wanted:
            return None, "no distinguishing words"
        scored: list[tuple[float, str]] = []
        for identifier, name_tokens in self.entries:
            best = 0.0
            for name in name_tokens:
                shared = name & wanted
                if not shared:
                    continue
                # How much of this name the phrase accounts for, and how much of
                # the phrase this name accounts for, both weighted towards the
                # words that actually distinguish one control from another.
                covered = self.weight(shared) / self.weight(name)
                explained = self.weight(shared) / self.weight(wanted)
                best = max(best, covered * 0.7 + explained * 0.3)
            if best:
                scored.append((best, identifier))
        if not scored:
            return None, f"no {self.kind} in this pack matches"
        scored.sort(reverse=True)
        # A near-tie is an ambiguity the author has to settle. Choosing for them
        # would be the compiler deciding what the lesson teaches.
        if len(scored) > 1 and scored[0][0] - scored[1][0] < 0.05:
            return None, f"matches both {scored[0][1]} and {scored[1][1]} equally"
        return scored[0][1], ""


def build_lesson(raw: dict[str, Any], index: int, targets: Resolver, detectors: Resolver,
                 warnings: list[str], assets: dict[str, dict[str, Any]]) -> dict[str, Any] | None:
    title = text(raw.get("title"), f"Lesson {index + 1}")
    lesson_id = f"blender.lesson.{slugify(title, f'lesson-{index + 1}')}"
    unresolved: list[str] = []

    def target_for(phrase: str, where: str) -> str | None:
        identifier, why = targets.resolve(phrase)
        if identifier is None:
            unresolved.append(f"{title}: {where} — {why}: {phrase!r}")
        return identifier

    def detector_for(phrase: str, where: str) -> str | None:
        identifier, why = detectors.resolve(phrase)
        if identifier is None:
            unresolved.append(f"{title}: {where} — {why}: {phrase!r}")
        return identifier

    steps: list[dict[str, Any]] = []
    for position, step in enumerate(raw.get("steps") or []):
        if not isinstance(step, dict):
            continue
        if len(steps) >= MAX_STEPS:
            warnings.append(f"{title}: only the first {MAX_STEPS} steps were kept.")
            break
        instruction = sentence(step.get("do"), "")
        if not instruction:
            continue
        target = target_for(text(step.get("look_for"), instruction), f"step {position + 1} look_for")
        detector = detector_for(text(step.get("done_when"), ""), f"step {position + 1} done_when")
        if not target or not detector:
            continue
        entry: dict[str, Any] = {
            "id": slugify(step.get("id") or instruction, f"step-{position + 1}"),
            "instruction": instruction,
            "target": target,
            "success": {"detector": detector},
        }
        diagnose = []
        for item in step.get("diagnose") or []:
            if not isinstance(item, dict):
                continue
            when = detector_for(text(item.get("when"), ""), f"step {position + 1} diagnose.when")
            say = text(item.get("say"), "")
            if when and say:
                diagnose.append({"when": when, "say": say})
        if diagnose:
            entry["diagnose"] = diagnose[:8]
        steps.append(entry)

    scored = {}
    for name, fallback in (("assessment", "Do it again without hints."),
                           ("transfer", "Do the same thing somewhere it is not identical."),
                           ("retention", "Do it again later, from memory.")):
        item = raw.get(name) if isinstance(raw.get(name), dict) else {}
        prompt = sentence(item.get("prompt"), fallback)
        target = steps[-1]["target"] if steps else None
        detector = detector_for(text(item.get("done_when"), ""), f"{name} done_when") if item.get("done_when") else None
        if not detector and steps:
            detector = steps[-1]["success"]["detector"]
        entry = {"prompt": prompt}
        if target and detector:
            entry["pass"] = {"target": target, "detector": detector}
        if name == "transfer":
            entry["differs_by"] = sentence(item.get("differs_by"), "The starting state is different.")
        scored[name] = entry

    misconceptions = [
        {"belief": text(item.get("belief"), ""), "correction": text(item.get("correction"), "")}
        for item in (raw.get("misconceptions") or [])
        if isinstance(item, dict) and item.get("belief") and item.get("correction")
    ]

    if unresolved:
        warnings.extend(unresolved[:6])
        return None
    if not steps:
        warnings.append(f"{title}: no step resolved to a control this pack knows.")
        return None
    if not misconceptions:
        warnings.append(f"{title}: no misconception was written, so one was not taught.")
        misconceptions = [{"belief": "The steps are the skill.",
                           "correction": "The steps are how the skill is practised; the idea behind them is what transfers."}]

    objective = raw.get("objective") if isinstance(raw.get("objective"), dict) else {}
    lesson: dict[str, Any] = {
        "id": lesson_id,
        "title": title,
        "app_versions": text(raw.get("app_versions"), ">=5.2 <5.3"),
        "source_refs": ["blender-manual", "open-tutor-authored"],
        "objective": {
            "given": sentence(objective.get("given"), "The application is open."),
            "behavior": sentence(objective.get("behavior"), title),
            "criterion": sentence(objective.get("criterion"), "The learner can do it unaided."),
        },
        "steps": steps,
        "assessment": scored["assessment"],
        "transfer": scored["transfer"],
        "retention": scored["retention"],
        "misconceptions": misconceptions[:8],
        "assets": [{key: value for key, value in assets[asset_id].items() if key != "payload"}
                   for asset_id in raw["assets"]],
    }
    checkpoint = sentence((raw.get("checkpoint") or {}).get("explain") if isinstance(raw.get("checkpoint"), dict) else "", "")
    if checkpoint:
        lesson["checkpoint"] = {"explain": checkpoint}
    prerequisites = []
    for item in raw.get("prerequisites") or []:
        if not isinstance(item, dict):
            continue
        identifier, _why = detectors.resolve(text(item.get("requires"), ""))
        say = text(item.get("say"), "")
        if identifier and say:
            prerequisites.append({"detector": identifier, "say": say})
    if prerequisites:
        lesson["prerequisites"] = prerequisites[:8]
    return lesson


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--course-key", required=True)
    parser.add_argument("--asset-bundle", type=Path, required=True)
    args = parser.parse_args()
    source = json.loads(args.source.read_text(encoding="utf-8"))
    if source.get("target_app") != TARGET or not isinstance(source.get("target_version"), str):
        raise ValueError("selected application is not supported by the installed descriptor set")
    outline = yaml.safe_load(source.get("outline", ""))
    if (not isinstance(outline, dict) or not isinstance(outline.get("course"), dict)
            or not isinstance(outline.get("lessons"), list) or not outline["lessons"]):
        raise ValueError("outline is not a complete Calla course")
    reject_unsafe(outline)
    assets = load_asset_bundle(args.asset_bundle)
    require_course_contract(outline, assets)
    course = outline["course"]
    if "blender" not in text(course.get("app"), "").lower():
        raise ValueError("outline application does not match selected application")

    stage = args.artifact.parent / (args.artifact.stem + ".source")
    shutil.rmtree(stage, ignore_errors=True)
    shutil.copytree(ROOT / "packs" / "blender", stage)
    shutil.rmtree(stage / "assets", ignore_errors=True)
    (stage / "assets").mkdir()
    for asset in assets.values():
        (stage / "assets" / f"{asset['asset_id']}.blend").write_bytes(asset["payload"])

    # Resolve against the descriptor set as shipped, before anything is written.
    installed: list[dict[str, Any]] = []
    for directory, kind in (("ui", "ui_target"), ("detectors", "detector")):
        for path in sorted((stage / directory).glob("*.yaml")):
            loaded = yaml.safe_load(path.read_text(encoding="utf-8"))
            for entity in (loaded.get("entities", []) if isinstance(loaded, dict) and "entities" in loaded
                           else [loaded] if isinstance(loaded, dict) else []):
                if isinstance(entity, dict) and entity.get("id"):
                    installed.append({**entity, "kind": entity.get("kind", kind)})
    targets = Resolver(installed, "ui_target")
    detectors = Resolver(installed, "detector")

    warnings: list[str] = []
    lessons: list[dict[str, Any]] = []
    for index, raw in enumerate(outline["lessons"][:MAX_LESSONS]):
        if not isinstance(raw, dict):
            continue
        lesson = build_lesson(raw, index, targets, detectors, warnings, assets)
        if lesson:
            lessons.append(lesson)
    if len(outline["lessons"]) > MAX_LESSONS:
        warnings.append(f"Only the first {MAX_LESSONS} lessons were compiled.")
    if warnings or len(lessons) != len(outline["lessons"]):
        # Loud, and by name. The previous version reached here and shipped a
        # different course under this one's title.
        detail = "; ".join(warnings[:4]) or "a lesson did not compile"
        raise ValueError(f"course import failed; every lesson must compile: {detail}")

    slug = slugify(text(course.get("title"), "course"), "course")
    manifest = yaml.safe_load((stage / "pack.yaml").read_text(encoding="utf-8"))
    course_key = re.sub(r"[^a-z0-9]+", "-", args.course_key.lower()).strip("-")[:80]
    manifest["id"] = f"org.calla.tutor.blender.course.{course_key}"
    manifest["pack_version"] = "1.0.0"
    (stage / "pack.yaml").write_text(yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8")

    # The staged copy exists for its controls and detectors, not its lessons. Its
    # own lessons and their expectations go, or an imported course ships a
    # stranger's lesson alongside its author's — reachable by search, listed by
    # nothing, and impossible to explain.
    for directory in ("lessons", "courses", "tests"):
        shutil.rmtree(stage / directory, ignore_errors=True)
        (stage / directory).mkdir()
    for lesson in lessons:
        path = stage / "lessons" / f"{lesson['id'].rsplit('.', 1)[-1]}.yaml"
        path.write_text(yaml.safe_dump(lesson, sort_keys=False, allow_unicode=True), encoding="utf-8")

    course_entity = {
        "id": f"blender.course.{slug}", "kind": "course", "title": text(course.get("title"), "Untitled course"),
        "icon": text(course.get("icon"), "books.vertical"), "summary": text(course.get("summary"), "A Calla course."),
        "app_versions": text(course.get("app_versions"), ">=5.2 <5.3"),
        "source_refs": ["blender-manual", "open-tutor-authored"],
        "lessons": [lesson["id"] for lesson in lessons],
    }
    (stage / "courses" / f"{slug}.yaml").write_text(yaml.safe_dump(course_entity, sort_keys=False), encoding="utf-8")
    compile_pack(stage, args.artifact)
    # Review status is owner-facing metadata only. It contains ordering and
    # deterministic compiler facts, never source outline, prompts, paths, or
    # model output. The Gateway keeps the artifact itself private until explicit
    # publication.
    print(json.dumps({
        "title": course_entity["title"],
        "lesson_count": len(lessons),
        "lessons": [{"id": lesson["id"], "title": lesson["title"], "step_count": len(lesson["steps"])} for lesson in lessons],
        "pack_id": manifest["id"],
        "artifact_digest": hashlib.sha256(args.artifact.read_bytes()).hexdigest(),
        "compiler_version": "calla_course_compiler/1",
        "pack_contract_version": 1,
        "validation_receipt": f"Compiled {len(lessons)} authored lesson(s) with zero warnings.",
        "warnings": [],
    }))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, PackError, OSError, json.JSONDecodeError, yaml.YAMLError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(2)
