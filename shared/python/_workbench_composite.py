"""Display-only, supported multi-channel mixing from one decoded acquisition."""
from __future__ import annotations

import base64
import copy
import io
import math
import re

ENGINE_VERSION = "composite-1"
MAX_CHANNELS = 8
MAX_SIZE = 2048
MAX_DIMENSION = 128
RANGE_CHUNK_SAMPLES = 1_000_000
DISPLAY_CHUNK_ROWS = 128
DEFAULT_COLORS = ["#00FF00", "#FF00FF", "#00BFFF", "#FF8000",
                  "#FFFF00", "#FF0000", "#00FFFF", "#FFFFFF"]


def argument_schema():
    from _workbench_schema import _ID, _object
    from _workbench_display_presets import reference_schema
    channel = _object({
        "channel": {"type": "integer", "minimum": 0, "maximum": 31,
                    "title": "Source channel", "description": "Zero-based source channel."},
        "color": {"type": "string", "minLength": 7, "maxLength": 7,
                  "pattern": "^#[0-9a-fA-F]{6}$", "title": "Display color"},
        "enabled": {"type": "boolean", "default": True, "title": "Show channel"},
        "lower": {"type": "number", "title": "Lower display limit",
                  "description": "Source-intensity units. Supply both limits, or omit both for supported min/max."},
        "upper": {"type": "number", "title": "Upper display limit",
                  "description": "Source-intensity units; must be greater than the lower limit."},
        "gamma": {"type": "number", "minimum": .05, "maximum": 20, "default": 1,
                  "title": "Gamma", "description": "Display intensity is normalized intensity raised to 1/gamma; values above one brighten midtones."},
        "opacity": {"type": "number", "minimum": 0, "maximum": 1, "default": 1,
                    "title": "Channel contribution", "description": "Multiplier before additive color mixing."},
    }, ["channel", "color"])
    return _object({
        "imageId": _ID,
        "target": {"type": "string", "enum": ["plane", "volume"], "default": "plane"},
        "sourceParameters": _object({
            "zProjection": {"type": "string", "enum": ["max", "mean", "middle"], "default": "max"},
        }),
        "timeIndex": {"type": "integer", "minimum": 0, "maximum": 64000000,
                      "description": "Required for volume display; zero-based."},
        "plane": {"type": "string", "enum": ["xy", "xz", "yz"],
                  "description": "Required for volume display."},
        "index": {"type": "integer", "minimum": 0, "maximum": 64000000,
                  "description": "Required for volume display; zero-based slice along the normal axis."},
        "channels": {"type": "array", "items": channel, "minItems": 1, "maxItems": MAX_CHANNELS},
        "maxSize": {"type": "integer", "minimum": 64, "maximum": MAX_SIZE, "default": 768},
        "presetRef": reference_schema(),
    }, ["imageId", "channels"])


def volume_argument_schema():
    from _workbench_schema import _ID, _object
    from _workbench_display_presets import reference_schema
    return _object({
        "imageId": _ID,
        "timeIndex": {"type": "integer", "minimum": 0, "maximum": 64000000,
                      "description": "Explicit zero-based acquisition time point."},
        "channels": argument_schema()["properties"]["channels"],
        "maxDimension": {"type": "integer", "minimum": 16, "maximum": MAX_DIMENSION, "default": 128,
                         "description": "Largest display-grid dimension; full-resolution scientific voxels remain unchanged."},
        "labelChannel": {"type": "integer", "minimum": 0, "maximum": 31,
                         "description": "Optionally include current saved labels for this channel at the selected time. No labels are inferred."},
        "presetRef": reference_schema(),
    }, ["imageId", "timeIndex", "channels"])


def operations():
    from _workbench_schema import _object, _op
    return [
        _op("image.composite.catalogue", "Describe display-only channel mixing controls and bounds.",
            _object(), project=False),
        _op("image.composite.preview",
            "Render a bounded multi-channel fluorescence display without changing source pixels, masks or analysis settings.",
            argument_schema()),
        _op("image.composite.volume",
            "Read a bounded true 3D RGBA channel composite and optional current labels without changing scientific data.",
            volume_argument_schema()),
    ]


def catalogue():
    return {
        "engineVersion": ENGINE_VERSION, "argumentSchema": argument_schema(),
        "volumeArgumentSchema": volume_argument_schema(),
        "defaultColors": list(DEFAULT_COLORS),
        "limits": {"channels": MAX_CHANNELS, "maxSize": MAX_SIZE, "maxDimension": MAX_DIMENSION,
                   "sourceChannels": 32, "planePixels": 16000000,
                   "volumeVoxels": 8000000, "decodeBytes": 256 * 1024 * 1024},
        "notes": [
            "Display controls do not change source intensities, scientific selectors, masks or measurements.",
            "Automatic limits are the exact minimum and maximum of acquired, supported samples in the selected plane.",
            "The selected plane is sampled at display-pixel centers with nearest-neighbor sampling; scientific pixels remain full resolution.",
            "Gamma is normalized intensity raised to 1/gamma; gamma above one brightens midtones.",
            "Channel RGB contributions are added, then clipped to the display range. Unsupported pixels are transparent.",
        ],
    }


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def _settings(image, arguments):
    from _workbench_schema import validate_value
    import _workbench_volume as volume
    validate_value(arguments, argument_schema())
    target = arguments.get("target", "plane")
    if arguments["imageId"] != image["id"]:
        fail("image-mismatch", "The composite request does not match the selected image.")
    if target == "plane":
        if any(key in arguments for key in ("timeIndex", "plane", "index")):
            fail("invalid-arguments", "Plane composites use sourceParameters.zProjection. Use target volume for an explicit time and orthogonal slice.")
        if image.get("timeCount", 1) != 1:
            fail("unsupported-time-selection", "Choose target volume with an explicit timeIndex, plane and index for this time series.")
        projection = arguments.get("sourceParameters", {}).get("zProjection", "max")
        selection = {"target": "plane", "sourceParameters": {"zProjection": projection}}
    else:
        missing = [key for key in ("timeIndex", "plane", "index") if key not in arguments]
        if missing:
            fail("invalid-arguments", "Volume composites require explicit timeIndex, plane and index.", {"missing": missing})
        if "sourceParameters" in arguments:
            fail("invalid-arguments", "Volume composites use an exact orthogonal slice; omit sourceParameters.")
        selection = {"target": "volume", **{key: arguments[key] for key in ("timeIndex", "plane", "index")}}
        volume.selection(image, arguments["timeIndex"], 0)
        count = {"xy": image.get("zCount", 1), "xz": image["height"], "yz": image["width"]}[arguments["plane"]]
        if arguments["index"] >= count:
            fail("slice-unavailable", "Choose a slice inside the selected volume.", {"sliceCount": count})
    return selection, _channel_settings(image, arguments["channels"])


def _channel_settings(image, supplied):
    channels = []
    seen = set()
    for item in supplied:
        channel = item["channel"]
        if channel in seen:
            fail("invalid-arguments", "Include each source channel at most once in a composite.", {"channel": channel})
        seen.add(channel)
        if channel >= image["channels"]:
            fail("channel-unavailable", "The selected composite channel is unavailable.",
                 {"channel": channel, "channels": image["channels"]})
        if not re.fullmatch(r"#[0-9a-fA-F]{6}", item["color"]):
            fail("invalid-arguments", "Display colors must use six hexadecimal digits, for example #00FF00.")
        if ("lower" in item) != ("upper" in item):
            fail("invalid-arguments", "Supply both lower and upper display limits, or omit both for an automatic window.")
        if "lower" in item and item["lower"] >= item["upper"]:
            fail("invalid-arguments", "The upper display limit must be greater than the lower limit.")
        channels.append({"channel": channel, "color": item["color"].upper(),
                         "enabled": item.get("enabled", True), "gamma": item.get("gamma", 1),
                         "opacity": item.get("opacity", 1),
                         **{key: item[key] for key in ("lower", "upper") if key in item}})
    return channels


def _range(array, mask, np):
    """Exact finite supported range, without flattening noncontiguous volumes."""
    low, high = math.inf, -math.inf
    operands = [array] if mask is None else [array, mask]
    iterator = np.nditer(operands, flags=["external_loop", "buffered"],
                         op_flags=[["readonly"] for _ in operands],
                         buffersize=RANGE_CHUNK_SAMPLES, order="C")
    for block in iterator:
        values = block if mask is None else block[0][block[1]]
        if not values.size:
            continue
        if not np.isfinite(values).all():
            fail("invalid-pixels", "Composite display requires finite intensities in acquired supported samples.")
        low = min(low, float(values.min()))
        high = max(high, float(values.max()))
    if low == math.inf:
        fail("no-valid-support", "The selected source has no acquired supported samples.")
    return low, high


def _effective_window(item, raw, mask, count, np):
    low, high = _range(raw, mask, np)
    manual = "lower" in item
    lower, upper = (float(item["lower"]), float(item["upper"])) if manual else (low, high)
    return {**item, "lower": lower, "upper": upper,
            "windowMode": "manual" if manual else "auto", "constantRange": upper == lower,
            "sourceRange": [low, high], "supportedSamples": count}


def _mix_samples(destination, samples, acquired, settings, np):
    """Shared planar/volumetric contrast and additive color calculation in place."""
    lower, upper = settings["lower"], settings["upper"]
    if not settings["enabled"] or settings["opacity"] == 0 or settings["constantRange"]:
        return
    if acquired is not None:
        samples[~acquired] = lower
    np.clip(samples, lower, upper, out=samples)
    span = upper - lower
    if math.isfinite(span):
        samples -= lower
        samples /= span
    else:
        samples *= .5
        samples -= lower * .5
        samples /= upper * .5 - lower * .5
    np.clip(samples, 0, 1, out=samples)
    np.power(samples, 1 / settings["gamma"], out=samples)
    for component, start in enumerate((1, 3, 5)):
        contribution = int(settings["color"][start:start + 2], 16) / 255 * settings["opacity"]
        if contribution:
            destination[..., component] += samples * contribution


def _rgba(mixed, display_mask, np):
    np.clip(mixed, 0, 1, out=mixed)
    mixed *= 255
    np.rint(mixed, out=mixed)
    rgba = np.empty((*mixed.shape[:-1], 4), dtype=np.uint8)
    rgba[..., :3] = mixed.astype(np.uint8)
    rgba[..., 3] = 255
    if display_mask is not None:
        rgba[~display_mask] = 0
    return rgba


def _decode(store, image):
    import _workbench_imaging as imaging
    path = store.verify_artifact(image["sourcePath"], image["sourceHash"])
    source, metadata = imaging.load_array(path)
    if (metadata["axes"] != image["axes"] or metadata["shape"] != image["shape"]
            or metadata["channels"] != image["channels"]):
        fail("source-changed", "Source axes or dimensions differ from the imported acquisition.")
    return source, metadata


def _support_metadata(image, mask, shape, axes, scale):
    import _workbench_support as support
    count = int(mask.sum()) if mask is not None else math.prod(shape)
    total = math.prod(shape)
    value = support.descriptor(image)
    pixel_area = scale[axes[0]] * scale[axes[1]] if all(scale[key] is not None for key in axes) else None
    return {
        "present": value is not None, "validPixelCount": count, "invalidPixelCount": total - count,
        "totalSampleCount": total, "shape": list(shape), "fraction": count / total,
        "sha256": value["hash"] if value else None, "policy": value.get("policy") if value else None,
        "areaUm2": count * pixel_area if pixel_area is not None else None,
        "displayAxes": list(axes), "invalidDisplay": "transparent",
        "notes": ["Unsupported samples do not contribute to channel windows or colors."] if value else [],
    }


def render(store, image, arguments, *, document=None):
    """Return the exact shared bounded RGBA rendering and serializable provenance."""
    import _workbench_imaging as imaging
    import _workbench_support as support
    import _workbench_volume as volume
    np, = imaging.require("numpy")
    imaging.require("PIL")
    from PIL import Image
    import _workbench_display_presets as presets

    selection, channels = _settings(image, arguments)
    binding = presets.bind_render(document, image, arguments, "plane")
    # The acquisition is decoded only once, then channel views are consumed sequentially.
    source, metadata = _decode(store, image)
    scale = volume.calibration(image)
    target = selection["target"]
    if target == "plane":
        shape = (image["height"], image["width"])
        mask = support.load(store, image, shape, selection["sourceParameters"])
        axes = ("x", "y")
        slice_metadata = {}
    else:
        raw_shape = (image.get("zCount", 1), image["height"], image["width"])
        full_mask = support.load(store, image, raw_shape)
        plane, index = selection["plane"], selection["index"]
        mask = volume.plane_array(full_mask, plane, index) if full_mask is not None else None
        shape = {"xy": raw_shape[1:], "xz": (raw_shape[0], raw_shape[2]),
                 "yz": raw_shape[:2]}[plane]
        axes = {"xy": ("x", "y"), "xz": ("x", "z"), "yz": ("y", "z")}[plane]
        slice_count = {"xy": raw_shape[0], "xz": raw_shape[1], "yz": raw_shape[2]}[plane]
        slice_metadata = {"plane": plane, "index": index, "sliceCount": slice_count,
                          "timeIndex": selection["timeIndex"]}
    valid = _support_metadata(image, mask, shape, axes, scale)
    if valid["validPixelCount"] == 0:
        fail("no-valid-support", "This selected plane has no acquired supported pixels. Choose another slice.")
    maximum = arguments.get("maxSize", 768)
    factor = min(1., maximum / max(shape))
    height, width = max(1, int(round(shape[0] * factor))), max(1, int(round(shape[1] * factor)))
    ys = np.minimum(((np.arange(height) + .5) * shape[0] / height).astype(np.intp), shape[0] - 1)
    xs = np.minimum(((np.arange(width) + .5) * shape[1] / width).astype(np.intp), shape[1] - 1)
    display_mask = mask[np.ix_(ys, xs)] if mask is not None else None
    mixed = np.zeros((height, width, 3), dtype=np.float32)
    effective = []
    for item in channels:
        if target == "plane":
            raw = imaging.plane_from_array(
                source, metadata, {"channel": item["channel"], **selection["sourceParameters"]},
                validate_finite=False)
        else:
            raw_volume = volume.load_source(store, image, selection["timeIndex"], item["channel"],
                                            source=(source, metadata), validate_finite=False)
            raw = volume.plane_array(raw_volume, selection["plane"], selection["index"])
        settings = _effective_window(item, raw, mask, valid["validPixelCount"], np)
        effective.append(settings)
        if settings["enabled"] and settings["opacity"] > 0 and not settings["constantRange"]:
            for row in range(0, height, DISPLAY_CHUNK_ROWS):
                stop = min(row + DISPLAY_CHUNK_ROWS, height)
                samples = np.asarray(raw[np.ix_(ys[row:stop], xs)], dtype=np.float64)
                acquired = display_mask[row:stop] if display_mask is not None else None
                _mix_samples(mixed[row:stop], samples, acquired, settings, np)
        del raw
        if target == "volume":
            del raw_volume
    rgba = _rgba(mixed, display_mask, np)
    notes = catalogue()["notes"]
    if any(item["constantRange"] for item in effective):
        notes.append("Channels with a constant automatic intensity range contribute black; explicit display limits can expose constant intensity.")
    if not any(item["enabled"] and item["opacity"] > 0 for item in effective):
        notes.append("All channel contributions are disabled; acquired samples are displayed as black.")
    result = {
        "engineVersion": ENGINE_VERSION, "imageId": image["id"], "target": target,
        "displayOnly": True, "selection": selection, "channels": effective,
        "sourceHash": image["sourceHash"], "sourceAxes": image["axes"], "sourceShape": copy.deepcopy(image["shape"]),
        "sourceDtype": image["dtype"], "intensityUnits": "processed-source" if image.get("derivation") else "raw-source",
        "width": shape[1], "height": shape[0], "previewWidth": width, "previewHeight": height,
        "voxelSizeUm": scale, "spacingUm": {"x": scale[axes[0]], "y": scale[axes[1]]},
        "timeStepSeconds": image.get("timeStepSeconds"), "validSupport": valid,
        "displayTransform": {"scale": [shape[1] / width, shape[0] / height], "offset": [0, 0],
                             "coordinateConvention": "pixel-edges", "sampling": "nearest-source-center"},
        **slice_metadata, **(binding or {}), "notes": notes,
    }
    if image.get("sourceRegion"):
        result["sourceRegion"] = copy.deepcopy(image["sourceRegion"])
    return Image.fromarray(rgba, "RGBA"), result


def preview(store, image, arguments, *, document=None):
    picture, result = render(store, image, arguments, document=document)
    encoded = io.BytesIO()
    picture.save(encoded, format="PNG")
    return {**result, "dataUrl": "data:image/png;base64," + base64.b64encode(encoded.getvalue()).decode("ascii")}


def volume_display(store, image, arguments, *, document=None):
    """Return true bounded voxel colors, with optional current authoritative labels."""
    from _workbench_schema import validate_value
    import _workbench_imaging as imaging
    import _workbench_support as support
    import _workbench_volume as volume
    import _workbench_display_presets as presets
    np, = imaging.require("numpy")
    validate_value(arguments, volume_argument_schema())
    if arguments["imageId"] != image["id"]:
        fail("image-mismatch", "The composite request does not match the selected image.")
    time_index = arguments["timeIndex"]
    volume.selection(image, time_index, 0)
    channels = _channel_settings(image, arguments["channels"])
    binding = presets.bind_render(document, image, arguments, "volume")
    label_channel = arguments.get("labelChannel")
    frame = None
    label_status = "not-requested"
    if label_channel is not None:
        volume.selection(image, time_index, label_channel)
        frame = volume.get_frame(image, time_index, label_channel, required=False)
        label_status = "absent" if frame is None else "current"
        if frame is not None:
            # Check currentness before decoding; the labels are verified when read below.
            frame = volume.current_frame(store, image, time_index, label_channel, verify=False)

    source, metadata = _decode(store, image)
    original = volume.dimensions(image)
    shape = tuple(reversed(original))
    mask = support.load(store, image, shape)
    supported = int(mask.sum()) if mask is not None else math.prod(shape)
    if supported == 0:
        fail("no-valid-support", "This volume has no acquired supported voxels.")
    maximum = arguments.get("maxDimension", 128)
    ratio = min(1., maximum / max(original))
    dimensions = [max(1, int(math.floor(size * ratio))) for size in original]
    scale = [size / count for size, count in zip(original, dimensions)]
    offset = [(value - 1) / 2 for value in scale]
    nearest = [np.floor(np.arange(dimensions[axis], dtype=np.float64) * scale[axis]
                        + offset[axis] + .5).astype(np.intp).clip(0, original[axis] - 1)
               for axis in (2, 1, 0)]
    display_shape = tuple(reversed(dimensions))
    display_mask = mask[np.ix_(*nearest)] if mask is not None else None
    mixed = np.zeros((*display_shape, 3), dtype=np.float32)
    effective = []
    for item in channels:
        raw = volume.load_source(store, image, time_index, item["channel"],
                                 source=(source, metadata), validate_finite=False)
        settings = _effective_window(item, raw, mask, supported, np)
        effective.append(settings)
        if settings["enabled"] and settings["opacity"] > 0 and not settings["constantRange"]:
            for start in range(0, display_shape[0], 16):
                stop = min(start + 16, display_shape[0])
                samples = np.asarray(raw[np.ix_(nearest[0][start:stop], nearest[1], nearest[2])], dtype=np.float64)
                acquired = display_mask[start:stop] if display_mask is not None else None
                _mix_samples(mixed[start:stop], samples, acquired, settings, np)
        del raw
    rgba = _rgba(mixed, display_mask, np)
    del mixed
    voxel_size = volume.calibration(image)
    physical_volume = (supported * math.prod(voxel_size.values())
                       if all(value is not None for value in voxel_size.values()) else None)
    support_descriptor = support.descriptor(image)
    notes = [
        "This RGBA buffer contains true sampled 3D voxels; it is not a projection or scientific source image.",
        "Automatic channel windows use all acquired supported voxels at the selected time. Slice previews use their own selected-plane windows.",
        "Gamma is normalized intensity raised to 1/gamma; RGB contributions are added and clipped to the display range.",
        "RGBA colors and optional labels use identical nearest source-center sampling. Thin structures may be absent from the bounded display.",
        "Alpha is 255 for acquired samples and zero outside support; color brightness and ray-marching opacity are display controls.",
        "The compatibility channel field is a display anchor only; this operation never changes the scientific channel selection.",
    ]
    if any(item["constantRange"] for item in effective):
        notes.append("Channels with constant automatic ranges contribute black; explicit limits can display constant intensity.")
    if not any(item["enabled"] and item["opacity"] > 0 for item in effective):
        notes.append("All channel contributions are disabled; acquired voxels are black.")
    result = {
        "engineVersion": ENGINE_VERSION, "displayOnly": True, "displayKind": "composite",
        "components": 4, "componentOrder": "rgba", "encoding": "base64", "dtype": "uint8", "order": "zyx",
        "dataBase64": base64.b64encode(rgba.tobytes(order="C")).decode("ascii"),
        "imageId": image["id"], "timeIndex": time_index,
        "channel": label_channel if label_channel is not None else channels[0]["channel"],
        "selection": {"target": "volume", "timeIndex": time_index},
        "channels": effective, "labelChannel": label_channel, "labelStatus": label_status,
        "dimensions": dimensions, "originalDimensions": original,
        "transform": {"scale": scale, "offset": offset}, "sampling": "nearest-source-center",
        "voxelSizeUm": voxel_size, "timeStepSeconds": image.get("timeStepSeconds"),
        "displayRange": [0, 255], "displayUnits": "normalized-display",
        "sourceHash": image["sourceHash"], "sourceAxes": image["axes"],
        "sourceShape": copy.deepcopy(image["shape"]), "sourceDtype": image["dtype"],
        "intensityUnits": "processed-source" if image.get("derivation") else "raw-source",
        "validSupport": {
            "present": support_descriptor is not None, "validVoxelCount": supported,
            "invalidVoxelCount": math.prod(shape) - supported, "totalSampleCount": math.prod(shape),
            "shape": list(shape), "fraction": supported / math.prod(shape), "volumeUm3": physical_volume,
            "sha256": support_descriptor["hash"] if support_descriptor else None,
            "policy": support_descriptor.get("policy") if support_descriptor else None,
            "invalidDisplay": "transparent", "displaySupportedVoxels": int(display_mask.sum()) if display_mask is not None else math.prod(display_shape),
        },
        **(binding or {}), "notes": notes,
    }
    if image.get("sourceRegion"):
        result["sourceRegion"] = copy.deepcopy(image["sourceRegion"])
    if frame is not None:
        labels = volume.read_labels(store, image, frame)
        sampled_labels = np.asarray(labels[np.ix_(*nearest)], dtype="<u4")
        if display_mask is not None:
            sampled_labels[~display_mask] = 0
        result.update({
            "labelDataBase64": base64.b64encode(sampled_labels.tobytes(order="C")).decode("ascii"),
            "labelDtype": "uint32-le",
            "labelSource": {"channel": label_channel, "timeIndex": time_index,
                            **{key: frame[key] for key in ("labelsHash", "analysisRevision", "measurementRevision", "inputFingerprint")}},
        })
    return result
