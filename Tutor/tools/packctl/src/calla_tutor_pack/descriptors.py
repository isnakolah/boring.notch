"""Validation shared by App-Pack compilation and App-Pack installation.

Descriptors are deliberately small, declarative documents.  They are passed
through the Gateway unchanged, so this module rejects anything that would make
their local interpretation ambiguous or turn a matcher into executable regex.
"""

from __future__ import annotations

import math
import re
from typing import Any


class DescriptorError(ValueError):
    """Raised when a pack-authored UI or detector descriptor is unsafe."""


MAX_MATCHER_BYTES = 128
MAX_RESOLVER_CANDIDATES = 16
MAX_SELECTOR_FIELDS = 16
MAX_QUERY_PATH_SEGMENTS = 8
FORBIDDEN_COORDINATE_KEYS = frozenset(
    {
        "x",
        "y",
        "left",
        "top",
        "width",
        "height",
        "coordinate",
        "coordinates",
        "screen_x",
        "screen_y",
        "bounds",
        "frame",
    }
)
_UNSAFE_MATCHER_TOKENS = frozenset("\\?*+(){}")


def _fail(path: str, message: str) -> None:
    raise DescriptorError(f"{path}: {message}")


def _require_object(value: Any, path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        _fail(path, "must be an object")
    return value


def _require_string(value: Any, path: str, *, maximum: int = 256) -> str:
    if not isinstance(value, str) or not value.strip() or len(value.encode("utf-8")) > maximum:
        _fail(path, f"must be a non-empty UTF-8 string of at most {maximum} bytes")
    return value


def _require_identifier(value: Any, path: str) -> str:
    candidate = _require_string(value, path)
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", candidate):
        _fail(path, "must be a stable semantic identifier")
    return candidate


def _walk(value: Any, path: tuple[str, ...] = ()):
    yield path, value
    if isinstance(value, dict):
        for key, child in value.items():
            yield from _walk(child, (*path, str(key)))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from _walk(child, (*path, str(index)))


def reject_coordinate_fields(value: Any, path: str = "descriptor") -> None:
    """Reject coordinate-bearing data everywhere in an authored descriptor."""
    for location, _ in _walk(value):
        if location and location[-1].lower() in FORBIDDEN_COORDINATE_KEYS:
            _fail(f"{path}.{'.'.join(location)}", "coordinate-bearing fields are forbidden")


def _validate_matcher_grammar(pattern: str, path: str) -> None:
    """Accept only literals, ^/$ anchors, character classes, and alternation.

    This intentionally tiny grammar has identical parsing rules in the Gateway
    and TutorKit.  Escapes are excluded so there are no backreferences or
    engine-specific escape semantics.
    """
    if not pattern or len(pattern.encode("utf-8")) > MAX_MATCHER_BYTES:
        _fail(path, f"pattern must be 1..{MAX_MATCHER_BYTES} UTF-8 bytes")
    if any(character in _UNSAFE_MATCHER_TOKENS for character in pattern):
        _fail(path, "pattern contains a forbidden regex operator")

    alternatives = pattern.split("|")
    if any(not alternative for alternative in alternatives):
        _fail(path, "alternation branches must not be empty")
    for alternative in alternatives:
        if alternative.count("^") > 1 or alternative.count("$") > 1:
            _fail(path, "anchors may appear at most once per alternation branch")
        if "^" in alternative and not alternative.startswith("^"):
            _fail(path, "^ is permitted only at the start of an alternation branch")
        if "$" in alternative and not alternative.endswith("$"):
            _fail(path, "$ is permitted only at the end of an alternation branch")
        index = 0
        while index < len(alternative):
            character = alternative[index]
            if character == "[":
                closing = alternative.find("]", index + 1)
                if closing < 0 or closing == index + 1:
                    _fail(path, "character classes must be non-empty and closed")
                contents = alternative[index + 1 : closing]
                if "[" in contents or "^" in contents or "$" in contents or "|" in contents:
                    _fail(path, "character class contains an unsupported token")
                index = closing + 1
                continue
            if character == "]":
                _fail(path, "character class is not opened")
            index += 1


def validate_safe_matcher(value: Any, path: str) -> dict[str, Any]:
    matcher = _require_object(value, path)
    if set(matcher) - {"pattern", "case_insensitive"} or "pattern" not in matcher:
        _fail(path, "must contain only pattern and optional case_insensitive")
    pattern = _require_string(matcher["pattern"], f"{path}.pattern", maximum=MAX_MATCHER_BYTES)
    if "case_insensitive" in matcher and not isinstance(matcher["case_insensitive"], bool):
        _fail(f"{path}.case_insensitive", "must be a boolean")
    _validate_matcher_grammar(pattern, f"{path}.pattern")
    return matcher


def safe_match(matcher: dict[str, Any], text: str) -> bool:
    """Evaluate a previously validated matcher with the common bounded grammar."""
    validated = validate_safe_matcher(matcher, "matcher")
    flags = re.IGNORECASE if validated.get("case_insensitive") else 0
    return re.search(validated["pattern"], text, flags=flags) is not None


def _validate_accessibility(value: Any, path: str) -> None:
    resolver = _require_object(value, path)
    if set(resolver) != {"candidates"}:
        _fail(path, "must contain only candidates")
    candidates = resolver.get("candidates")
    if not isinstance(candidates, list) or not 1 <= len(candidates) <= MAX_RESOLVER_CANDIDATES:
        _fail(f"{path}.candidates", f"must contain 1..{MAX_RESOLVER_CANDIDATES} candidates")
    matcher_fields = {"label_matcher", "description_matcher", "help_matcher"}
    for index, candidate in enumerate(candidates):
        candidate_path = f"{path}.candidates.{index}"
        candidate = _require_object(candidate, candidate_path)
        if set(candidate) - ({"role"} | matcher_fields):
            _fail(candidate_path, "contains an unsupported accessibility field")
        _require_string(candidate.get("role"), f"{candidate_path}.role", maximum=80)
        present = matcher_fields & set(candidate)
        if not present:
            _fail(candidate_path, "requires at least one authored matcher")
        for field in present:
            validate_safe_matcher(candidate[field], f"{candidate_path}.{field}")


def _validate_bridge(value: Any, path: str) -> None:
    resolver = _require_object(value, path)
    if set(resolver) != {"selector"}:
        _fail(path, "must contain only selector")
    selector = _require_object(resolver.get("selector"), f"{path}.selector")
    if not selector or len(selector) > MAX_SELECTOR_FIELDS:
        _fail(f"{path}.selector", f"must contain 1..{MAX_SELECTOR_FIELDS} fields")
    for key, item in selector.items():
        _require_string(key, f"{path}.selector key", maximum=64)
        if not isinstance(item, (str, bool, int, float)) or isinstance(item, float) and not math.isfinite(item):
            _fail(f"{path}.selector.{key}", "must be a finite scalar")
        if isinstance(item, str):
            _require_string(item, f"{path}.selector.{key}", maximum=128)


def _validate_visual(value: Any, path: str) -> None:
    visual = _require_object(value, path)
    allowed = {"icon", "relative_to", "layout_hint", "constraints", "text_matcher"}
    if set(visual) - allowed or not visual:
        _fail(path, "contains an unsupported or empty visual resolver")
    for field in {"icon", "relative_to", "layout_hint"} & set(visual):
        _require_string(visual[field], f"{path}.{field}", maximum=128)
    if "constraints" in visual:
        constraints = visual["constraints"]
        if not isinstance(constraints, list) or len(constraints) > 8 or not all(
            isinstance(item, str) and item in {"visible", "enabled"} for item in constraints
        ):
            _fail(f"{path}.constraints", "must contain at most eight known visual constraints")
    if "text_matcher" in visual:
        validate_safe_matcher(visual["text_matcher"], f"{path}.text_matcher")


def _validate_neighbor_constraints(value: Any, path: str) -> None:
    constraints = _require_object(value, path)
    if set(constraints) != {"expected"}:
        _fail(path, "must contain only expected")
    expected = constraints.get("expected")
    if not isinstance(expected, list) or not 1 <= len(expected) <= 8:
        _fail(f"{path}.expected", "must contain 1..8 semantic neighbor labels")
    for index, item in enumerate(expected):
        _require_identifier(item, f"{path}.expected.{index}")


def validate_ui_target(entity: Any, path: str = "entity") -> dict[str, Any]:
    target = _require_object(entity, path)
    allowed = {
        "id", "kind", "title", "aliases", "app_versions", "source_refs", "region", "resolve",
        "neighbor_constraints", "minimum_confidence", "source_file",
    }
    if set(target) - allowed:
        _fail(path, "contains unsupported ui_target fields")
    _require_identifier(target.get("id"), f"{path}.id")
    if target.get("kind") != "ui_target":
        _fail(f"{path}.kind", "must be ui_target")
    _require_string(target.get("title"), f"{path}.title")
    aliases = target.get("aliases", [])
    if not isinstance(aliases, list) or len(aliases) > 32 or not all(isinstance(item, str) and item.strip() for item in aliases):
        _fail(f"{path}.aliases", "must contain at most 32 non-empty strings")
    if "region" in target:
        _require_identifier(target["region"], f"{path}.region")
    resolve = _require_object(target.get("resolve"), f"{path}.resolve")
    if not resolve or set(resolve) - {"accessibility", "bridge", "visual"}:
        _fail(f"{path}.resolve", "requires one or more known resolver branches")
    if "accessibility" in resolve:
        _validate_accessibility(resolve["accessibility"], f"{path}.resolve.accessibility")
    if "bridge" in resolve:
        _validate_bridge(resolve["bridge"], f"{path}.resolve.bridge")
    if "visual" in resolve:
        _validate_visual(resolve["visual"], f"{path}.resolve.visual")
    if "neighbor_constraints" in target:
        _validate_neighbor_constraints(target["neighbor_constraints"], f"{path}.neighbor_constraints")
    confidence = _require_object(target.get("minimum_confidence"), f"{path}.minimum_confidence")
    if set(confidence) != {"point", "act"}:
        _fail(f"{path}.minimum_confidence", "must contain exactly point and act")
    for field in ("point", "act"):
        value = confidence[field]
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value) or not 0 < value <= 1:
            _fail(f"{path}.minimum_confidence.{field}", "must be a finite number in (0, 1]")
    reject_coordinate_fields(target, path)
    return target


def _validate_query_value(value: Any, path: str) -> None:
    if isinstance(value, bool) or value is None or isinstance(value, (str, int)):
        if isinstance(value, str):
            _require_string(value, path, maximum=128)
        return
    if isinstance(value, float) and math.isfinite(value):
        return
    _fail(path, "must be a finite scalar")


def _validate_bridge_query(query: dict[str, Any], path: str) -> None:
    allowed = {"path", "equals", "contains", "any", "ordered"}
    if set(query) - allowed or "path" not in query:
        _fail(path, "contains unsupported bridge query fields")
    segments = _require_string(query["path"], f"{path}.path", maximum=128).split(".")
    if not 1 <= len(segments) <= MAX_QUERY_PATH_SEGMENTS or not all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", item) for item in segments):
        _fail(f"{path}.path", "must contain 1..8 bounded object-path segments")
    operators = [field for field in ("equals", "contains", "any", "ordered") if field in query]
    if len(operators) != 1:
        _fail(path, "requires exactly one of equals, contains, any, or ordered")
    if operators[0] == "any":
        any_value = _require_object(query["any"], f"{path}.any")
        if not any_value or len(any_value) > 8:
            _fail(f"{path}.any", "must contain 1..8 scalar fields")
        for key, value in any_value.items():
            _require_string(key, f"{path}.any key", maximum=64)
            _validate_query_value(value, f"{path}.any.{key}")
    elif operators[0] == "ordered":
        ordered = _require_object(query["ordered"], f"{path}.ordered")
        if set(ordered) != {"before", "after"}:
            _fail(f"{path}.ordered", "must contain before and after")
        _require_string(ordered["before"], f"{path}.ordered.before")
        _require_string(ordered["after"], f"{path}.ordered.after")
    else:
        _validate_query_value(query[operators[0]], f"{path}.{operators[0]}")


def _validate_accessibility_query(query: dict[str, Any], path: str) -> None:
    if set(query) != {"target", "attribute", "equals"}:
        _fail(path, "accessibility detectors require target, attribute, and equals")
    _require_identifier(query["target"], f"{path}.target")
    if query["attribute"] not in {"selected", "enabled", "visible"}:
        _fail(f"{path}.attribute", "must be selected, enabled, or visible")
    if not isinstance(query["equals"], bool):
        _fail(f"{path}.equals", "must be a boolean")


def validate_detector(entity: Any, path: str = "entity") -> dict[str, Any]:
    detector = _require_object(entity, path)
    allowed = {"id", "kind", "title", "aliases", "app_versions", "source_refs", "provider", "query", "source_file"}
    if set(detector) - allowed:
        _fail(path, "contains unsupported detector fields")
    _require_identifier(detector.get("id"), f"{path}.id")
    if detector.get("kind") != "detector":
        _fail(f"{path}.kind", "must be detector")
    _require_string(detector.get("title"), f"{path}.title")
    provider = detector.get("provider")
    if provider not in {"blender_bridge", "accessibility"}:
        _fail(f"{path}.provider", "must be blender_bridge or accessibility")
    query = _require_object(detector.get("query"), f"{path}.query")
    if provider == "blender_bridge":
        _validate_bridge_query(query, f"{path}.query")
    else:
        _validate_accessibility_query(query, f"{path}.query")
    reject_coordinate_fields(detector, path)
    return detector


def validate_descriptor(entity: Any, path: str = "entity") -> dict[str, Any]:
    if not isinstance(entity, dict):
        _fail(path, "must be an object")
    if entity.get("kind") == "ui_target":
        return validate_ui_target(entity, path)
    if entity.get("kind") == "detector":
        return validate_detector(entity, path)
    _fail(f"{path}.kind", "must be ui_target or detector")
    raise AssertionError("unreachable")
