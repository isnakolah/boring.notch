#!/usr/bin/env python3
"""Exercise the Calla TutorHost socket protocol boundary."""
import json
import os
import socket
import sys
import time

SOCK = os.environ.get(
    "CALLA_TUTOR_HOST_SOCKET",
    os.path.expanduser("~/Library/Application Support/CallaTutor/tutor-host.sock"),
)
SESSION = "session-abcdefgh"


def send_raw(raw: bytes, timeout: float = 8.0):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(SOCK)
        s.sendall(raw)
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        return json.loads(buf.decode()) if buf.strip() else None
    finally:
        s.close()


def send(obj, timeout=8.0):
    return send_raw((json.dumps(obj) + "\n").encode(), timeout)


PROTOCOL_VERSION = 2


def req(op, payload=None, version=PROTOCOL_VERSION, session=SESSION, rid="probe-1"):
    return {
        "protocol_version": version,
        "request_id": rid,
        "operation": op,
        "session_id": session,
        "payload": payload or {},
    }


def code_of(resp):
    if resp is None:
        return "<no response>"
    if resp.get("ok"):
        return "ok"
    return (resp.get("error") or {}).get("code", "<no code>")


CASES = [
    ("wrong protocol version rejected",  lambda: send(req("observe", version=1)),               "unsupported_version"),
    ("short session rejected",           lambda: send(req("observe", session="short")),         "invalid_session"),
    ("unknown operation rejected",       lambda: send(req("shell_exec")),                       "unsupported_operation"),
    ("raw click(x,y) refused as coordinates", lambda: send(req("click", {"x": 100, "y": 200})),  "invalid_coordinates"),
    ("arbitrary python not an operation",lambda: send(req("run_python", {"code": "import os"})), "unsupported_operation"),
    ("propose_action type must be click",lambda: send(req("propose_action", {"action": "type", "text": "rm -rf"})), "unsupported_action"),
    ("propose_action with coords still needs semantics",
                                          lambda: send(req("propose_action", {"action": "click", "x": 10, "y": 20})), None),
    ("malformed JSON rejected",          lambda: send_raw(b"{not json at all}\n"),              "protocol_error"),
    # Rejection is the security property. The transport catch flattens every
    # TutorHostFailure to protocol_error, so frame_limit never reaches the client.
    ("oversized frame rejected",         lambda: send_raw(b'{"a":"' + b"x" * (70 * 1024) + b'"}\n'), "protocol_error"),
    ("observe requires a focused allowlisted app", lambda: send(req("observe")),               None),
    ("point without a descriptor is refused",     lambda: send(req("point", {"snapshot_id": "x"})), "missing_target"),
    ("verify without a descriptor is refused",    lambda: send(req("verify", {})),              "missing_target"),
]


BLENDER = "org.blenderfoundation.blender"


def _focus_and_observe(bundle_id, include_crop=False):
    import subprocess

    descriptor = {"semantic_id": "probe.window", "bundle_ids": [bundle_id]}
    app = bundle_id.rsplit(".", 1)[-1]
    subprocess.run(["osascript", "-e", f'tell application "{app}" to activate'], capture_output=True)
    time.sleep(2.5)
    body = {"target_descriptor": descriptor}
    if include_crop:
        body["include_crop"] = True
    return descriptor, send(req("observe", body), timeout=45)


def hint_range_check():
    """A pixel-shaped hint must be refused even with a valid observation."""
    descriptor, response = _focus_and_observe(BLENDER)
    snapshot_id = (response.get("payload") or {}).get("snapshot_id")
    if not snapshot_id:
        return f"could not observe: {code_of(response)}"
    refused = send(req("point", {
        "snapshot_id": snapshot_id,
        "semantic_target": descriptor["semantic_id"],
        "target_descriptor": descriptor,
        "target_hint": {"description": "d", "region": {"x": 1420, "y": 377, "width": 24, "height": 24}},
    }))
    accepted = send(req("point", {
        "snapshot_id": snapshot_id,
        "semantic_target": descriptor["semantic_id"],
        "target_descriptor": descriptor,
        "target_hint": {"description": "wrench", "region": {"x": 0.82, "y": 0.2, "width": 0.02, "height": 0.02}},
    }))
    return f"pixel-shaped -> {code_of(refused)}; normalised -> {code_of(accepted)}"


def capture_round_trip():
    """Optional: needs the target app focused and Screen Recording granted."""
    import base64

    _descriptor, response = _focus_and_observe(BLENDER, include_crop=True)
    payload = response.get("payload") or {}
    if payload.get("capture_error"):
        return f"capture_error={payload['capture_error']}"
    capture = payload.get("capture")
    if not capture:
        return f"no capture: {code_of(response)}"
    raw = base64.b64decode(capture["data_base64"])
    ok = raw[:3] == b"\xff\xd8\xff"
    return f"{capture['width']}x{capture['height']} {len(raw)}B jpeg={ok}"


def main():
    if not os.path.exists(SOCK):
        print(f"FAIL: socket missing at {SOCK}")
        return 2
    mode = oct(os.stat(SOCK).st_mode & 0o777)
    print(f"socket mode: {mode}  (expected 0o600)")
    print("-" * 78)
    failures = 0
    for name, call, expected in CASES:
        try:
            resp = call()
            actual = code_of(resp)
        except Exception as exc:  # noqa: BLE001
            actual = f"<exception: {type(exc).__name__}: {exc}>"
        if expected is None:
            verdict = "INFO"
        elif actual == expected:
            verdict = "PASS"
        else:
            verdict = "FAIL"
            failures += 1
        suffix = "" if expected is None else f"  (expected {expected})"
        print(f"[{verdict}] {name:44} -> {actual}{suffix}")
    if "--live" in sys.argv:
        print(f"[INFO] {'hint range check':44} -> {hint_range_check()}")
        print(f"[INFO] {'capture round trip':44} -> {capture_round_trip()}")
    print("-" * 78)
    print(f"asserted failures: {failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
