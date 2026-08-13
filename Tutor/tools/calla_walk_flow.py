#!/usr/bin/env python3
"""Walk the Calla teaching flow against the running TutorHost."""
import base64
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tutor_host_probe import send, req  # noqa: E402

BLENDER = "org.blenderfoundation.blender"

# The canonical descriptor exactly as authored in packs/blender/ui/modifiers_tab.yaml.
TARGET = {
    "id": "blender.ui.properties.modifiers_tab",
    "kind": "ui_target",
    "title": "Modifier Properties tab",
    "aliases": ["Modifiers", "wrench icon", "Modifier Properties"],
    "app_versions": ">=5.2 <5.3",
    "source_refs": ["blender-manual"],
    "region": "blender.ui.properties_editor",
    "resolve": {
        "bridge": {"selector": {"editor_type": "PROPERTIES", "context": "MODIFIER"}},
        "accessibility": {
            "candidates": [
                {"role": "AXRadioButton", "label_matcher": {"pattern": "modifier", "case_insensitive": True}},
                {"role": "AXButton", "description_matcher": {"pattern": "modifier", "case_insensitive": True}},
            ]
        },
        "visual": {
            "icon": "wrench",
            "relative_to": "properties_editor.vertical_context_tabs",
            "constraints": ["visible", "enabled"],
        },
    },
    "neighbor_constraints": {"expected": ["object_data", "particles"]},
    "minimum_confidence": {"point": 0.72, "act": 0.92},
    "source_file": "ui/modifiers_tab.yaml",
}


def frontmost():
    result = subprocess.run(
        ["osascript", "-e",
         'tell application "System Events" to get bundle identifier of first application process whose frontmost is true'],
        capture_output=True, text=True)
    return result.stdout.strip()


def focus(app="Blender", bundle_id=BLENDER, timeout=15):
    """`activate` does not always win the focus race, so wait for it."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        subprocess.run(["osascript", "-e", f'tell application "{app}" to activate'], capture_output=True)
        time.sleep(1.2)
        if frontmost() == bundle_id:
            return True
    print(f"   (could not focus {app}; frontmost is {frontmost()})")
    return False


def step(number, title):
    print(f"\n--- {number}. {title} " + "-" * max(0, 56 - len(title)))


def main():
    focus()

    step(1, "observe with capture")
    response = send(req("observe", {"include_capture": True}), timeout=45)
    payload = response.get("payload") or {}
    if not response.get("ok"):
        print("   FAILED:", json.dumps(response.get("error")))
        return 1
    snapshot_id = payload.get("snapshot_id")
    capture = payload.get("capture") or {}
    jpeg = base64.b64decode(capture["base64"]) if capture.get("base64") else b""
    print(f"   snapshot   : {snapshot_id}")
    print(f"   app        : {payload.get('app_bundle_id')} {payload.get('app_version', '')}")
    valid = jpeg[:3] == bytes([0xFF, 0xD8, 0xFF])
    print(f"   capture    : {len(jpeg)} bytes, valid jpeg={valid}, mime={capture.get('mime_type')}")
    print(f"   bound to   : {capture.get('snapshot_id')}")
    print("   -> this JPEG is what would cross the tailnet to Calla")

    step(2, "point using the vision hint Calla would return")
    hint = {"region": {"left": 0.818, "top": 0.196, "width": 0.022, "height": 0.028}}
    response = send(req("point", {
        "target_descriptor": TARGET,
        "snapshot_id": snapshot_id,
        "target_hint": hint,
        "step": "Step 1 of 2",
        "label": "Open the Modifier Properties tab — the wrench icon. The cube stays untouched.",
    }))
    print("   ", json.dumps(response.get("payload") or response.get("error")))

    step(3, "the boundary still holds")
    checks = [
        ("raw click(x,y)", req("click", {"x": 100, "y": 200})),
        ("hint on an action", req("propose_action", {
            "action": "click", "target_descriptor": TARGET, "snapshot_id": snapshot_id,
            "expected_state": {}, "rationale": "open modifiers",
            "target_hint": hint,
        })),
    ]
    for name, request in checks:
        result = send(request)
        error = (result.get("error") or {}).get("code", "ok")
        print(f"   {name:20} -> {error}")

    step(4, "verify from ground truth")
    print("   Click the wrench in Blender, then run: make PYTHON=.venv/bin/python pack-search QUERY=bevel")
    print("   or open the lesson UI:  .venv/bin/python tools/calla_lesson_ui.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
