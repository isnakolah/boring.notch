from __future__ import annotations

import json
import hashlib
import re
import sqlite3
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import yaml
from jsonschema import Draft202012Validator, FormatChecker

from .descriptors import DescriptorError, reject_coordinate_fields, validate_detector, validate_ui_target


ENTITY_KIND_BY_DIRECTORY = {
    "concepts": "concept",
    "ui": "ui_target",
    "detectors": "detector",
    "lessons": "lesson",
    "courses": "course",
    "workflows": "workflow",
    "commands": "command",
    "shortcuts": "shortcut",
    "recovery": "recovery",
}

INDEXABLE_SUFFIXES = {".yaml", ".yml", ".json", ".md"}
FIXED_ZIP_TIME = (2026, 1, 1, 0, 0, 0)


class PackError(ValueError):
    """Raised when a pack cannot be validated or compiled safely."""


@dataclass(frozen=True)
class ValidationResult:
    pack_path: Path
    manifest: dict[str, Any]
    entities: tuple[dict[str, Any], ...]


@dataclass(frozen=True)
class CompileResult:
    output_path: Path
    entity_count: int
    pack_id: str
    pack_version: str


def _repo_root(start: Path) -> Path:
    module_path = Path(__file__).resolve()
    candidates = (
        start.resolve(),
        *start.resolve().parents,
        Path.cwd().resolve(),
        *Path.cwd().resolve().parents,
        module_path,
        *module_path.parents,
    )
    for candidate in candidates:
        if (candidate / "schemas" / "app-pack" / "v1" / "pack.schema.json").is_file():
            return candidate
    raise PackError("could not locate schemas/app-pack/v1 from the pack path")


def _read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise PackError(f"{path}: expected a JSON object")
    return value


def _load_yaml_or_json(path: Path) -> Any:
    try:
        text = path.read_text(encoding="utf-8")
        return json.loads(text) if path.suffix == ".json" else yaml.safe_load(text)
    except (OSError, json.JSONDecodeError, yaml.YAMLError) as exc:
        raise PackError(f"{path}: could not parse: {exc}") from exc


def _load_markdown(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---\n"):
        raise PackError(f"{path}: Markdown entities require YAML front matter")
    try:
        _, front_matter, body = text.split("---\n", 2)
        metadata = yaml.safe_load(front_matter)
    except (ValueError, yaml.YAMLError) as exc:
        raise PackError(f"{path}: invalid Markdown front matter: {exc}") from exc
    if not isinstance(metadata, dict):
        raise PackError(f"{path}: Markdown front matter must be an object")
    metadata["text"] = body.strip()
    return metadata


def _entity_documents(path: Path) -> Iterable[dict[str, Any]]:
    value = _load_markdown(path) if path.suffix == ".md" else _load_yaml_or_json(path)
    if isinstance(value, dict) and isinstance(value.get("entities"), list):
        value = value["entities"]
    if isinstance(value, dict):
        yield value
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            if not isinstance(item, dict):
                raise PackError(f"{path}: entity {index} must be an object")
            yield item
        return
    raise PackError(f"{path}: expected an entity object or list")


def _schema_errors(instance: Any, schema: dict[str, Any], source: Path) -> list[str]:
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    errors: list[str] = []
    for error in sorted(validator.iter_errors(instance), key=lambda item: list(item.path)):
        location = ".".join(str(part) for part in error.path) or "<root>"
        errors.append(f"{source}: {location}: {error.message}")
    return errors


def _iter_entity_paths(pack_path: Path) -> Iterable[Path]:
    root_files = [pack_path / "terminology.yaml", pack_path / "terminology.yml", pack_path / "terminology.json"]
    for path in root_files:
        if path.is_file():
            yield path
    for directory in ENTITY_KIND_BY_DIRECTORY:
        base = pack_path / directory
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if path.is_file() and path.suffix.lower() in INDEXABLE_SUFFIXES:
                yield path


def _normalize_entity(entity: dict[str, Any], path: Path, pack_path: Path) -> dict[str, Any]:
    normalized = dict(entity)
    relative = path.relative_to(pack_path)
    if "kind" not in normalized:
        if relative.name.startswith("terminology."):
            normalized["kind"] = "terminology"
        else:
            normalized["kind"] = ENTITY_KIND_BY_DIRECTORY.get(relative.parts[0])
    normalized["_source_file"] = relative.as_posix()
    if "title" not in normalized and isinstance(normalized.get("name"), str):
        normalized["title"] = normalized["name"]
    return normalized


def _walk(value: Any, path: tuple[str, ...] = ()) -> Iterable[tuple[tuple[str, ...], Any]]:
    yield path, value
    if isinstance(value, dict):
        for key, child in value.items():
            yield from _walk(child, (*path, str(key)))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from _walk(child, (*path, str(index)))


def _semantic_errors(
    manifest: dict[str, Any], entities: list[dict[str, Any]], pack_path: Path
) -> list[str]:
    errors: list[str] = []
    by_id: dict[str, dict[str, Any]] = {}
    source_ids = {item["id"] for item in manifest.get("sources", []) if isinstance(item, dict) and "id" in item}

    for entity in entities:
        entity_id = entity.get("id")
        source_file = entity.get("_source_file", "<unknown>")
        if isinstance(entity_id, str):
            if entity_id in by_id:
                errors.append(
                    f"{pack_path / source_file}: duplicate entity id {entity_id!r}; first defined in "
                    f"{by_id[entity_id].get('_source_file')}"
                )
            else:
                by_id[entity_id] = entity

        for source_ref in entity.get("source_refs", []):
            if source_ref not in source_ids:
                errors.append(f"{pack_path / source_file}: unknown source_ref {source_ref!r}")

        try:
            reject_coordinate_fields(entity, str(pack_path / source_file))
        except DescriptorError as exc:
            errors.append(str(exc))

        try:
            if entity.get("kind") == "ui_target":
                validate_ui_target({key: value for key, value in entity.items() if not key.startswith("_")}, str(pack_path / source_file))
            elif entity.get("kind") == "detector":
                validate_detector({key: value for key, value in entity.items() if not key.startswith("_")}, str(pack_path / source_file))
        except DescriptorError as exc:
            errors.append(str(exc))

    def require_reference(owner: dict[str, Any], ref: Any, expected_kind: str, field: str) -> None:
        if not isinstance(ref, str):
            return
        target = by_id.get(ref)
        source_file = owner.get("_source_file", "<unknown>")
        if target is None:
            errors.append(f"{pack_path / source_file}: {field} references unknown id {ref!r}")
        elif target.get("kind") != expected_kind:
            errors.append(
                f"{pack_path / source_file}: {field} references {ref!r} of kind {target.get('kind')!r}, "
                f"expected {expected_kind!r}"
            )

    for entity in entities:
        for location, value in _walk(entity):
            key = location[-1] if location else ""
            if key == "target":
                require_reference(entity, value, "ui_target", ".".join(location))
            elif key == "detector":
                require_reference(entity, value, "detector", ".".join(location))
            # A diagnosis explains a failure, and the learner believes it. It may
            # therefore only name a detector this pack actually ships, checked on
            # the Mac exactly as a success condition is — the same rule as every
            # other reference here, applied to the one field whose output is a
            # sentence rather than a verdict.
            elif key == "when":
                require_reference(entity, value, "detector", ".".join(location))
            elif key == "target" and entity.get("kind") == "detector":
                require_reference(entity, value, "ui_target", ".".join(location))
            elif key == "concept_refs" and isinstance(value, list):
                for ref in value:
                    require_reference(entity, ref, "concept", ".".join(location))
            # A course is a list of lessons and nothing else, so a name that
            # resolves to nothing is the whole course being empty. Caught here
            # rather than at teach time, where it would reach a learner as a
            # course that opens onto nothing.
            elif key == "lessons" and entity.get("kind") == "course" and isinstance(value, list):
                for ref in value:
                    require_reference(entity, ref, "lesson", ".".join(location))

    # Binary lesson scenes are intentionally opaque to Gateway prompts and
    # learning records, but they are not optional.  A lesson without both a
    # starter and a proof scene cannot be resumed or preflighted honestly.
    assets = pack_path / "assets"
    for entity in entities:
        if entity.get("kind") != "lesson":
            continue
        source_file = entity.get("_source_file", "<unknown>")
        entries = entity.get("assets")
        if not isinstance(entries, list) or len(entries) != 2:
            errors.append(f"{pack_path / source_file}: lesson requires exactly starter and proof assets")
            continue
        roles: set[str] = set()
        for asset in entries:
            if not isinstance(asset, dict):
                errors.append(f"{pack_path / source_file}: lesson asset must be an object")
                continue
            asset_id, role, digest, size = asset.get("asset_id"), asset.get("role"), asset.get("sha256"), asset.get("bytes")
            if not isinstance(asset_id, str) or not re.fullmatch(r"[a-z0-9][a-z0-9._-]{2,120}", asset_id):
                errors.append(f"{pack_path / source_file}: lesson asset has invalid asset_id")
                continue
            if role not in {"starter", "proof"} or role in roles:
                errors.append(f"{pack_path / source_file}: lesson asset roles must be one starter and one proof")
                continue
            roles.add(role)
            if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest) or not isinstance(size, int) or size < 1:
                errors.append(f"{pack_path / source_file}: lesson asset hash or byte count is invalid")
                continue
            candidate = assets / f"{asset_id}.blend"
            if not candidate.is_file():
                errors.append(f"{pack_path / source_file}: missing lesson asset {asset_id}")
                continue
            payload = candidate.read_bytes()
            if len(payload) != size or hashlib.sha256(payload).hexdigest() != digest:
                errors.append(f"{pack_path / source_file}: lesson asset {asset_id} does not match manifest")
        if roles != {"starter", "proof"}:
            errors.append(f"{pack_path / source_file}: lesson requires one starter and one proof asset")

    return errors


def validate_pack(pack_path: str | Path) -> ValidationResult:
    pack_path = Path(pack_path).resolve()
    manifest_path = pack_path / "pack.yaml"
    if not manifest_path.is_file():
        raise PackError(f"{pack_path}: missing pack.yaml")

    repo_root = _repo_root(pack_path)
    manifest = _load_yaml_or_json(manifest_path)
    if not isinstance(manifest, dict):
        raise PackError(f"{manifest_path}: manifest must be an object")

    pack_schema = _read_json(repo_root / "schemas" / "app-pack" / "v1" / "pack.schema.json")
    entity_schema = _read_json(repo_root / "schemas" / "app-pack" / "v1" / "entity.schema.json")
    errors = _schema_errors(manifest, pack_schema, manifest_path)

    entities: list[dict[str, Any]] = []
    for path in _iter_entity_paths(pack_path):
        for entity in _entity_documents(path):
            normalized = _normalize_entity(entity, path, pack_path)
            public_entity = {key: value for key, value in normalized.items() if not key.startswith("_")}
            errors.extend(_schema_errors(public_entity, entity_schema, path))
            entities.append(normalized)

    if not entities:
        errors.append(f"{pack_path}: pack contains no entities")
    errors.extend(_semantic_errors(manifest, entities, pack_path))
    if errors:
        raise PackError("pack validation failed:\n- " + "\n- ".join(errors))

    return ValidationResult(pack_path=pack_path, manifest=manifest, entities=tuple(entities))


def _entity_search_text(entity: dict[str, Any]) -> str:
    ignored = {"resolve", "minimum_confidence", "_source_file"}
    parts: list[str] = []
    for key, value in entity.items():
        if key in ignored:
            continue
        if isinstance(value, str):
            parts.append(value)
        elif isinstance(value, list) and all(isinstance(item, str) for item in value):
            parts.extend(value)
    return "\n".join(parts)


def _build_index(database_path: Path, entities: Iterable[dict[str, Any]]) -> None:
    connection = sqlite3.connect(database_path)
    try:
        connection.executescript(
            """
            PRAGMA journal_mode=DELETE;
            PRAGMA synchronous=FULL;
            CREATE TABLE entities (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                source_file TEXT NOT NULL,
                body_json TEXT NOT NULL
            );
            CREATE VIRTUAL TABLE entities_fts USING fts5(
                id UNINDEXED,
                kind,
                title,
                aliases,
                text,
                tokenize='unicode61 remove_diacritics 2'
            );
            """
        )
        for entity in sorted(entities, key=lambda item: item["id"]):
            public = {key: value for key, value in entity.items() if not key.startswith("_")}
            body = json.dumps(public, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
            aliases = " ".join(entity.get("aliases", []))
            connection.execute(
                "INSERT INTO entities(id, kind, title, source_file, body_json) VALUES (?, ?, ?, ?, ?)",
                (entity["id"], entity["kind"], entity["title"], entity["_source_file"], body),
            )
            connection.execute(
                "INSERT INTO entities_fts(id, kind, title, aliases, text) VALUES (?, ?, ?, ?, ?)",
                (entity["id"], entity["kind"], entity["title"], aliases, _entity_search_text(entity)),
            )
        connection.commit()
    finally:
        connection.close()


def _write_zip_member(archive: zipfile.ZipFile, name: str, data: bytes) -> None:
    info = zipfile.ZipInfo(name, FIXED_ZIP_TIME)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o100644 << 16
    archive.writestr(info, data)


def compile_pack(pack_path: str | Path, output_path: str | Path) -> CompileResult:
    result = validate_pack(pack_path)
    output = Path(output_path).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    public_entities = [
        {key: value for key, value in entity.items() if not key.startswith("_")}
        | {"source_file": entity["_source_file"]}
        for entity in result.entities
    ]
    compiled_manifest = {
        "format": "calla-tutor-pack",
        "format_version": 1,
        "pack": result.manifest,
        "entity_count": len(public_entities),
    }

    with tempfile.TemporaryDirectory(prefix="calla-tutor-pack-") as temp_directory:
        index_path = Path(temp_directory) / "index.sqlite3"
        _build_index(index_path, result.entities)
        with zipfile.ZipFile(output, "w") as archive:
            _write_zip_member(
                archive,
                "manifest.json",
                json.dumps(compiled_manifest, sort_keys=True, indent=2, ensure_ascii=False).encode("utf-8"),
            )
            _write_zip_member(
                archive,
                "entities.json",
                json.dumps(public_entities, sort_keys=True, indent=2, ensure_ascii=False).encode("utf-8"),
            )
            _write_zip_member(archive, "index.sqlite3", index_path.read_bytes())
            # Keep learner scenes opaque. They are copied and hash-checked by
            # the Mac; neither index nor FTS can inspect their bytes.
            assets = result.pack_path / "assets"
            if assets.is_dir():
                for asset in sorted(assets.glob("*.blend")):
                    _write_zip_member(archive, f"assets/{asset.name}", asset.read_bytes())

    return CompileResult(
        output_path=output,
        entity_count=len(public_entities),
        pack_id=result.manifest["id"],
        pack_version=result.manifest["pack_version"],
    )


def _fts_query(query: str) -> str:
    tokens = re.findall(r"[\w.-]+", query, flags=re.UNICODE)
    if not tokens:
        raise PackError("search query contains no searchable terms")
    return " AND ".join(f'"{token.replace(chr(34), chr(34) * 2)}"' for token in tokens)


def search_pack(pack_file: str | Path, query: str, limit: int = 5) -> list[dict[str, Any]]:
    pack_file = Path(pack_file).resolve()
    if not pack_file.is_file():
        raise PackError(f"compiled pack does not exist: {pack_file}")
    if limit < 1 or limit > 50:
        raise PackError("search limit must be between 1 and 50")

    with tempfile.TemporaryDirectory(prefix="calla-tutor-search-") as temp_directory:
        database_path = Path(temp_directory) / "index.sqlite3"
        with zipfile.ZipFile(pack_file, "r") as archive:
            try:
                database_path.write_bytes(archive.read("index.sqlite3"))
            except KeyError as exc:
                raise PackError(f"{pack_file}: missing index.sqlite3") from exc
        connection = sqlite3.connect(f"file:{database_path}?mode=ro", uri=True)
        connection.row_factory = sqlite3.Row
        try:
            rows = connection.execute(
                """
                SELECT e.id, e.kind, e.title, e.source_file, e.body_json, bm25(entities_fts) AS score
                FROM entities_fts
                JOIN entities e ON e.id = entities_fts.id
                WHERE entities_fts MATCH ?
                ORDER BY score, e.id
                LIMIT ?
                """,
                (_fts_query(query), limit),
            ).fetchall()
        finally:
            connection.close()
    return [
        {
            "id": row["id"],
            "kind": row["kind"],
            "title": row["title"],
            "source_file": row["source_file"],
            "score": row["score"],
            "entity": json.loads(row["body_json"]),
        }
        for row in rows
    ]
