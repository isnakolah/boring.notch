from __future__ import annotations

import json
import os
import queue
import secrets
import socketserver
import sys
import tempfile
import threading
from pathlib import Path
from typing import Any

from .protocol import ALLOWED_OPERATIONS, dispatch_request, error_response


MAX_REQUEST_BYTES = 256 * 1024
MAIN_THREAD_TIMEOUT_SECONDS = 5.0


class _BridgeRequestHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        request_id: str | None = None
        try:
            raw = self.rfile.readline(MAX_REQUEST_BYTES + 1)
            if len(raw) > MAX_REQUEST_BYTES:
                raise ValueError("request exceeds maximum size")
            if not raw.endswith(b"\n"):
                raise ValueError("request must be one newline-delimited JSON object")
            request = json.loads(raw)
            request_id = request.get("request_id") if isinstance(request, dict) else None
            response = self.server.runtime.dispatch_on_blender_thread(request)  # type: ignore[attr-defined]
        except Exception as exc:
            response = error_response(request_id, exc)
        encoded = json.dumps(response, separators=(",", ":"), ensure_ascii=False).encode("utf-8") + b"\n"
        self.wfile.write(encoded)


class _ThreadingBridgeServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = False
    daemon_threads = True

    def __init__(self, server_address: tuple[str, int], runtime: "BlenderBridgeRuntime"):
        self.runtime = runtime
        super().__init__(server_address, _BridgeRequestHandler)


class BlenderBridgeRuntime:
    """Loopback-only, per-launch-token bridge with Blender-main-thread dispatch."""

    def __init__(self, bpy_module: Any, descriptor_directory: str | Path | None = None):
        self.bpy_module = bpy_module
        self.token = secrets.token_urlsafe(32)
        self.descriptor_directory = Path(descriptor_directory) if descriptor_directory else self._default_descriptor_directory()
        self.server: _ThreadingBridgeServer | None = None
        self.thread: threading.Thread | None = None
        self.descriptor_path: Path | None = None

    @staticmethod
    def _default_descriptor_directory() -> Path:
        base = Path.home() / "Library" / "Caches" if sys.platform == "darwin" else Path(tempfile.gettempdir())
        return base / "CallaTutor"

    def start(self) -> Path:
        if self.server is not None:
            if self.descriptor_path is None:
                raise RuntimeError("bridge server is active without a descriptor")
            return self.descriptor_path

        self.server = _ThreadingBridgeServer(("127.0.0.1", 0), self)
        host, port = self.server.server_address
        self.thread = threading.Thread(target=self.server.serve_forever, name="CallaTutorBlenderBridge", daemon=True)
        self.thread.start()

        self.descriptor_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.descriptor_directory, 0o700)
        self.descriptor_path = self.descriptor_directory / f"blender-{os.getpid()}.json"
        descriptor = {
            "protocol_version": 1,
            "bridge": "blender-tutor-bridge-v1",
            "host": host,
            "port": port,
            "token": self.token,
            "pid": os.getpid(),
            # Data stays untouched: no scene, object, file or asset is ever
            # written. The one thing this bridge may change is which Properties
            # tab is on screen, and it says so rather than hiding behind the
            # older, broader claim.
            "read_only": True,
            "navigates_ui": True,
            # Named here as well as on `ping` so the host can tell an add-on that
            # predates an operation from one that is refusing it, without a round
            # trip and without guessing from an error code.
            "capabilities": sorted(ALLOWED_OPERATIONS),
        }
        file_descriptor = os.open(self.descriptor_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.write(file_descriptor, json.dumps(descriptor, separators=(",", ":")).encode("utf-8"))
        finally:
            os.close(file_descriptor)
        return self.descriptor_path

    def stop(self) -> None:
        if self.server is not None:
            self.server.shutdown()
            self.server.server_close()
            self.server = None
        if self.thread is not None:
            self.thread.join(timeout=1.0)
            self.thread = None
        if self.descriptor_path is not None:
            self.descriptor_path.unlink(missing_ok=True)
            self.descriptor_path = None

    def dispatch_on_blender_thread(self, request: Any) -> dict[str, Any]:
        completed: queue.Queue[tuple[bool, Any]] = queue.Queue(maxsize=1)

        def execute() -> None:
            try:
                completed.put((True, dispatch_request(request, expected_token=self.token, bpy_module=self.bpy_module)))
            except Exception as exc:
                completed.put((False, exc))
            return None

        self.bpy_module.app.timers.register(execute, first_interval=0.0)
        try:
            ok, value = completed.get(timeout=MAIN_THREAD_TIMEOUT_SECONDS)
        except queue.Empty as exc:
            raise TimeoutError("Blender main thread did not process the bridge request before the deadline") from exc
        if ok:
            return value
        raise value
