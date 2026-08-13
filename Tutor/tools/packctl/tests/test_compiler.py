from __future__ import annotations

import json
import shutil
import tempfile
import unittest
import zipfile
from pathlib import Path

from calla_tutor_pack import PackError, compile_pack, search_pack, validate_pack


REPO_ROOT = Path(__file__).resolve().parents[3]
BLENDER_PACK = REPO_ROOT / "packs" / "blender"


class PackCompilerTests(unittest.TestCase):
    def test_blender_pack_validates_with_semantic_references(self) -> None:
        result = validate_pack(BLENDER_PACK)
        self.assertEqual(result.manifest["id"], "org.calla.tutor.blender")
        ids = {entity["id"] for entity in result.entities}
        self.assertIn("blender.lesson.lamp_finish", ids)
        self.assertIn("blender.ui.properties.modifiers_tab", ids)
        self.assertGreaterEqual(len(ids), 10)

    def test_compile_builds_manifest_entities_and_fts_index(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "blender.otpack"
            result = compile_pack(BLENDER_PACK, output)
            self.assertEqual(result.pack_id, "org.calla.tutor.blender")
            self.assertTrue(output.is_file())
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(
                    sorted(archive.namelist()),
                    ["assets/lamp-base-proof.blend", "assets/lamp-base-starter.blend",
                     "assets/lamp-finish-proof.blend", "assets/lamp-finish-starter.blend",
                     "assets/lamp-proportion-proof.blend", "assets/lamp-proportion-starter.blend",
                     "assets/lamp-shade-proof.blend", "assets/lamp-shade-starter.blend",
                     "assets/lamp-stem-proof.blend", "assets/lamp-stem-starter.blend",
                     "entities.json", "index.sqlite3", "manifest.json"],
                )
                manifest = json.loads(archive.read("manifest.json"))
                self.assertEqual(manifest["format"], "calla-tutor-pack")
                self.assertEqual(manifest["entity_count"], result.entity_count)
                entities = json.loads(archive.read("entities.json"))
                descriptor = next(item for item in entities if item["id"] == "blender.ui.properties.modifiers_tab")
                self.assertEqual(descriptor["resolve"]["bridge"]["selector"]["tab"], "MODIFIER")
                self.assertEqual(descriptor["resolve"]["bridge"]["selector"]["region_type"], "NAVIGATION_BAR")
                self.assertEqual(descriptor["minimum_confidence"], {"point": 0.72, "act": 0.92})
                self.assertEqual(descriptor["source_file"], "ui/modifiers_tab.yaml")

            matches = search_pack(output, "bevel", limit=10)
            self.assertTrue(matches)
            self.assertIn("blender.detector.active_object_has_bevel_modifier", {match["id"] for match in matches})

    def test_duplicate_entity_ids_fail_closed(self) -> None:
        with self._pack_copy() as pack:
            duplicate = pack / "ui" / "duplicate.yaml"
            duplicate.write_text(
                "id: blender.ui.properties.modifiers_tab\n"
                "title: Duplicate\n"
                "source_refs: [open-tutor-authored]\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(PackError, "duplicate entity id"):
                validate_pack(pack)

    def test_raw_action_coordinates_are_forbidden(self) -> None:
        with self._pack_copy() as pack:
            unsafe = pack / "lessons" / "unsafe.yaml"
            unsafe.write_text(
                "id: blender.lesson.unsafe\n"
                "title: Unsafe coordinate lesson\n"
                "source_refs: [open-tutor-authored]\n"
                "action:\n"
                "  coordinates: [847, 291]\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(PackError, "coordinate-bearing fields"):
                validate_pack(pack)

    def test_unsafe_or_oversized_matchers_fail_closed(self) -> None:
        with self._pack_copy() as pack:
            target = pack / "ui" / "modifiers_tab.yaml"
            target.write_text(
                target.read_text(encoding="utf-8").replace("pattern: modifier", "pattern: 'modifier.*'"),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(PackError, "forbidden regex operator"):
                validate_pack(pack)

        with self._pack_copy() as pack:
            target = pack / "ui" / "modifiers_tab.yaml"
            target.write_text(
                target.read_text(encoding="utf-8").replace("pattern: modifier", f"pattern: {'m' * 129}"),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(PackError, "128 bytes"):
                validate_pack(pack)

    def test_invalid_descriptor_confidence_and_coordinates_fail_closed(self) -> None:
        with self._pack_copy() as pack:
            target = pack / "ui" / "modifiers_tab.yaml"
            target.write_text(
                target.read_text(encoding="utf-8").replace("point: 0.72", "point: 1.2"),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(PackError, "minimum_confidence.point"):
                validate_pack(pack)

        with self._pack_copy() as pack:
            target = pack / "ui" / "modifiers_tab.yaml"
            target.write_text(
                target.read_text(encoding="utf-8").replace("      tab: MODIFIER", "      tab: MODIFIER\n      left: 0.1"),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(PackError, "coordinate-bearing fields"):
                validate_pack(pack)

    def test_unknown_semantic_target_fails(self) -> None:
        with self._pack_copy() as pack:
            broken = pack / "workflows" / "broken.yaml"
            broken.write_text(
                "id: blender.workflow.broken\n"
                "title: Broken workflow\n"
                "source_refs: [open-tutor-authored]\n"
                "steps:\n"
                "  - instruction: Do something\n"
                "    target: blender.ui.does_not_exist\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(PackError, "references unknown id"):
                validate_pack(pack)

    def test_lesson_pedagogy_fields_are_required_and_scored(self) -> None:
        with self._pack_copy() as pack:
            lesson = pack / "lessons" / "lamp_finish.yaml"
            lesson.write_text(lesson.read_text(encoding="utf-8").replace(
                "objective: {given: Completed lamp mesh is selected., behavior: Add non-destructive Bevel modifier., criterion: Active mesh has Bevel modifier.}",
                "objective: {behavior: Add non-destructive Bevel modifier., criterion: Active mesh has Bevel modifier.}"), encoding="utf-8")
            with self.assertRaisesRegex(PackError, "objective.*given"):
                validate_pack(pack)
        with self._pack_copy() as pack:
            lesson = pack / "lessons" / "lamp_finish.yaml"
            lesson.write_text(lesson.read_text(encoding="utf-8").replace("target: blender.ui.properties.add_modifier_button, detector: blender.detector.bevel_precedes_subsurf", "detector: blender.detector.bevel_precedes_subsurf"), encoding="utf-8")
            with self.assertRaisesRegex(PackError, "target"):
                validate_pack(pack)

    def test_course_orders_lessons_and_rejects_one_that_does_not_exist(self) -> None:
        result = validate_pack(BLENDER_PACK)
        courses = [entity for entity in result.entities if entity["kind"] == "course"]
        self.assertTrue(courses, "the Blender pack ships at least one course")
        for course in courses:
            self.assertTrue(course.get("lessons"), f"{course['id']} lists its lessons in teaching order")
            self.assertTrue(course.get("summary"), f"{course['id']} says what it is for")

        # A course is a list of lessons and nothing else, so a name that resolves
        # to nothing is the whole course being empty. It has to fail the build
        # rather than reach a learner as a course that opens onto nothing.
        with self._pack_copy() as pack:
            course = pack / "courses" / "modelling_basics.yaml"
            course.write_text(
                course.read_text(encoding="utf-8") + "  - blender.lesson.does_not_exist\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(PackError, "lessons references unknown id"):
                validate_pack(pack)

        # And a course may only point at lessons: naming a concept or a detector
        # would compile into a course whose contents cannot be taught.
        with self._pack_copy() as pack:
            course = pack / "courses" / "modelling_basics.yaml"
            course.write_text(
                course.read_text(encoding="utf-8").replace(
                    "  - blender.lesson.lamp_base",
                    "  - blender.concept.non_destructive_modifiers",
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(PackError, "expected 'lesson'"):
                validate_pack(pack)

    def _pack_copy(self):
        class CopyContext:
            def __init__(self) -> None:
                self.temporary_directory = tempfile.TemporaryDirectory()
                self.path = Path(self.temporary_directory.name) / "blender"

            def __enter__(inner_self) -> Path:
                shutil.copytree(BLENDER_PACK, inner_self.path)
                return inner_self.path

            def __exit__(inner_self, exc_type, exc, traceback) -> None:
                inner_self.temporary_directory.cleanup()

        return CopyContext()


if __name__ == "__main__":
    unittest.main()
