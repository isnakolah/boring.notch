#!/usr/bin/env python3
"""Fail-closed migration from the retired desktop-tutor OpenClaw identity."""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


PLUGIN_ID = "tutor"
LEGACY_PLUGIN_ID = "desktop-tutor"
KNOWN_LEGACY_CALLA_WORKSPACE = Path("/srv/app/calla-workspace")
LEGACY_PLUGIN_PATHS = {
    Path("/srv/app/.openclaw/apps/desktop-tutor"),
    Path("/srv/app/open-desktop-tutor/integrations/openclaw"),
}
# Keep in step with calla_openclaw_setup.CALLA_AGENT_TOOLS; a name missing from
# either list is a tool the model cannot call. See the drift test in
# tools/tests/test_calla_tools.py.
CALLA_AGENT_TOOLS = [
    "tutor_observe",
    "tutor_plan",
    "tutor_remember",
    "tutor_guide",
    "tutor_narrate",
    "tutor_point",
    "tutor_propose_action",
    "tutor_verify",
]


class MigrationError(RuntimeError):
    """Raised when the exact owned legacy configuration cannot be proven."""


def run(command: list[str], *, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, input=input_text, text=True, capture_output=True, check=False)
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or "no diagnostic output"
        raise MigrationError(f"{' '.join(command[:3])} failed: {detail}")
    return result


def config_get(binary: str, path: str) -> Any | None:
    result = subprocess.run([binary, "config", "get", path, "--json"], text=True, capture_output=True, check=False)
    if result.returncode or not result.stdout.strip():
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise MigrationError(f"OpenClaw returned invalid JSON for {path}") from error


def active_config_path(binary: str) -> Path:
    result = run([binary, "config", "file"])
    for line in reversed(result.stdout.splitlines()):
        candidate = Path(line.strip()).expanduser()
        if candidate.is_file():
            return candidate
    raise MigrationError("OpenClaw did not report an existing configuration file")


def atomic_json(path: Path, value: dict[str, Any]) -> None:
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


def migrate_calla_agent(agents: Any, destination: Path) -> tuple[list[dict[str, Any]], bool]:
    """Move exactly the known Calla scaffold and preserve all other agents."""
    if not isinstance(agents, list):
        raise MigrationError("agents.list is not an array; refusing to replace it")
    matches = [entry for entry in agents if isinstance(entry, dict) and entry.get("id") == "calla"]
    if len(matches) != 1:
        raise MigrationError("expected exactly one configured calla agent")
    original = matches[0]
    workspace = original.get("workspace")
    if workspace == str(destination):
        return agents, False
    if workspace != str(KNOWN_LEGACY_CALLA_WORKSPACE):
        raise MigrationError(
            "refusing to move Calla from an unexpected workspace; only the known "
            f"{KNOWN_LEGACY_CALLA_WORKSPACE} scaffold may be migrated"
        )
    migrated = copy.deepcopy(agents)
    calla = next(entry for entry in migrated if entry["id"] == "calla")
    calla["workspace"] = str(destination)
    calla["thinkingDefault"] = "low"
    params = calla.get("params") if isinstance(calla.get("params"), dict) else {}
    calla["params"] = {**params, "cacheRetention": "long"}
    tools = calla.get("tools") if isinstance(calla.get("tools"), dict) else {}
    calla["tools"] = {**tools, "profile": "minimal", "alsoAllow": CALLA_AGENT_TOOLS}
    return migrated, True


def migrated_plugin_config(legacy: Any, state_directory: Path) -> dict[str, Any]:
    """Carry forward only schema-valid values, including an enrolled node id."""
    if not isinstance(legacy, dict):
        raise MigrationError("legacy desktop-tutor configuration is not an object")
    config: dict[str, Any] = {
        "role": legacy.get("role") if legacy.get("role") in {"gateway", "node", "both"} else "gateway",
        "stateDirectory": str(state_directory),
        "developmentMode": legacy.get("developmentMode") is True,
        "requireOwnerIdentity": legacy.get("requireOwnerIdentity") is True,
    }
    for field in ("nodeId", "socketPath"):
        value = legacy.get(field)
        if isinstance(value, str) and value.strip():
            config[field] = value.strip()
    if isinstance(legacy.get("timeoutMs"), int):
        config["timeoutMs"] = legacy["timeoutMs"]
    return config


def rewritten_paths(paths: Any, plugin_path: Path) -> list[str]:
    if paths is None:
        return [str(plugin_path)]
    if not isinstance(paths, list) or not all(isinstance(item, str) for item in paths):
        raise MigrationError("plugins.load.paths is not a string array")
    result = [item for item in paths if Path(item) not in LEGACY_PLUGIN_PATHS]
    if str(plugin_path) not in result:
        result.append(str(plugin_path))
    return result


def rewritten_allow(allowed: Any, *, include_legacy: bool) -> list[str] | None:
    if allowed is None:
        return None
    if not isinstance(allowed, list) or not all(isinstance(item, str) for item in allowed):
        raise MigrationError("plugins.allow is not a string array")
    result = [item for item in allowed if include_legacy or item != LEGACY_PLUGIN_ID]
    if PLUGIN_ID not in result:
        result.append(PLUGIN_ID)
    return result


def build_migration_patches(
    *,
    legacy_entry: Any,
    plugin_paths: Any,
    plugin_allow: Any,
    agents: Any,
    plugin_path: Path,
    state_directory: Path,
    agent_workspace: Path,
) -> tuple[dict[str, Any], dict[str, Any], bool]:
    if not isinstance(legacy_entry, dict) or not isinstance(legacy_entry.get("config"), dict):
        raise MigrationError("desktop-tutor plugin entry is missing its configuration")
    migrated_agents, agent_changed = migrate_calla_agent(agents, agent_workspace)
    staged_plugins: dict[str, Any] = {
        "entries": {PLUGIN_ID: {"enabled": True, "config": migrated_plugin_config(legacy_entry["config"], state_directory)}},
        "load": {"paths": rewritten_paths(plugin_paths, plugin_path)},
    }
    staged_allow = rewritten_allow(plugin_allow, include_legacy=True)
    if staged_allow is not None:
        staged_plugins["allow"] = staged_allow
    stage = {"plugins": staged_plugins, "agents": {"list": migrated_agents}}

    cleanup_plugins: dict[str, Any] = {
        "entries": {LEGACY_PLUGIN_ID: None},
        "load": {"paths": rewritten_paths(plugin_paths, plugin_path)},
    }
    cleanup_allow = rewritten_allow(plugin_allow, include_legacy=False)
    if cleanup_allow is not None:
        cleanup_plugins["allow"] = cleanup_allow
    cleanup = {"plugins": cleanup_plugins}
    return stage, cleanup, agent_changed


def legacy_state_path(config: dict[str, Any]) -> Path:
    raw = config.get("stateDirectory")
    candidate = Path(raw).expanduser() if isinstance(raw, str) and raw.strip() else Path.home() / ".openclaw" / "calla"
    candidate = candidate.resolve()
    allowed = {
        (Path.home() / ".openclaw" / "calla").resolve(),
        (Path.home() / ".openclaw" / "agents" / "main" / "desktop-tutor").resolve(),
    }
    if candidate not in allowed:
        raise MigrationError(f"refusing to copy unexpected desktop-tutor state directory {candidate}")
    return candidate


def migrate_state(legacy: Path, destination: Path, timestamp: str) -> Path | None:
    """Copy state and preserve an exact legacy snapshot; never delete the source."""
    receipt = destination / "migration-receipt.json"
    if destination.exists():
        if receipt.is_file():
            return None
        raise MigrationError(f"refusing to merge into existing state directory {destination}")
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    backup_root = destination.parent / "backups" / f"calla-tutor-legacy-state-{timestamp}"
    if legacy.exists():
        if not legacy.is_dir():
            raise MigrationError(f"legacy state path is not a directory: {legacy}")
        shutil.copytree(legacy, backup_root, copy_function=shutil.copy2)
        shutil.copytree(legacy, destination, copy_function=shutil.copy2)
    else:
        destination.mkdir(mode=0o700)
    os.chmod(destination, 0o700)
    for name in ("packs", "indexes", "lessons", "learners", "audit", "backups"):
        directory = destination / name
        directory.mkdir(mode=0o700, exist_ok=True)
        os.chmod(directory, 0o700)
    return backup_root if legacy.exists() else None


def patch_config(binary: str, patch: dict[str, Any], *, dry_run: bool) -> None:
    command = [binary, "config", "patch", "--stdin"]
    if dry_run:
        command.extend(["--dry-run", "--json"])
    run(command, input_text=json.dumps(patch))


def validate(binary: str) -> None:
    run([binary, "config", "validate"])


def merge_final_patch(stage: dict[str, Any], cleanup: dict[str, Any]) -> dict[str, Any]:
    result = copy.deepcopy(stage)
    result["plugins"]["entries"].update(cleanup["plugins"]["entries"])
    result["plugins"]["load"] = cleanup["plugins"]["load"]
    if "allow" in cleanup["plugins"]:
        result["plugins"]["allow"] = cleanup["plugins"]["allow"]
    return result


def migrate(arguments: argparse.Namespace) -> int:
    binary = arguments.openclaw_bin
    run([binary, "--version"])
    legacy_entry = config_get(binary, f"plugins.entries.{LEGACY_PLUGIN_ID}")
    target_entry = config_get(binary, f"plugins.entries.{PLUGIN_ID}")
    destination = arguments.state_directory.expanduser().resolve()
    plugin_path = arguments.plugin_path.resolve()
    agent_workspace = arguments.agent_workspace.resolve()
    if not plugin_path.is_dir() or not (plugin_path / "openclaw.plugin.json").is_file():
        raise MigrationError(f"Tutor plugin source is incomplete: {plugin_path}")
    if not agent_workspace.is_dir() or not (agent_workspace / "AGENTS.md").is_file():
        raise MigrationError(f"Calla agent workspace is incomplete: {agent_workspace}")
    if legacy_entry is None:
        if isinstance(target_entry, dict) and target_entry.get("config", {}).get("stateDirectory") == str(destination):
            print("Tutor migration is already complete; no legacy plugin entry is active.")
            return 0
        raise MigrationError("desktop-tutor is not configured; refusing to infer migration ownership")

    paths = config_get(binary, "plugins.load.paths")
    allowed = config_get(binary, "plugins.allow")
    agents = config_get(binary, "agents.list")
    stage, cleanup, agent_changed = build_migration_patches(
        legacy_entry=legacy_entry,
        plugin_paths=paths,
        plugin_allow=allowed,
        agents=agents,
        plugin_path=plugin_path,
        state_directory=destination,
        agent_workspace=agent_workspace,
    )
    final = merge_final_patch(stage, cleanup)
    print("Validating the staged tutor configuration without writing it...")
    patch_config(binary, stage, dry_run=True)
    print("Validating the final legacy-removal configuration without writing it...")
    patch_config(binary, final, dry_run=True)
    if arguments.dry_run:
        print("Dry run complete; no state or OpenClaw configuration changed.")
        return 0

    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    legacy_state = legacy_state_path(legacy_entry["config"])
    state_backup = migrate_state(legacy_state, destination, timestamp)
    config_file = active_config_path(binary)
    config_backup = destination / "backups" / f"openclaw-before-tutor-migration-{timestamp}.json5"
    shutil.copy2(config_file, config_backup)
    os.chmod(config_backup, 0o600)
    try:
        patch_config(binary, stage, dry_run=False)
        validate(binary)
        run([binary, "plugins", "inspect", PLUGIN_ID, "--runtime", "--json"])
        patch_config(binary, cleanup, dry_run=False)
        validate(binary)
        run([binary, "plugins", "inspect", PLUGIN_ID, "--runtime", "--json"])
    except Exception:
        shutil.copy2(config_backup, config_file)
        raise
    atomic_json(destination / "migration-receipt.json", {
        "format": "calla-tutor-migration-receipt",
        "format_version": 1,
        "migrated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "legacy_plugin": LEGACY_PLUGIN_ID,
        "plugin": PLUGIN_ID,
        "config_backup": str(config_backup),
        "legacy_state": str(legacy_state),
        "legacy_state_backup": str(state_backup) if state_backup else None,
        "agent_workspace_migrated": agent_changed,
    })
    print("Tutor plugin and Calla workspace migrated. The old plugin entry, path, and allow-list item are removed.")
    return 0


def parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="validate both migration phases without writing")
    parser.add_argument("--apply", action="store_true", help="write the validated migration")
    parser.add_argument("--openclaw-bin", default="openclaw")
    parser.add_argument("--state-directory", type=Path, default=Path.home() / ".openclaw" / "tutor")
    parser.add_argument("--plugin-path", type=Path, default=Path(__file__).resolve().parents[1] / "integrations" / "openclaw")
    parser.add_argument("--agent-workspace", type=Path, default=Path(__file__).resolve().parents[1] / "agent-workspace")
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    if arguments.dry_run == arguments.apply:
        parser().error("choose exactly one of --dry-run or --apply")
    try:
        return migrate(arguments)
    except (MigrationError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
