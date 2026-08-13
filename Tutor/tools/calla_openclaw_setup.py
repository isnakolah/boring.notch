#!/usr/bin/env python3
"""Safely configure Calla on an existing user-owned OpenClaw Gateway."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
PLUGIN_ID = "tutor"
CALLA_AGENT_ID = "calla"
DEFAULT_STATE_DIRECTORY = Path.home() / ".openclaw" / "tutor"
# This was the earlier workspace prototype. The standalone rewrite is now the
# configured source of truth on this host, so never leave both IDs loadable.
LEGACY_TUTOR_PLUGIN_PATHS = {
    "/srv/app/.openclaw/apps/desktop-tutor",
    "/srv/app/open-desktop-tutor/integrations/openclaw",
}
# The previous public setup added this browser-control origin. The private
# one-user route does not need it, so remove only this exact obsolete value.
LEGACY_CALLA_ORIGINS = {"https://calla.nomonlab.com"}

# Keep Calla's prompt small and purpose-built. These are all of the plugin's
# teaching tools: omitting one makes an otherwise-supported recovery path
# inaccessible. The minimal profile excludes unrelated coding, browser, and
# messaging schemas from the teaching prompt.
CALLA_AGENT_TOOLS = (
    "tutor_observe",
    # The route comes from the authored lesson now, but the model still has to
    # send it: the tooltip shows the steps, and the Mac cannot hold a plan it
    # was never given. Omitting this leaves the lesson with no visible shape.
    "tutor_plan",
    "tutor_remember",
    "tutor_guide",
    "tutor_narrate",
    "tutor_point",
    "tutor_propose_action",
    "tutor_verify",
)


class SetupError(RuntimeError):
    """A safe setup operation could not be completed."""


def run(command: list[str], *, input_text: str | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, input=input_text, capture_output=True, text=True, check=False)
    if check and result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or "no diagnostic output"
        raise SetupError(f"{' '.join(command[:3])} failed: {detail}")
    return result


def ensure_openclaw(binary: str) -> str:
    if shutil.which(binary) is None:
        raise SetupError(f"OpenClaw CLI not found: {binary}")
    return run([binary, "--version"]).stdout.strip()


def read_json_config(binary: str, path: str) -> Any | None:
    result = run([binary, "config", "get", path, "--json"], check=False)
    if result.returncode or not result.stdout.strip():
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def unique_append(values: Any, value: str) -> tuple[list[str] | None, bool]:
    if values is None:
        return None, False
    if not isinstance(values, list) or not all(isinstance(item, str) for item in values):
        raise SetupError("existing OpenClaw allowlist/origin configuration is not a string array")
    return values if value in values else [*values, value], value not in values


def remove_known(values: Any, known_values: set[str]) -> tuple[list[str] | None, bool]:
    if values is None:
        return None, False
    if not isinstance(values, list) or not all(isinstance(item, str) for item in values):
        raise SetupError("existing OpenClaw allowlist/origin configuration is not a string array")
    remaining = [item for item in values if item not in known_values]
    return remaining, len(remaining) != len(values)


def adaptive_thinking_configuration(binary: str) -> tuple[str, str]:
    """Use adaptive only for providers whose configured model advertises it.

    This is an installer preflight, not a probe that sends a paid model request.
    Unknown or unsupported providers deliberately stay on low and leave a
    receipt explaining why.
    """
    status = run([binary, "models", "status", "--json"], check=False)
    models = run([binary, "models", "list", "--json"], check=False)
    if status.returncode or models.returncode:
        return "low", "provider-capability-unavailable"
    try:
        default = json.loads(status.stdout).get("resolvedDefault")
        listed = json.loads(models.stdout).get("models", [])
        model = next((item for item in listed if item.get("key") == default and item.get("available")), None)
        provider = str(model.get("key", "")).split("/", 1)[0] if model else ""
    except (json.JSONDecodeError, AttributeError, TypeError):
        return "low", "provider-capability-unavailable"
    # These provider routes expose OpenClaw's adaptive level. Every other route
    # is a conservative fallback; no model/provider is substituted here.
    return ("adaptive", f"{provider}-adaptive") if provider in {"openai", "anthropic"} else ("low", f"{provider or 'unknown'}-no-adaptive")


def calla_agent_configuration(workspace: Path, thinking: str = "low") -> dict[str, Any]:
    """Return the isolated, low-latency OpenClaw agent Calla owns."""
    return {
        "id": CALLA_AGENT_ID,
        "name": "Calla",
        "workspace": str(workspace),
        "thinkingDefault": thinking,
        # The teaching prompt and plugin schemas are stable across the lesson.
        "params": {"cacheRetention": "long"},
        # Calla has no general-agent skills or memory search. Its only durable
        # recall is the bounded Calla SQLite/FTS graph owned by the Tutor plugin.
        "skills": [],
        "memorySearch": {"enabled": False},
        "contextInjection": "continuation-skip",
        "bootstrapMaxChars": 4000,
        "bootstrapTotalMaxChars": 6000,
        "tools": {"profile": "minimal", "alsoAllow": list(CALLA_AGENT_TOOLS)},
    }


def append_calla_agent(agent_list: Any, workspace: Path, thinking: str) -> tuple[list[dict[str, Any]], bool]:
    """Append or update only the Calla agent whose workspace this installer owns."""
    if agent_list is None:
        return [calla_agent_configuration(workspace, thinking)], True
    if not isinstance(agent_list, list):
        raise SetupError("existing OpenClaw agents.list configuration is not an array")
    for entry in agent_list:
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
            raise SetupError("existing OpenClaw agents.list must contain object entries with string ids")
        if entry["id"] == CALLA_AGENT_ID:
            if entry.get("workspace") != str(workspace): return agent_list, False
            updated = dict(entry)
            updated["thinkingDefault"] = thinking
            return [updated if item is entry else item for item in agent_list], updated != entry
    return [*agent_list, calla_agent_configuration(workspace, thinking)], True


def remove_calla_agent(agent_list: Any) -> tuple[list[dict[str, Any]] | None, bool]:
    """Remove only the dedicated agent Calla's installer created."""
    if agent_list is None:
        return None, False
    if not isinstance(agent_list, list):
        raise SetupError("existing OpenClaw agents.list configuration is not an array")
    if any(not isinstance(entry, dict) or not isinstance(entry.get("id"), str) for entry in agent_list):
        raise SetupError("existing OpenClaw agents.list must contain object entries with string ids")
    remaining = [entry for entry in agent_list if entry["id"] != CALLA_AGENT_ID]
    return remaining, len(remaining) != len(agent_list)


def build_gateway_patch(
    *,
    plugin_allow: Any,
    plugin_paths: Any,
    allowed_origins: Any,
    agent_list: Any,
    node_id: str | None,
    state_directory: Path,
    plugin_path: Path,
    agent_workspace: Path,
    thinking: str = "low",
) -> tuple[dict[str, Any], dict[str, bool]]:
    allow, allow_added = unique_append(plugin_allow, PLUGIN_ID)
    paths, path_added = unique_append(plugin_paths, str(plugin_path))
    legacy_paths_removed = False
    if paths is not None:
        legacy_paths_removed = any(path in LEGACY_TUTOR_PLUGIN_PATHS for path in paths)
        paths = [path for path in paths if path not in LEGACY_TUTOR_PLUGIN_PATHS]
    origins, legacy_origin_removed = remove_known(allowed_origins, LEGACY_CALLA_ORIGINS)
    agents, calla_agent_added = append_calla_agent(agent_list, agent_workspace, thinking)
    plugin_config: dict[str, Any] = {
        "role": "gateway",
        "stateDirectory": str(state_directory),
        # This is a private, single-user installation. The local Mac still
        # owns every Accessibility permission and action approval.
        "requireOwnerIdentity": False,
    }
    if node_id:
        plugin_config["nodeId"] = node_id
    patch: dict[str, Any] = {
        "plugins": {
            "entries": {PLUGIN_ID: {"enabled": True, "config": plugin_config}},
            "load": {"paths": paths or [str(plugin_path)]},
        },
        "gateway": {
            "mode": "local",
            "bind": "loopback",
            "auth": {"mode": "none", "token": None},
            # OpenClaw disallows auth:none for its own tailnet listener. The
            # server setup therefore owns an external Tailscale HTTPS proxy to
            # this loopback listener; the Gateway itself remains unexposed.
            "tailscale": {"mode": "off", "resetOnExit": False},
        },
        # Patches replace arrays, so preserve every existing agent before
        # appending Calla's narrow teaching context.
        "agents": {"list": agents},
    }
    if legacy_origin_removed:
        patch["gateway"]["controlUi"] = {"allowedOrigins": origins}
    if allow is not None:
        patch["plugins"]["allow"] = allow
    return patch, {
        "plugin_allow_added": allow_added,
        "plugin_path_added": path_added,
        "legacy_plugin_paths_removed": legacy_paths_removed,
        "legacy_origin_removed": legacy_origin_removed,
        "calla_agent_added": calla_agent_added,
    }


def prepare_state_directory(state_directory: Path) -> None:
    state_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(state_directory, 0o700)
    for name in ("packs", "indexes", "lessons", "learners", "audit", "backups"):
        directory = state_directory / name
        directory.mkdir(mode=0o700, exist_ok=True)
        os.chmod(directory, 0o700)


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


def active_config_path(binary: str) -> Path:
    result = run([binary, "config", "file"])
    # OpenClaw can emit a boxed plugin warning before the final config path.
    # Select an existing path from the output instead of treating the complete
    # warning-and-path transcript as a filesystem name.
    for line in reversed(result.stdout.splitlines()):
        config_path = Path(line.strip()).expanduser()
        if config_path.is_file():
            return config_path
    raise SetupError("OpenClaw config file path was not present in `openclaw config file` output")


def backup_config(binary: str, state_directory: Path) -> Path:
    source = active_config_path(binary)
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    destination = state_directory / "backups" / f"openclaw-{timestamp}.json5"
    shutil.copy2(source, destination)
    os.chmod(destination, 0o600)
    return destination


def patch_config(binary: str, patch: dict[str, Any], *, dry_run: bool) -> subprocess.CompletedProcess[str]:
    command = [binary, "config", "patch", "--stdin"]
    if dry_run:
        command.extend(["--dry-run", "--json"])
    return run(command, input_text=json.dumps(patch))


def validate_config(binary: str) -> None:
    run([binary, "config", "validate"])


def install(arguments: argparse.Namespace) -> int:
    binary = arguments.openclaw_bin
    ensure_openclaw(binary)
    state_directory = arguments.state_directory.expanduser().resolve()
    prior_receipt_path = state_directory / "install-receipt.json"
    prior_receipt = json.loads(prior_receipt_path.read_text(encoding="utf-8")) if prior_receipt_path.is_file() else {}
    plugin_allow = read_json_config(binary, "plugins.allow")
    plugin_paths = read_json_config(binary, "plugins.load.paths")
    allowed_origins = read_json_config(binary, "gateway.controlUi.allowedOrigins")
    agent_list = read_json_config(binary, "agents.list")
    thinking, thinking_reason = adaptive_thinking_configuration(binary)
    patch, ownership = build_gateway_patch(
        plugin_allow=plugin_allow,
        plugin_paths=plugin_paths,
        allowed_origins=allowed_origins,
        agent_list=agent_list,
        node_id=arguments.node_id,
        state_directory=state_directory,
        plugin_path=arguments.repository.resolve() / "integrations" / "openclaw",
        agent_workspace=arguments.repository.resolve() / "agent-workspace",
        thinking=thinking,
    )
    print("Calla additive OpenClaw patch:")
    print(json.dumps(patch, indent=2, sort_keys=True))
    print("Validating the patch without writing OpenClaw configuration...")
    preview = patch_config(binary, patch, dry_run=True)
    if preview.stdout.strip():
        print(preview.stdout.strip())
    if not arguments.yes:
        print("Preview complete. Add --yes to install; no files or OpenClaw configuration were changed.")
        return 0
    prepare_state_directory(state_directory)
    backup = backup_config(binary, state_directory)
    try:
        patch_config(binary, patch, dry_run=False)
        run([binary, "plugins", "enable", PLUGIN_ID])
        validate_config(binary)
    except Exception:
        shutil.copy2(backup, active_config_path(binary))
        raise
    receipt = {
        "format": "calla-openclaw-install-receipt",
        "format_version": 1,
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "state_directory": str(state_directory),
        "config_backup": str(backup),
        "plugin_allow_added": prior_receipt.get("plugin_allow_added", False) or ownership["plugin_allow_added"],
        "plugin_path_added": prior_receipt.get("plugin_path_added", False) or ownership["plugin_path_added"],
        "legacy_plugin_paths_removed": prior_receipt.get("legacy_plugin_paths_removed", False) or ownership["legacy_plugin_paths_removed"],
        "legacy_origin_removed": prior_receipt.get("legacy_origin_removed", False) or ownership["legacy_origin_removed"],
        "calla_agent_added": prior_receipt.get("calla_agent_added", False) or ownership["calla_agent_added"],
        "thinking_default": thinking,
        "thinking_reason": thinking_reason,
    }
    atomic_json(state_directory / "install-receipt.json", receipt)
    if arguments.app_pack:
        command = [sys.executable, str(REPOSITORY_ROOT / "tools" / "calla_pack_store.py"), str(arguments.app_pack), "--state-directory", str(state_directory)]
        run(command)
    if arguments.restart:
        run([binary, "gateway", "restart"])
    print(f"Calla Gateway configuration installed. Backup: {backup}")
    print("The private Tailscale endpoint is ready for the bundled Mac bootstrap. The local enroller will bind the first pending node named Calla Mac.")
    return 0


def status(arguments: argparse.Namespace) -> int:
    binary = arguments.openclaw_bin
    version = ensure_openclaw(binary)
    state_directory = arguments.state_directory.expanduser().resolve()
    configuration = read_json_config(binary, f"plugins.entries.{PLUGIN_ID}.config")
    print(json.dumps({
        "openclaw": version,
        "plugin_config": configuration,
        "calla_state_directory": str(state_directory),
        "state_exists": state_directory.is_dir(),
        "installed_packs": len(list((state_directory / "indexes").glob("*.json"))) if (state_directory / "indexes").is_dir() else 0,
        "install_receipt": (state_directory / "install-receipt.json").is_file(),
    }, indent=2, sort_keys=True))
    return 0


def check(arguments: argparse.Namespace) -> int:
    binary = arguments.openclaw_bin
    version = ensure_openclaw(binary)
    validate_config(binary)
    state_directory = arguments.state_directory.expanduser().resolve()
    print(json.dumps({
        "ok": True,
        "openclaw": version,
        "plugin_source": str(arguments.repository.resolve() / "integrations" / "openclaw"),
        "state_directory": str(state_directory),
        "state_exists": state_directory.is_dir(),
        "gateway_auth": read_json_config(binary, "gateway.auth.mode"),
        "gateway_bind": read_json_config(binary, "gateway.bind"),
        "gateway_tailscale": read_json_config(binary, "gateway.tailscale.mode"),
    }, indent=2, sort_keys=True))
    return 0


def remove(arguments: argparse.Namespace) -> int:
    if not arguments.yes:
        raise SetupError("--remove requires --yes because it removes Calla configuration and state")
    binary = arguments.openclaw_bin
    ensure_openclaw(binary)
    state_directory = arguments.state_directory.expanduser().resolve()
    receipt_path = state_directory / "install-receipt.json"
    if not receipt_path.is_file():
        raise SetupError(f"refusing to remove {state_directory}: no Calla install receipt exists")
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    if receipt.get("format") != "calla-openclaw-install-receipt" or receipt.get("state_directory") != str(state_directory):
        raise SetupError("refusing to remove state that was not created by this Calla installer")
    plugin_allow = read_json_config(binary, "plugins.allow")
    plugin_paths = read_json_config(binary, "plugins.load.paths")
    agent_list = read_json_config(binary, "agents.list")
    plugins: dict[str, Any] = {"entries": {PLUGIN_ID: None}}
    if receipt.get("plugin_allow_added") and isinstance(plugin_allow, list):
        plugins["allow"] = [item for item in plugin_allow if item != PLUGIN_ID]
    if receipt.get("plugin_path_added") and isinstance(plugin_paths, list):
        plugins["load"] = {"paths": [item for item in plugin_paths if item != str(arguments.repository.resolve() / "integrations" / "openclaw")]}
    patch: dict[str, Any] = {"plugins": plugins}
    if receipt.get("calla_agent_added"):
        remaining_agents, removed = remove_calla_agent(agent_list)
        if removed:
            patch["agents"] = {"list": remaining_agents}
    print("Calla removal patch:")
    print(json.dumps(patch, indent=2, sort_keys=True))
    patch_config(binary, patch, dry_run=True)
    backup = backup_config(binary, state_directory)
    try:
        patch_config(binary, patch, dry_run=False)
        validate_config(binary)
    except Exception:
        shutil.copy2(backup, active_config_path(binary))
        raise
    if arguments.restart:
        run([binary, "gateway", "restart"])
    shutil.rmtree(state_directory)
    print("Removed only Calla-owned OpenClaw configuration and state.")
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    mode = result.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="validate prerequisites without writing")
    mode.add_argument("--install", action="store_true", help="install Calla Gateway configuration")
    mode.add_argument("--status", action="store_true", help="show Calla configuration and local state")
    mode.add_argument("--remove", action="store_true", help="remove only state created by this installer")
    result.add_argument("--yes", action="store_true", help="confirm an install or removal")
    result.add_argument("--restart", action="store_true", help="perform one Gateway restart after successful validation")
    result.add_argument("--node-id", help="optional existing Mac node id; normally set by the local auto-enroller")
    result.add_argument("--app-pack", type=Path, help="compiled .otpack to install in Calla server-local retrieval")
    result.add_argument("--state-directory", type=Path, default=DEFAULT_STATE_DIRECTORY)
    result.add_argument("--repository", type=Path, default=REPOSITORY_ROOT)
    result.add_argument("--openclaw-bin", default="openclaw")
    return result


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        if arguments.check:
            return check(arguments)
        if arguments.status:
            return status(arguments)
        if arguments.install:
            return install(arguments)
        return remove(arguments)
    except (SetupError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
