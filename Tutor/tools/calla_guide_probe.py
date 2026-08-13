#!/usr/bin/env python3
"""Exercise Calla's screenshot-only teaching path against a running TutorHost.

This walks the same operations the Gateway model calls — observe, guide,
narrate — for any application, not just one with an authored pack. Nothing here
reads the Accessibility tree, and nothing here can click.

    python3 tools/calla_guide_probe.py --bundle-id org.blenderfoundation.blender

Pass --capture-out to write the observed window JPEG somewhere you can look at
it; that image is exactly what would cross the tailnet to the model.
"""
import argparse
import base64
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tutor_host_probe import req, send  # noqa: E402


def frontmost_bundle_id():
    result = subprocess.run(
        ["osascript", "-e",
         'tell application "System Events" to get bundle identifier of first application process whose frontmost is true'],
        capture_output=True, text=True)
    return result.stdout.strip()


def focus(bundle_id, timeout=20):
    """`activate` loses the focus race often enough to be worth waiting out."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        subprocess.run(["osascript", "-e", f'tell application id "{bundle_id}" to activate'],
                       capture_output=True)
        time.sleep(1.0)
        if frontmost_bundle_id() == bundle_id:
            return True
    return False


PLACEMENT_LOG = Path.home() / "Library" / "Logs" / "Calla" / "placement.log"
TIMING_LOG = Path.home() / "Library" / "Logs" / "Calla" / "step-timing.log"


def pack_ui_targets(pack):
    """Every authored control, as the host would be handed it."""
    try:
        import yaml
    except ImportError:
        return []
    entities = []
    for path in sorted((pack / "ui").glob("*.yaml")):
        loaded = yaml.safe_load(path.read_text(encoding="utf-8"))
        for entity in (loaded.get("entities", []) if isinstance(loaded, dict) and "entities" in loaded
                       else [loaded] if isinstance(loaded, dict) else []):
            if isinstance(entity, dict) and entity.get("id"):
                entity.setdefault("kind", "ui_target")
                entity.pop("region", None)
                entities.append(entity)
    return entities


def placements_since(offset):
    """New `place` lines the host wrote, keyed by semantic id."""
    if not TIMING_LOG.exists():
        return {}, offset
    size = TIMING_LOG.stat().st_size
    if size < offset:
        offset = 0
    with TIMING_LOG.open("r", encoding="utf-8", errors="replace") as handle:
        handle.seek(offset)
        text = handle.read()
        offset = handle.tell()
    found = {}
    for line in text.splitlines():
        match = re.search(r"place (\S+) conf=(\S+) rect=(-?[\d.]+),(-?[\d.]+),([\d.]+)x([\d.]+) via=(\S+)", line)
        if match:
            found[match.group(1)] = {
                "confidence": float(match.group(2)),
                "rect": tuple(float(match.group(index)) for index in (3, 4, 5, 6)),
                "via": match.group(7),
            }
    return found, offset


def step(number, title):
    print(f"\n--- {number}. {title} " + "-" * max(0, 54 - len(title)))


def show(response):
    body = response.get("payload") if response.get("ok") else response.get("error")
    print("   ", json.dumps(body))
    return response.get("ok", False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", default="org.blenderfoundation.blender")
    parser.add_argument("--capture-out", type=Path,
                        help="Write the observed window JPEG here for inspection")
    parser.add_argument("--region", default="0.82,0.20,0.03,0.03",
                        help="left,top,width,height normalized to the observed window")
    parser.add_argument("--no-focus", action="store_true",
                        help="Use whatever is already focused")
    parser.add_argument("--pack", type=Path, default=Path(__file__).resolve().parents[1] / "packs" / "blender",
                        help="Pack whose authored controls should be resolved and measured")
    parser.add_argument("--skip-placement", action="store_true",
                        help="Skip the per-control placement pass")
    arguments = parser.parse_args()

    if not arguments.no_focus and not focus(arguments.bundle_id):
        print(f"Could not focus {arguments.bundle_id}; frontmost is {frontmost_bundle_id()}")
        return 2

    allowed = {"allowed_bundle_ids": [arguments.bundle_id]}

    step(1, "observe the focused window, with a capture")
    response = send(req("observe", {**allowed, "include_capture": True}), timeout=60)
    if not response.get("ok"):
        show(response)
        return 1
    payload = response["payload"]
    snapshot_id = payload["snapshot_id"]
    capture = payload.get("capture") or {}
    jpeg = base64.b64decode(capture["base64"]) if capture.get("base64") else b""
    print(f"   snapshot : {snapshot_id}")
    print(f"   app      : {payload.get('app_bundle_id')} {payload.get('app_version', '')}")
    print(f"   capture  : {len(jpeg)} bytes, jpeg={jpeg[:3] == bytes([0xFF, 0xD8, 0xFF])}")
    if arguments.capture_out and jpeg:
        arguments.capture_out.write_bytes(jpeg)
        print(f"   wrote    : {arguments.capture_out}")

    left, top, width, height = (float(part) for part in arguments.region.split(","))
    step(2, "guide: point at a region the model read off that capture")
    ok = show(send(req("guide", {
        **allowed,
        "snapshot_id": snapshot_id,
        "region": {"left": left, "top": top, "width": width, "height": height},
        "step": "Step 1 of 2",
        "text": "This is the control the lesson is about. Nothing was clicked.",
        "status": "Calla — teaching",
    }), timeout=30))
    if not ok:
        return 1

    step(3, "plan: a route the Mac can advance without the model")
    # A planned step carrying its own region and words is what lets the host
    # point at the next thing locally, with no Gateway turn at all.
    planned = send(req("plan", {
        "snapshot_id": snapshot_id,
        "index": 0,
        "steps": [
            {"title": "Look here first",
             "region": {"left": left, "top": top, "width": width, "height": height},
             "text": "This step was planned, not guided."},
            {"title": "Then here",
             "region": {"left": min(left + 0.05, 0.9), "top": top,
                        "width": width, "height": height},
             "text": "The Mac can point at this one on its own."},
        ],
    }), timeout=30)
    show(planned)
    if planned.get("ok"):
        advanceable = planned["payload"].get("locally_advanceable")
        print(f"   steps the Mac can advance itself: {advanceable}")

    step(4, "narrate: change the tooltip without moving the cursor")
    time.sleep(2.5)
    show(send(req("narrate", {
        "step": "Step 2 of 2",
        "text": "Same cursor, new words. This is how a lesson keeps talking.",
        "status": "Calla — narrating",
        "thinking": True,
    }), timeout=30))

    if not arguments.skip_placement:
        step(5, "where each authored control actually resolves")
        # This is the accuracy gate. A receipt says which evidence answered but
        # not where the pointer went, so the host writes the rectangle to its own
        # local log and it is read back here. A control resolved by the
        # application's own bridge should be a tight rectangle on the thing; one
        # that fell through to a model hint or to nothing is visible as such.
        offset = TIMING_LOG.stat().st_size if TIMING_LOG.exists() else 0
        targets = pack_ui_targets(arguments.pack)
        if not targets:
            print("   no authored controls found (is PyYAML installed?)")
        for entity in targets:
            fresh = send(req("observe", {**allowed, "include_capture": False}), timeout=30)
            if not fresh.get("ok"):
                print(f"   {entity['id']:52} observe failed")
                continue
            result = send(req("point", {
                **allowed,
                "snapshot_id": fresh["payload"]["snapshot_id"],
                "target_descriptor": entity,
                "label": entity.get("title", ""),
                "step": "placement probe",
            }), timeout=30)
            if not result.get("ok"):
                code = (result.get("error") or {}).get("code", "?")
                print(f"   {entity['id']:52} {code}")
                continue
            found, offset = placements_since(offset)
            record = found.get(entity["id"])
            if record:
                x, y, width, height = record["rect"]
                print(f"   {entity['id']:52} {width:5.0f}x{height:<5.0f} at {x:5.0f},{y:<5.0f} "
                      f"conf={record['confidence']:.2f} via={record['via']}")
            else:
                receipt = result["payload"].get("resolution_receipt", {})
                print(f"   {entity['id']:52} resolved, no placement line: {json.dumps(receipt)}")
        print(f"   full detail: {TIMING_LOG}")

    step(6, "the boundary still holds")
    normalized = {"left": 0.5, "top": 0.5, "width": 0.1, "height": 0.1}
    pixels = {"left": 1420, "top": 377, "width": 24, "height": 24}
    checks = [
        ("pixel region on guide", req("guide", {
            **allowed, "snapshot_id": snapshot_id, "region": pixels, "text": "x"})),
        ("raw click(x,y)", req("click", {"x": 100, "y": 200})),
        ("region on an action", req("propose_action", {
            "action": "click", "snapshot_id": snapshot_id, "region": normalized,
            "expected_state": {}, "rationale": "nope"})),
        # A plan may carry one region per step and nothing else. These are the
        # ways that exemption could have been wider than intended.
        ("pixel region on a plan step", req("plan", {
            "snapshot_id": snapshot_id,
            "steps": [{"title": "a", "region": pixels, "text": "x"}, "b"]})),
        ("region beside the steps", req("plan", {
            "snapshot_id": snapshot_id, "region": normalized, "steps": ["a", "b"]})),
        ("region on a verify", req("verify", {
            "snapshot_id": snapshot_id, "region": normalized,
            "target_descriptor": {}, "detector_descriptor": {}})),
    ]
    for name, request in checks:
        result = send(request, timeout=20)
        print(f"   {name:24} -> {(result.get('error') or {}).get('code', 'ok')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
