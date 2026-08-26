"""A researched course must compile into the course that was researched.

The regression these guard is specific and was shipping: the compiler counted the
outline's lessons for the progress card and then built the same hardcoded lesson
every time, so every course anyone imported was one particular bevel lesson
wearing the title they had given it. Nothing said so — the card reported the
lesson count they wrote.
"""
from __future__ import annotations

import json
import hashlib
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
COMPILER = ROOT / "tools" / "calla_course_compiler.py"


def lesson(title: str, look_for: str, done_when: str, **extra) -> dict:
    body = {
        "title": title,
        "objective": {"given": "A mesh.", "behavior": title, "criterion": "Unaided."},
        "prerequisites": [{"requires": "The active object is a mesh.", "say": "Select a mesh first."}],
        "misconceptions": [{"belief": "It is permanent.", "correction": "It is not."}],
        "steps": [{"do": f"{title}.", "look_for": look_for, "done_when": done_when}],
        "assessment": {"prompt": "Again.", "done_when": done_when},
        "transfer": {"prompt": "Elsewhere.", "differs_by": "Different start.", "done_when": done_when},
        "retention": {"prompt": "Later.", "done_when": done_when},
    }
    body.update(extra)
    return body


def outline(*lessons: dict) -> str:
    return yaml.safe_dump({
        "course": {"title": "Compiled course", "app": "Blender", "app_versions": ">=5.2 <5.3",
                   "icon": "cube.transparent", "summary": "A course."},
        "lessons": list(lessons),
    }, sort_keys=False)


def compile_outline(text: str, key: str = "compiler-test") -> tuple[int, dict | str]:
    with tempfile.TemporaryDirectory() as directory:
        # Every imported course now owns opaque starter/proof scenes. Test
        # fixtures use tiny opaque payloads; Blender preflight belongs to the
        # lifecycle worker, not this deterministic compiler unit.
        parsed = yaml.safe_load(text)
        starter, proof = b"starter blend fixture", b"proof blend fixture"
        for item in parsed["lessons"]:
            item["assets"] = ["fixture-starter", "fixture-proof"]
        bundle = Path(directory) / "assets.zip"
        with zipfile.ZipFile(bundle, "w") as archive:
            archive.writestr("starter/fixture-starter.blend", starter)
            archive.writestr("proof/fixture-proof.blend", proof)
            archive.writestr("manifest.yaml", yaml.safe_dump({"format": "calla-course-assets", "format_version": 1,
                "assets": [{"asset_id": "fixture-starter", "role": "starter", "sha256": hashlib.sha256(starter).hexdigest(), "bytes": len(starter)},
                           {"asset_id": "fixture-proof", "role": "proof", "sha256": hashlib.sha256(proof).hexdigest(), "bytes": len(proof)}]}))
        source = Path(directory) / "source.json"
        source.write_text(json.dumps({
            "target_app": "org.blenderfoundation.blender",
            "target_version": "5.2.0",
            "outline": yaml.safe_dump(parsed, sort_keys=False),
        }), encoding="utf-8")
        artifact = Path(directory) / "out.pack"
        result = subprocess.run([sys.executable, str(COMPILER), "--source", str(source),
                                 "--artifact", str(artifact), "--course-key", key,
                                 "--asset-bundle", str(bundle)],
                                capture_output=True, text=True)
        if result.returncode != 0:
            return result.returncode, result.stderr.strip()
        report = json.loads(result.stdout)
        staged = artifact.parent / (artifact.stem + ".source")
        report["_lessons"] = sorted(path.name for path in (staged / "lessons").glob("*.yaml"))
        report["_bodies"] = [yaml.safe_load(path.read_text(encoding="utf-8"))
                             for path in sorted((staged / "lessons").glob("*.yaml"))]
        report["_course"] = yaml.safe_load(
            next((staged / "courses").glob("*.yaml")).read_text(encoding="utf-8"))
        return 0, report


class CourseCompilerTests(unittest.TestCase):
    def test_every_authored_lesson_is_compiled_and_none_is_substituted(self):
        code, report = compile_outline(outline(
            lesson("Open the modifier panel", "The wrench icon", "The Modifier Properties context is open."),
            lesson("Add a Bevel", "The Add Modifier button", "The active object has a Bevel modifier."),
        ))
        self.assertEqual(code, 0, report)
        self.assertEqual(report["lesson_count"], 2)
        self.assertEqual(
            report["lessons"],
            [
                {"id": report["lessons"][0]["id"], "title": "Open the modifier panel", "step_count": 1},
                {"id": report["lessons"][1]["id"], "title": "Add a Bevel", "step_count": 1},
            ],
        )
        self.assertRegex(report["artifact_digest"], r"^[0-9a-f]{64}$")
        self.assertEqual(report["compiler_version"], "calla_course_compiler/1")
        self.assertEqual(report["pack_contract_version"], 1)
        self.assertEqual(report["validation_receipt"], "Compiled 2 authored lesson(s) with zero warnings.")
        self.assertEqual(len(report["_bodies"]), 2)
        titles = {body["title"] for body in report["_bodies"]}
        self.assertEqual(titles, {"Open the modifier panel", "Add a Bevel"})
        # The pack's own lesson must not ride along under someone else's course.
        self.assertNotIn("bevel_basics.yaml", report["_lessons"])
        self.assertEqual(len(report["_course"]["lessons"]), 2)

    def test_a_step_resolves_to_the_control_it_described(self):
        code, report = compile_outline(outline(
            lesson("Add a Bevel", "The Add Modifier button", "The active object has a Bevel modifier."),
        ))
        self.assertEqual(code, 0, report)
        step = report["_bodies"][0]["steps"][0]
        self.assertEqual(step["target"], "blender.ui.properties.add_modifier_button")
        self.assertEqual(step["success"]["detector"], "blender.detector.active_object_has_bevel_modifier")

    def test_a_control_this_pack_never_heard_of_fails_loudly(self):
        code, error = compile_outline(outline(
            lesson("Impossible", "The Grease Pencil onion skinning toggle", "Onion skinning is on."),
        ))
        self.assertEqual(code, 2)
        self.assertIn("Grease Pencil onion skinning toggle", error)

    def test_one_unteachable_lesson_fails_the_whole_course(self):
        code, report = compile_outline(outline(
            lesson("Add a Bevel", "The Add Modifier button", "The active object has a Bevel modifier."),
            lesson("Impossible", "The Grease Pencil onion skinning toggle", "Onion skinning is on."),
        ))
        self.assertEqual(code, 2)
        self.assertIn("Grease Pencil", report)

    def test_diagnoses_and_prerequisites_survive_into_the_lesson(self):
        code, report = compile_outline(outline(lesson(
            "Add a Bevel", "The Add Modifier button", "The active object has a Bevel modifier.",
            prerequisites=[{"requires": "The active object is a mesh.",
                            "say": "Select a mesh first."}],
        ) | {"steps": [{
            "do": "Choose Add Modifier and pick Bevel.",
            "look_for": "The Add Modifier button",
            "done_when": "The active object has a Bevel modifier.",
            "diagnose": [{"when": "The active object has a Subdivision Surface modifier.",
                          "say": "That is a Subdivision Surface, not a Bevel."}],
        }]}))
        self.assertEqual(code, 0, report)
        body = report["_bodies"][0]
        self.assertEqual(body["prerequisites"],
                         [{"detector": "blender.detector.active_object_is_mesh", "say": "Select a mesh first."}])
        self.assertEqual(body["steps"][0]["diagnose"],
                         [{"when": "blender.detector.active_object_has_subsurf",
                           "say": "That is a Subdivision Surface, not a Bevel."}])

    def test_a_coordinate_anywhere_in_the_outline_is_refused(self):
        raw = yaml.safe_load(outline(
            lesson("Add a Bevel", "The Add Modifier button", "The active object has a Bevel modifier.")))
        raw["lessons"][0]["steps"][0]["x"] = 1420
        code, error = compile_outline(yaml.safe_dump(raw, sort_keys=False))
        self.assertEqual(code, 2)
        self.assertIn("unsupported target data", error)


if __name__ == "__main__":
    unittest.main()
