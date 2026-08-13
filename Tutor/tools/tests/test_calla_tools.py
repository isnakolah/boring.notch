from __future__ import annotations

import importlib.util
import io
import json
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from contextlib import redirect_stdout


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


def load_script(name: str):
    path = REPOSITORY_ROOT / "tools" / name
    spec = importlib.util.spec_from_file_location(path.stem, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pack_store = load_script("calla_pack_store.py")
gateway_setup = load_script("calla_openclaw_setup.py")
migration = load_script("calla_migration.py")


class CallaToolTests(unittest.TestCase):
    def test_active_config_path_ignores_openclaw_warning_lines(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            config = Path(temporary_directory) / "openclaw.json"
            config.write_text("{}", encoding="utf-8")
            warning = "plugin tutor: duplicate plugin id resolved"
            with patch.object(gateway_setup, "run", return_value=SimpleNamespace(stdout=f"{warning}\n{config}\n")):
                self.assertEqual(gateway_setup.active_config_path("openclaw"), config)

    def test_compiled_pack_is_copied_to_server_local_index(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            source = temporary / "blender.otpack"
            prior_pack = temporary / "tutor" / "packs" / "org.open-desktop-tutor.blender-0.1.0.otpack"
            prior_index = temporary / "tutor" / "indexes" / "org.open-desktop-tutor.blender-0.1.0.json"
            prior_pack.parent.mkdir(parents=True)
            prior_index.parent.mkdir(parents=True)
            prior_pack.write_bytes(b"old-pack")
            prior_index.write_text("{}", encoding="utf-8")
            manifest = {
                "format": "open-desktop-tutor-pack",
                "format_version": 1,
                "entity_count": 1,
                "pack": {
                    "id": "org.open-desktop-tutor.blender",
                    "pack_version": "0.2.0",
                    "apps": [{"platform": "macos", "bundle_ids": ["org.blenderfoundation.blender"], "versions": ">=5.2 <5.3", "locales": ["en"]}],
                },
            }
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr("manifest.json", json.dumps(manifest))
                archive.writestr("entities.json", json.dumps([{"id": "blender.lesson.bevel", "kind": "lesson", "title": "Bevel"}]))
            result = pack_store.install_pack(source, temporary / "tutor")
            index_path = Path(result["index_path"])
            self.assertTrue(Path(result["pack_path"]).is_file())
            self.assertEqual(stat.S_IMODE(index_path.stat().st_mode), 0o600)
            index = json.loads(index_path.read_text())
            self.assertEqual(index["format"], "calla-local-pack-index")
            self.assertEqual(index["entities"][0]["id"], "blender.lesson.bevel")
            self.assertFalse(prior_pack.exists())
            self.assertFalse(prior_index.exists())
            self.assertEqual(result["removed_revisions"], 2)

    def test_pack_store_rejects_an_invalid_compiled_descriptor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = Path(temporary_directory) / "unsafe.otpack"
            manifest = {
                "format": "calla-tutor-pack",
                "format_version": 1,
                "entity_count": 1,
                "pack": {
                    "id": "org.calla.tutor.blender",
                    "pack_version": "0.3.0",
                    "apps": [{"platform": "macos", "bundle_ids": ["org.blenderfoundation.blender"], "versions": ">=5.2 <5.3", "locales": ["en"]}],
                },
            }
            unsafe = {
                "id": "blender.ui.unsafe", "kind": "ui_target", "title": "Unsafe", "source_file": "ui/unsafe.yaml",
                "resolve": {"accessibility": {"candidates": [{"role": "AXButton", "label_matcher": {"pattern": "unsafe.*"}}]}},
                "minimum_confidence": {"point": 0.7, "act": 0.9},
            }
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr("manifest.json", json.dumps(manifest))
                archive.writestr("entities.json", json.dumps([unsafe]))
            with self.assertRaisesRegex(pack_store.PackStoreError, "invalid descriptor"):
                pack_store.install_pack(source, Path(temporary_directory) / "tutor")

    def test_gateway_patch_is_additive_and_records_ownership(self) -> None:
        patch, ownership = gateway_setup.build_gateway_patch(
            plugin_allow=["existing-plugin"],
            plugin_paths=["/safe/existing-plugin", "/srv/app/.openclaw/apps/desktop-tutor"],
            allowed_origins=["https://private.nomonlab.com"],
            agent_list=[{"id": "main", "name": "Main"}],
            node_id="paired-mac-node",
            state_directory=Path("/safe/tutor"),
            plugin_path=Path("/safe/calla-plugin"),
            agent_workspace=Path("/safe/calla-workspace"),
        )
        self.assertEqual(patch["plugins"]["allow"], ["existing-plugin", "tutor"])
        self.assertEqual(patch["plugins"]["load"]["paths"], ["/safe/existing-plugin", "/safe/calla-plugin"])
        self.assertNotIn("controlUi", patch["gateway"])
        self.assertEqual(patch["plugins"]["entries"]["tutor"]["config"]["nodeId"], "paired-mac-node")
        self.assertFalse(patch["plugins"]["entries"]["tutor"]["config"]["requireOwnerIdentity"])
        self.assertEqual(patch["agents"]["list"][1], gateway_setup.calla_agent_configuration(Path("/safe/calla-workspace")))
        calla = patch["agents"]["list"][1]
        self.assertEqual(calla["skills"], [])
        self.assertEqual(calla["memorySearch"], {"enabled": False})
        self.assertEqual(calla["contextInjection"], "continuation-skip")
        self.assertEqual(calla["params"]["cacheRetention"], "long")
        self.assertEqual(patch["gateway"]["auth"]["mode"], "none")
        self.assertEqual(patch["gateway"]["bind"], "loopback")
        self.assertEqual(patch["gateway"]["tailscale"]["mode"], "off")
        self.assertEqual(ownership, {"plugin_allow_added": True, "plugin_path_added": True, "legacy_plugin_paths_removed": True, "legacy_origin_removed": False, "calla_agent_added": True})

    def test_gateway_patch_does_not_create_an_allowlist_when_none_exists(self) -> None:
        patch, ownership = gateway_setup.build_gateway_patch(
            plugin_allow=None,
            plugin_paths=None,
            allowed_origins=None,
            agent_list=None,
            node_id=None,
            state_directory=Path("/safe/tutor"),
            plugin_path=Path("/safe/calla-plugin"),
            agent_workspace=Path("/safe/calla-workspace"),
        )
        self.assertNotIn("allow", patch["plugins"])
        self.assertEqual(patch["plugins"]["load"]["paths"], ["/safe/calla-plugin"])
        self.assertFalse(ownership["legacy_origin_removed"])
        self.assertEqual(patch["agents"]["list"], [gateway_setup.calla_agent_configuration(Path("/safe/calla-workspace"))])

    def test_gateway_patch_preserves_an_existing_calla_agent(self) -> None:
        existing = {"id": "calla", "name": "User-owned Calla", "thinkingDefault": "high"}
        patch, ownership = gateway_setup.build_gateway_patch(
            plugin_allow=None,
            plugin_paths=None,
            allowed_origins=None,
            agent_list=[existing],
            node_id=None,
            state_directory=Path("/safe/tutor"),
            plugin_path=Path("/safe/calla-plugin"),
            agent_workspace=Path("/safe/calla-workspace"),
        )
        self.assertEqual(patch["agents"]["list"], [existing])
        self.assertFalse(ownership["calla_agent_added"])

    def test_migration_moves_only_the_known_calla_workspace_and_preserves_state_backup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            legacy_state = temporary / "calla"
            (legacy_state / "indexes").mkdir(parents=True)
            (legacy_state / "indexes" / "org.open-desktop-tutor.blender-0.3.0.json").write_text("{}", encoding="utf-8")
            destination = temporary / "tutor"
            backup = migration.migrate_state(legacy_state, destination, "20260811T000000Z")
            self.assertTrue((destination / "indexes" / "org.open-desktop-tutor.blender-0.3.0.json").is_file())
            self.assertTrue((backup / "indexes" / "org.open-desktop-tutor.blender-0.3.0.json").is_file())
            agents, changed = migration.migrate_calla_agent(
                [{"id": "main"}, {"id": "calla", "workspace": str(migration.KNOWN_LEGACY_CALLA_WORKSPACE)}],
                temporary / "agent-workspace",
            )
            self.assertTrue(changed)
            calla = agents[1]
            self.assertEqual(calla["workspace"], str(temporary / "agent-workspace"))
            self.assertEqual(calla["tools"]["alsoAllow"], migration.CALLA_AGENT_TOOLS)
            with self.assertRaisesRegex(migration.MigrationError, "unexpected workspace"):
                migration.migrate_calla_agent([{"id": "calla", "workspace": "/user/owned"}], temporary / "agent-workspace")

    def test_gateway_installer_is_idempotent_and_removal_stays_in_calla_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            state_directory = root / "tutor"
            unrelated = root / "unrelated"
            unrelated.mkdir()
            (unrelated / "keep.txt").write_text("keep", encoding="utf-8")
            arguments = SimpleNamespace(
                yes=True,
                openclaw_bin="fake-openclaw",
                state_directory=state_directory,
                repository=REPOSITORY_ROOT,
                node_id=None,
                app_pack=None,
                restart=False,
            )
            calls: list[tuple[str, bool]] = []

            def patch_config(_binary, _patch, *, dry_run):
                calls.append((json.dumps(_patch, sort_keys=True), dry_run))
                return SimpleNamespace(stdout="preview" if dry_run else "")

            def backup_config(_binary, state):
                backup = state / "backups" / "openclaw-test.json5"
                backup.parent.mkdir(parents=True, exist_ok=True)
                backup.write_text("{}", encoding="utf-8")
                return backup

            def read_for_install(_binary, path):
                if path == "plugins.allow":
                    return ["existing-plugin"]
                if path == "plugins.load.paths":
                    return ["/existing-plugin", "/srv/app/.openclaw/apps/desktop-tutor"]
                if path == "agents.list":
                    return [{"id": "main", "name": "Main"}]
                return ["https://private.nomonlab.com"]

            with redirect_stdout(io.StringIO()):
                with (
                    patch.object(gateway_setup, "ensure_openclaw", return_value="OpenClaw test"),
                    patch.object(gateway_setup, "read_json_config", side_effect=read_for_install),
                    patch.object(gateway_setup, "patch_config", side_effect=patch_config),
                    patch.object(gateway_setup, "backup_config", side_effect=backup_config),
                    patch.object(gateway_setup, "validate_config"),
                    patch.object(gateway_setup, "run", return_value=SimpleNamespace(stdout="", returncode=0)),
                ):
                    self.assertEqual(gateway_setup.install(arguments), 0)
                    self.assertEqual(gateway_setup.install(arguments), 0)
            receipt = json.loads((state_directory / "install-receipt.json").read_text())
            self.assertFalse(receipt["legacy_origin_removed"])
            self.assertTrue(receipt["plugin_path_added"])
            self.assertEqual(len([dry_run for _patch, dry_run in calls if dry_run]), 2)

            removal_calls: list[dict] = []

            def read_for_removal(_binary, path):
                if path == "plugins.allow":
                    return ["tutor", "existing-plugin"]
                if path == "plugins.load.paths":
                    return [str(REPOSITORY_ROOT / "integrations" / "openclaw"), "/existing-plugin"]
                if path == "agents.list":
                    return [{"id": "main", "name": "Main"}, {"id": "calla", "workspace": str(REPOSITORY_ROOT / "agent-workspace")}]
                return ["https://private.nomonlab.com"]

            def capture_removal(_binary, removal_patch, *, dry_run):
                removal_calls.append(removal_patch)
                return SimpleNamespace(stdout="")

            with redirect_stdout(io.StringIO()):
                with (
                    patch.object(gateway_setup, "ensure_openclaw", return_value="OpenClaw test"),
                    patch.object(gateway_setup, "read_json_config", side_effect=read_for_removal),
                    patch.object(gateway_setup, "patch_config", side_effect=capture_removal),
                    patch.object(gateway_setup, "backup_config", side_effect=backup_config),
                    patch.object(gateway_setup, "validate_config"),
                    patch.object(gateway_setup, "run", return_value=SimpleNamespace(stdout="", returncode=0)),
                ):
                    self.assertEqual(gateway_setup.remove(arguments), 0)
            self.assertFalse(state_directory.exists())
            self.assertEqual((unrelated / "keep.txt").read_text(), "keep")
            final_patch = removal_calls[-1]
            self.assertEqual(final_patch["plugins"]["entries"]["tutor"], None)
            self.assertEqual(final_patch["plugins"]["allow"], ["existing-plugin"])
            self.assertEqual(final_patch["plugins"]["load"]["paths"], ["/existing-plugin"])
            self.assertEqual(final_patch["agents"]["list"], [{"id": "main", "name": "Main"}])

    def test_calla_agent_is_allowed_every_tool_the_plugin_registers(self) -> None:
        """A tool the plugin registers but the agent may not call does nothing.

        Calla runs on the minimal tool profile, so its `alsoAllow` list is the
        whole surface it can reach. `tutor_plan` was missing from it for long
        enough that the teaching prompt's first instruction named a tool the
        model could not call, and no lesson ever showed its steps.
        """
        manifest = json.loads(
            (REPOSITORY_ROOT / "integrations" / "openclaw" / "openclaw.plugin.json").read_text(encoding="utf-8"))
        registered = set(manifest["contracts"]["tools"])

        self.assertEqual(set(gateway_setup.CALLA_AGENT_TOOLS), registered)
        self.assertEqual(set(migration.CALLA_AGENT_TOOLS), registered)
        # Same order in both, so a diff of the two files stays readable.
        self.assertEqual(list(gateway_setup.CALLA_AGENT_TOOLS), list(migration.CALLA_AGENT_TOOLS))


if __name__ == "__main__":
    unittest.main()
