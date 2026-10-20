"""Reversible source-coordinate annotations and calibrated acquisition profiles."""
from __future__ import annotations

import base64
import copy
import hashlib
import io
import json
import math
import os
import stat
import uuid

ENGINE_VERSION = "annotations-1"
MAX_POINTS = 2048
MAX_ANNOTATIONS_PER_IMAGE = 500
MAX_ANNOTATIONS = 2000
MAX_HISTORY = 100
MAX_SNAPSHOTS = 5000
MAX_POLYGON_SAMPLES = 4_000_000
MAX_POLYGON_VISITS = 100_000_000
MAX_PROFILE_SAMPLES = 4096
MAX_IMPORT_BYTES = 2 * 1024 * 1024


def geometry_schema():
    from _workbench_schema import _object, _POINT
    return _object({"type": {"type": "string", "enum": ["point", "line", "polyline", "polygon"]},
                    "points": {"type": "array", "items": _POINT, "minItems": 1, "maxItems": MAX_POINTS}},
                   ["type", "points"])


def draft_schema():
    from _workbench_schema import _object
    return _object({
        "name": {"type": "string", "minLength": 1, "maxLength": 200},
        "notes": {"type": "string", "minLength": 0, "maxLength": 4096},
        "geometry": geometry_schema(),
        "target": {"type": "string", "enum": ["plane", "volume"]},
        "sourceParameters": _object({"channel": {"type": "integer", "minimum": 0, "maximum": 31},
                                    "zProjection": {"type": "string", "enum": ["max", "mean", "middle"]}}),
        "timeIndex": {"type": "integer", "minimum": 0, "maximum": 64000000},
        "channel": {"type": "integer", "minimum": 0, "maximum": 31},
        "plane": {"type": "string", "enum": ["xy", "xz", "yz"]},
        "index": {"type": "integer", "minimum": 0, "maximum": 64000000},
    }, ["geometry"])


def operations():
    from _workbench_schema import _object, _ID, _STRING, _op
    identity = {"imageId": _ID, "annotationId": _ID}
    return [
        _op("annotation.save", "Save or edit exact point, line, polyline or polygon geometry with immutable revision history.",
            _object({**draft_schema()["properties"], **identity}, ["imageId", "name", "geometry"]), True),
        _op("annotation.list", "List source annotations, saved selections, geometry bounds and undo availability.",
            _object({"imageId": _ID, "includeDeleted": {"type": "boolean"}}, ["imageId"])),
        _op("annotation.get", "Read complete saved geometry and revision history, including reversible deleted annotations.",
            _object(identity, list(identity))),
        _op("annotation.measure", "Measure saved or draft geometry using current calibration and bounded source intensity profiles.",
            _object({**identity, "draft": draft_schema(),
                     "measurementChannel": {"type": "integer", "minimum": 0, "maximum": 31},
                     "profileSamples": {"type": "integer", "minimum": 2, "maximum": MAX_PROFILE_SAMPLES},
                     "maxSize": {"type": "integer", "minimum": 64, "maximum": 2048}}, ["imageId"])),
        _op("annotation.delete", "Retain a reversible deletion event without removing annotation evidence.",
            _object({**identity, "reason": {"type": "string", "maxLength": 4096}}, list(identity)), True),
        _op("annotation.undo", "Restore the previous annotation state while retaining every immutable revision.",
            _object(identity, list(identity)), True),
        _op("annotation.import.preview", "Inspect exported annotation JSON for exact source compatibility without changing the project.",
            _object({"imageId": _ID, "path": _STRING}, ["imageId", "path"])),
        _op("annotation.import.run", "Import a previewed geometry as a new annotation and retain the original file as evidence.",
            _object({"imageId": _ID, "path": _STRING,
                     "previewFingerprint": {"type": "string", "minLength": 64, "maxLength": 64}},
                    ["imageId", "path", "previewFingerprint"]), True),
    ]


def fail(code, message):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message)


def limits():
    return {"points": MAX_POINTS, "annotationsPerImage": MAX_ANNOTATIONS_PER_IMAGE,
            "annotationsPerProject": MAX_ANNOTATIONS, "revisionsPerAnnotation": MAX_HISTORY,
            "projectAnnotationRevisions": MAX_SNAPSHOTS, "profileSamples": MAX_PROFILE_SAMPLES,
            "polygonBoundingSamples": MAX_POLYGON_SAMPLES, "polygonVertexSampleVisits": MAX_POLYGON_VISITS,
            "importBytes": MAX_IMPORT_BYTES}


def _selection(image, args):
    import _workbench_volume as volume
    target = args.get("target", "plane")
    if target == "plane":
        if any(key in args for key in ("timeIndex", "channel", "plane", "index")):
            fail("invalid-selection", "Projected annotations select sourceParameters; volume slice controls do not apply.")
        if image["timeCount"] > 1:
            fail("unsupported-time-selection", "Annotations on a time series require an explicit volume slice and time index.")
        preferred = (image.get("analysis") or {}).get("parameters", image.get("preferredSourceParameters", {}))
        chosen = {key: preferred.get(key, default) for key, default in (("channel", 0), ("zProjection", "max"))}
        chosen.update(args.get("sourceParameters", {}))
        if not 0 <= chosen["channel"] < image["channels"]:
            fail("channel-unavailable", "The annotation source channel is unavailable.")
        return target, {"sourceParameters": chosen}, (image["height"], image["width"]), "xy"
    if "sourceParameters" in args:
        fail("invalid-selection", "Volume annotations use an explicit time, channel and orthogonal slice.")
    time, channel = args.get("timeIndex", 0), args.get("channel", 0)
    volume.selection(image, time, channel)
    plane = args.get("plane", "xy")
    dimensions = dict(zip("xyz", volume.dimensions(image)))
    normal = {"xy": "z", "xz": "y", "yz": "x"}[plane]
    index = args.get("index", dimensions[normal] // 2)
    if not 0 <= index < dimensions[normal]:
        fail("slice-unavailable", "The annotation slice is outside the source volume.")
    return target, {"timeIndex": time, "channel": channel, "plane": plane, "index": index}, (
        dimensions[plane[1]], dimensions[plane[0]]), plane


def _validate_geometry(geometry, shape):
    import _workbench_imaging as imaging
    np, = imaging.require("numpy")
    from _workbench_schema import validate_value
    validate_value(geometry, geometry_schema(), "geometry")
    kind, points = geometry["type"], geometry["points"]
    n = len(points)
    if ((kind == "point" and n != 1) or (kind == "line" and n != 2)
            or (kind == "polyline" and n < 2) or (kind == "polygon" and n < 3)):
        fail("invalid-geometry", "Point, line, polyline and polygon annotations need 1, 2, at least 2 and at least 3 vertices.")
    p = np.asarray(points, dtype=np.float64)
    if (p < 0).any() or (p[:, 0] > shape[1]).any() or (p[:, 1] > shape[0]).any():
        fail("invalid-geometry", "Annotation vertices must lie within the source pixel-edge boundaries.")
    segments = np.diff(np.vstack((p, p[0])) if kind == "polygon" else p, axis=0)
    if kind != "point" and np.any(np.linalg.norm(segments, axis=1) <= 1e-10):
        fail("invalid-geometry", "Consecutive vertices must be distinct; polygons close automatically.")
    if kind == "polygon":
        relative = p - p[0]
        area = abs(float(np.sum(relative[:, 0] * np.roll(relative[:, 1], -1) -
                                np.roll(relative[:, 0], -1) * relative[:, 1]))) / 2
        if area <= 1e-10:
            fail("invalid-geometry", "A polygon must enclose positive geometric area.")
        # Exact segment intersection decisions on bounded source coordinates;
        # adjacent edges share one endpoint but cannot overlap back on themselves.
        def cross(a, b):
            return a[..., 0] * b[..., 1] - a[..., 1] * b[..., 0]
        for i in range(n):
            a, b = p[i], p[(i + 1) % n]
            previous, following = p[(i - 1) % n] - a, b - a
            if abs(float(cross(previous, following))) <= 1e-10 and float(previous @ following) > 0:
                fail("invalid-geometry", "Polygon edges cannot overlap or reverse along the preceding edge.")
            indices = [j for j in range(i + 1, n) if j != (i + 1) % n and (j + 1) % n != i]
            if not indices:
                continue
            c, d = p[indices], p[[(j + 1) % n for j in indices]]
            ab = b - a
            first, second = cross(ab, c - a), cross(ab, d - a)
            third, fourth = cross(d - c, a - c), cross(d - c, b - c)
            bbox = (np.maximum(np.minimum(a, b), np.minimum(c, d)) <=
                    np.minimum(np.maximum(a, b), np.maximum(c, d)) + 1e-10).all(axis=1)
            if np.any(bbox & (np.minimum(first, second) <= 1e-10) & (np.maximum(first, second) >= -1e-10)
                      & (np.minimum(third, fourth) <= 1e-10) & (np.maximum(third, fourth) >= -1e-10)):
                fail("invalid-geometry", "Polygon edges must form a simple boundary without crossings or self-touching.")
    return {"type": kind, "points": p.tolist()}


def _draft(image, args):
    import _workbench_support as support
    target, selection, shape, _ = _selection(image, args)
    return {"schemaVersion": 1, "id": None, "imageId": image["id"],
            "name": args.get("name", "Annotation"), "notes": args.get("notes", ""),
            "geometry": _validate_geometry(args["geometry"], shape),
            "target": target, "selection": selection, "sourcePath": image["sourcePath"],
            "sourceHash": image["sourceHash"], "sourceSupport": support.fingerprint(image),
            "geometryRevision": None, "deleted": False}


def _record(document, image, annotation_id):
    record = next((item for item in document.get("annotations", [])
                   if item["id"] == annotation_id and item["imageId"] == image["id"]), None)
    if record is None:
        fail("annotation-not-found", "The annotation does not belong to the selected image.")
    return record


def _snapshot(record, identifier=None):
    identifier = identifier or record["currentSnapshotId"]
    found = next((item for item in record["snapshots"] if item["id"] == identifier), None)
    if found is None:
        fail("annotation-corrupt", "The annotation revision reference is unavailable.")
    return found


def _read(store, record, identifier=None):
    snapshot = _snapshot(record, identifier)
    path = store.verify_artifact(snapshot["path"], snapshot["hash"])
    if path.stat().st_size > 512 * 1024:
        fail("annotation-too-large", "The annotation revision exceeds its allocation bound.")
    try:
        value = json.loads(path.read_text("utf-8"))
    except (ValueError, UnicodeError):
        fail("annotation-corrupt", "The annotation revision is not readable JSON.")
    if not isinstance(value, dict) or value.get("id") != record["id"] or value.get("imageId") != record["imageId"]:
        fail("annotation-corrupt", "The annotation revision has inconsistent source identity.")
    return value


def describe(image, record, full=False, value=None):
    import _workbench_support as support
    value = copy.deepcopy(value or record["value"])
    value.pop("sourcePath", None)
    frozen_support = value.pop("sourceSupport", None)
    value["sourceCurrent"] = value["sourceHash"] == image["sourceHash"] and frozen_support == support.fingerprint(image)
    value["undoAvailable"] = bool(record.get("undoStack"))
    if record.get("importOrigin"):
        value["importOrigin"] = {key: copy.deepcopy(item) for key, item in record["importOrigin"].items()
                                 if not key.endswith("Path")}
    if full:
        value["history"] = [{key: item[key] for key in ("revision", "operation", "at", "actor", "reason") if key in item}
                            for item in record["snapshots"]]
    else:
        points = value["geometry"]["points"]
        xs, ys = [point[0] for point in points], [point[1] for point in points]
        value["geometry"] = {"type": value["geometry"]["type"], "pointCount": len(points),
                             "bounds": {"x": min(xs), "y": min(ys), "width": max(xs) - min(xs), "height": max(ys) - min(ys)}}
    return value


def _write(store, document, image, record, value, revision, operation, actor, reason=None, undo=None):
    from _workbench_store import canonical, utc_now
    if len(record["snapshots"]) >= MAX_HISTORY or sum(len(item["snapshots"]) for item in document.get("annotations", [])) >= MAX_SNAPSHOTS:
        fail("annotation-history-full", "The retained annotation history reached its published revision limit.")
    value = copy.deepcopy(value)
    value["geometryRevision"] = revision
    value["createdAt"] = record["createdAt"]
    value["updatedAt"] = utc_now()
    path, checksum = store.put_bytes((canonical(value) + "\n").encode("utf-8"), ".annotation.json")
    event = {"id": str(uuid.uuid4()), "path": path, "hash": checksum, "revision": revision,
             "operation": operation, "actor": copy.deepcopy(actor), "at": value["updatedAt"],
             "sourcePath": value["sourcePath"], "sourceHash": value["sourceHash"],
             "sourceSupport": value.get("sourceSupport")}
    if reason is not None:
        event["reason"] = reason
    if undo is None:
        undo = list(record.get("undoStack", []))
        if record.get("currentSnapshotId"):
            undo.append(record["currentSnapshotId"])
    record.update({"value": value, "currentSnapshotId": event["id"], "undoStack": undo})
    record["snapshots"].append(event)
    return {"annotation": describe(image, record, full=True)}


def _new_record(document, image):
    from _workbench_store import utc_now
    records = document.setdefault("annotations", [])
    if len(records) >= MAX_ANNOTATIONS or sum(item["imageId"] == image["id"] for item in records) >= MAX_ANNOTATIONS_PER_IMAGE:
        fail("too-many-annotations", "This project or image reached the published annotation count limit.")
    record = {"id": str(uuid.uuid4()), "imageId": image["id"], "createdAt": utc_now(),
              "snapshots": [], "undoStack": [], "currentSnapshotId": None}
    records.append(record)
    return record


def _bound_import_json(value, depth=0, remaining=None):
    remaining = [50000] if remaining is None else remaining
    remaining[0] -= 1
    if depth > 32 or remaining[0] < 0:
        fail("invalid-annotation-file", "Annotation JSON exceeds its nesting or item budget.")
    if value is None or type(value) is bool:
        return
    if type(value) in (int, float):
        try:
            if math.isfinite(value):
                return
        except OverflowError:
            pass
    elif isinstance(value, str):
        if len(value) <= 65536 and "\x00" not in value:
            return
    elif isinstance(value, (dict, list)):
        if len(value) > (128 if isinstance(value, dict) else 5000):
            fail("invalid-annotation-file", "Annotation JSON contains an oversized collection.")
        for key, item in (value.items() if isinstance(value, dict) else enumerate(value)):
            if isinstance(value, dict) and (not isinstance(key, str) or not key or len(key) > 256 or "\x00" in key):
                fail("invalid-annotation-file", "Annotation JSON contains an invalid property name.")
            _bound_import_json(item, depth + 1, remaining)
        return
    fail("invalid-annotation-file", "Annotation JSON must contain bounded, finite values.")


def _read_import_file(value):
    from _workbench_schema import absolute_path
    path = absolute_path(value, "path")
    if path.suffix.lower() != ".json":
        fail("unsupported-annotation-file", "Annotation import requires a CellCounter geometry JSON export.")
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_BINARY", 0))
        with os.fdopen(descriptor, "rb") as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= MAX_IMPORT_BYTES:
                fail("invalid-annotation-file", "Annotation input must be a nonempty regular file of at most 2 MiB.")
            contents = stream.read(MAX_IMPORT_BYTES + 1)
            after = os.fstat(stream.fileno())
        if (len(contents) != before.st_size or
                (before.st_size, before.st_mtime_ns, before.st_ctime_ns) !=
                (after.st_size, after.st_mtime_ns, after.st_ctime_ns)):
            fail("annotation-file-changed", "The annotation file changed while being read. Preview the completed file again.")
    except OSError as exc:
        fail("annotation-file-unavailable", f"Cannot read the annotation file: {exc}")
    def pairs(items):
        result = {}
        for key, item in items:
            if key in result:
                raise ValueError("Duplicate JSON property")
            result[key] = item
        return result
    def nonfinite(_):
        raise ValueError("Non-finite JSON number")
    try:
        payload = json.loads(contents.decode("utf-8"), object_pairs_hook=pairs, parse_constant=nonfinite)
    except (ValueError, UnicodeError, RecursionError) as exc:
        fail("invalid-annotation-file", f"Annotation input is not unambiguous UTF-8 JSON: {str(exc)[:200]}")
    _bound_import_json(payload)
    return path, contents, hashlib.sha256(contents).hexdigest(), payload


def _import_preview(store, document, image, args):
    from _workbench_schema import validate_value, _ID, _object
    from _workbench_store import canonical
    import _workbench_support as support
    import _workbench_volume as volume
    path, contents, checksum, payload = _read_import_file(args["path"])
    if (not isinstance(payload, dict) or type(payload.get("schemaVersion")) is not int or
            payload["schemaVersion"] != 1 or payload.get("format") != "cellcounter-annotation"):
        fail("unsupported-annotation-file", "This file is not a supported CellCounter annotation geometry export.")
    annotation, provenance = payload.get("annotation"), payload.get("provenance")
    if not isinstance(annotation, dict) or not isinstance(provenance, dict):
        fail("invalid-annotation-file", "Annotation JSON must contain saved geometry and provenance.")
    if hashlib.sha256((canonical(provenance) + "\n").encode("utf-8")).hexdigest() != payload.get("provenanceSha256"):
        fail("annotation-provenance-mismatch", "The exported provenance does not match its retained hash.")
    if (annotation.get("deleted") is not False or annotation.get("sourceCurrent") is not True
            or provenance.get("format") != "geometry-json" or provenance.get("coordinateSpace") != "pixel-edges"):
        fail("invalid-annotation-file", "Import requires active geometry exported in current local pixel-edge coordinates.")
    identity = {key: annotation.get(key) for key in ("id", "imageId", "geometryRevision")}
    validate_value(identity, _object({"id": _ID, "imageId": _ID,
                                      "geometryRevision": {"type": "integer", "minimum": 1}}, list(identity)), "annotation")
    validate_value(provenance.get("projectId"), _ID, "provenance.projectId")
    if any(provenance.get(key) != annotation.get(other) for key, other in
           (("annotationId", "id"), ("imageId", "imageId"), ("geometryRevision", "geometryRevision"),
            ("target", "target"), ("selection", "selection"))):
        fail("annotation-provenance-mismatch", "The exported geometry and provenance identities disagree.")
    source = provenance.get("source")
    if (not isinstance(source, dict) or source.get("sha256") != image["sourceHash"]
            or annotation.get("sourceHash") != image["sourceHash"]):
        fail("annotation-source-mismatch", "Import requires the exact source image bytes used by the exported annotation.")
    for key in ("width", "height", "channels", "zCount", "timeCount"):
        if type(source.get(key)) is not int or source[key] != image[key]:
            fail("annotation-source-mismatch", "Imported annotation source dimensions must exactly match the target image.")
    def support_identity(value):
        if value is None:
            return None
        if not isinstance(value, dict):
            fail("invalid-annotation-file", "The exported source-support descriptor is malformed.")
        return {key: value.get(key) for key in ("hash", "shape", "policy")}
    current_support = support.fingerprint(image)
    if support_identity(provenance.get("validSupport")) != support_identity(current_support):
        fail("annotation-support-mismatch", "The exported annotation and target image have different acquired support.")
    target, selected = annotation.get("target"), annotation.get("selection")
    if target not in ("plane", "volume") or not isinstance(selected, dict):
        fail("invalid-annotation-file", "The annotation source selection is invalid.")
    expected_selection_keys = {"sourceParameters"} if target == "plane" else {"timeIndex", "channel", "plane", "index"}
    if set(selected) != expected_selection_keys:
        fail("invalid-annotation-file", "The annotation must contain one complete source selection.")
    draft = {"name": annotation.get("name"), "notes": annotation.get("notes"),
             "geometry": annotation.get("geometry"), "target": target, **selected}
    validate_value(draft, draft_schema(), "annotation")
    if target == "plane" and set(selected["sourceParameters"]) != {"channel", "zProjection"}:
        fail("invalid-annotation-file", "The exported projection must include its channel and Z selection.")
    value = _draft(image, draft)
    validate_value(provenance.get("voxelSizeUm"), _object({
        axis: {"type": ["number", "null"], "exclusiveMinimum": 0} for axis in "xyz"
    }, list("xyz")), "provenance.voxelSizeUm")
    exported_calibration, current_calibration = provenance["voxelSizeUm"], volume.calibration(image)
    matches = exported_calibration == current_calibration
    store.verify_artifact(image["sourcePath"], image["sourceHash"])
    if current_support:
        store.verify_artifact(current_support["path"], current_support["hash"])
    identity = {
        "fileHash": checksum, "projectId": document["id"], "imageId": image["id"],
        "source": source, "support": current_support, "calibration": current_calibration,
        "timeStepSeconds": image.get("timeStepSeconds"), "draft": draft,
    }
    fingerprint = hashlib.sha256(canonical(identity).encode("utf-8")).hexdigest()
    notes = [
        "A new annotation ID is created; existing annotations and masks are unchanged.",
        "Coordinates remain in the exact source image grid, with no resizing or geographic conversion.",
        "The imported file preserves external history as evidence. The local annotation history begins with this import.",
        "Measurements use the target image's current calibration and valid support.",
    ]
    if not matches:
        notes.append("Exported calibration differs from the target; target calibration is used without changing pixel coordinates.")
    result = {
        "imageId": image["id"],
        "source": {"name": path.name, "sha256": checksum, "bytes": len(contents), "format": "cellcounter-annotation"},
        "annotation": {key: copy.deepcopy(value[key]) for key in ("name", "notes", "geometry", "target", "selection")},
        "compatibility": {"sourceMatches": True, "calibrationMatches": matches},
        "previewFingerprint": fingerprint, "notes": notes,
    }
    return result, contents, value, provenance


def _import(store, document, image, operation, args, revision, actor):
    from _workbench_store import utc_now
    import _workbench_volume as volume
    result, contents, value, provenance = _import_preview(store, document, image, args)
    if operation == "annotation.import.preview":
        return result
    if args["previewFingerprint"] != result["previewFingerprint"]:
        fail("annotation-preview-changed", "The file, image selection, calibration or support changed. Preview the import again.")
    record = _new_record(document, image)
    file_path, checksum = store.put_bytes(contents, ".annotation-import.json")
    import_id = str(uuid.uuid4())
    record["importOrigin"] = {
        "importId": import_id, "filePath": file_path, "fileHash": checksum,
        "fileName": result["source"]["name"], "importedAt": utc_now(),
        "sourceProjectId": provenance["projectId"], "sourceImageId": provenance["imageId"],
        "sourceAnnotationId": provenance["annotationId"], "sourceGeometryRevision": provenance["geometryRevision"],
        "exportedCalibration": copy.deepcopy(provenance["voxelSizeUm"]),
        "targetCalibrationAtImport": volume.calibration(image),
        "calibrationMatchesAtImport": result["compatibility"]["calibrationMatches"],
        "previewFingerprint": result["previewFingerprint"],
    }
    value["id"] = record["id"]
    saved = _write(store, document, image, record, value, revision, operation, actor)
    return {**saved, "source": result["source"], "importId": import_id}


def _source(store, image, annotation, channel_override):
    import _workbench_imaging as imaging
    import _workbench_support as support
    import _workbench_volume as volume
    chosen = copy.deepcopy(annotation["selection"])
    saved_channel = chosen["sourceParameters"]["channel"] if annotation["target"] == "plane" else chosen["channel"]
    channel = saved_channel if channel_override is None else channel_override
    if not 0 <= channel < image["channels"]:
        fail("channel-unavailable", "The requested measurement channel is unavailable.")
    if annotation["target"] == "plane":
        chosen["sourceParameters"]["channel"] = channel
        raw, _ = imaging.load_plane(store.verify_artifact(image["sourcePath"], image["sourceHash"]), chosen["sourceParameters"])
        valid = support.load(store, image, raw.shape, chosen["sourceParameters"])
        axes = "xy"
    else:
        chosen["channel"] = channel
        raw = volume.load_source(store, image, chosen["timeIndex"], channel)
        valid = support.load(store, image, raw.shape)
        raw = volume.plane_array(raw, chosen["plane"], chosen["index"])
        if valid is not None:
            valid = volume.plane_array(valid, chosen["plane"], chosen["index"])
        axes = chosen["plane"]
    return raw, valid, chosen, axes, channel


def _bilinear(raw, valid, coordinates):
    import numpy as np
    xy = np.asarray(coordinates, dtype=np.float64) - .5
    inside = ((xy[:, 0] >= 0) & (xy[:, 0] <= raw.shape[1] - 1) &
              (xy[:, 1] >= 0) & (xy[:, 1] <= raw.shape[0] - 1))
    x = np.clip(xy[:, 0], 0, raw.shape[1] - 1)
    y = np.clip(xy[:, 1], 0, raw.shape[0] - 1)
    x0, y0 = np.floor(x).astype(int), np.floor(y).astype(int)
    x1, y1 = np.minimum(x0 + 1, raw.shape[1] - 1), np.minimum(y0 + 1, raw.shape[0] - 1)
    dx, dy = x - x0, y - y0
    values = np.zeros(len(coordinates), dtype=np.float64)
    for xs, ys, weight in ((x0, y0, (1 - dx) * (1 - dy)), (x1, y0, dx * (1 - dy)),
                           (x0, y1, (1 - dx) * dy), (x1, y1, dx * dy)):
        values += raw[ys, xs] * weight
        if valid is not None:
            inside &= (weight == 0) | valid[ys, xs]
    inside &= np.isfinite(values)
    return values, inside


def _stats(values, missing, units, sampling):
    import numpy as np
    values = np.asarray(values, dtype=np.float64)
    result = {"units": units, "sampling": sampling, "validSamples": int(values.size),
              "missingSamples": int(missing), "mean": None, "min": None, "max": None, "sd": None, "sum": None}
    if values.size:
        scale = max(float(np.max(np.abs(values))), 1.)
        scaled = values / scale
        def finite(value):
            return float(value) if math.isfinite(value) else None
        result.update({"mean": finite(float(scaled.mean()) * scale), "min": float(values.min()),
                       "max": float(values.max()), "sd": finite(float(scaled.std(ddof=0)) * scale),
                       "sum": finite(float(scaled.sum()) * scale)})
    return result


def _geometry_metrics(geometry, spacing):
    import numpy as np
    p = np.asarray(geometry["points"], dtype=np.float64)
    kind = geometry["type"]
    result = dict.fromkeys(("lengthPx", "perimeterPx", "areaPx2", "lengthUm", "perimeterUm", "areaUm2"))
    if kind == "point":
        return result
    vertices = np.vstack((p, p[0])) if kind == "polygon" else p
    delta = np.diff(vertices, axis=0)
    length = float(np.linalg.norm(delta, axis=1).sum())
    complete = all(value is not None for value in spacing)
    physical = float(np.linalg.norm(delta * spacing, axis=1).sum()) if complete else None
    if kind == "polygon":
        relative = p - p[0]
        area = abs(float(np.sum(relative[:, 0] * np.roll(relative[:, 1], -1) -
                                np.roll(relative[:, 0], -1) * relative[:, 1]))) / 2
        result.update({"perimeterPx": length, "areaPx2": area, "perimeterUm": physical,
                       "areaUm2": area * spacing[0] * spacing[1] if complete else None})
    else:
        result.update({"lengthPx": length, "lengthUm": physical})
    return result


def _sample(raw, valid, geometry, spacing, count, units):
    import numpy as np
    points = np.asarray(geometry["points"], dtype=np.float64)
    kind = geometry["type"]
    if kind == "polygon":
        from _workbench_imaging import require
        require("skimage")
        from skimage.draw import polygon
        low = np.floor(points.min(axis=0)).astype(int).clip(0, [raw.shape[1], raw.shape[0]])
        high = np.ceil(points.max(axis=0)).astype(int).clip(0, [raw.shape[1], raw.shape[0]])
        width, height = high - low
        budget = int(width) * int(height)
        if budget > MAX_POLYGON_SAMPLES or budget * len(points) > MAX_POLYGON_VISITS:
            fail("annotation-too-large", "Polygon acquisition sampling exceeds the bounding-area or vertex-work limit; use a smaller region or fewer vertices.")
        rows, cols = polygon(points[:, 1] - low[1] - .5, points[:, 0] - low[0] - .5,
                             shape=(int(height), int(width)))
        rows, cols = rows + low[1], cols + low[0]
        accepted = np.ones(len(rows), dtype=bool) if valid is None else valid[rows, cols]
        return _stats(raw[rows[accepted], cols[accepted]], int((~accepted).sum()), units, "acquisition-centres"), None
    if kind == "point":
        values, accepted = _bilinear(raw, valid, points)
        return _stats(values[accepted], int((~accepted).sum()), units, "bilinear"), None
    delta = np.diff(points, axis=0)
    segment_lengths = np.linalg.norm(delta, axis=1)
    cumulative = np.concatenate(([0.], np.cumsum(segment_lengths)))
    count = count or min(MAX_PROFILE_SAMPLES, max(2, math.ceil(float(cumulative[-1])) + 1))
    positions = np.linspace(0, cumulative[-1], count)
    segments = np.searchsorted(cumulative, positions, side="right") - 1
    segments = segments.clip(0, len(segment_lengths) - 1)
    fractions = (positions - cumulative[segments]) / segment_lengths[segments]
    coordinates = points[segments] + delta[segments] * fractions[:, None]
    values, accepted = _bilinear(raw, valid, coordinates)
    physical = [None] * count
    if all(value is not None for value in spacing):
        physical_lengths = np.linalg.norm(delta * spacing, axis=1)
        physical_cumulative = np.concatenate(([0.], np.cumsum(physical_lengths)))
        physical = (physical_cumulative[segments] + physical_lengths[segments] * fractions).tolist()
    profile = {"sampleCount": count, "positionsPx": positions.tolist(), "positionsUm": physical,
               "coordinates": coordinates.tolist(), "values": [float(value) if ok else None for value, ok in zip(values, accepted)],
               "interpolation": "bilinear"}
    return _stats(values[accepted], int((~accepted).sum()), units, "bilinear"), profile


def _preview(raw, valid, geometry, maximum):
    import numpy as np
    from PIL import Image, ImageDraw
    height, width = raw.shape
    ratio = min(1., maximum / max(width, height))
    w, h = max(1, round(width * ratio)), max(1, round(height * ratio))
    xs = np.floor((np.arange(w) + .5) * width / w).astype(int).clip(0, width - 1)
    ys = np.floor((np.arange(h) + .5) * height / h).astype(int).clip(0, height - 1)
    samples = raw[np.ix_(ys, xs)]
    accepted = np.ones((h, w), dtype=bool) if valid is None else valid[np.ix_(ys, xs)]
    values = raw.ravel() if valid is None else raw[valid]
    low, high = (float(values.min()), float(values.max())) if values.size else (0., 0.)
    scale = max(abs(low), abs(high), 1.)
    gray = (np.zeros((h, w), dtype=np.uint8) if high == low else
            np.rint((samples / scale - low / scale) / (high / scale - low / scale) * 255).clip(0, 255).astype(np.uint8))
    rgb = np.repeat(gray[:, :, None], 3, axis=2)
    rgb[~accepted] = (40, 40, 40)
    source = Image.fromarray(rgb)
    overlay = source.copy()
    draw = ImageDraw.Draw(overlay, "RGBA")
    vertices = [(u * w / width - .5, v * h / height - .5) for u, v in geometry["points"]]
    if geometry["type"] == "polygon":
        draw.polygon(vertices, fill=(255, 190, 40, 40))
        draw.line(vertices + [vertices[0]], fill=(255, 190, 40, 255), width=2)
    elif geometry["type"] != "point":
        draw.line(vertices, fill=(255, 190, 40, 255), width=2)
    for u, v in vertices:
        draw.ellipse((u - 3, v - 3, u + 3, v + 3), fill=(255, 190, 40, 255))
    def encoded(image):
        buffer = io.BytesIO()
        image.save(buffer, format="PNG")
        return "data:image/png;base64," + base64.b64encode(buffer.getvalue()).decode("ascii")
    return {"dataUrl": encoded(source), "overlayDataUrl": encoded(overlay), "width": width, "height": height,
            "previewWidth": w, "previewHeight": h, "displayRange": [low, high]}


def measure(store, document, image, args, *, include_preview=True):
    import _workbench_imaging as imaging
    import _workbench_volume as volume
    import _workbench_support as support
    imaging.require("numpy")
    if ("annotationId" in args) == ("draft" in args):
        fail("invalid-arguments", "Measure exactly one saved annotationId or one draft.")
    if "annotationId" in args:
        record = _record(document, image, args["annotationId"])
        value = _read(store, record)
        annotation = describe(image, record, full=True, value=value)
        if annotation["deleted"]:
            fail("annotation-deleted", "Restore a deleted annotation before measuring it.")
        if not annotation["sourceCurrent"]:
            fail("annotation-source-changed", "The saved annotation source or valid support changed.")
    else:
        value = _draft(image, args["draft"])
        annotation = {key: copy.deepcopy(item) for key, item in value.items() if key not in ("sourcePath", "sourceSupport")}
        annotation.update({"sourceCurrent": True, "undoAvailable": False, "history": []})
    raw, valid, selection, axes, channel = _source(store, image, value, args.get("measurementChannel"))
    geometry = _validate_geometry(value["geometry"], raw.shape)
    if "profileSamples" in args and geometry["type"] not in ("line", "polyline"):
        fail("invalid-arguments", "profileSamples applies only to line and polyline annotations.")
    spacing = [volume.calibration(image)[axis] for axis in axes]
    units = "processed-source" if image.get("derivation") else "raw-source"
    intensity, profile = _sample(raw, valid, geometry, spacing, args.get("profileSamples"), units)
    count = int(valid.sum()) if valid is not None else int(raw.size)
    physical_area = count * spacing[0] * spacing[1] if all(value is not None for value in spacing) else None
    support_info = {"present": valid is not None, "validPixelCount": count, "invalidPixelCount": int(raw.size) - count,
                    "totalSampleCount": int(raw.size), "fraction": count / int(raw.size), "shape": list(raw.shape),
                    "areaUm2": physical_area, "volumeUm3": None}
    notes = [
        "Geometry uses source pixel edges; acquisition sample centres are index + 0.5.",
        "Lengths and areas describe drawn geometry. Polygon intensity statistics use included acquisition sample centres, including centres on the boundary.",
        "Line profiles are uniform in pixel arc length. Physical distances account for anisotropic in-plane spacing.",
        "Bilinear samples use no extrapolation. Any unsupported contributing neighbour makes that sample missing.",
        "Intensity SD is population SD. Profile means average valid profile samples, not an integral; a nonrepresentable sum is null.",
        "Calibration is read at measurement time. Physical metrics remain null when either in-plane spacing is unknown.",
    ]
    measurement = {"sourceRevision": document["revision"], "geometryRevision": value["geometryRevision"],
                   "sourceHash": image["sourceHash"], "measurementChannel": channel, "selection": selection,
                   "axes": list(axes), "pixelSpacingUm": {"u": spacing[0], "v": spacing[1]},
                   "geometry": _geometry_metrics(geometry, spacing), "intensity": intensity, "profile": profile,
                   "validSupport": support_info, "notes": notes}
    result = {"annotation": annotation, "measurement": measurement}
    if include_preview:
        imaging.require("PIL")
        result.update(_preview(raw, valid, geometry, args.get("maxSize", 768)))
    return result


def execute(store, document, operation, args, revision, actor):
    from _workbench_core import _image
    image = _image(document, args["imageId"])
    if operation in ("annotation.import.preview", "annotation.import.run"):
        return _import(store, document, image, operation, args, revision, actor)
    if operation == "annotation.list":
        return {"imageId": image["id"],
                "annotations": [describe(image, item) for item in document.get("annotations", [])
                                if item["imageId"] == image["id"] and
                                (args.get("includeDeleted", False) or not item["value"]["deleted"])],
                "limits": limits(), "coordinateSpace": "pixel-edges"}
    if operation == "annotation.measure":
        return measure(store, document, image, args)
    if operation == "annotation.get":
        record = _record(document, image, args["annotationId"])
        return {"annotation": describe(image, record, full=True, value=_read(store, record))}
    if operation == "annotation.save":
        value = _draft(image, args)
        if "annotationId" in args:
            record = _record(document, image, args["annotationId"])
        else:
            record = _new_record(document, image)
        value["id"] = record["id"]
        return _write(store, document, image, record, value, revision, operation, actor)
    record = _record(document, image, args["annotationId"])
    if operation == "annotation.delete":
        value = _read(store, record)
        if value["deleted"]:
            fail("annotation-deleted", "This annotation is already deleted; undo can restore it.")
        value["deleted"] = True
        return _write(store, document, image, record, value, revision, operation, actor, args.get("reason"))
    if operation == "annotation.undo":
        undo = list(record.get("undoStack", []))
        if not undo:
            fail("nothing-to-undo", "The annotation has no preceding saved state.")
        value = _read(store, record, undo.pop())
        return _write(store, document, image, record, value, revision, operation, actor, undo=undo)
    fail("unknown-operation", "Unknown annotation operation.")


def artifact_references(document):
    references = {}
    for record in document.get("annotations", []):
        if record.get("importOrigin"):
            references[record["importOrigin"]["filePath"]] = record["importOrigin"]["fileHash"]
        for snapshot in record["snapshots"]:
            references[snapshot["path"]] = snapshot["hash"]
            references[snapshot["sourcePath"]] = snapshot["sourceHash"]
            if snapshot.get("sourceSupport"):
                references[snapshot["sourceSupport"]["path"]] = snapshot["sourceSupport"]["hash"]
    return references
