"""Generate deterministic Blender Simple Lamp starter/proof scenes."""
from pathlib import Path
import bpy

root = Path(__file__).resolve().parents[1] / "packs" / "blender" / "assets"
root.mkdir(parents=True, exist_ok=True)
for name, stage in [("lamp-base", 0), ("lamp-stem", 1), ("lamp-shade", 2), ("lamp-proportion", 3), ("lamp-finish", 4)]:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.mesh.primitive_cylinder_add(vertices=32, radius=2, depth=.35, location=(0, 0, .175))
    bpy.context.object.name = "Lamp Base"
    bpy.ops.wm.save_as_mainfile(filepath=str(root / f"{name}-starter.blend"))
    if stage >= 1:
        bpy.ops.mesh.primitive_cylinder_add(vertices=24, radius=.22, depth=4, location=(0, 0, 2.15))
        bpy.context.object.name = "Lamp Stem"
    if stage >= 2:
        bpy.ops.mesh.primitive_cone_add(vertices=32, radius1=1.55, radius2=.8, depth=1.5, location=(0, 0, 4.9))
        bpy.context.object.name = "Lamp Shade"
    if stage >= 4:
        for obj in bpy.context.scene.objects:
            if obj.type == "MESH":
                obj.modifiers.new("Finish Bevel", "BEVEL").width = .08
    bpy.ops.wm.save_as_mainfile(filepath=str(root / f"{name}-proof.blend"))
