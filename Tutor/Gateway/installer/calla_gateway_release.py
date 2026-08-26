#!/usr/bin/env python3
"""Atomic private Calla Gateway release installer.

Runs only on nomonhomelab. It owns `~/.openclaw/apps/calla-tutor`; unrelated
OpenClaw configuration and Tutor learner state remain outside its transaction.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import tempfile
import time
import uuid
import zipfile
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Callable


REQUIRED_RELEASE_DIRECTORIES = ("plugin", "packs", "agent-workspace", "bin", "migrations")
REQUIRED_MANIFEST_FIELDS = (
    "releaseVersion", "gatewayDigest", "protocolRange", "nodeContractHash", "packDigest", "configMigrationVersion",
)
LEGACY_PLUGIN_PATHS = {
    "/srv/app/open-desktop-tutor/integrations/openclaw",
    "/srv/app/open-desktop-tutor/apps/tutor/integrations/openclaw",
    "/srv/app/.openclaw/apps/desktop-tutor",
    "/srv/app/.openclaw/apps/tutor/integrations/openclaw",
}


class ReleaseError(RuntimeError):
    pass


@dataclass(frozen=True)
class ReleaseManifest:
    releaseVersion: str
    gatewayDigest: str
    protocolRange: dict[str, int]
    nodeContractHash: str
    packDigest: str
    configMigrationVersion: int

    @classmethod
    def load(cls, path: Path) -> "ReleaseManifest":
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ReleaseError(f"invalid release manifest: {error}") from error
        if not isinstance(raw, dict) or any(field not in raw for field in REQUIRED_MANIFEST_FIELDS):
            raise ReleaseError("release manifest is missing required fields")
        protocol = raw["protocolRange"]
        if not isinstance(protocol, dict) or not isinstance(protocol.get("min"), int) or not isinstance(protocol.get("max"), int):
            raise ReleaseError("release manifest protocolRange is invalid")
        if protocol["min"] > protocol["max"] or protocol["min"] < 2 or protocol["max"] > 4:
            raise ReleaseError("release manifest protocolRange must stay within 2...4")
        if not isinstance(raw["configMigrationVersion"], int) or raw["configMigrationVersion"] < 1:
            raise ReleaseError("release manifest configMigrationVersion is invalid")
        for field in ("releaseVersion", "gatewayDigest", "nodeContractHash", "packDigest"):
            if not isinstance(raw[field], str) or not raw[field].strip():
                raise ReleaseError(f"release manifest {field} is invalid")
        return cls(**{field: raw[field] for field in REQUIRED_MANIFEST_FIELDS})


def tree_digest(root: Path) -> str:
    digest = hashlib.sha256()
    # Python may create cache files beside a release entrypoint while it is
    # validating that same release. Caches are not release content and must
    # never make an otherwise immutable release fail its own digest check.
    for path in sorted(
        path for path in root.rglob("*")
        if (path.is_file()
            and path.name != "manifest.json"
            and "__pycache__" not in path.parts
            and "__MACOSX" not in path.parts
            and not path.name.startswith("._"))
    ):
        digest.update(str(path.relative_to(root)).encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def directory_digest(root: Path) -> str:
    if not root.is_dir():
        raise ReleaseError(f"missing release directory: {root}")
    return tree_digest(root)


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def atomic_symlink(target: Path, link: Path) -> None:
    link.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = link.with_name(f".{link.name}.{os.getpid()}")
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(target)
    os.replace(temporary, link)


def migrate_calla_config(config: dict[str, Any], *, current: Path, manifest: ReleaseManifest) -> dict[str, Any]:
    """Change Calla-owned fields only. Preserve every unrelated entry/value."""
    result = json.loads(json.dumps(config))
    plugins = result.setdefault("plugins", {})
    load = plugins.setdefault("load", {})
    paths = load.get("paths", [])
    if not isinstance(paths, list) or not all(isinstance(item, str) for item in paths):
        raise ReleaseError("plugins.load.paths must be a string list")
    stable_plugin = str(current / "plugin")
    # Source checkout paths and a previous release resource path are Calla
    # ownership. Preserve every other plugin path verbatim.
    def is_calla_path(item: str) -> bool:
        return (item in LEGACY_PLUGIN_PATHS
                or item == stable_plugin
                or "calla-openclaw/apps/tutor/integrations/openclaw" in item
                or item.endswith("/.openclaw/apps/tutor/integrations/openclaw")
                or item.endswith("/Calla/openclaw"))
    load["paths"] = [item for item in paths if not is_calla_path(item)] + [stable_plugin]
    entries = plugins.setdefault("entries", {})
    tutor = entries.setdefault("tutor", {"enabled": True, "config": {}})
    if not isinstance(tutor, dict):
        raise ReleaseError("plugins.entries.tutor must be an object")
    tutor["enabled"] = True
    tutor_config = tutor.setdefault("config", {})
    if not isinstance(tutor_config, dict):
        raise ReleaseError("plugins.entries.tutor.config must be an object")
    tutor_config.setdefault("stateDirectory", str(Path.home() / ".openclaw" / "tutor"))
    # This release is consumed by Boring's Engine control plane.  Leaving the
    # mode implicit selects the portable standalone default, which would
    # restore model-visible Tutor operations and omit Engine snapshot identity.
    # Gateway config is Calla-owned at this boundary, so pin it explicitly.
    tutor_config["runtimeMode"] = "engine"
    # Release-derived facts live in current/manifest.json, read by the plugin
    # after the atomic pointer flip. Persisting them here breaks OpenClaw builds
    # that validate the cached old schema before loading current/plugin.
    for key in ("nodeContractHash", "engineBuild", "agentWorkspace"):
        tutor_config.pop(key, None)
    return result


class GatewayReleaseInstaller:
    def __init__(self, root: Path, *, runner: Callable[[list[str]], None] | None = None, home: Path | None = None) -> None:
        self.root = root
        self.releases = root / "releases"
        self.incoming = root / "incoming"
        self.receipts = root / "receipts"
        self.current = root / "current"
        self.previous = root / "previous"
        self.runner = runner or self._run
        self.home = home or Path.home()

    def stage(self, source: Path) -> ReleaseManifest:
        manifest = self.validate_release(source)
        destination = self.incoming / manifest.releaseVersion
        if destination.exists():
            existing = self.validate_release(destination)
            if existing.gatewayDigest == manifest.gatewayDigest:
                return manifest
            raise ReleaseError(f"incoming release version already exists with a different digest: {manifest.releaseVersion}")
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        shutil.copytree(source, destination, copy_function=shutil.copy2)
        return manifest

    def validate_release(self, source: Path) -> ReleaseManifest:
        if not source.is_dir():
            raise ReleaseError("staged release directory is missing")
        for name in REQUIRED_RELEASE_DIRECTORIES:
            if not (source / name).is_dir():
                raise ReleaseError(f"staged release missing {name}/")
        manifest = ReleaseManifest.load(source / "manifest.json")
        if tree_digest(source) != manifest.gatewayDigest:
            raise ReleaseError("staged release gatewayDigest mismatch")
        if directory_digest(source / "plugin") != manifest.nodeContractHash:
            raise ReleaseError("staged release nodeContractHash mismatch")
        if directory_digest(source / "packs") != manifest.packDigest:
            raise ReleaseError("staged release packDigest mismatch")
        return manifest

    def apply(self, source: Path, *, config_path: Path, restart: bool = True) -> ReleaseManifest:
        manifest = self.stage(source)
        staged = self.incoming / manifest.releaseVersion
        receipt = {"release": manifest.releaseVersion, "startedAt": dt.datetime.now(dt.UTC).isoformat(), "ok": False}
        old_current = self.current.resolve() if self.current.is_symlink() else None
        config_backup = self.receipts / f"config-{manifest.releaseVersion}.json"
        adapter_backup = self._backup_gateway_adapters()
        try:
            config = json.loads(config_path.read_text(encoding="utf-8"))
            if not isinstance(config, dict):
                raise ReleaseError("OpenClaw config root must be an object")
            migrated_config = migrate_calla_config(config, current=self.current, manifest=manifest)
            self._run_checks(staged, config_path, migrated_config)
            atomic_write_json(config_backup, config)
            destination = self.releases / manifest.releaseVersion
            if destination.exists():
                existing = self.validate_release(destination)
                if existing.gatewayDigest != manifest.gatewayDigest:
                    raise ReleaseError(f"release version already exists with a different digest: {manifest.releaseVersion}")
            self.releases.mkdir(mode=0o700, parents=True, exist_ok=True)
            if not destination.exists():
                os.replace(staged, destination)
            atomic_write_json(config_path, migrated_config)
            if old_current:
                atomic_symlink(old_current, self.previous)
            atomic_symlink(destination, self.current)
            pack_backup = self._backup_pack_state(manifest.releaseVersion, migrated_config)
            self._install_compiled_packs(destination, migrated_config)
            self._install_stable_gateway_adapters()
            if restart:
                self.runner(["openclaw", "gateway", "restart"])
                self._probe(destination, config_path)
            self._retain_latest_three()
            receipt.update({"ok": True, "current": str(destination), "previous": str(old_current) if old_current else None})
            self._write_receipt(manifest.releaseVersion, receipt)
            return manifest
        except Exception as error:
            if config_backup.exists():
                atomic_write_json(config_path, json.loads(config_backup.read_text(encoding="utf-8")))
            if old_current:
                atomic_symlink(old_current, self.current)
            elif self.current.is_symlink():
                self.current.unlink()
            if 'pack_backup' in locals():
                self._restore_pack_state(pack_backup, migrated_config)
            self._restore_gateway_adapters(adapter_backup)
            if restart:
                try:
                    self.runner(["openclaw", "gateway", "restart"])
                except Exception:
                    pass
            receipt.update({"error": str(error), "restoredCurrent": str(old_current) if old_current else None})
            self._write_receipt(manifest.releaseVersion, receipt)
            raise

    def _run_checks(self, release: Path, config_path: Path, migrated_config: dict[str, Any]) -> None:
        self.runner(["npm", "test", "--prefix", str(release / "plugin")])
        # Validate exact new plugin schema without flipping `current`
        # before checks pass. Production config keeps stable
        # `current/plugin`; staging config points only this subprocess at
        # release/plugin.
        validation_config = json.loads(json.dumps(migrated_config))
        validation_paths = validation_config["plugins"]["load"]["paths"]
        validation_config["plugins"]["load"]["paths"] = [
            str(release / "plugin") if path == str(self.current / "plugin") else path
            for path in validation_paths
        ]
        # Some OpenClaw builds resolve an already-loaded plugin schema by id
        # before reading the staged `load.paths` entry. That old schema cannot
        # know Engine-only fields added by this release, so validate the
        # unchanged base config first. The durable config still receives these
        # fields after the atomic current-pointer flip, where new schema wins.
        validation_tutor = validation_config.get("plugins", {}).get("entries", {}).get("tutor", {})
        if isinstance(validation_tutor, dict) and isinstance(validation_tutor.get("config"), dict):
            for key in ("nodeContractHash", "engineBuild", "agentWorkspace"):
                validation_tutor["config"].pop(key, None)
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", prefix="calla-config-check-", delete=False, encoding="utf-8") as handle:
            json.dump(validation_config, handle)
            handle.flush()
            temporary_config = Path(handle.name)
        try:
            self.runner(["env", f"OPENCLAW_CONFIG_PATH={temporary_config}", "openclaw", "config", "validate"])
        finally:
            temporary_config.unlink(missing_ok=True)

    def _probe(self, release: Path, config_path: Path) -> None:
        """Prove active release, course socket, and paired engine together."""
        # This OpenClaw version rejects an unauthenticated explicit local URL
        # even when its configured private Gateway is healthy. Service status,
        # plugin inspection, course socket, and node invocation below still
        # prove the active Gateway and Tutor path end-to-end.
        self.runner(["openclaw", "gateway", "status", "--no-probe"])
        self.runner(["openclaw", "plugins", "inspect", "tutor"])
        if not (release / "plugin" / "openclaw.plugin.json").is_file():
            raise ReleaseError("Gateway probe failed: Tutor plugin disappeared")
        course = self.home / ".local" / "bin" / "calla-course"
        request = '{"version":1,"command":"list","payload":{}}\\n'
        self.runner(["/bin/sh", "-c", f"printf %s {shlex.quote(request)} | {shlex.quote(str(course))}"])
        self._probe_paired_node(config_path, release)

    def _probe_paired_node(self, config_path: Path, release: Path) -> None:
        deadline = time.monotonic() + 30
        last_error = "no paired Calla Mac node"
        while time.monotonic() < deadline:
            try:
                config = json.loads(config_path.read_text(encoding="utf-8"))
                tutor = config["plugins"]["entries"]["tutor"]["config"]
                node_id = tutor.get("nodeId")
                manifest = ReleaseManifest.load(release / "manifest.json")
                contract = manifest.nodeContractHash
                engine_build = manifest.releaseVersion
                if not isinstance(node_id, str) or not node_id:
                    last_error = "Calla Mac is still re-pairing"
                elif not isinstance(contract, str) or len(contract) < 16:
                    last_error = "Calla node contract hash is missing"
                else:
                    envelope = {
                        "protocol_version": 2,
                        "request_id": str(uuid.uuid4()),
                        "operation": "session_start",
                        "session_id": "calla-release-probe",
                        "payload": {
                            "supported_protocol_range": {"min": 2, "max": 3},
                            "engine_build": engine_build,
                            "node_contract_hash": contract,
                        },
                    }
                    self.runner([
                        "openclaw", "nodes", "invoke", "--node", node_id,
                        "--command", "tutor.host", "--params", json.dumps(envelope, separators=(",", ":")),
                        "--json", "--invoke-timeout", "15000",
                    ])
                    return
            except (KeyError, TypeError, json.JSONDecodeError) as error:
                last_error = f"invalid Calla config while waiting for node: {error}"
            time.sleep(3)
        raise ReleaseError(f"Gateway probe failed: {last_error}")

    @staticmethod
    def _state_directory(config: dict[str, Any]) -> Path:
        try:
            value = config["plugins"]["entries"]["tutor"]["config"]["stateDirectory"]
        except (KeyError, TypeError) as error:
            raise ReleaseError("Calla stateDirectory is missing after migration") from error
        if not isinstance(value, str) or not value.strip():
            raise ReleaseError("Calla stateDirectory is invalid after migration")
        return Path(value).expanduser()

    def _backup_pack_state(self, version: str, config: dict[str, Any]) -> Path:
        state = self._state_directory(config)
        backup = self.receipts / f"packs-{version}"
        if backup.exists():
            shutil.rmtree(backup)
        backup.mkdir(mode=0o700, parents=True)
        for name in ("packs", "indexes"):
            source = state / name
            if source.is_dir():
                shutil.copytree(source, backup / name, copy_function=shutil.copy2)
        return backup

    def _install_compiled_packs(self, release: Path, config: dict[str, Any]) -> None:
        packs = sorted((release / "packs").glob("*.otpack"))
        if not packs:
            raise ReleaseError("release has no compiled .otpack files")
        for pack in packs:
            try:
                with zipfile.ZipFile(pack) as archive:
                    if "manifest.json" not in archive.namelist() or "entities.json" not in archive.namelist():
                        raise ReleaseError(f"compiled pack is incomplete: {pack.name}")
            except zipfile.BadZipFile as error:
                raise ReleaseError(f"compiled pack is invalid: {pack.name}") from error
            self.runner([
                "/usr/bin/python3", str(release / "migrations" / "tools" / "calla_pack_store.py"),
                str(pack), "--state-directory", str(self._state_directory(config)),
            ])

    def _restore_pack_state(self, backup: Path, config: dict[str, Any]) -> None:
        state = self._state_directory(config)
        for name in ("packs", "indexes"):
            destination = state / name
            if destination.exists():
                shutil.rmtree(destination)
            source = backup / name
            if source.is_dir():
                shutil.copytree(source, destination, copy_function=shutil.copy2)

    def _install_stable_gateway_adapters(self) -> None:
        """Keep user entry points stable while `current` flips between releases."""
        bin_directory = self.home / ".local" / "bin"
        unit_directory = self.home / ".config" / "systemd" / "user"
        bin_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        unit_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        course = bin_directory / "calla-course"
        atomic_symlink(self.current / "bin" / "calla-course-gateway.sh", course)
        feedback = bin_directory / "calla-feedback"
        atomic_symlink(self.current / "bin" / "calla-feedback-gateway.sh", feedback)
        unit = unit_directory / "calla-node-enroller.service"
        content = "\n".join((
            "[Unit]",
            "Description=Calla Mac private node enroller",
            "After=default.target",
            "",
            "[Service]",
            "Type=simple",
            f"ExecStart=/usr/bin/python3 {self.current}/migrations/calla_node_enroller.py --watch --openclaw-bin {self.home}/.npm-global/bin/openclaw --display-name \"Calla Mac\"",
            "Restart=always",
            "RestartSec=3",
            "",
            "[Install]",
            "WantedBy=default.target",
            "",
        ))
        descriptor, temporary_name = tempfile.mkstemp(prefix=".calla-node-enroller.", dir=unit_directory)
        temporary = Path(temporary_name)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                handle.write(content)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, 0o600)
            os.replace(temporary, unit)
        finally:
            temporary.unlink(missing_ok=True)
        self.runner(["systemctl", "--user", "daemon-reload"])
        self.runner(["systemctl", "--user", "enable", "--now", "calla-node-enroller.service"])

    def _backup_gateway_adapters(self) -> dict[Path, tuple[str, bytes | str] | None]:
        """Capture Calla-owned entry points so failed first install is harmless."""
        paths = (
            self.home / ".local" / "bin" / "calla-course",
            self.home / ".config" / "systemd" / "user" / "calla-node-enroller.service",
        )
        backup: dict[Path, tuple[str, bytes | str] | None] = {}
        for path in paths:
            if path.is_symlink():
                backup[path] = ("symlink", str(path.readlink()))
            elif path.is_file():
                backup[path] = ("file", path.read_bytes())
            else:
                backup[path] = None
        return backup

    def _restore_gateway_adapters(self, backup: dict[Path, tuple[str, bytes | str] | None]) -> None:
        for path, value in backup.items():
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            path.unlink(missing_ok=True)
            if value is None:
                continue
            kind, content = value
            if kind == "symlink":
                path.symlink_to(str(content))
                continue
            descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
            temporary = Path(temporary_name)
            try:
                with os.fdopen(descriptor, "wb") as handle:
                    handle.write(bytes(content))
                    handle.flush()
                    os.fsync(handle.fileno())
                os.chmod(temporary, 0o600)
                os.replace(temporary, path)
            finally:
                temporary.unlink(missing_ok=True)
        try:
            self.runner(["systemctl", "--user", "daemon-reload"])
            self.runner(["systemctl", "--user", "restart", "calla-node-enroller.service"])
        except Exception:
            # Preserve original release failure when no previous unit existed.
            pass

    def _retain_latest_three(self) -> None:
        protected = {path.resolve() for path in (self.current, self.previous) if path.is_symlink()}
        releases = sorted((path for path in self.releases.iterdir() if path.is_dir()), key=lambda path: path.stat().st_mtime, reverse=True)
        for release in releases[3:]:
            if release.resolve() not in protected:
                shutil.rmtree(release)

    def _write_receipt(self, version: str, value: dict[str, Any]) -> None:
        self.receipts.mkdir(mode=0o700, parents=True, exist_ok=True)
        atomic_write_json(self.receipts / f"{version}.json", value)

    @staticmethod
    def _run(command: list[str]) -> None:
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        if result.returncode:
            raise ReleaseError(result.stderr.strip() or result.stdout.strip() or f"{' '.join(command)} failed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staged", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--root", type=Path, default=Path.home() / ".openclaw/apps/calla-tutor")
    parser.add_argument("--no-restart", action="store_true")
    args = parser.parse_args()
    installer = GatewayReleaseInstaller(args.root)
    manifest = installer.apply(args.staged.expanduser(), config_path=args.config.expanduser(), restart=not args.no_restart)
    print(json.dumps(asdict(manifest), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
