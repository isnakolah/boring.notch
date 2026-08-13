from __future__ import annotations

import importlib.util
import json
import stat
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


def load_script(name: str):
    path = REPOSITORY_ROOT / "tools" / name
    spec = importlib.util.spec_from_file_location(path.stem, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


package_addon = load_script("package_blender_addon.py")
bridge_probe = load_script("blender_bridge_probe.py")


class MacSetupToolTests(unittest.TestCase):
    def test_server_setup_installs_the_private_tailscale_path(self):
        setup_script = REPOSITORY_ROOT / "scripts" / "setup-calla-server.sh"
        source = setup_script.read_text(encoding="utf-8")
        help_output = subprocess.run(
            ["bash", str(setup_script), "--help"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        self.assertIn("--install", help_output)
        self.assertIn("Tailscale", help_output)
        self.assertIn('MODE="check"', source)
        self.assertIn("calla_openclaw_setup.py", source)
        self.assertIn("pack-build", source)
        self.assertIn("--openclaw-bin $openclaw_binary", source)
        self.assertIn("WantedBy=default.target", source)
        self.assertIn("completed (Calla Mac paired)", source)
        self.assertNotIn("cf-dns is required", source)

    def test_macos_setup_installs_the_single_private_node_without_credentials(self):
        setup_script = REPOSITORY_ROOT / "scripts" / "setup-macos.sh"
        bootstrap_script = REPOSITORY_ROOT / "scripts" / "bootstrap-calla-mac.sh"
        source = setup_script.read_text(encoding="utf-8")
        bootstrap_source = bootstrap_script.read_text(encoding="utf-8")
        help_output = subprocess.run(
            ["bash", str(setup_script), "--help"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        self.assertIn("--install-calla-node", help_output)
        self.assertIn("bootstrap-calla-mac.sh\" --install --yes", source)
        self.assertNotIn("--transport", bootstrap_source)
        self.assertNotIn("cloudflared", bootstrap_source)
        self.assertIn('"role":"node"', bootstrap_source)
        self.assertIn("calla-node-host.sh", bootstrap_source)
        self.assertIn("calla-tutor-host.sh", bootstrap_source)
        self.assertIn('"requireOwnerIdentity":false', bootstrap_source)
        self.assertNotIn("OpenClaw Gateway token:", bootstrap_source)
        self.assertIn("remove_legacy_auth_state", bootstrap_source)
        self.assertIn("--install-openclaw-plugin", source)

    def test_addon_zip_has_blender_package_layout(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "addon.zip"
            result = package_addon.build_addon(output)
            self.assertTrue(result["ok"])
            with zipfile.ZipFile(output) as archive:
                names = set(archive.namelist())
                self.assertEqual(names, set(package_addon.PACKAGE_FILES.values()))
                init_source = archive.read("calla_tutor_blender/__init__.py").decode("utf-8")
                self.assertIn('"name": "Calla Tutor Bridge"', init_source)

    def test_descriptor_validation_accepts_owner_only_loopback_file(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            descriptor = Path(temporary_directory) / "blender-123.json"
            descriptor.write_text(
                json.dumps(
                    {
                        "protocol_version": 1,
                        "bridge": "blender-tutor-bridge-v1",
                        "host": "127.0.0.1",
                        "port": 12345,
                        "token": "t" * 32,
                        "pid": 123,
                        "read_only": True,
                    }
                ),
                encoding="utf-8",
            )
            descriptor.chmod(0o600)
            loaded = bridge_probe.load_descriptor(descriptor)
            self.assertEqual(loaded["port"], 12345)

    def test_descriptor_validation_rejects_group_readability(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            descriptor = Path(temporary_directory) / "blender-123.json"
            descriptor.write_text("{}", encoding="utf-8")
            descriptor.chmod(0o640)
            with self.assertRaisesRegex(PermissionError, "owner-only"):
                bridge_probe.load_descriptor(descriptor)
            self.assertEqual(stat.S_IMODE(descriptor.stat().st_mode), 0o640)


if __name__ == "__main__":
    unittest.main()
