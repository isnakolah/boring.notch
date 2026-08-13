#!/usr/bin/env python3
"""Probe the installed Blender bridge without exposing its session token."""

from __future__ import annotations

import argparse
import json
import os
import secrets
import socket
import stat
import sys
from pathlib import Path
from typing import Any


MAX_RESPONSE_BYTES = 2 * 1024 * 1024


def default_descriptor_directory() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Caches" / "CallaTutor"
    return Path(os.environ.get("TMPDIR", "/tmp")) / "CallaTutor"


def find_descriptor(directory: Path | None = None) -> Path:
    root = directory or default_descriptor_directory()
    candidates = sorted(root.glob("blender-*.json"), key=lambda path: path.stat().st_mtime, reverse=True)
    if not candidates:
        raise FileNotFoundError(
            f"no Blender bridge descriptor found in {root}; enable the add-on and keep Blender open"
        )
    return candidates[0]


def load_descriptor(path: Path) -> dict[str, Any]:
    path = path.expanduser().resolve()
    metadata = path.stat()
    mode = stat.S_IMODE(metadata.st_mode)
    if mode & 0o077:
        raise PermissionError(f"descriptor must be owner-only; found mode {mode:04o} at {path}")
    if hasattr(os, "getuid") and metadata.st_uid != os.getuid():
        raise PermissionError(f"descriptor is not owned by the current user: {path}")

    descriptor = json.loads(path.read_text(encoding="utf-8"))
    if descriptor.get("protocol_version") != 1 or descriptor.get("bridge") != "blender-tutor-bridge-v1":
        raise ValueError("descriptor uses an unsupported bridge protocol")
    if descriptor.get("host") != "127.0.0.1":
        raise ValueError("bridge descriptor is not restricted to IPv4 loopback")
    port = descriptor.get("port")
    if not isinstance(port, int) or not 1 <= port <= 65535:
        raise ValueError("bridge descriptor contains an invalid port")
    token = descriptor.get("token")
    if not isinstance(token, str) or len(token) < 16:
        raise ValueError("bridge descriptor contains an invalid session token")
    if descriptor.get("read_only") is not True:
        raise ValueError("bridge descriptor does not declare read-only mode")
    return descriptor


def probe(path: Path, operation: str, timeout: float = 5.0) -> dict[str, Any]:
    descriptor = load_descriptor(path)
    request = {
        "protocol_version": 1,
        "request_id": f"probe-{secrets.token_hex(8)}",
        "token": descriptor["token"],
        "operation": operation,
        "payload": {},
    }
    encoded = json.dumps(request, separators=(",", ":")).encode("utf-8") + b"\n"

    response = bytearray()
    with socket.create_connection((descriptor["host"], descriptor["port"]), timeout=timeout) as client:
        client.sendall(encoded)
        while not response.endswith(b"\n"):
            chunk = client.recv(65536)
            if not chunk:
                raise ConnectionError("Blender bridge closed before returning a response")
            response.extend(chunk)
            if len(response) > MAX_RESPONSE_BYTES:
                raise ValueError("Blender bridge response exceeded 2 MiB")

    decoded = json.loads(response)
    if decoded.get("request_id") != request["request_id"]:
        raise ValueError("Blender bridge returned a mismatched request id")
    return decoded


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--descriptor", type=Path, help="descriptor path; defaults to the newest active Blender bridge")
    parser.add_argument("--operation", choices=("ping", "observe_state", "observe_layout"), default="observe_state")
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args()

    try:
        descriptor = args.descriptor or find_descriptor()
        result = probe(descriptor, args.operation, args.timeout)
    except (ConnectionError, FileNotFoundError, json.JSONDecodeError, OSError, ValueError) as error:
        print(f"Bridge probe failed: {error}", file=sys.stderr)
        return 1

    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0 if result.get("ok") is True else 1


if __name__ == "__main__":
    raise SystemExit(main())
