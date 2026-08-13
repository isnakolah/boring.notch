from __future__ import annotations

import json
import socket
import stat
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace


BRIDGE_ROOT = Path(__file__).resolve().parents[1]
import sys

sys.path.insert(0, str(BRIDGE_ROOT))

from calla_tutor_blender.observer import observe_layout, observe_state, property_contexts, set_property_context
from calla_tutor_blender.protocol import BridgeProtocolError, dispatch_request
from calla_tutor_blender.server import BlenderBridgeRuntime


class ImmediateTimers:
    def register(self, callback, first_interval=0.0):
        self.first_interval = first_interval
        return callback()


class FakeObject:
    def __init__(self, name: str, object_type: str, modifiers=()):
        self.name = name
        self.type = object_type
        self.modifiers = list(modifiers)
        self.location = [1.0, 2.0, 3.0]
        self.rotation_euler = [0.0, 0.25, 0.5]
        self.scale = [1.0, 1.0, 1.0]
        self.data = SimpleNamespace(vertices=range(8), edges=range(12), polygons=range(6))

    def select_get(self):
        return True

    def visible_get(self):
        return True


def region(region_type: str, x: int, y: int, width: int, height: int):
    return SimpleNamespace(type=region_type, x=x, y=y, width=width, height=height)


def fake_bpy():
    bevel = SimpleNamespace(name="Bevel", type="BEVEL", show_viewport=True, show_render=True)
    cube = FakeObject("Cube", "MESH", [bevel])
    class FakeSpace:
        """A Properties space that refuses the tabs a mesh does not show."""

        available = ("OBJECT", "MODIFIER", "DATA", "MATERIAL")

        def __init__(self):
            self._context = "MODIFIER"
            items = [SimpleNamespace(identifier=name) for name in
                     ("TOOL", "OBJECT", "MODIFIER", "DATA", "MATERIAL", "PHYSICS")]
            self.bl_rna = SimpleNamespace(properties={"context": SimpleNamespace(enum_items=items)})

        @property
        def context(self):
            return self._context

        @context.setter
        def context(self, value):
            if value not in self.available:
                raise TypeError("context not available for this object")
            self._context = value

    properties_space = FakeSpace()
    # A 1520x900 window: the viewport on the left, the Properties editor down the
    # right edge with its context tabs in a NAV_BAR strip.
    properties_area = SimpleNamespace(
        type="PROPERTIES", x=1200, y=0, width=320, height=900, ui_type="PROPERTIES",
        spaces=SimpleNamespace(active=properties_space), tag_redraw=lambda: None,
        regions=[
            region("HEADER", 1200, 874, 320, 26),
            region("NAV_BAR", 1200, 0, 48, 874),
            region("WINDOW", 1248, 0, 272, 874),
        ],
    )
    viewport_area = SimpleNamespace(
        type="VIEW_3D", x=0, y=0, width=1200, height=900, ui_type="VIEW_3D", spaces=None,
        regions=[
            region("HEADER", 0, 874, 1200, 26),
            region("TOOLS", 0, 0, 60, 874),
            region("WINDOW", 0, 0, 1200, 874),
        ],
    )
    scene = SimpleNamespace(name="Scene", objects=[cube])
    screen = SimpleNamespace(areas=[viewport_area, properties_area])
    context = SimpleNamespace(
        scene=scene,
        mode="OBJECT",
        active_object=cube,
        view_layer=SimpleNamespace(objects=SimpleNamespace(active=cube)),
        screen=screen,
        window=SimpleNamespace(width=1520, height=900, screen=screen),
        preferences=SimpleNamespace(system=SimpleNamespace(ui_scale=1.0, pixel_size=2.0)),
    )
    return SimpleNamespace(
        context=context,
        app=SimpleNamespace(version=(5, 2, 0), version_string="5.2.0", timers=ImmediateTimers()),
    )


def request(token: str, operation: str, payload=None):
    return {
        "protocol_version": 1,
        "request_id": "request-1234",
        "token": token,
        "operation": operation,
        "payload": payload or {},
    }


class BlenderBridgeTests(unittest.TestCase):
    def test_observer_returns_bounded_semantic_state(self):
        state = observe_state(fake_bpy())
        self.assertEqual(state["blender"]["version_string"], "5.2.0")
        self.assertEqual(state["mode"], "OBJECT")
        self.assertEqual(state["active_object"]["type"], "MESH")
        self.assertEqual(state["active_object"]["modifiers"][0]["type"], "BEVEL")
        self.assertEqual(state["properties_contexts"], ["MODIFIER"])

    def test_layout_reports_area_and_region_rectangles(self):
        layout = observe_layout(fake_bpy())
        self.assertEqual(layout["window"], {"width": 1520, "height": 900})
        properties = next(area for area in layout["areas"] if area["type"] == "PROPERTIES")
        # The right edge of the Properties editor is the right edge of the
        # window: this is the invariant that proves x is in window space and not
        # in the area's own.
        self.assertEqual(properties["x"] + properties["width"], layout["window"]["width"])
        self.assertEqual(properties["context"], "MODIFIER")
        nav_bar = next(region for region in properties["regions"] if region["type"] == "NAV_BAR")
        self.assertEqual(nav_bar["x"], properties["x"])
        self.assertLess(nav_bar["width"], properties["width"])
        self.assertFalse(layout["areas_truncated"])

    def test_layout_drops_areas_and_regions_without_a_rectangle(self):
        bpy_module = fake_bpy()
        collapsed = SimpleNamespace(type="OUTLINER", x=0, y=0, width=0, height=0, spaces=None, regions=[])
        bpy_module.context.screen.areas.append(collapsed)
        properties = bpy_module.context.screen.areas[1]
        properties.regions.append(SimpleNamespace(type="UI", x=0, y=0, width=0, height=40))
        layout = observe_layout(bpy_module)
        self.assertNotIn("OUTLINER", [area["type"] for area in layout["areas"]])
        emitted = next(area for area in layout["areas"] if area["type"] == "PROPERTIES")
        self.assertNotIn("UI", [region["type"] for region in emitted["regions"]])

    def test_layout_is_reachable_over_the_bridge(self):
        token = "t" * 32
        response = dispatch_request(request(token, "observe_layout"), expected_token=token, bpy_module=fake_bpy())
        self.assertTrue(response["ok"])
        self.assertEqual(response["result"]["window"]["width"], 1520)

    def test_layout_rejects_a_payload(self):
        token = "t" * 32
        with self.assertRaisesRegex(BridgeProtocolError, "no payload fields"):
            dispatch_request(
                request(token, "observe_layout", {"area": "PROPERTIES"}),
                expected_token=token,
                bpy_module=fake_bpy(),
            )

    def test_properties_tabs_can_be_listed_and_shown(self):
        bpy_module = fake_bpy()
        self.assertIn("MODIFIER", property_contexts(bpy_module))
        result = set_property_context(bpy_module, "DATA")
        self.assertEqual(result, {"context": "DATA", "previous": "MODIFIER"})
        # Blender refuses a tab this object does not show, which is how the host
        # discovers which rows are on screen at all.
        with self.assertRaisesRegex(ValueError, "not available"):
            set_property_context(bpy_module, "PHYSICS")
        # And a name Blender has never heard of never reaches Blender.
        with self.assertRaisesRegex(ValueError, "unknown properties context"):
            set_property_context(bpy_module, "ARBITRARY")

    def test_showing_a_tab_is_the_only_write_and_is_bounded(self):
        token = "t" * 32
        bpy_module = fake_bpy()
        response = dispatch_request(request(token, "set_property_context", {"context": "OBJECT"}),
                                    expected_token=token, bpy_module=bpy_module)
        self.assertTrue(response["ok"])
        self.assertEqual(response["result"]["context"], "OBJECT")
        # Anything beyond the one field is refused rather than ignored.
        with self.assertRaisesRegex(BridgeProtocolError, "accepts a context only"):
            dispatch_request(request(token, "set_property_context", {"context": "OBJECT", "scene": "x"}),
                             expected_token=token, bpy_module=fake_bpy())
        # Still no way to run anything.
        with self.assertRaisesRegex(BridgeProtocolError, "not allowlisted"):
            dispatch_request(request(token, "set_scene_property", {"path": "x"}),
                             expected_token=token, bpy_module=fake_bpy())

    def test_protocol_denies_wrong_token(self):
        with self.assertRaisesRegex(BridgeProtocolError, "invalid bridge session token") as raised:
            dispatch_request(request("x" * 32, "ping"), expected_token="y" * 32, bpy_module=fake_bpy())
        self.assertEqual(raised.exception.code, "UNAUTHORIZED")

    def test_protocol_denies_arbitrary_code(self):
        token = "t" * 32
        with self.assertRaisesRegex(BridgeProtocolError, "not allowlisted") as raised:
            dispatch_request(
                request(token, "execute_code", {"code": "import os"}),
                expected_token=token,
                bpy_module=fake_bpy(),
            )
        self.assertEqual(raised.exception.code, "OPERATION_DENIED")

    def test_loopback_server_uses_owner_only_descriptor_and_main_thread_dispatch(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            runtime = BlenderBridgeRuntime(fake_bpy(), descriptor_directory=temporary_directory)
            descriptor_path = runtime.start()
            try:
                descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
                mode = stat.S_IMODE(descriptor_path.stat().st_mode)
                self.assertEqual(mode, 0o600)
                self.assertEqual(descriptor["host"], "127.0.0.1")
                self.assertTrue(descriptor["read_only"])
                self.assertIn("observe_layout", descriptor["capabilities"])
                self.assertIn("set_property_context", descriptor["capabilities"])
                # The descriptor says what it may change rather than only what it
                # may not: data is untouched, one editor's tab is not.
                self.assertTrue(descriptor["navigates_ui"])

                with socket.create_connection((descriptor["host"], descriptor["port"]), timeout=2.0) as client:
                    payload = json.dumps(request(descriptor["token"], "observe_state")).encode("utf-8") + b"\n"
                    client.sendall(payload)
                    response = b""
                    while not response.endswith(b"\n"):
                        response += client.recv(65536)
                decoded = json.loads(response)
                self.assertTrue(decoded["ok"])
                self.assertEqual(decoded["result"]["properties_contexts"], ["MODIFIER"])
            finally:
                runtime.stop()
            self.assertFalse(descriptor_path.exists())


if __name__ == "__main__":
    unittest.main()
