"""Bounded, full-resolution volumetric analysis with explicit time and channel.

Display resampling is isolated from authoritative ZYX labels and measurements.
Coordinates are XYZ voxel-edge coordinates; array storage is X-fastest ZYX.
"""
from __future__ import annotations

import base64
import copy
import hashlib
import io
import math

MAX_VOLUME_VOXELS = 8_000_000
MAX_DISPLAY_DIMENSION = 128
MAX_TRACK_OBJECTS = 2000


def operations():
    from _workbench_schema import _object, _ID, _op, _POINT
    integer = {"type": "integer", "minimum": 0, "maximum": 64000000}
    label = {"type": "integer", "minimum": 1, "maximum": 4294967295}
    positive = {"type": "number", "exclusiveMinimum": 0, "maximum": 1000000}
    nullable = {**positive, "type": ["number", "null"]}
    selection = {"imageId": _ID, "timeIndex": integer, "channel": integer}
    required = ["imageId", "timeIndex", "channel"]
    parameters = parameter_schema()
    plane = {"type": "string", "enum": ["xy", "xz", "yz"]}
    links = {"imageId": _ID, "channel": integer, "sourceTimeIndex": integer,
             "sourceLabelId": label, "targetTimeIndex": integer, "targetLabelId": label}
    return [
        _op("volume.inspect", "Inspect source dimensions, anisotropic calibration and saved 3D frames.",
            _object({"imageId": _ID}, ["imageId"])),
        _op("volume.slice", "Read an exact selected orthogonal plane; resizing affects display only.",
            _object({**selection, "plane": plane, "index": integer,
                     "maxSize": {"type": "integer", "minimum": 64, "maximum": 4096},
                     "includeContours": {"type": "boolean", "default": True},
                     "labelIds": {"type": "array", "minItems": 1, "maxItems": 1000, "items": label}},
                    required + ["plane", "index"])),
        _op("volume.display", "Read a bounded visualization volume, never used for scientific measurements.",
            _object({**selection, "maxDimension": {"type": "integer", "minimum": 8, "maximum": 128},
                     "includeLabels": {"type": "boolean"}}, required)),
        _op("volume.calibration.set", "Update or clear physical voxel spacing and recalculate saved measurements.",
            _object({"imageId": _ID, "voxelSizeUm": _object({axis: nullable for axis in "xyz"}),
                     "timeStepSeconds": nullable}, ["imageId"]), True),
        *[_op("volume.analysis." + action, description,
              _object({**selection, "parameters": parameters,
                       **({"maxSize": {"type": "integer", "minimum": 64, "maximum": 2048}} if action == "preview" else {})}, required), action == "run")
          for action, description in (
              ("preview", "Preview true 3D threshold/watershed segmentation with an ephemeral display volume."),
              ("run", "Save full-resolution 3D labels and exact per-time measurements."))],
        _op("volume.measurements.get", "Read current volumetric measurements for an explicit time and channel.",
            _object(selection, required)),
        _op("volume.mask.edit", "Edit exact 3D labels through delete, merge, slice polygons or a voxel-radius brush.",
            _object({**selection, "action": {"type": "string", "enum": ["delete", "merge", "polygon", "brush"]},
                     "labelIds": {"type": "array", "items": label, "minItems": 1, "maxItems": 10000},
                     "labelId": label, "plane": plane, "index": integer,
                     "polygon": {"type": "array", "items": _POINT, "minItems": 3, "maxItems": 10000},
                     "center": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3},
                     "radiusVox": {"type": "number", "exclusiveMinimum": 0, "maximum": 128},
                     "mode": {"type": "string", "enum": ["paint", "erase"]}}, required + ["action"]), True),
        _op("volume.mask.undo", "Restore previous 3D geometry and measure with current calibration.",
            _object(selection, required), True),
        _op("tracks.run", "Build bounded one-to-one centroid tracks; no cell division inference.",
            _object({"imageId": _ID, "channel": integer,
                     "timeIndices": {"type": "array", "items": integer, "minItems": 2, "maxItems": 1000},
                     "maxDistance": positive, "units": {"type": "string", "enum": ["voxel", "um"]},
                     "maxGapFrames": {"type": "integer", "minimum": 0, "maximum": 10}},
                    ["imageId", "channel", "maxDistance", "units"]), True),
        _op("tracks.get", "Read saved tracks and whether their geometry and calibration inputs are still current.",
            _object({"imageId": _ID, "channel": integer}, ["imageId", "channel"])),
        *[_op("tracks." + action, "Explicitly " + action + " a one-to-one forward-time correspondence.",
              _object(links, list(links)), True) for action in ("link", "unlink")],
    ]


def parameter_schema():
    from _workbench_schema import _object
    return _object({
        "method": {"type": "string", "enum": ["otsu", "manual"], "default": "otsu"},
        "threshold": {"type": "number"},
        "polarity": {"type": "string", "enum": ["bright", "dark"], "default": "bright"},
        "minVolumeVox": {"type": "integer", "minimum": 1, "maximum": MAX_VOLUME_VOXELS, "default": 8},
        "minDistanceVox": {"type": "integer", "minimum": 1, "maximum": 128, "default": 3},
    })


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def digest(value):
    from _workbench_store import canonical
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def parameters(supplied=None):
    from _workbench_schema import validate_value
    supplied = supplied or {}
    validate_value(supplied, parameter_schema(), "parameters")
    result = {key: value["default"] for key, value in parameter_schema()["properties"].items() if "default" in value}
    result.update(supplied)
    if (result["method"] == "manual") != ("threshold" in result):
        fail("invalid-arguments", "Only manual thresholding requires threshold in raw source units.")
    return result


def calibration(image):
    if "voxelSizeUm" in image:
        return {axis: image["voxelSizeUm"].get(axis) for axis in "xyz"}
    scale = image.get("pxPerUm")
    return {"x": 1 / scale if scale else None, "y": 1 / scale if scale else None, "z": None}


def xy_calibrated(image):
    scale = calibration(image)
    return scale["x"] is not None and scale["y"] is not None


def dimensions(image):
    return [image["width"], image["height"], image.get("zCount", 1)]


def selection(image, time_index, channel):
    if type(time_index) is not int or not 0 <= time_index < image.get("timeCount", 1):
        fail("time-unavailable", "Selected time point is unavailable.")
    if type(channel) is not int or not 0 <= channel < image["channels"]:
        fail("channel-unavailable", "Selected channel is unavailable.")
    if math.prod(dimensions(image)) > MAX_VOLUME_VOXELS:
        fail("volume-too-large", "Selected volume exceeds the 8-million-voxel scientific allocation limit.")


def load_source(store, image, time_index, channel, source=None, *, validate_finite=True):
    np, = imaging.require("numpy")
    selection(image, time_index, channel)
    if source is None:
        path = store.verify_artifact(image["sourcePath"], image["sourceHash"])
        array, metadata = imaging.load_array(path)
    else:
        array, metadata = source
    axes = metadata["axes"].replace("S", "C")
    for axis, value in (("T", time_index), ("C", channel)):
        if axis in axes:
            index = axes.index(axis)
            indices = [slice(None)] * array.ndim
            indices[index] = value
            array = array[tuple(indices)]
            axes = axes[:index] + axes[index + 1:]
    if axes == "YX":
        array = array[None, ...]
    elif axes != "ZYX":
        fail("unsupported-axes", "Selected source cannot be represented as ZYX.")
    if list(reversed(array.shape)) != dimensions(image):
        fail("source-changed", "Source dimensions differ from the imported image.")
    array = np.asarray(array, dtype=np.float64)
    if validate_finite and not np.isfinite(array).all():
        fail("invalid-pixels", "Volumetric analysis requires finite source intensities.")
    return array


def get_frame(image, time_index, channel, required=True):
    for frame in image.get("volumeFrames", []):
        if frame["timeIndex"] == time_index and frame["channel"] == channel:
            return frame
    if required:
        fail("volume-analysis-required", "Run 3D analysis for this time and channel first.")
    return None


def analysis_fingerprint(image, frame):
    import _workbench_support as support
    value = {"sourceHash": image["sourceHash"], "timeIndex": frame["timeIndex"],
                   "channel": frame["channel"], "parameters": frame["parameters"],
                   "labelsHash": frame["labelsHash"], "voxelSizeUm": calibration(image),
                   "engineVersion": frame["engineVersion"]}
    if support.descriptor(image):
        value["validSupport"] = support.fingerprint(image)
    return digest(value)


def input_fingerprint(image, time_index, channel):
    import _workbench_support as support
    frame = get_frame(image, time_index, channel, required=False)
    return digest({"sourceHash": image["sourceHash"], "timeIndex": time_index, "channel": channel,
                   "voxelSizeUm": calibration(image),
                   **({"validSupport": support.fingerprint(image)} if support.descriptor(image) else {}),
                   "frame": None if frame is None else {
                       key: frame[key] for key in ("inputFingerprint", "analysisRevision", "measurementRevision")}})


def current_frame(store, image, time_index, channel, verify=True):
    frame = get_frame(image, time_index, channel)
    if frame["inputFingerprint"] != analysis_fingerprint(image, frame):
        fail("stale-volume-analysis", "Saved volume measurements do not match current geometry or calibration.")
    if verify:
        store.verify_artifact(image["sourcePath"], image["sourceHash"])
        import _workbench_support as support
        if support.descriptor(image):
            read_labels(store, image, frame)
        else:
            store.verify_artifact(frame["labelsPath"], frame["labelsHash"])
    return frame


def read_labels(store, image, frame):
    np, = imaging.require("numpy")
    path = store.verify_artifact(frame["labelsPath"], frame["labelsHash"])
    if path.stat().st_size > MAX_VOLUME_VOXELS * 4 + 65536:
        fail("invalid-labels", "Volume labels exceed the allocation limit.")
    labels = np.load(path, mmap_mode="r", allow_pickle=False)
    if labels.dtype != np.dtype("uint32") or list(reversed(labels.shape)) != dimensions(image) or labels.ndim != 3:
        fail("invalid-labels", "Volume label dimensions or dtype are invalid.")
    import _workbench_support as support
    if support.descriptor(image):
        support.assert_labels(store, image, labels)
    return labels


def segment(raw, params, valid_support=None):
    np, = imaging.require("numpy")
    imaging.require("scipy", "skimage")
    from scipy import ndimage as ndi
    from skimage.filters import threshold_otsu
    from skimage.feature import peak_local_max
    from skimage.segmentation import watershed
    samples = raw if valid_support is None else raw[valid_support]
    if not samples.size:
        fail("no-valid-support", "Segmentation requires supported acquired voxels.")
    if params["method"] == "otsu" and samples.min() == samples.max():
        return np.zeros(raw.shape, np.uint32), {"threshold": float(samples.min()), "foregroundVoxels": 0}
    threshold = params["threshold"] if params["method"] == "manual" else float(threshold_otsu(samples))
    binary = raw > threshold if params["polarity"] == "bright" else raw < threshold
    if valid_support is not None:
        binary &= valid_support
    components, count = ndi.label(binary)
    if count:
        keep = np.bincount(components.ravel()) >= params["minVolumeVox"]
        keep[0] = False
        binary = keep[components]
    if not binary.any():
        return np.zeros(raw.shape, np.uint32), {"threshold": threshold, "foregroundVoxels": 0}
    distance = ndi.distance_transform_edt(binary)
    peaks = peak_local_max(distance, min_distance=params["minDistanceVox"], labels=binary, exclude_border=False)
    if len(peaks) > imaging.MAX_CELLS:
        fail("too-many-objects", "3D segmentation exceeds the 20,000-object limit.")
    markers = np.zeros(raw.shape, np.int32)
    for index, point in enumerate(peaks, 1):
        markers[tuple(point)] = index
    components, count = ndi.label(binary)
    if count > imaging.MAX_CELLS:
        fail("too-many-objects", "3D segmentation exceeds the 20,000-object limit.")
    seeded = set(map(int, components[markers > 0]))
    next_marker = len(peaks) + 1
    for label_id, region in enumerate(ndi.find_objects(components), 1):
        if region is None or label_id in seeded:
            continue
        local = np.where(components[region] == label_id, distance[region], -1)
        point = np.unravel_index(local.argmax(), local.shape)
        markers[tuple(point[axis] + region[axis].start for axis in range(3))] = next_marker
        next_marker += 1
    if next_marker > imaging.MAX_CELLS + 1:
        fail("too-many-objects", "3D segmentation exceeds the 20,000-object limit.")
    labels = watershed(-distance, markers, mask=binary).astype(np.uint32)
    keep = np.bincount(labels.ravel()) >= params["minVolumeVox"]
    keep[0] = False
    labels[~keep[labels]] = 0
    return labels, {"threshold": float(threshold), "foregroundVoxels": int(np.count_nonzero(labels))}


def measure(labels, raw, scale):
    np, = imaging.require("numpy")
    imaging.require("skimage")
    from skimage.measure import regionprops
    ids = np.unique(labels)
    ids = ids[ids > 0]
    if len(ids) > imaging.MAX_CELLS:
        fail("too-many-objects", "3D measurements exceed the object limit.")
    dense = np.searchsorted(ids, labels).astype(np.int32) + 1
    dense[labels == 0] = 0
    physical = all(scale.get(axis) is not None for axis in "xyz")
    voxel_volume = math.prod(scale[axis] for axis in "xyz") if physical else None
    cells = []
    for prop in regionprops(dense, intensity_image=raw):
        z, y, x = prop.centroid
        z0, y0, x0, z1, y1, x1 = prop.bbox
        count = int(prop.area)
        volume = count * voxel_volume if physical else None
        cells.append({"labelId": int(ids[prop.label - 1]), "cx": float(x + .5), "cy": float(y + .5),
                      "cz": float(z + .5), "voxelCount": count, "volumeUm3": volume,
                      "equivalentDiameterUm": (6 * volume / math.pi) ** (1 / 3) if volume is not None else None,
                      "centroidUm": {"x": (x + .5) * scale["x"], "y": (y + .5) * scale["y"],
                                     "z": (z + .5) * scale["z"]} if physical else None,
                      "meanIntensity": float(prop.mean_intensity),
                      "bbox": {"min": [x0, y0, z0], "max": [x1, y1, z1]}})
    return cells


def result(image, frame):
    import _workbench_support as support
    return {"imageId": image["id"], "timeIndex": frame["timeIndex"], "channel": frame["channel"],
            "cells": frame["cells"], "cellCount": len(frame["cells"]), "dimensions": dimensions(image),
            "voxelSizeUm": calibration(image), "parameters": frame["parameters"],
            "analysisRevision": frame["analysisRevision"], "measurementRevision": frame["measurementRevision"],
            "inputFingerprint": frame["inputFingerprint"], "coordinateSpace": "voxel-edges",
            "intensityUnits": "processed-source" if image.get("derivation") else "raw-source",
            "validSupport": copy.deepcopy(frame.get("validSupport", support.summary(image))),
            "imageStats": frame["imageStats"]}


def save_frame(store, image, raw, labels, params, time_index, channel, revision, stats=None, undo=True):
    from _workbench_store import utc_now
    import _workbench_support as support
    labels, support_info = support.clip_labels(store, image, labels)
    previous = get_frame(image, time_index, channel, required=False)
    undo_stack = copy.deepcopy(previous.get("undoStack", [])) if previous else []
    if previous and undo:
        undo_stack.append({key: previous[key] for key in
                           ("labelsPath", "labelsHash", "parameters", "engineVersion", "imageStats")})
        del undo_stack[:-100]
    path, checksum = store.put_bytes(imaging.encode_labels(labels), ".volume-labels.npy")
    frame = {"timeIndex": time_index, "channel": channel, "parameters": copy.deepcopy(params),
             "labelsPath": path, "labelsHash": checksum, "cells": measure(labels, raw, calibration(image)),
             "analysisRevision": revision, "measurementRevision": revision, "engineVersion": "volume-1",
             "imageStats": {**(stats or {}), "foregroundVoxels": int((labels > 0).sum()),
                            "validSupport": support_info},
             "validSupport": support_info,
             "undoStack": undo_stack, "updatedAt": utc_now()}
    frame["inputFingerprint"] = analysis_fingerprint(image, frame)
    frames = image.setdefault("volumeFrames", [])
    frames[:] = [item for item in frames if not (item["timeIndex"] == time_index and item["channel"] == channel)]
    frames.append(frame)
    frames.sort(key=lambda item: (item["timeIndex"], item["channel"]))
    return frame


def plane_array(array, plane, index):
    axis = {"xy": 0, "xz": 1, "yz": 2}[plane]
    if not 0 <= index < array.shape[axis]:
        fail("slice-unavailable", "Slice index is outside the selected volume.")
    if plane == "xy":
        return array[index, :, :]
    if plane == "xz":
        return array[:, index, :]
    return array[:, :, index]


def display(raw, labels, image, time_index, channel, max_dimension=128):
    np, = imaging.require("numpy")
    imaging.require("scipy")
    from scipy.ndimage import map_coordinates
    original = list(reversed(raw.shape))
    ratio = min(1.0, max_dimension / max(original))
    dims = [max(1, int(math.floor(size * ratio))) for size in original]
    scale = [original[axis] / dims[axis] for axis in range(3)]
    offset = [(value - 1) / 2 for value in scale]
    axes = [(np.arange(dims[axis], dtype=np.float64) * scale[axis] + offset[axis])
            for axis in (2, 1, 0)]
    coords = np.meshgrid(*axes, indexing="ij")
    sampled = map_coordinates(raw, coords, order=1, mode="nearest", prefilter=False)
    low, high = float(raw.min()), float(raw.max())
    normalized = np.zeros(sampled.shape, np.uint8) if high <= low else np.rint((sampled - low) / (high - low) * 255).clip(0, 255).astype(np.uint8)
    descriptor = {"imageId": image["id"], "timeIndex": time_index, "channel": channel,
                  "dataBase64": base64.b64encode(normalized.tobytes(order="C")).decode("ascii"),
                  "encoding": "base64", "dtype": "uint8", "order": "zyx",
                  "dimensions": dims, "originalDimensions": original, "voxelSizeUm": calibration(image),
                  "displayRange": [low, high], "transform": {"scale": scale, "offset": offset}}
    if labels is not None:
        nearest = [np.floor(axis + .5).astype(np.int64).clip(0, raw.shape[index] - 1)
                   for index, axis in enumerate(axes)]
        selected = np.asarray(labels[np.ix_(*nearest)], dtype="<u4")
        descriptor.update({"labelDataBase64": base64.b64encode(selected.tobytes(order="C")).decode("ascii"),
                           "labelDtype": "uint32-le"})
    return descriptor


def slice_result(raw, labels, image, args):
    np, = imaging.require("numpy")
    imaging.require("PIL")
    from PIL import Image
    selected = plane_array(raw, args["plane"], args["index"])
    low, high = float(selected.min()), float(selected.max())
    pixels = np.zeros(selected.shape, np.uint8) if high <= low else np.rint((selected - low) / (high - low) * 255).astype(np.uint8)
    picture = Image.fromarray(pixels)
    if "maxSize" in args:
        picture.thumbnail((args["maxSize"], args["maxSize"]), Image.Resampling.LANCZOS)
    output = io.BytesIO()
    picture.save(output, format="PNG")
    contours = []
    if labels is not None and args.get("includeContours", True):
        plane_labels = plane_array(labels, args["plane"], args["index"])
        if "labelIds" in args:
            if len(args["labelIds"]) != len(set(args["labelIds"])): fail("invalid-labels", "Selected contour label IDs must be distinct.")
            plane_labels = np.where(np.isin(plane_labels, args["labelIds"]), plane_labels, 0)
        contours = [{"labelId": cell["labelId"], "contoursPx": cell["contoursPx"]}
                    for cell in imaging.measure(plane_labels, selected, None)]
    return {**{key: args[key] for key in ("imageId", "timeIndex", "channel", "plane", "index")},
            "dataUrl": "data:image/png;base64," + base64.b64encode(output.getvalue()).decode("ascii"),
            "width": selected.shape[1], "height": selected.shape[0],
            "previewWidth": picture.width, "previewHeight": picture.height,
            "displayRange": [low, high], "voxelSizeUm": calibration(image), "contours": contours}


def edit_labels(labels, args):
    np, = imaging.require("numpy")
    result_labels = labels.copy()
    existing = set(map(int, np.unique(labels))) - {0}
    action = args["action"]
    common = {"imageId", "timeIndex", "channel", "action"}
    allowed = {"delete": {"labelIds"}, "merge": {"labelIds"},
               "polygon": {"labelId", "plane", "index", "polygon"},
               "brush": {"labelId", "center", "radiusVox", "mode"}}[action]
    if set(args) - common - allowed:
        fail("invalid-arguments", "This edit contains fields that do not apply to its action.")
    if action in ("delete", "merge"):
        selected = args.get("labelIds", [])
        if not selected or len(selected) != len(set(selected)) or not set(selected) <= existing:
            fail("invalid-labels", "Select distinct existing volume labels.")
        if action == "merge" and len(selected) < 2:
            fail("invalid-labels", "Merge requires at least two labels.")
        result_labels[np.isin(labels, selected)] = 0 if action == "delete" else min(selected)
    else:
        label_id = args.get("labelId")
        if label_id is None:
            label_id = max(existing, default=0) + 1
            if label_id > 4294967295:
                fail("invalid-labels", "No further uint32 label IDs are available.")
        elif label_id not in existing:
            fail("invalid-labels", "labelId must exist; omit it to create an object.")
        if action == "polygon":
            if not all(key in args for key in ("plane", "index", "polygon")):
                fail("invalid-arguments", "A slice polygon requires plane, index and vertices.")
            plane = plane_array(result_labels, args["plane"], args["index"])
            original = plane.copy()
            # Reuse exact pixel-centre rasterization and overlap rules, allowing
            # a label present elsewhere in 3D but absent from this slice.
            plane_args = {"action": "polygon", "polygon": args["polygon"]}
            if label_id in set(map(int, np.unique(plane))):
                plane_args["labelId"] = label_id
                edited = imaging.edit_labels(plane, plane_args)
            else:
                edited = imaging.edit_labels(plane, plane_args)
                fresh = max(set(map(int, np.unique(plane))) - {0}, default=0) + 1
                edited[edited == fresh] = label_id
            plane[:] = edited
            if np.array_equal(original, plane):
                fail("no-change", "The polygon does not change the selected plane.")
        else:
            if "center" not in args or "radiusVox" not in args:
                fail("invalid-arguments", "A brush requires a centre and radiusVox.")
            x, y, z = args["center"]
            if not (0 <= x <= labels.shape[2] and 0 <= y <= labels.shape[1] and 0 <= z <= labels.shape[0]):
                fail("invalid-arguments", "Brush centre must be inside the volume.")
            radius = args["radiusVox"]
            starts = [max(0, int(math.floor(value - radius))) for value in (z, y, x)]
            stops = [min(labels.shape[axis], int(math.ceil(value + radius)))
                     for axis, value in enumerate((z, y, x))]
            region = tuple(slice(starts[axis], stops[axis]) for axis in range(3))
            zz, yy, xx = np.ogrid[starts[0]:stops[0], starts[1]:stops[1], starts[2]:stops[2]]
            sphere = (xx + .5 - x) ** 2 + (yy + .5 - y) ** 2 + (zz + .5 - z) ** 2 <= radius ** 2
            local = result_labels[region]
            if args.get("mode", "paint") == "erase":
                if "labelId" not in args:
                    fail("invalid-labels", "Erasing requires an explicit labelId.")
                local[sphere & (local == label_id)] = 0
            else:
                if np.any(sphere & (local != 0) & (local != label_id)):
                    fail("label-overlap", "Brush overlaps another object; merge or delete it explicitly.")
                local[sphere] = label_id
    if np.array_equal(result_labels, labels):
        fail("no-change", "The edit does not change any volume voxels.")
    return result_labels


def recalibrate(store, image, args, revision):
    supplied = args.get("voxelSizeUm", {})
    if not supplied and "timeStepSeconds" not in args:
        fail("invalid-arguments", "Supply at least one voxel axis or timeStepSeconds.")
    scale = calibration(image)
    scale.update(supplied)
    image["voxelSizeUm"] = scale
    image["pxPerUm"] = (1 / scale["x"] if scale["x"] is not None and scale["y"] is not None
                       and math.isclose(scale["x"], scale["y"], rel_tol=1e-9) else None)
    if "timeStepSeconds" in args:
        image["timeStepSeconds"] = args["timeStepSeconds"]
    frames = image.get("volumeFrames", [])
    source = (imaging.load_array(store.verify_artifact(image["sourcePath"], image["sourceHash"]))
              if frames else None)
    for frame in frames:
        raw = load_source(store, image, frame["timeIndex"], frame["channel"], source=source)
        frame["cells"] = measure(read_labels(store, image, frame), raw, scale)
        frame["measurementRevision"] = revision
        frame["inputFingerprint"] = analysis_fingerprint(image, frame)
        import _workbench_support as support
        support.refresh_calibration(image, frame)


def tracks_fingerprint(image, record):
    indices = record["timeIndices"]
    if record.get("timeSelection") == "all-analyzed":
        indices = sorted(frame["timeIndex"] for frame in image.get("volumeFrames", []) if frame["channel"] == record["channel"])
    return digest({"frames": [input_fingerprint(image, index, record["channel"]) for index in indices],
                   "voxelSizeUm": calibration(image), "timeStepSeconds": image.get("timeStepSeconds")})


def get_tracks(image, channel):
    return next((item for item in image.get("volumeTracks", []) if item["channel"] == channel), None)


def describe_tracks(image, channel):
    record = get_tracks(image, channel)
    if record is None:
        return {"imageId": image["id"], "channel": channel, "status": "none", "tracks": [], "edges": []}
    return {"imageId": image["id"], **copy.deepcopy(record),
            "status": "current" if record["inputFingerprint"] == tracks_fingerprint(image, record) else "stale"}


def build_track_observations(image, record):
    nodes = {(time, cell["labelId"]): cell for time in record["timeIndices"]
             for cell in get_frame(image, time, record["channel"])["cells"]}
    incoming = {(edge["targetTimeIndex"], edge["targetLabelId"]): (edge["sourceTimeIndex"], edge["sourceLabelId"])
                for edge in record["edges"]}
    grouped = {}
    for node in sorted(nodes):
        root = node
        while root in incoming:
            root = incoming[root]
        grouped.setdefault(root, []).append({"timeIndex": node[0], "labelId": node[1],
                                             **{key: nodes[node][key] for key in ("cx", "cy", "cz")}})
    record["tracks"] = [{"trackId": f"track-{index}", "observations": observations}
                        for index, (_, observations) in enumerate(sorted(grouped.items()), 1)]


def run_tracks(store, image, args, revision):
    np, = imaging.require("numpy")
    imaging.require("scipy")
    from _workbench_tracking import gated_assignment
    from scipy.spatial.distance import cdist
    channel = args["channel"]
    indices = args.get("timeIndices", sorted(frame["timeIndex"] for frame in image.get("volumeFrames", [])
                                             if frame["channel"] == channel))
    if len(indices) < 2 or len(indices) != len(set(indices)):
        fail("invalid-time-selection", "Tracking requires at least two distinct analyzed time points.")
    indices = sorted(indices)
    store.verify_artifact(image["sourcePath"], image["sourceHash"])
    frames = [current_frame(store, image, index, channel, verify=False) for index in indices]
    for frame in frames:
        store.verify_artifact(frame["labelsPath"], frame["labelsHash"])
    if any(len(frame["cells"]) > MAX_TRACK_OBJECTS for frame in frames):
        fail("tracking-too-large", "Centroid matching supports at most 2,000 objects per frame.")
    scale = calibration(image)
    if args["units"] == "um" and not all(scale[axis] is not None for axis in "xyz"):
        fail("calibration-required", "Physical tracking distance requires all three voxel dimensions.")
    factors = np.asarray([scale[axis] for axis in "xyz"] if args["units"] == "um" else [1, 1, 1])
    edges, active = [], []
    for target in frames:
        active = [(time, cell) for time, cell in active
                  if target["timeIndex"] - time - 1 <= args.get("maxGapFrames", 0)]
        if len(active) > MAX_TRACK_OBJECTS:
            fail("tracking-too-large", "Gap matching supports at most 2,000 active object endpoints.")
        matched = set()
        if active and target["cells"]:
            source_points = np.asarray([[cell[key] for key in ("cx", "cy", "cz")] for _, cell in active]) * factors
            target_points = np.asarray([[cell[key] for key in ("cx", "cy", "cz")] for cell in target["cells"]]) * factors
            distances = cdist(source_points, target_points)
            for row, column in gated_assignment(distances, args["maxDistance"]):
                if distances[row, column] <= args["maxDistance"]:
                    source_time, source_cell = active[row]
                    edges.append({"sourceTimeIndex": source_time, "sourceLabelId": source_cell["labelId"],
                                  "targetTimeIndex": target["timeIndex"], "targetLabelId": target["cells"][column]["labelId"],
                                  "distance": float(distances[row, column]), "units": args["units"], "origin": "automatic"})
                    matched.add(int(row))
        active = [endpoint for index, endpoint in enumerate(active) if index not in matched]
        active.extend((target["timeIndex"], cell) for cell in target["cells"])
    record = {"channel": channel, "timeIndices": indices, "edges": edges, "sourceRevision": revision,
              "timeSelection": "explicit" if "timeIndices" in args else "all-analyzed",
              "parameters": {key: args[key] for key in ("maxDistance", "units", "maxGapFrames") if key in args}}
    record["inputFingerprint"] = tracks_fingerprint(image, record)
    record["correctionHistory"] = []
    record["frameReferences"] = [{key: copy.deepcopy(frame[key]) for key in ("timeIndex", "channel", "labelsPath", "labelsHash", "inputFingerprint", "analysisRevision", "measurementRevision")} for frame in frames]
    record["sourcePath"], record["sourceHash"] = image["sourcePath"], image["sourceHash"]
    build_track_observations(image, record)
    records = image.setdefault("volumeTracks", [])
    records[:] = [item for item in records if item["channel"] != channel] + [record]
    return describe_tracks(image, channel)


def edit_track(store, image, operation, args, revision):
    channel = args["channel"]
    if args["sourceTimeIndex"] >= args["targetTimeIndex"]:
        fail("invalid-link", "Tracks link strictly forward in time.")
    cells = []
    for prefix in ("source", "target"):
        frame = current_frame(store, image, args[prefix + "TimeIndex"], channel)
        cell = next((cell for cell in frame["cells"] if cell["labelId"] == args[prefix + "LabelId"]), None)
        if cell is None:
            fail("invalid-labels", "A track link references an unavailable volume object.")
        cells.append(cell)
    record = get_tracks(image, channel)
    if record is None:
        if operation == "tracks.unlink":
            fail("track-not-found", "No saved track exists.")
        record = {"channel": channel, "timeIndices": sorted({frame["timeIndex"] for frame in image.get("volumeFrames", [])
                                                            if frame["channel"] == channel}),
                  "edges": [], "parameters": {"units": "voxel"}, "timeSelection": "all-analyzed"}
        image.setdefault("volumeTracks", []).append(record)
        record["inputFingerprint"] = tracks_fingerprint(image, record)
    if record["inputFingerprint"] != tracks_fingerprint(image, record):
        fail("stale-tracks", "Tracking inputs changed. Recompute tracks before editing links.")
    record["timeIndices"] = sorted(set(record["timeIndices"]) | {args["sourceTimeIndex"], args["targetTimeIndex"]})
    record["inputFingerprint"] = tracks_fingerprint(image, record)
    keys = ("sourceTimeIndex", "sourceLabelId", "targetTimeIndex", "targetLabelId")
    matching = [edge for edge in record["edges"] if all(edge[key] == args[key] for key in keys)]
    if operation == "tracks.unlink":
        if not matching:
            fail("track-not-found", "The requested correspondence does not exist.")
        record["edges"] = [edge for edge in record["edges"] if edge not in matching]
    else:
        if any((edge["sourceTimeIndex"], edge["sourceLabelId"]) == (args["sourceTimeIndex"], args["sourceLabelId"]) or
               (edge["targetTimeIndex"], edge["targetLabelId"]) == (args["targetTimeIndex"], args["targetLabelId"])
               for edge in record["edges"]):
            fail("link-conflict", "An object already has an incoming or outgoing link. Unlink it explicitly first.")
        distance = math.sqrt(sum((cells[1][key] - cells[0][key]) ** 2 for key in ("cx", "cy", "cz")))
        record["edges"].append({**{key: args[key] for key in keys}, "distance": distance,
                                "units": "voxel", "origin": "manual"})
    if "correctionHistory" in record:
        record["correctionHistory"].append({"operation": operation, "arguments": {key: args[key] for key in keys}, "revision": revision})
        if len(record["correctionHistory"]) > 1000:
            fail("track-correction-limit", "This tracker retains at most 1,000 manual corrections; create an explicit new baseline before continuing.")
    record["sourceRevision"] = revision
    build_track_observations(image, record)
    return describe_tracks(image, channel)


def inspect(image):
    return {"imageId": image["id"], "dimensions": dimensions(image), "timeCount": image.get("timeCount", 1),
            "channels": image["channels"], "voxelSizeUm": calibration(image),
            "timeStepSeconds": image.get("timeStepSeconds"),
            "frames": [{**{key: frame[key] for key in
                          ("timeIndex", "channel", "analysisRevision", "measurementRevision", "parameters", "inputFingerprint")},
                        "cellCount": len(frame["cells"])} for frame in image.get("volumeFrames", [])],
            "tracks": {"status": "none" if not image.get("volumeTracks") else
                       "stale" if any(describe_tracks(image, item["channel"])["status"] == "stale"
                                      for item in image["volumeTracks"]) else "current"},
            "limits": {"scientificVoxels": MAX_VOLUME_VOXELS, "displayDimension": MAX_DISPLAY_DIMENSION}}


def summary(document):
    frames = []
    for image in document["images"]:
        for frame in image.get("volumeFrames", []):
            cells = frame["cells"]
            calibrated = all(calibration(image)[axis] is not None for axis in "xyz")
            frames.append({"imageId": image["id"], "name": image["name"], "timeIndex": frame["timeIndex"],
                           "channel": frame["channel"], "cellCount": len(cells),
                           "voxelCount": sum(cell["voxelCount"] for cell in cells),
                           "volumeUm3": sum(cell["volumeUm3"] for cell in cells) if calibrated else None,
                           "analysisRevision": frame["analysisRevision"], "measurementRevision": frame["measurementRevision"]})
    return {"sourceRevision": document["revision"], "dimension": 3, "frameCount": len(frames),
            "cellCount": sum(frame["cellCount"] for frame in frames), "frames": frames,
            "aggregation": "descriptive-per-frame; time points are not biological replicates"}


def execute(store, image, operation, args, revision):
    """Execute an operation inside a caller-owned document snapshot."""
    if operation == "volume.inspect":
        return inspect(image)
    if operation == "volume.calibration.set":
        recalibrate(store, image, args, revision)
        return inspect(image)
    if operation == "tracks.get":
        if not 0 <= args["channel"] < image["channels"]:
            fail("channel-unavailable", "Selected channel is unavailable.")
        return describe_tracks(image, args["channel"])
    if operation == "tracks.run":
        return run_tracks(store, image, args, revision)
    if operation in ("tracks.link", "tracks.unlink"):
        return edit_track(store, image, operation, args, revision)
    time_index, channel = args["timeIndex"], args["channel"]
    selection(image, time_index, channel)
    if operation == "volume.measurements.get":
        return result(image, current_frame(store, image, time_index, channel))
    raw = load_source(store, image, time_index, channel)
    frame = get_frame(image, time_index, channel, required=False)
    if operation in ("volume.display", "volume.slice"):
        labels = None
        if frame is not None and args.get("includeLabels", True) and (operation != "volume.slice" or args.get("includeContours", True)):
            current_frame(store, image, time_index, channel, verify=False)
            labels = read_labels(store, image, frame)
        value = (display(raw, labels, image, time_index, channel, args.get("maxDimension", 128))
                 if operation == "volume.display" else slice_result(raw, labels, image, args))
        if frame is not None:
            value["analysisRevision"] = frame["analysisRevision"]
        return value
    if operation.startswith("volume.analysis."):
        import _workbench_support as support
        params = parameters(args.get("parameters"))
        valid = support.load(store, image, raw.shape)
        labels, stats = segment(raw, params, valid)
        if operation == "volume.analysis.run":
            return result(image, save_frame(store, image, raw, labels, params, time_index, channel, revision, stats))
        cells = measure(labels, raw, calibration(image))
        return {"imageId": image["id"], "timeIndex": time_index, "channel": channel,
                "cells": cells, "cellCount": len(cells), "parameters": params,
                "voxelSizeUm": calibration(image), "dimensions": dimensions(image), "imageStats": stats,
                "validSupport": support.summary(image, valid, raw.shape),
                "coordinateSpace": "voxel-edges", "intensityUnits": "processed-source" if image.get("derivation") else "raw-source",
                "display": display(raw, labels, image, time_index, channel),
                "overlayDataUrl": imaging.preview_data(raw[raw.shape[0] // 2], labels[raw.shape[0] // 2], max_size=args.get("maxSize", 768))["dataUrl"]}
    frame = current_frame(store, image, time_index, channel, verify=False)
    if operation == "volume.mask.edit":
        labels = edit_labels(read_labels(store, image, frame), args)
        return result(image, save_frame(store, image, raw, labels, frame["parameters"], time_index, channel, revision))
    if operation == "volume.mask.undo":
        if not frame.get("undoStack"):
            fail("nothing-to-undo", "No prior volume mask is available.")
        previous = frame["undoStack"].pop()
        labels = read_labels(store, image, previous)
        return result(image, save_frame(store, image, raw, labels, previous["parameters"], time_index, channel,
                                        revision, previous["imageStats"], undo=False))
    fail("unknown-operation", "Unknown volume operation.")


# Schema discovery imports this module while imaging itself is initializing.
# Define the operation catalogue before binding the lazy numerical helpers so
# importing either module directly has the same behavior as dispatcher imports.
import _workbench_imaging as imaging
