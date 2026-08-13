from __future__ import annotations

import hmac
from typing import Any

from .observer import observe_layout, observe_state, property_contexts, set_property_context


ALLOWED_OPERATIONS = frozenset({"ping", "observe_state", "observe_layout", "property_contexts", "set_property_context"})


class BridgeProtocolError(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def _require_string(request: dict[str, Any], key: str, *, minimum: int = 1) -> str:
    value = request.get(key)
    if not isinstance(value, str) or len(value) < minimum:
        raise BridgeProtocolError("INVALID_REQUEST", f"{key} must be a string of at least {minimum} characters")
    return value


def dispatch_request(request: Any, *, expected_token: str, bpy_module: Any) -> dict[str, Any]:
    """Validate and execute one allowlisted bridge request."""

    if not isinstance(request, dict):
        raise BridgeProtocolError("INVALID_REQUEST", "request must be an object")
    if request.get("protocol_version") != 1:
        raise BridgeProtocolError("UNSUPPORTED_PROTOCOL", "protocol_version must be 1")

    request_id = _require_string(request, "request_id", minimum=8)
    supplied_token = _require_string(request, "token", minimum=16)
    if not hmac.compare_digest(supplied_token, expected_token):
        raise BridgeProtocolError("UNAUTHORIZED", "invalid bridge session token")

    operation = _require_string(request, "operation")
    if operation not in ALLOWED_OPERATIONS:
        raise BridgeProtocolError(
            "OPERATION_DENIED",
            f"operation {operation!r} is not allowlisted; supported operations: {sorted(ALLOWED_OPERATIONS)}",
        )
    payload = request.get("payload", {})
    if not isinstance(payload, dict):
        raise BridgeProtocolError("INVALID_REQUEST", "payload must be an object")

    if operation == "ping":
        result = {"bridge": "blender-tutor-bridge-v1", "read_only": True, "capabilities": sorted(ALLOWED_OPERATIONS)}
    elif operation == "observe_state":
        if payload:
            raise BridgeProtocolError("INVALID_REQUEST", "observe_state currently accepts no payload fields")
        result = observe_state(bpy_module)
    elif operation == "observe_layout":
        if payload:
            raise BridgeProtocolError("INVALID_REQUEST", "observe_layout currently accepts no payload fields")
        result = observe_layout(bpy_module)
    elif operation == "property_contexts":
        if payload:
            raise BridgeProtocolError("INVALID_REQUEST", "property_contexts accepts no payload fields")
        result = {"contexts": property_contexts(bpy_module)}
    elif operation == "set_property_context":
        # The one operation that writes, and it writes one enum on one editor.
        if set(payload) != {"context"}:
            raise BridgeProtocolError("INVALID_REQUEST", "set_property_context accepts a context only")
        requested = _require_string(payload, "context")
        try:
            result = set_property_context(bpy_module, requested)
        except ValueError as error:
            raise BridgeProtocolError("OPERATION_DENIED", str(error)) from error
    else:  # pragma: no cover - guarded by ALLOWED_OPERATIONS
        raise AssertionError(operation)

    return {
        "protocol_version": 1,
        "request_id": request_id,
        "ok": True,
        "result": result,
    }


def error_response(request_id: str | None, error: Exception) -> dict[str, Any]:
    if isinstance(error, BridgeProtocolError):
        code = error.code
        message = str(error)
    else:
        code = "INTERNAL_ERROR"
        message = "bridge request failed"
    return {
        "protocol_version": 1,
        "request_id": request_id,
        "ok": False,
        "error": {"code": code, "message": message},
    }
