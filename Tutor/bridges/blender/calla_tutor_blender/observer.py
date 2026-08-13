from __future__ import annotations

from typing import Any


MAX_OBJECTS = 100
MAX_MODIFIERS = 50
MAX_AREAS = 32
MAX_REGIONS = 16


def _vector(value: Any, length: int) -> list[float] | None:
    if value is None:
        return None
    try:
        return [round(float(value[index]), 6) for index in range(length)]
    except (IndexError, KeyError, TypeError, ValueError):
        axes = ("x", "y", "z", "w")[:length]
        try:
            return [round(float(getattr(value, axis)), 6) for axis in axes]
        except (AttributeError, TypeError, ValueError):
            return None


def _modifier_summary(modifier: Any) -> dict[str, Any]:
    return {
        "name": str(getattr(modifier, "name", "")),
        "type": str(getattr(modifier, "type", "UNKNOWN")),
        "show_viewport": bool(getattr(modifier, "show_viewport", True)),
        "show_render": bool(getattr(modifier, "show_render", True)),
    }


def _object_summary(obj: Any, *, detailed: bool) -> dict[str, Any]:
    summary: dict[str, Any] = {
        "name": str(getattr(obj, "name", "")),
        "type": str(getattr(obj, "type", "UNKNOWN")),
        "selected": bool(obj.select_get()) if callable(getattr(obj, "select_get", None)) else False,
        "visible": bool(obj.visible_get()) if callable(getattr(obj, "visible_get", None)) else True,
    }
    if detailed:
        summary.update(
            {
                "location": _vector(getattr(obj, "location", None), 3),
                "rotation_euler": _vector(getattr(obj, "rotation_euler", None), 3),
                "scale": _vector(getattr(obj, "scale", None), 3),
                "modifiers": [
                    _modifier_summary(modifier)
                    for modifier in list(getattr(obj, "modifiers", ()))[:MAX_MODIFIERS]
                ],
            }
        )
        mesh = getattr(obj, "data", None)
        if summary["type"] == "MESH" and mesh is not None:
            summary["mesh"] = {
                "vertices": len(getattr(mesh, "vertices", ())),
                "edges": len(getattr(mesh, "edges", ())),
                "polygons": len(getattr(mesh, "polygons", ())),
            }
    return summary


def _screen_areas(context: Any) -> tuple[list[dict[str, Any]], list[str]]:
    screen = getattr(context, "screen", None)
    areas: list[dict[str, Any]] = []
    properties_contexts: list[str] = []
    for area in list(getattr(screen, "areas", ()))[:MAX_AREAS]:
        area_type = str(getattr(area, "type", "UNKNOWN"))
        entry: dict[str, Any] = {
            "type": area_type,
            "width": int(getattr(area, "width", 0)),
            "height": int(getattr(area, "height", 0)),
        }
        ui_type = getattr(area, "ui_type", None)
        if ui_type:
            entry["ui_type"] = str(ui_type)
        if area_type == "PROPERTIES":
            spaces = getattr(area, "spaces", None)
            active_space = getattr(spaces, "active", None)
            current_context = getattr(active_space, "context", None)
            if current_context:
                current_context = str(current_context)
                entry["context"] = current_context
                properties_contexts.append(current_context)
        areas.append(entry)
    return areas, sorted(set(properties_contexts))


def _rect(value: Any) -> dict[str, int] | None:
    """A Blender rectangle in window pixels, or None if it is not one."""

    try:
        rect = {
            "x": int(getattr(value, "x")),
            "y": int(getattr(value, "y")),
            "width": int(getattr(value, "width")),
            "height": int(getattr(value, "height")),
        }
    except (AttributeError, TypeError, ValueError):
        return None
    if rect["width"] <= 0 or rect["height"] <= 0:
        return None
    return rect


def _area_layout(area: Any) -> dict[str, Any] | None:
    rect = _rect(area)
    if rect is None:
        return None
    entry: dict[str, Any] = dict(rect)
    entry["type"] = str(getattr(area, "type", "UNKNOWN"))
    ui_type = getattr(area, "ui_type", None)
    if ui_type:
        entry["ui_type"] = str(ui_type)
    active_space = getattr(getattr(area, "spaces", None), "active", None)
    current_context = getattr(active_space, "context", None)
    if current_context:
        entry["context"] = str(current_context)
    regions: list[dict[str, Any]] = []
    for region in list(getattr(area, "regions", ()))[:MAX_REGIONS]:
        region_rect = _rect(region)
        if region_rect is None:
            continue
        region_rect["type"] = str(getattr(region, "type", "UNKNOWN"))
        regions.append(region_rect)
    entry["regions"] = regions
    return entry


def observe_layout(bpy_module: Any) -> dict[str, Any]:
    """Where Blender has drawn its editors, in window pixels.

    Geometry only, and only Blender's own idea of it. Blender draws its entire
    interface itself, so macOS Accessibility sees one opaque window and anything
    pointing at a panel inside it is guessing. Blender knows exactly where it put
    each editor; this hands that over so the guess can stop.

    The origin is the window's bottom-left and the unit is a framebuffer pixel,
    which is what `bpy` reports. Neither is converted here: the caller knows the
    window's rectangle in screen points and can derive the scale from the two
    widths, which is the only way to be right on a Retina display, on an external
    display, and after the window is moved.
    """

    context = bpy_module.context
    window = getattr(context, "window", None)
    screen = getattr(window, "screen", None) or getattr(context, "screen", None)

    areas: list[dict[str, Any]] = []
    for area in list(getattr(screen, "areas", ()))[:MAX_AREAS]:
        entry = _area_layout(area)
        if entry is not None:
            areas.append(entry)

    system = getattr(getattr(context, "preferences", None), "system", None)
    pixel_size = float(getattr(system, "pixel_size", 1.0) or 1.0)
    window_width = int(getattr(window, "width", 0) or 0)
    window_height = int(getattr(window, "height", 0) or 0)

    return {
        "bridge_protocol_version": 1,
        # `window.width`/`height` and the area rectangles are not in the same
        # unit, which is the sort of thing that produces a cursor exactly twice
        # as far from the origin as it should be. On a Retina display the window
        # is reported at 1710x1041 while its areas run to 3416x2029 — the window
        # in points, the areas in framebuffer pixels.
        #
        # `framebuffer` is the one the areas are measured in, stated outright, so
        # the host converts against the right number instead of inferring which
        # of two plausible ones was meant.
        "window": {"width": window_width, "height": window_height},
        "framebuffer": {
            "width": int(round(window_width * pixel_size)),
            "height": int(round(window_height * pixel_size)),
        },
        "ui_scale": round(float(getattr(system, "ui_scale", 1.0) or 1.0), 4),
        "pixel_size": round(pixel_size, 4),
        "areas": areas,
        "areas_truncated": len(list(getattr(screen, "areas", ()))) > MAX_AREAS,
    }


def observe_state(bpy_module: Any) -> dict[str, Any]:
    """Return a bounded, JSON-safe snapshot without mutating Blender state."""

    context = bpy_module.context
    scene = context.scene
    objects = list(getattr(scene, "objects", ()))
    active_object = getattr(context, "active_object", None)
    if active_object is None:
        view_layer = getattr(context, "view_layer", None)
        active_object = getattr(getattr(view_layer, "objects", None), "active", None)

    areas, properties_contexts = _screen_areas(context)
    app = getattr(bpy_module, "app", None)
    version = tuple(getattr(app, "version", (0, 0, 0)))
    version_string = str(getattr(app, "version_string", ".".join(str(part) for part in version)))

    return {
        "bridge_protocol_version": 1,
        "blender": {
            "version": list(version),
            "version_string": version_string,
        },
        "scene": {
            "name": str(getattr(scene, "name", "")),
            "object_count": len(objects),
            "objects_truncated": len(objects) > MAX_OBJECTS,
        },
        "mode": str(getattr(context, "mode", "UNKNOWN")),
        "active_object": _object_summary(active_object, detailed=True) if active_object is not None else None,
        "objects": [_object_summary(obj, detailed=False) for obj in objects[:MAX_OBJECTS]],
        "areas": areas,
        "properties_contexts": properties_contexts,
    }


def _properties_space(bpy_module):
    """The Properties editor's active space, or None."""

    screen = getattr(getattr(bpy_module.context, "window", None), "screen", None) or getattr(bpy_module.context, "screen", None)
    for area in list(getattr(screen, "areas", ()))[:MAX_AREAS]:
        if str(getattr(area, "type", "")) == "PROPERTIES":
            space = getattr(getattr(area, "spaces", None), "active", None)
            if space is not None:
                return area, space
    return None, None


def property_contexts(bpy_module) -> list[str]:
    """Every context the Properties editor knows the name of."""

    _area, space = _properties_space(bpy_module)
    if space is None:
        return []
    try:
        return [str(item.identifier) for item in space.bl_rna.properties["context"].enum_items]
    except (AttributeError, KeyError, TypeError):
        return []


def set_property_context(bpy_module, requested: str) -> dict:
    """Show one Properties tab, so the host can see where its button is.

    The single write in an otherwise read-only bridge, and deliberately the
    smallest one that answers the question. Blender publishes where it drew the
    tab *strip* and not where it drew any tab in it, and the only way to learn
    which row is which is to watch the highlight move — which means asking the
    highlight to move.

    It is bounded to this one enum on this one editor. It cannot touch the
    scene, an object, a file, or anything the learner has made: the worst it can
    do is show a different tab, which the caller then puts back.
    """

    area, space = _properties_space(bpy_module)
    if space is None:
        raise ValueError("no Properties editor is open")
    known = property_contexts(bpy_module)
    if requested not in known:
        raise ValueError("unknown properties context")
    previous = str(getattr(space, "context", ""))
    try:
        space.context = requested
    except TypeError as error:
        # Blender refuses a tab that does not apply to the active object, which
        # is exactly how the host discovers which tabs are on screen.
        raise ValueError("properties context is not available") from error
    if area is not None and callable(getattr(area, "tag_redraw", None)):
        area.tag_redraw()
    return {"context": str(getattr(space, "context", "")), "previous": previous}
