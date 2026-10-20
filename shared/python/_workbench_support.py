"""Authoritative valid-sample support for derived scientific acquisitions."""
from __future__ import annotations

import copy
import io
import math


def descriptor(image):
    return image.get("validSupport") or image.get("derivation", {}).get("validSupport")


def fingerprint(image):
    value = descriptor(image)
    return ({key: copy.deepcopy(value[key]) for key in ("path", "hash", "shape", "policy") if key in value}
            if value else None)


def load(store, image, shape=None, parameters=None):
    from _workbench_imaging import require
    from _workbench_schema import WorkbenchError
    np, = require("numpy")
    value = descriptor(image)
    if not value:
        return None
    path = store.verify_artifact(value["path"], value["hash"])
    if path.stat().st_size > 16_000_000 + 65536:
        raise WorkbenchError("invalid-support", "The valid-support mask exceeds its allocation bound.")
    mask = np.load(path, mmap_mode="r", allow_pickle=False)
    if mask.dtype != np.uint8 or mask.ndim not in (2, 3) or list(mask.shape) != value["shape"]:
        raise WorkbenchError("invalid-support", "The retained support mask has invalid shape or dtype.")
    if np.any(mask > 1):
        raise WorkbenchError("invalid-support", "Support samples must be exactly zero or one.")
    mask = np.asarray(mask, dtype=bool)
    if shape is not None and tuple(mask.shape) != tuple(shape):
        if mask.ndim == 2 and len(shape) == 3 and shape[0] == 1 and tuple(mask.shape) == tuple(shape[1:]):
            mask = mask[None, ...]
        elif mask.ndim == 3 and len(shape) == 2 and tuple(mask.shape[1:]) == tuple(shape):
            projection = (parameters or {}).get("zProjection", "max")
            mask = mask[mask.shape[0] // 2] if projection == "middle" else mask.all(axis=0)
        else:
            raise WorkbenchError("invalid-support", "Valid-support geometry differs from the selected source.")
    if not mask.any():
        raise WorkbenchError("no-valid-support", "No acquired samples remain in this derived image.")
    return mask


def summary(image, mask=None, shape=None):
    from _workbench_volume import calibration
    value = descriptor(image)
    if mask is not None:
        shape = mask.shape
        count = int(mask.sum())
    elif value:
        shape = value["shape"]
        count = value["validPixelCount"]
    else:
        shape = shape or (image["height"], image["width"])
        count = math.prod(shape)
    total = math.prod(shape)
    scale = calibration(image)
    axes = "xy" if len(shape) == 2 else "xyz"
    calibrated = all(scale[axis] is not None for axis in axes)
    return {"present": value is not None, "validPixelCount": count, "invalidPixelCount": total - count,
            "validVoxelCount": count, "totalSampleCount": total, "shape": list(shape),
            "fraction": count / total, "fingerprint": fingerprint(image),
            "areaUm2": count * scale["x"] * scale["y"] if len(shape) == 2 and calibrated else None,
            "volumeUm3": count * math.prod(scale[axis] for axis in axes) if len(shape) == 3 and calibrated else None,
            "notes": ["Only supported acquired samples contribute to scientific measurements; filled samples are excluded."]
            if value else []}


def clip_labels(store, image, labels, parameters=None):
    from _workbench_imaging import require
    np, = require("numpy")
    mask = load(store, image, labels.shape, parameters)
    info = summary(image, mask, labels.shape)
    clipped = 0
    affected = []
    removed = 0
    if mask is not None:
        outside = (labels > 0) & ~mask
        clipped = int(outside.sum())
        if clipped:
            affected = list(map(int, np.unique(labels[outside])))
            labels = labels.copy()
            labels[~mask] = 0
            remaining = set(map(int, np.unique(labels))) - {0}
            removed = sum(label not in remaining for label in affected)
    info.update({"clippedPixelCount": clipped, "clippedVoxelCount": clipped,
                 "affectedLabelIds": affected[:1000], "affectedLabelCount": len(affected),
                 "removedLabelCount": removed})
    return labels, info


def refresh_calibration(image, analysis):
    from _workbench_volume import calibration
    info = analysis.get("validSupport")
    if not info:
        return
    scale = calibration(image)
    count = info["validPixelCount"]
    dimensions = len(info["shape"])
    info["areaUm2"] = count * scale["x"] * scale["y"] if dimensions == 2 and all(
        scale[axis] is not None for axis in "xy") else None
    info["volumeUm3"] = count * math.prod(scale[axis] for axis in "xyz") if dimensions == 3 and all(
        scale[axis] is not None for axis in "xyz") else None
    analysis.get("imageStats", {})["validSupport"] = copy.deepcopy(info)


def assert_labels(store, image, labels, parameters=None):
    from _workbench_schema import WorkbenchError
    mask = load(store, image, labels.shape, parameters)
    if mask is not None and ((labels > 0) & ~mask).any():
        raise WorkbenchError("stale-support-analysis", "Saved labels include unsupported fill samples. Recompute the analysis.")
    return mask


def retain(store, mask, provenance=None):
    from _workbench_imaging import require
    from _workbench_schema import WorkbenchError
    np, = require("numpy")
    count = int(mask.sum())
    if not count:
        raise WorkbenchError("no-valid-support", "This processing step leaves no uncontaminated acquired samples.")
    buffer = io.BytesIO()
    np.save(buffer, np.asarray(mask, dtype=np.uint8), allow_pickle=False)
    path, hashed = store.put_bytes(buffer.getvalue(), ".support.npy")
    return {"path": path, "hash": hashed, "shape": list(mask.shape), "dtype": "uint8",
            "validPixelCount": count, "invalidPixelCount": int(mask.size) - count,
            "policy": "exclude-unsupported-samples-v1", "provenance": copy.deepcopy(provenance or {})}


def rectangular_crop(mask):
    """Return a completely supported bounding box, rejecting internal holes."""
    from _workbench_imaging import require
    from _workbench_schema import WorkbenchError
    np, = require("numpy")
    slices = []
    for axis in range(mask.ndim):
        occupied = np.flatnonzero(mask.any(axis=tuple(index for index in range(mask.ndim) if index != axis)))
        if not len(occupied):
            raise WorkbenchError("no-valid-support", "No supported source region remains.")
        slices.append(slice(int(occupied[0]), int(occupied[-1]) + 1))
    region = tuple(slices)
    if not mask[region].all():
        raise WorkbenchError("unsupported-irregular-support", "This algorithm requires one entirely supported rectangle or cuboid.")
    return region


def artifact_references(document):
    refs = {}
    for image in document["images"]:
        value = descriptor(image)
        if value:
            refs[value["path"]] = value["hash"]
    return refs
