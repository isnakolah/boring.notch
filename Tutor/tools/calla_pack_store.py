#!/usr/bin/env python3
"""Install compiled Calla App Packs into the OpenClaw server-local state store."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import Any

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
PACKCTL_SOURCE = REPOSITORY_ROOT / "tools" / "packctl" / "src"
if str(PACKCTL_SOURCE) not in sys.path:
    sys.path.insert(0, str(PACKCTL_SOURCE))

from calla_tutor_pack.descriptors import DescriptorError, validate_descriptor


INDEX_FORMAT = "calla-local-pack-index"
DEFAULT_STATE_DIRECTORY = Path.home() / ".openclaw" / "tutor"


class PackStoreError(ValueError):
    """Raised when a compiled pack cannot safely enter the Calla state store."""


def _read_json_member(archive: zipfile.ZipFile, member: str) -> Any:
    try:
        return json.loads(archive.read(member).decode("utf-8"))
    except KeyError as exc:
        raise PackStoreError(f"compiled pack is missing {member}") from exc
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PackStoreError(f"compiled pack has invalid {member}") from exc


def load_compiled_pack(source: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Load the public manifest and entities without extracting the SQLite index."""
    if not source.is_file():
        raise PackStoreError(f"compiled pack does not exist: {source}")
    try:
        with zipfile.ZipFile(source) as archive:
            manifest = _read_json_member(archive, "manifest.json")
            entities = _read_json_member(archive, "entities.json")
    except zipfile.BadZipFile as exc:
        raise PackStoreError(f"compiled pack is not a valid .otpack ZIP: {source}") from exc
    if not isinstance(manifest, dict) or manifest.get("format") not in {"calla-tutor-pack", "open-desktop-tutor-pack"}:
        raise PackStoreError("compiled pack has an unsupported manifest format")
    if manifest.get("format_version") != 1:
        raise PackStoreError("compiled pack format_version must be 1")
    pack = manifest.get("pack")
    if not isinstance(pack, dict) or not isinstance(pack.get("id"), str) or not isinstance(pack.get("pack_version"), str):
        raise PackStoreError("compiled pack is missing a valid pack id or pack_version")
    if not isinstance(pack.get("apps"), list):
        raise PackStoreError("compiled pack is missing application compatibility metadata")
    if not isinstance(entities, list) or not all(isinstance(entity, dict) for entity in entities):
        raise PackStoreError("compiled pack entities must be an array of objects")
    if manifest.get("entity_count") != len(entities):
        raise PackStoreError("compiled pack entity_count does not match entities.json")
    for index, entity in enumerate(entities):
        if entity.get("kind") not in {"ui_target", "detector"}:
            continue
        try:
            validate_descriptor(entity, f"compiled entity {index}")
        except DescriptorError as exc:
            raise PackStoreError(f"compiled pack contains an invalid descriptor: {exc}") from exc
    return pack, entities


def _safe_component(value: str) -> str:
    component = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip(".-")
    if not component:
        raise PackStoreError("pack identifier cannot be converted to a safe filename")
    return component


def _atomic_write(path: Path, content: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def install_pack(source: Path, state_directory: Path = DEFAULT_STATE_DIRECTORY) -> dict[str, Any]:
    """Replace prior revisions of one pack and write its retrieval sidecar atomically."""
    pack, entities = load_compiled_pack(source)
    state_directory = state_directory.expanduser().resolve()
    pack_component = _safe_component(pack["id"])
    component = f"{pack_component}-{_safe_component(pack['pack_version'])}"
    pack_path = state_directory / "packs" / f"{component}.otpack"
    index_path = state_directory / "indexes" / f"{component}.json"
    index = {
        "format": INDEX_FORMAT,
        "format_version": 1,
        "pack": pack,
        "entities": entities,
    }
    _atomic_write(pack_path, source.read_bytes())
    _atomic_write(index_path, (json.dumps(index, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8"))
    removed_revisions = 0
    for directory, suffix, current in ((pack_path.parent, ".otpack", pack_path), (index_path.parent, ".json", index_path)):
        for candidate in directory.glob(f"{pack_component}-*{suffix}"):
            if candidate != current:
                candidate.unlink()
                removed_revisions += 1
    return {
        "ok": True,
        "pack_id": pack["id"],
        "pack_version": pack["pack_version"],
        "entities": len(entities),
        "pack_path": str(pack_path),
        "index_path": str(index_path),
        "removed_revisions": removed_revisions,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compiled_pack", type=Path, help="compiled .otpack file")
    parser.add_argument("--state-directory", type=Path, default=DEFAULT_STATE_DIRECTORY)
    arguments = parser.parse_args(argv)
    try:
        print(json.dumps(install_pack(arguments.compiled_pack, arguments.state_directory), sort_keys=True))
        return 0
    except PackStoreError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
