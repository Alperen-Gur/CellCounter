"""Structural native-workspace conversion; never reads pixels or invents masks.

The caller retains the exact original JSON before committing the converted
metadata and invokes the shared TypeScript validator. Raster sources always
remain unresolved until explicitly bound to canonical acquired image planes.
"""
from __future__ import annotations

import copy
import math


def _fail(message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError("native-workspace-conversion", message, details)


def _object(value, label):
    if not isinstance(value, dict):
        _fail(label + " must be an object.")
    return value


def _array(value, label, maximum=100000):
    if not isinstance(value, list) or len(value) > maximum:
        _fail(label + " must be a bounded array.")
    return value


def _string(value, label, maximum=4096):
    if not isinstance(value, str) or not value or len(value) > maximum:
        _fail(label + " must be a bounded nonempty string.")
    return value


def _number(value, label):
    if type(value) not in (int, float) or not math.isfinite(value):
        _fail(label + " must be finite.")
    return value


def _integer(value, label, minimum=0):
    if type(value) is not int or value < minimum:
        _fail(label + " must be an integer of at least " + str(minimum) + ".")
    return value


def _budget(value):
    stack = [(value, 0)]
    count = 0
    while stack:
        item, depth = stack.pop()
        count += 1
        if count > 1_000_000 or depth > 32:
            _fail("The native workspace exceeds the structural conversion budget.")
        if isinstance(item, dict):
            for key, child in item.items():
                if not isinstance(key, str) or key in ("__proto__", "constructor", "prototype"):
                    _fail("The native workspace contains an unsupported object key.")
                stack.append((child, depth + 1))
        elif isinstance(item, list):
            stack.extend((child, depth + 1) for child in item)
        elif type(item) in (int, float) and not math.isfinite(item):
            _fail("Native workspace numbers must be finite.")
        if len(stack) + count > 1_000_000:
            _fail("The native workspace exceeds the structural conversion budget.")


def _uuid_map(value, label):
    # Swift Codable dictionaries with UUID keys use an alternating key/value
    # array. Accept explicit object encoding too, but never drop duplicate keys.
    if isinstance(value, dict):
        return copy.deepcopy(value)
    rows = _array(value, label, 200000)
    if len(rows) % 2:
        _fail(label + " has an incomplete UUID-key/value pair.")
    result = {}
    for index in range(0, len(rows), 2):
        key = _string(rows[index], label + " key")
        if key in result:
            _fail(label + " repeats a UUID key.")
        result[key] = copy.deepcopy(rows[index + 1])
    return result


def _position(value):
    value = _object(value, "Native position")
    if set(value) - {"indices"}:
        _fail("The native position contains unsupported fields.")
    result = _uuid_map(value.get("indices", []), "Native axis positions")
    for key, number in result.items():
        _string(key, "Axis ID")
        _integer(number, "Axis index")
    return result


def _variant(value, label, supported):
    value = _object(value, label)
    if len(value) != 1:
        _fail(label + " must contain exactly one native enum case.")
    name, body = next(iter(value.items()))
    if name not in supported:
        _fail("Unsupported native " + label.lower() + " case: " + name)
    return name, _object(body, label + " payload")


def _coordinate(value):
    value = _object(value, "Coordinate")
    result = {key: _number(value.get(key), "Coordinate " + key) for key in ("x", "y")}
    if value.get("z") is not None:
        result["z"] = _number(value["z"], "Coordinate z")
    return result


def _optional_fields(value, names):
    return {key: copy.deepcopy(value[key]) for key in names if value.get(key) is not None}


def _positioned_geometry(value, kind):
    value = _object(value, "Native " + kind)
    result = {"id": _string(value.get("id"), kind + " ID"), "position": _position(value.get("position", {"indices": []}))}
    result.update(_optional_fields(value, ("label", "features")))
    if kind == "point":
        result["coordinate"] = _coordinate(value.get("coordinate"))
    else:
        result["kind"] = _string(value.get("kind"), "Shape kind")
        result["vertices"] = [_coordinate(point) for point in _array(value.get("vertices"), "Shape vertices", 10000)]
    return result


def _paint(value):
    value = _object(value, "Native paint document")
    result = {"width": _integer(value.get("width"), "Paint width", 1), "height": _integer(value.get("height"), "Paint height", 1),
              "classes": copy.deepcopy(_array(value.get("classes"), "Paint classes", 1024)), "strokes": []}
    for stroke in _array(value.get("strokes", []), "Paint strokes", 10000):
        stroke = _object(stroke, "Native paint stroke")
        result["strokes"].append({"id": _string(stroke.get("id"), "Stroke ID"), "classValue": _integer(stroke.get("classValue"), "Semantic class"),
            "radius": _number(stroke.get("radiusPx"), "Brush radius"), "points": [_coordinate(point) for point in _array(stroke.get("points"), "Stroke points", 4096)],
            "position": _position(stroke.get("position", {"indices": []})), "erases": stroke.get("erases", False)})
    return result


def _workflow(value):
    value = _object(value, "Native workflow")
    result = {key: _string(value.get(key), "Workflow " + key) for key in ("id", "name", "createdAt")}
    result["steps"] = []
    mappings = {"setLayerVisibility": ("visibility", {"id": "layerID", "visible": "visible"}),
                "setLayerOpacity": ("opacity", {"id": "layerID", "opacity": "opacity"}),
                "translateLayer": ("translate", {"id": "layerID", "x": "x", "y": "y"}),
                "selectAxis": ("position", {"axisID": "axisID", "index": "index"}),
                "register": ("register", {"referenceID": "referenceID", "movingID": "movingID", "maxShift": "maxShift"}),
                "stitch": ("stitch", {"layerIDs": "layerIDs", "columns": "columns", "overlap": "overlap", "outputName": "outputName"})}
    for raw in _array(value.get("steps"), "Workflow steps", 1024):
        name, body = _variant(raw, "Workflow step", mappings)
        translated, fields = mappings[name]
        if set(body) != set(fields):
            _fail("Native workflow step fields do not match the supported case: " + name)
        result["steps"].append({"type": translated, **{target: copy.deepcopy(body[source]) for source, target in fields.items()}})
    return result


def _animation(value):
    value = _object(value, "Native animation")
    result = {key: _string(value.get(key), "Animation " + key) for key in ("id", "name", "easing")}
    result["framesPerSecond"] = _integer(value.get("framesPerSecond"), "Animation frame rate", 1)
    result["keyframes"] = []
    for frame in _array(value.get("keyframes"), "Animation keyframes", 3600):
        frame = _object(frame, "Native keyframe")
        result["keyframes"].append({"id": _string(frame.get("id"), "Keyframe ID"), "timeSeconds": _number(frame.get("timeSeconds"), "Keyframe time"),
            "zoom": _number(frame.get("zoom", 1), "Keyframe zoom"), "center": _coordinate(frame.get("center", {"x": .5, "y": .5})),
            "position": _position(frame.get("position", {"indices": []})), "visibleLayerIDs": copy.deepcopy(_array(frame.get("visibleLayerIDs", []), "Visible layers", 256))})
    return result


def convert_native_workspace(value):
    """Convert metadata only; preserve original bytes and validate in caller."""
    _budget(value)
    value = _object(value, "Native workspace")
    if value.get("schemaVersion") != 1:
        _fail("Only saved native workspace schema version 1 is supported.")
    result = {key: _string(value.get(key), "Workspace " + key) for key in ("id", "name", "createdAt", "modifiedAt")}
    result.update({"schemaVersion": 1, "axes": [], "layers": [], "position": _position(value.get("position", {"indices": []})),
                   "lineage": copy.deepcopy(value.get("lineage", {"nodes": [], "edges": []})), "paintDocuments": {}, "workflows": [], "animationPlans": []})
    physical_units = {"m", "mm", "cm", "um", "µm", "μm", "nm", "meter", "metre", "millimeter", "millimetre", "micrometer", "micrometre", "nanometer", "nanometre"}
    time_units = {"s", "ms", "us", "µs", "μs", "min", "h", "second", "seconds", "millisecond", "milliseconds", "minute", "minutes", "hour", "hours"}
    notes = ["The original native JSON is retained unchanged. This document converts metadata only and contains no inferred acquisition paths or raster labels.",
             "Native display defaults do not establish physical calibration. Only explicit recognized physical units mark converted axes as calibrated.",
             "Display controls start at normalized 0–1, gamma 1 and white; adjust them after binding sources. Source pixels remain unchanged."]
    for axis in _array(value.get("axes"), "Workspace axes", 16):
        axis = _object(axis, "Native axis")
        output = {key: _string(axis.get(key), "Axis " + key) for key in ("id", "name", "kind")}
        output.update({"length": _integer(axis.get("length"), "Axis length", 1), "scale": _number(axis.get("scale", 1), "Axis scale")})
        if output["scale"] <= 0:
            _fail("Native axis scale must be positive; no default scale is substituted.")
        unit = axis.get("unit")
        if unit is not None:
            output["unit"] = _string(unit, "Axis unit")
        units = physical_units if output["kind"] in ("x", "y", "z") else time_units if output["kind"] == "time" else set()
        output["calibrated"] = isinstance(unit, str) and unit.lower() in units
        result["axes"].append(output)
    paint = _uuid_map(value.get("paintDocuments", []), "Native paint documents")
    result["paintDocuments"] = {key: _paint(document) for key, document in paint.items()}
    if paint:
        notes.append("Native semantic paint interpolated disks along stroke segments. Shared re-rendering uses bounded segment-distance capsules; boundary pixels may differ. Original stroke journals and any prior exports remain historical evidence, not equivalent new masks.")
    missing, mappings = [], []
    for layer in _array(value.get("layers", []), "Workspace layers", 256):
        layer = _object(layer, "Native layer")
        output = {key: _string(layer.get(key), "Layer " + key) for key in ("id", "name", "kind", "blendMode")}
        output.update({"axisIDs": copy.deepcopy(_array(layer.get("axisIDs"), "Layer axes", 16)), "visible": layer.get("isVisible", True),
                       "opacity": _number(layer.get("opacity", 1), "Layer opacity"), "transform": copy.deepcopy(_object(layer.get("transform"), "Layer transform")),
                       "display": {"min": 0, "max": 1, "gamma": 1, "color": [255, 255, 255]}})
        source_kind, source = _variant(layer.get("source"), "Layer source", {"localFile", "omeZarr", "generated", "embedded"})
        source_name = source.get("displayName") or source.get("rootName") or output["name"]
        identity = {"id": "native-source-" + output["id"], "name": _string(source_name, "Source name"),
                    "kind": "zarr" if source_kind == "omeZarr" else "local" if source_kind == "localFile" else "generated"}
        output["source"] = {"identity": identity}
        if source_kind == "omeZarr":
            output["source"].update({"arrayPath": _string(source.get("arrayPath"), "Zarr array path"), "level": _integer(source.get("level"), "Zarr level")})
        if source_kind == "generated":
            output["source"]["operation"] = _string(source.get("operation"), "Generated operation")
        payload_kind, payload = _variant(layer.get("payload"), "Layer payload", {"raster", "points", "shapes", "tracks", "surface"})
        if payload_kind != "raster" and payload_kind != output["kind"]:
            _fail("Native layer kind and vector payload disagree.", {"layerId": output["id"]})
        if payload_kind == "raster" and output["kind"] not in ("image", "labels"):
            _fail("Native raster payload requires an image or label layer.", {"layerId": output["id"]})
        if payload_kind in ("points", "shapes"):
            if set(payload) != {"_0"}:
                _fail("Unknown native vector enum payload.")
            output[payload_kind] = [_positioned_geometry(item, "point" if payload_kind == "points" else "shape") for item in _array(payload["_0"], "Native vectors")]
        elif payload_kind in ("tracks", "surface"):
            if set(payload) != {"_0"}:
                _fail("Unknown native track/surface enum payload.")
            # Preserve track vertex IDs/features as additive metadata. Their
            # coordinate/frame fields and surface triangles have identical meaning.
            output[payload_kind] = copy.deepcopy(payload["_0"])
        elif payload:
            _fail("Native raster payload unexpectedly contains raster data. No decoder or implicit raster conversion is allowed.")
        metadata = copy.deepcopy(_object(layer.get("metadata", {}), "Native layer metadata"))
        mapping = {"layerId": output["id"], "name": output["name"], "sourceKind": source_kind,
                   "nativeSource": copy.deepcopy(layer["source"]), "nativeMetadata": metadata, "rasterRequired": payload_kind == "raster"}
        dimensions = None
        if output["id"] in result["paintDocuments"]:
            document = result["paintDocuments"][output["id"]]
            dimensions = {"width": document["width"], "height": document["height"], "origin": "native-paint-grid"}
        elif all(isinstance(metadata.get(key), str) and metadata[key].isdigit() and int(metadata[key]) > 0 for key in ("width", "height")):
            dimensions = {"width": int(metadata["width"]), "height": int(metadata["height"]), "origin": "native-loaded-raster-grid"}
        if dimensions:
            mapping["expectedGrid"] = dimensions
            mapping["coordinateSpace"] = "native-layer-pixel-edges"
        if "frame" in metadata:
            # The native viewer filtered image layers by metadata.frame; the
            # shared layer schema has no implicit frame-visibility rule.
            _fail("Frame-indexed native layer visibility requires explicit timeline conversion; it cannot be silently converted into always-visible layers.", {"layerId": output["id"], "frame": metadata["frame"]})
        if payload_kind == "raster":
            unresolved = {"layerId": output["id"], "name": output["name"], "sourceKind": source_kind,
                          "reason": "Bind an explicit canonical acquisition and plane. Native display names, generated labels and bookmarks do not establish a source identity."}
            if dimensions:
                unresolved["expectedGrid"] = dimensions
            missing.append(unresolved)
        mappings.append(mapping)
        result["layers"].append(output)
    result["workflows"] = [_workflow(workflow) for workflow in _array(value.get("workflows", []), "Native workflows", 256)]
    result["animationPlans"] = [_animation(plan) for plan in _array(value.get("animationPlans", []), "Native animations", 256)]
    if value.get("plate") is not None:
        result["plate"] = copy.deepcopy(_object(value["plate"], "Native plate"))
    notes.append("Every raster binding must match its retained layer/paint grid. Native display-preview dimensions must not be treated as full-resolution labels or rescaled implicitly.")
    return {"document": result, "notes": notes, "missingSources": missing, "nativeSourceMappings": mappings, "originalFormat": "native"}
