"""Blender add-on entrypoint for the read-only Calla Tutor bridge."""

bl_info = {
    "name": "Calla Tutor Bridge",
    "author": "Calla Tutor contributors",
    "version": (0, 3, 0),
    "blender": (5, 2, 0),
    "location": "Preferences > Add-ons",
    "description": "Expose bounded read-only Blender state to the local Calla Tutor host",
    "category": "Interface",
}

_runtime = None


def register():
    global _runtime
    import bpy

    from calla_tutor_blender.server import BlenderBridgeRuntime

    if _runtime is None:
        _runtime = BlenderBridgeRuntime(bpy)
        descriptor = _runtime.start()
        print(f"Calla Tutor bridge started; descriptor: {descriptor}")


def unregister():
    global _runtime
    if _runtime is not None:
        _runtime.stop()
        _runtime = None
        print("Calla Tutor bridge stopped")
