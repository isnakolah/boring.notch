#!/usr/bin/env python3
"""Bind the single private Calla Mac node after its first OpenClaw connection."""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from typing import Any


COMMAND_TIMEOUT_SECONDS = 8
GATEWAY_TIMEOUT_MILLISECONDS = 5_000


def run(command: list[str], *, input_text: str | None = None) -> str:
    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(input=input_text, timeout=COMMAND_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as error:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        process.communicate()
        raise RuntimeError(f"{' '.join(command[:3])} timed out after {COMMAND_TIMEOUT_SECONDS} seconds") from error
    if process.returncode:
        detail = stderr.strip() or stdout.strip() or "no diagnostic output"
        raise RuntimeError(f"{' '.join(command[:3])} failed: {detail}")
    return stdout


def matching_pending(items: Any, display_name: str, *, kind: str, require_node_metadata: bool) -> list[dict[str, Any]]:
    if not isinstance(items, list):
        raise RuntimeError(f"OpenClaw returned an invalid pending-{kind} response")
    return [
        item
        for item in items
        if isinstance(item, dict)
        and item.get("displayName") == display_name
        and isinstance(item.get("requestId"), str)
        and (
            not require_node_metadata
            or (item.get("clientMode") == "node" and item.get("role") == "node")
        )
    ]


def pending_calla_devices(binary: str, display_name: str) -> list[dict[str, Any]]:
    raw = run([binary, "devices", "list", "--json", "--timeout", str(GATEWAY_TIMEOUT_MILLISECONDS)])
    parsed = json.loads(raw)
    if not isinstance(parsed, dict):
        raise RuntimeError("OpenClaw returned an invalid devices response")
    return matching_pending(parsed.get("pending"), display_name, kind="device", require_node_metadata=True)


def pending_calla_nodes(binary: str, display_name: str) -> list[dict[str, Any]]:
    raw = run([binary, "nodes", "pending", "--json", "--timeout", str(GATEWAY_TIMEOUT_MILLISECONDS)])
    parsed = json.loads(raw)
    nodes = matching_pending(parsed, display_name, kind="node", require_node_metadata=False)
    return [node for node in nodes if isinstance(node.get("nodeId"), str)]


def require_one(pending: list[dict[str, Any]], display_name: str, kind: str) -> dict[str, Any] | None:
    if not pending:
        return None
    if len(pending) != 1:
        raise RuntimeError(f"refusing to auto-enroll {len(pending)} pending {kind}s named {display_name!r}")
    return pending[0]


def enroll_one(binary: str, display_name: str) -> bool:
    device = require_one(pending_calla_devices(binary, display_name), display_name, "device")
    if device:
        run([binary, "devices", "approve", device["requestId"], "--json", "--timeout", str(GATEWAY_TIMEOUT_MILLISECONDS)])
        print(f"Approved Calla Mac device {device.get('deviceId', 'unknown')}.")
        return False
    node = require_one(pending_calla_nodes(binary, display_name), display_name, "node")
    if not node:
        return False
    run([binary, "nodes", "approve", node["requestId"], "--json", "--timeout", str(GATEWAY_TIMEOUT_MILLISECONDS)])
    patch = {"plugins": {"entries": {"tutor": {"enabled": True, "config": {"nodeId": node["nodeId"]}}}}}
    run([binary, "config", "patch", "--stdin"], input_text=json.dumps(patch))
    run([binary, "config", "validate"])
    print(f"Enrolled Calla Mac node {node['nodeId']}.")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--openclaw-bin", default="openclaw")
    parser.add_argument("--display-name", default="Calla Mac")
    parser.add_argument("--watch", action="store_true", help="poll until a matching Mac connects")
    parser.add_argument("--interval", type=float, default=3.0)
    arguments = parser.parse_args()
    if arguments.interval <= 0:
        parser.error("--interval must be positive")
    try:
        while True:
            if enroll_one(arguments.openclaw_bin, arguments.display_name):
                return 0
            if not arguments.watch:
                print("No pending Calla Mac node yet.")
                return 0
            time.sleep(arguments.interval)
    except (RuntimeError, json.JSONDecodeError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
