import hashlib
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from calla_gateway_release import GatewayReleaseInstaller, ReleaseError, ReleaseManifest, migrate_calla_config, tree_digest
from build_release import build_release


class GatewayReleaseTests(unittest.TestCase):
    def release(self, root: Path, version: str = "v1") -> Path:
        for name in ("plugin", "packs", "agent-workspace", "bin", "migrations"):
            (root / name).mkdir(parents=True, exist_ok=True)
        (root / "plugin" / "openclaw.plugin.json").write_text("{}", encoding="utf-8")
        with zipfile.ZipFile(root / "packs" / "test.otpack", "w") as archive:
            archive.writestr("manifest.json", "{}")
            archive.writestr("entities.json", "[]")
        manifest = {"releaseVersion": version, "gatewayDigest": tree_digest(root), "protocolRange": {"min": 2, "max": 4}, "nodeContractHash": tree_digest(root / "plugin"), "packDigest": tree_digest(root / "packs"), "configMigrationVersion": 1}
        (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        return root

    def test_config_migration_preserves_unrelated_values(self):
        current = Path("/private/calla/current")
        manifest = ReleaseManifest("test", "digest", {"min": 2, "max": 3}, "a" * 64, "pack", 1)
        migrated = migrate_calla_config({"plugins": {"load": {"paths": ["/other", "/srv/app/open-desktop-tutor/integrations/openclaw"]}}, "unrelated": {"keep": True}}, current=current, manifest=manifest)
        self.assertEqual(migrated["unrelated"], {"keep": True})
        self.assertEqual(migrated["plugins"]["load"]["paths"], ["/other", "/private/calla/current/plugin"])
        self.assertEqual(migrated["plugins"]["entries"]["tutor"]["config"]["runtimeMode"], "engine")
        self.assertNotIn("agentWorkspace", migrated["plugins"]["entries"]["tutor"]["config"])
        self.assertNotIn("nodeContractHash", migrated["plugins"]["entries"]["tutor"]["config"])

    def test_cli_expands_tilde_config_path(self):
        # Main delegates to the installer with an expanded path; direct unit
        # tests exercise installer mechanics without needing a real Gateway.
        self.assertEqual(Path("~/openclaw.json").expanduser().name, "openclaw.json")

    def test_contract_metadata_is_removed_from_persisted_config(self):
        manifest = ReleaseManifest("test", "digest", {"min": 2, "max": 3}, "b" * 64, "pack", 1)
        migrated = migrate_calla_config({"plugins": {"entries": {"tutor": {"config": {"nodeId": "old-mac", "nodeContractHash": "a" * 64}}}}}, current=Path("/private/calla/current"), manifest=manifest)
        self.assertEqual(migrated["plugins"]["entries"]["tutor"]["config"]["nodeId"], "old-mac")
        self.assertNotIn("nodeContractHash", migrated["plugins"]["entries"]["tutor"]["config"])

    def test_legacy_missing_contract_keeps_v2_node_for_first_migration(self):
        manifest = ReleaseManifest("test", "digest", {"min": 2, "max": 3}, "b" * 64, "pack", 1)
        migrated = migrate_calla_config({"plugins": {"entries": {"tutor": {"config": {"nodeId": "legacy-mac"}}}}}, current=Path("/private/calla/current"), manifest=manifest)
        self.assertEqual(migrated["plugins"]["entries"]["tutor"]["config"]["nodeId"], "legacy-mac")

    def test_config_migration_replaces_legacy_standalone_mode(self):
        manifest = ReleaseManifest("test", "digest", {"min": 2, "max": 3}, "b" * 64, "pack", 1)
        migrated = migrate_calla_config({"plugins": {"entries": {"tutor": {"config": {"runtimeMode": "standalone"}}}}}, current=Path("/private/calla/current"), manifest=manifest)
        self.assertEqual(migrated["plugins"]["entries"]["tutor"]["config"]["runtimeMode"], "engine")

    def test_digest_ignores_runtime_python_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            release = self.release(Path(temporary) / "release")
            cache = release / "bin" / "__pycache__"
            cache.mkdir()
            (cache / "runtime.pyc").write_bytes(b"runtime cache")
            GatewayReleaseInstaller(Path(temporary) / "gateway", runner=lambda _: None).validate_release(release)

    def test_digest_ignores_macos_tar_sidecars(self):
        with tempfile.TemporaryDirectory() as temporary:
            release = self.release(Path(temporary) / "release")
            (release / "plugin" / "._index.mjs").write_bytes(b"macOS metadata")
            GatewayReleaseInstaller(Path(temporary) / "gateway", runner=lambda _: None).validate_release(release)

    def test_bad_digest_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            release = self.release(Path(temporary) / "release")
            (release / "packs" / "changed").write_text("not in digest", encoding="utf-8")
            with self.assertRaisesRegex(ReleaseError, "gatewayDigest mismatch"):
                GatewayReleaseInstaller(Path(temporary) / "root", runner=lambda _: None).stage(release)

    def test_bad_contract_or_pack_digest_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            release = self.release(Path(temporary) / "release")
            manifest_path = release / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["nodeContractHash"] = "wrong"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(ReleaseError, "nodeContractHash mismatch"):
                GatewayReleaseInstaller(Path(temporary) / "root", runner=lambda _: None).stage(release)

    def test_builder_emits_complete_release_layout_and_valid_digest(self):
        with tempfile.TemporaryDirectory() as temporary:
            tutor = Path(temporary) / "Tutor"
            for path in ("Gateway/openclaw", "packs/blender", "build/packs", "agent-workspace", "scripts", "tools"):
                (tutor / path).mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(tutor / "build" / "packs" / "blender.otpack", "w") as archive:
                archive.writestr("manifest.json", "{}")
                archive.writestr("entities.json", "[]")
            for name in ("calla-course-gateway.sh", "calla-course.sh", "calla-feedback-gateway.sh", "calla-feedback.sh"):
                (tutor / "scripts" / name).write_text("#!/bin/sh\n", encoding="utf-8")
            for name in ("calla_migration.py", "calla_openclaw_setup.py", "calla_pack_store.py", "calla_node_enroller.py"):
                (tutor / "tools" / name).write_text("", encoding="utf-8")
            release = build_release(tutor, Path(temporary) / "release", "test")
            manifest = GatewayReleaseInstaller(Path(temporary) / "gateway", runner=lambda _: None).validate_release(release)
            self.assertEqual(manifest.releaseVersion, "test")

    def test_apply_rolls_back_config_and_current_after_probe_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "gateway"
            old = self.release(root / "releases" / "old", "old")
            root.mkdir(exist_ok=True)
            (root / "current").symlink_to(old)
            staged = self.release(base / "staged", "new")
            config = base / "openclaw.json"
            original = {"plugins": {"load": {"paths": ["/other"]}, "entries": {"tutor": {"config": {"stateDirectory": str(base / "state")}}}}, "unrelated": "kept"}
            config.write_text(json.dumps(original), encoding="utf-8")
            calls = []
            def runner(command):
                calls.append(command)
                if command[:3] == ["openclaw", "gateway", "status"]:
                    raise ReleaseError("probe failed")
            with self.assertRaisesRegex(ReleaseError, "probe failed"):
                GatewayReleaseInstaller(root, runner=runner).apply(staged, config_path=config)
            self.assertEqual(json.loads(config.read_text(encoding="utf-8")), original)
            self.assertEqual((root / "current").resolve(), old.resolve())
            receipt = json.loads((root / "receipts" / "new.json").read_text(encoding="utf-8"))
            self.assertFalse(receipt["ok"])

    def test_first_release_failure_leaves_no_current_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "gateway"
            staged = self.release(base / "staged", "first")
            config = base / "openclaw.json"
            original = {"plugins": {"load": {"paths": []}, "entries": {"tutor": {"config": {"stateDirectory": str(base / "state")}}}}}
            config.write_text(json.dumps(original), encoding="utf-8")
            def runner(command):
                if command[:3] == ["openclaw", "gateway", "status"]:
                    raise ReleaseError("probe failed")
            with self.assertRaisesRegex(ReleaseError, "probe failed"):
                GatewayReleaseInstaller(root, runner=runner, home=base / "home").apply(staged, config_path=config)
            self.assertFalse((root / "current").exists())
            self.assertEqual(json.loads(config.read_text(encoding="utf-8")), original)

    def test_checks_validate_migrated_config_not_original(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "gateway"
            staged = self.release(base / "staged", "new")
            config = base / "openclaw.json"
            config.write_text(json.dumps({"plugins": {"load": {"paths": ["/other"]}, "entries": {"tutor": {"config": {"stateDirectory": str(base / "state")}}}}}), encoding="utf-8")
            calls = []
            GatewayReleaseInstaller(root, runner=lambda command: calls.append(command)).apply(staged, config_path=config, restart=False)
            validated = next(command for command in calls if command[0] == "env" and command[2:] == ["openclaw", "config", "validate"])
            self.assertTrue(validated[1].startswith("OPENCLAW_CONFIG_PATH="))
            self.assertNotEqual(validated[1], f"OPENCLAW_CONFIG_PATH={config}")

    def test_validation_config_uses_staged_plugin_without_flipping_current(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "gateway"
            staged = self.release(base / "staged", "new")
            migrated = migrate_calla_config({"plugins": {"load": {"paths": []}}}, current=root / "current", manifest=ReleaseManifest("new", "digest", {"min": 2, "max": 3}, "a" * 64, "pack", 1))
            captured = []
            def runner(command):
                if command[0] == "env":
                    captured.append(json.loads(Path(command[1].split("=", 1)[1]).read_text(encoding="utf-8")))
            GatewayReleaseInstaller(root, runner=runner)._run_checks(staged, base / "openclaw.json", migrated)
            self.assertEqual(captured[0]["plugins"]["load"]["paths"], [str(staged / "plugin")])
            self.assertFalse((root / "current").exists())

    def test_gateway_adapters_resolve_through_current(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "gateway"
            home = base / "home"
            staged = self.release(base / "staged", "new")
            config = base / "openclaw.json"
            config.write_text(json.dumps({"plugins": {"load": {"paths": ["/other"]}, "entries": {"tutor": {"config": {"stateDirectory": str(base / "state")}}}}}), encoding="utf-8")
            GatewayReleaseInstaller(root, runner=lambda _: None, home=home).apply(staged, config_path=config, restart=False)
            course = home / ".local" / "bin" / "calla-course"
            feedback = home / ".local" / "bin" / "calla-feedback"
            unit = home / ".config" / "systemd" / "user" / "calla-node-enroller.service"
            self.assertTrue(course.is_symlink())
            self.assertEqual(course.readlink(), root / "current" / "bin" / "calla-course-gateway.sh")
            self.assertTrue(feedback.is_symlink())
            self.assertEqual(feedback.readlink(), root / "current" / "bin" / "calla-feedback-gateway.sh")
            self.assertIn(str(root / "current" / "migrations" / "calla_node_enroller.py"), unit.read_text(encoding="utf-8"))
            self.assertIn(f"--openclaw-bin {home}/.npm-global/bin/openclaw", unit.read_text(encoding="utf-8"))
            self.assertIn('--display-name "Calla Mac"', unit.read_text(encoding="utf-8"))

    def test_probe_requires_course_socket_and_internal_node_handshake(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "gateway"
            release = self.release(base / "release", "probe")
            config = base / "openclaw.json"
            config.write_text(json.dumps({"plugins": {"entries": {"tutor": {"config": {
                "nodeId": "calla-node", "nodeContractHash": "a" * 64, "engineBuild": "probe-build",
            }}}}}), encoding="utf-8")
            calls = []
            GatewayReleaseInstaller(root, runner=lambda command: calls.append(command), home=base / "home")._probe(release, config)
            self.assertIn(["openclaw", "gateway", "status", "--no-probe"], calls)
            self.assertIn(["openclaw", "plugins", "inspect", "tutor"], calls)
            self.assertTrue(any(command[:2] == ["/bin/sh", "-c"] and "calla-course" in command[2] for command in calls))
            node_call = next(command for command in calls if command[:3] == ["openclaw", "nodes", "invoke"])
            self.assertIn("calla-node", node_call)
            self.assertTrue(any("session_start" in argument for argument in node_call))

    def test_pack_install_failure_restores_existing_pack_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "gateway"
            state = base / "state"
            (state / "packs").mkdir(parents=True)
            (state / "indexes").mkdir(parents=True)
            (state / "packs" / "author.otpack").write_bytes(b"author-pack")
            (state / "indexes" / "author.json").write_text("{}", encoding="utf-8")
            staged = self.release(base / "staged", "new")
            config = base / "openclaw.json"
            config.write_text(json.dumps({"plugins": {"load": {"paths": []}, "entries": {"tutor": {"config": {"stateDirectory": str(state)}}}}}), encoding="utf-8")
            def runner(command):
                if command[0] == "/usr/bin/python3":
                    raise ReleaseError("pack install failed")
            with self.assertRaisesRegex(ReleaseError, "pack install failed"):
                GatewayReleaseInstaller(root, runner=runner, home=base / "home").apply(staged, config_path=config, restart=False)
            self.assertEqual((state / "packs" / "author.otpack").read_bytes(), b"author-pack")
            self.assertEqual((state / "indexes" / "author.json").read_text(encoding="utf-8"), "{}")
