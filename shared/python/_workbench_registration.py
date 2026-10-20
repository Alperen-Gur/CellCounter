"""Explicit 2D translation estimation and immutable fixed-grid resampling."""
from __future__ import annotations

from _workbench_indexed import image_capacity

from _workbench_indexed import image_index

import base64
import copy
import hashlib
import io
import math
import uuid

ENGINE_VERSION = "translation-2d-1"
MAX_ESTIMATION_PIXELS = 4_000_000
MAX_PAIR_PIXELS = 24_000_000
MAX_OUTPUT_PIXELS = 16_000_000


def selection_schema():
    from _workbench_schema import _object
    return _object({"channel": {"type": "integer", "minimum": 0, "maximum": 31},
                    "timeIndex": {"type": "integer", "minimum": 0, "maximum": 64000000},
                    "zProjection": {"type": "string", "enum": ["max", "mean", "middle"]}})


def operations():
    from _workbench_schema import _object, _ID, _op
    base = {"fixedImageId": _ID, "movingImageId": _ID,
            "fixedSelection": selection_schema(), "movingSelection": selection_schema()}
    required = ["fixedImageId", "movingImageId"]
    transformed = {**base,
                   "shiftPx": _object({axis: {"type": "number", "minimum": -1000000, "maximum": 1000000}
                                       for axis in "xy"}, ["x", "y"]),
                   "interpolation": {"type": "string", "enum": ["nearest", "linear"]},
                   "fillValue": {"type": "number"},
                   "expectedInputFingerprint": _ID,
                   "maxSize": {"type": "integer", "minimum": 64, "maximum": 2048}}
    return [
        _op("registration.estimate", "Estimate a bounded subpixel 2D translation with phase correlation and report observed overlap quality.",
            _object({**base, "upsampleFactor": {"type": "integer", "minimum": 1, "maximum": 100},
                     "maxShiftPx": {"type": "number", "exclusiveMinimum": 0, "maximum": 1000000},
                     "window": {"type": "string", "enum": ["hann", "none"]}}, required)),
        _op("registration.preview", "Preview explicit moving-to-fixed translation, valid support and red/green overlay without saving.",
            _object(transformed, required + ["shiftPx"])),
        _op("registration.apply", "Save a new fixed-grid TIFF and exact valid-support mask with frozen translation provenance.",
            _object({**transformed, "name": {"type": "string", "minLength": 1, "maxLength": 200}},
                    required + ["shiftPx"]), True),
        _op("registration.inspect", "Inspect saved registration provenance and whether both parent inputs remain current.",
            _object({"imageId": _ID}, ["imageId"])),
    ]


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def digest(value):
    from _workbench_store import canonical
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def selection(image, supplied):
    preferred = image.get("preferredSourceParameters", {})
    result = {"channel": preferred.get("channel", 0), "zProjection": preferred.get("zProjection", "max"),
              "timeIndex": image.get("preferredVolumeSelection", {}).get("timeIndex", 0)}
    result.update(supplied or {})
    if not 0 <= result["channel"] < image["channels"] or not 0 <= result["timeIndex"] < image.get("timeCount", 1):
        fail("invalid-source-selection", "Selected registration channel or time is unavailable.")
    return result


def descriptor(image, chosen):
    import _workbench_volume as volume
    import _workbench_support as support
    return {"imageId": image["id"], "sourcePath": image["sourcePath"], "sourceHash": image["sourceHash"],
            "selection": copy.deepcopy(chosen), "width": image["width"], "height": image["height"],
            "shape": image["shape"], "voxelSizeUm": volume.calibration(image),
            "intensityUnits": "processed-source" if image.get("derivation") else "raw-source",
            **({"sourceRegion": copy.deepcopy(image["sourceRegion"])} if image.get("sourceRegion") else {}),
            **({"validSupport": support.fingerprint(image)} if support.descriptor(image) else {})}


def calibration_status(fixed, moving):
    left, right = fixed["voxelSizeUm"], moving["voxelSizeUm"]
    for axis in "xy":
        if left[axis] is not None and right[axis] is not None and not math.isclose(left[axis], right[axis], rel_tol=1e-6):
            fail("calibration-mismatch", "Translation cannot reconcile different known pixel spacings. Rescale explicitly before registration.",
                 {"axis": axis, "fixedUmPerPixel": left[axis], "movingUmPerPixel": right[axis]})
    complete = all(value[axis] is not None for value in (left, right) for axis in "xy")
    return {"status": "compatible" if complete else "incomplete",
            "notes": ["Output calibration and pixel grid come from the fixed image.",
                      "Only translation is estimated; rotation, scale and deformation are not estimated."] +
            ([] if complete else ["One or more XY spacings are unknown; equal physical sampling has not been established."])}


def inputs(store, document, args, load=True):
    import _workbench_imaging as imaging
    images = image_index(document)
    try:
        fixed_image, moving_image = images[args["fixedImageId"]], images[args["movingImageId"]]
    except KeyError:
        fail("image-not-found", "Both registration images must belong to this project.")
    fixed_selection = selection(fixed_image, args.get("fixedSelection"))
    moving_selection = selection(moving_image, args.get("movingSelection"))
    fixed = descriptor(fixed_image, fixed_selection)
    moving = descriptor(moving_image, moving_selection)
    if fixed["width"] * fixed["height"] > MAX_OUTPUT_PIXELS or sum(
            item["width"] * item["height"] for item in (fixed, moving)) > MAX_PAIR_PIXELS:
        fail("registration-too-large", "Registration supports at most 16 million output pixels and 24 million combined input-plane pixels.")
    calibration = calibration_status(fixed, moving)
    fingerprint = digest({"fixed": fixed, "moving": moving})
    if args.get("expectedInputFingerprint", fingerprint) != fingerprint:
        fail("stale-registration", "The estimated source selection or calibration changed. Estimate again before applying.")
    result = {"fixedImageId": fixed["imageId"], "movingImageId": moving["imageId"],
              "fixedSelection": fixed_selection, "movingSelection": moving_selection,
              "fixed": fixed, "moving": moving, "inputFingerprint": fingerprint, "calibration": calibration,
              "method": "translation-2d",
              "convention": {"positiveX": "moving pixels move right", "positiveY": "moving pixels move down",
                             "sampling": "fixed(x,y) = moving(x - shiftPx.x, y - shiftPx.y)",
                             "coordinates": "pixel-edges; sample centres are index + 0.5"},
              "limits": {"estimationPixels": MAX_ESTIMATION_PIXELS, "outputPixels": MAX_OUTPUT_PIXELS,
                         "combinedInputPixels": MAX_PAIR_PIXELS}}
    if not load:
        return result
    planes = []
    for item in (fixed, moving):
        chosen = item["selection"]
        path = store.verify_artifact(item["sourcePath"], item["sourceHash"])
        plane, _ = imaging.load_plane(path, chosen, time_index=chosen["timeIndex"])
        if plane.shape != (item["height"], item["width"]):
            fail("source-changed", "Registration source dimensions differ from the retained metadata.")
        planes.append(plane)
    return result, planes[0], planes[1]


def _unit_values(values):
    import numpy as np
    low, high = float(values.min()), float(values.max())
    if not math.isfinite(high - low):
        fail("invalid-pixels", "Registration requires a finite source dynamic range.")
    return np.zeros_like(values) if high == low else (values - low) / (high - low)


def resample(moving, shape, shift, interpolation, fill, moving_support=None, fixed_support=None):
    import numpy as np
    from scipy import ndimage
    output = ndimage.affine_transform(moving, np.eye(2), offset=[-shift["y"], -shift["x"]],
                                      output_shape=shape, order=0 if interpolation == "nearest" else 1,
                                      mode="constant", cval=fill, prefilter=False)
    xs = np.arange(shape[1], dtype=np.float64) - shift["x"]
    ys = np.arange(shape[0], dtype=np.float64) - shift["y"]
    valid_x = (xs >= 0) & (xs <= moving.shape[1] - 1)
    valid_y = (ys >= 0) & (ys <= moving.shape[0] - 1)
    valid = valid_y[:, None] & valid_x[None, :]
    if moving_support is not None:
        warped_support = ndimage.affine_transform(moving_support.astype(np.float64), np.eye(2),
                                                  offset=[-shift["y"], -shift["x"]], output_shape=shape,
                                                  order=0 if interpolation == "nearest" else 1,
                                                  mode="constant", cval=0, prefilter=False)
        valid &= warped_support >= 1.0
    if fixed_support is not None:
        valid &= fixed_support
    output[~valid] = fill
    count = int(np.count_nonzero(valid))
    if not count:
        fail("no-registration-overlap", "This translation leaves no valid moving samples in the fixed grid.")
    coordinates_x, coordinates_y = np.flatnonzero(valid.any(axis=0)), np.flatnonzero(valid.any(axis=1))
    support = {"validPixelCount": count, "invalidPixelCount": int(valid.size - count),
               "overlapFraction": count / valid.size,
               "boundsPx": {"x": int(coordinates_x[0]), "y": int(coordinates_y[0]),
                            "width": int(coordinates_x[-1] - coordinates_x[0] + 1),
                            "height": int(coordinates_y[-1] - coordinates_y[0] + 1)},
               "definition": "fixed samples and the entire moving interpolation stencil are supported acquired samples",
               "fillValue": fill, "fillIsMeasuredSource": False}
    return output, valid, support


def input_support(store, document, metadata, fixed_shape, moving_shape):
    import _workbench_support as support
    by_id = image_index(document)
    return (support.load(store, by_id[metadata["fixedImageId"]], fixed_shape, metadata["fixedSelection"]),
            support.load(store, by_id[metadata["movingImageId"]], moving_shape, metadata["movingSelection"]))


def correlation(first, second, valid):
    import numpy as np
    if np.count_nonzero(valid) < 2:
        return None
    a, b = _unit_values(first[valid]), _unit_values(second[valid])
    a -= a.mean()
    b -= b.mean()
    denominator = float(np.sqrt(np.dot(a, a) * np.dot(b, b)))
    return float(np.clip(np.dot(a, b) / denominator, -1, 1)) if denominator > 0 else None


def estimate(store, document, args):
    import _workbench_imaging as imaging
    imaging.require("numpy", "scipy", "skimage")
    import numpy as np
    from skimage.registration import phase_cross_correlation
    metadata = inputs(store, document, args, load=False)
    fixed_descriptor, moving_descriptor = metadata["fixed"], metadata["moving"]
    if (fixed_descriptor["width"], fixed_descriptor["height"]) != (
            moving_descriptor["width"], moving_descriptor["height"]):
        fail("registration-shape-mismatch", "Phase-correlation estimation requires equal plane dimensions; explicit translations can use different grids.")
    if fixed_descriptor["width"] * fixed_descriptor["height"] > MAX_ESTIMATION_PIXELS:
        fail("registration-estimation-too-large", "Phase correlation is bounded to 4 million pixels; extract comparable source regions first.")
    metadata, fixed, moving = inputs(store, document, args)
    fixed_support, moving_support = input_support(store, document, metadata, fixed.shape, moving.shape)
    crop = (slice(None), slice(None))
    support_crop = {"x": 0, "y": 0, "width": fixed.shape[1], "height": fixed.shape[0]}
    if fixed_support is not None or moving_support is not None:
        common = np.ones(fixed.shape, dtype=bool)
        if fixed_support is not None:
            common &= fixed_support
        if moving_support is not None:
            common &= moving_support
        ys, xs = np.flatnonzero(common.any(axis=1)), np.flatnonzero(common.any(axis=0))
        if not len(xs) or not len(ys):
            fail("no-registration-overlap", "Phase correlation requires a common supported source region.")
        crop = (slice(ys[0], ys[-1] + 1), slice(xs[0], xs[-1] + 1))
        if not common[crop].all():
            fail("unsupported-registration-support", "Subpixel phase correlation currently requires a rectangular common support region; use an explicit translation for irregular support.")
        support_crop = {"x": int(xs[0]), "y": int(ys[0]), "width": len(xs), "height": len(ys)}
    reference, candidate = _unit_values(fixed[crop]), _unit_values(moving[crop])
    if float(reference.std()) < 1e-12 or float(candidate.std()) < 1e-12:
        fail("registration-no-texture", "A constant or numerically uniform image does not support translation estimation.")
    reference -= reference.mean()
    candidate -= candidate.mean()
    window = args.get("window", "hann")
    if window == "hann":
        if min(reference.shape) < 3:
            fail("registration-no-texture", "A Hann registration window requires at least three pixels on each axis.")
        rows, columns = np.hanning(reference.shape[0]), np.hanning(reference.shape[1])
        reference *= rows[:, None]
        reference *= columns[None, :]
        candidate *= rows[:, None]
        candidate *= columns[None, :]
    if float(reference.std()) < 1e-12 or float(candidate.std()) < 1e-12:
        fail("registration-no-texture", "The selected window contains no usable registration texture.")
    factor = args.get("upsampleFactor", 10)
    # Bound the local matrix-multiply DFT even for very long, thin inputs.
    if sum(reference.shape) * math.ceil(1.5 * factor) ** 2 > 250000000:
        fail("registration-compute-limit", "Reduce the subpixel upsampling factor for this plane shape.")
    displacement, error, phase = phase_cross_correlation(reference, candidate, upsample_factor=factor,
                                                        normalization="phase")
    shift = {"x": float(displacement[1]), "y": float(displacement[0])}
    if not all(math.isfinite(value) for value in shift.values()):
        fail("registration-failed", "Phase correlation did not produce a finite displacement.")
    maximum = args.get("maxShiftPx", math.hypot(*fixed.shape) / 2)
    if math.hypot(shift["x"], shift["y"]) > maximum:
        fail("registration-shift-limit", "The estimated displacement exceeds the requested maximum.",
             {"estimatedShiftPx": shift, "maxShiftPx": maximum})
    registered, valid, support = resample(moving, fixed.shape, shift, "linear", 0, moving_support, fixed_support)
    before_valid = valid if moving_support is None else valid & moving_support
    quality = {"phaseError": float(error) if math.isfinite(float(error)) else None,
               "phaseDifferenceRad": float(phase) if math.isfinite(float(phase)) else None,
               "correlationBefore": correlation(fixed, moving, before_valid),
               "correlationAfter": correlation(fixed, registered, before_valid),
               "correlationPixelCount": int(before_valid.sum()),
               "validPixelCount": support["validPixelCount"], "overlapFraction": support["overlapFraction"]}
    return {**metadata, "shiftPx": shift, "quality": quality,
            "estimation": {"upsampleFactor": factor, "nominalResolutionPx": 1 / factor,
                           "window": window, "normalization": "phase", "maxShiftPx": maximum},
            "estimationSupport": support_crop,
            "notes": ["A phase-correlation peak is an estimate, not a verified correspondence or confidence probability.",
                      "Periodic or repeated structures can produce ambiguous shifts; the translation is reviewed before saving.",
                      "Reported correlations use the same output support; phase error is the algorithm's normalized error, not a success score."]}


def previews(fixed, moving, valid, maximum):
    import numpy as np
    from PIL import Image
    from _workbench_imaging import preview_data
    def encoded(image):
        image.thumbnail((maximum, maximum), Image.Resampling.LANCZOS)
        buffer = io.BytesIO()
        image.save(buffer, format="PNG")
        return "data:image/png;base64," + base64.b64encode(buffer.getvalue()).decode("ascii")
    # Normalize each source independently for alignment display only. Numeric
    # intensities and the persisted output retain their source units.
    red = np.rint(_unit_values(fixed) * 255).astype(np.uint8)
    green = np.zeros(fixed.shape, dtype=np.uint8)
    green[valid] = np.rint(_unit_values(moving[valid]) * 255).astype(np.uint8)
    rgb = np.stack((red, green, np.zeros_like(red)), axis=-1)
    result = preview_data(moving, max_size=maximum)
    result.update({"fixedDataUrl": preview_data(fixed, max_size=maximum)["dataUrl"],
                   "overlayDataUrl": encoded(Image.fromarray(rgb)),
                   "supportDataUrl": encoded(Image.fromarray(valid.astype(np.uint8) * 255)),
                   "overlayChannels": {"red": "fixed", "green": "registered moving",
                                       "scaling": "independent display ranges; no scientific rescaling"}})
    return result


def inspect(image, document):
    derivation = image.get("derivation", {})
    if derivation.get("kind") != "registration":
        return {"imageId": image["id"], "registered": False}
    registration = derivation["registration"]
    current = {}
    by_id = image_index(document)
    for key in ("fixed", "moving"):
        frozen = registration[key]
        parent = by_id.get(frozen["imageId"])
        current[key] = parent is not None and descriptor(parent, frozen["selection"]) == frozen
    return {"imageId": image["id"], "registered": True, "registration": copy.deepcopy(registration),
            "parentInputsCurrent": all(current.values()), "parentCurrentness": current,
            "validSupport": copy.deepcopy(derivation["validSupport"]), "intensityUnits": "processed-source"}


def artifact_references(document):
    references = {}
    for image in document["images"]:
        derivation = image.get("derivation", {})
        if derivation.get("kind") != "registration":
            continue
        support = derivation["validSupport"]
        references[support["path"]] = support["hash"]
        for key in ("fixed", "moving"):
            frozen = derivation["registration"][key]
            references[frozen["sourcePath"]] = frozen["sourceHash"]
            if frozen.get("validSupport"):
                references[frozen["validSupport"]["path"]] = frozen["validSupport"]["hash"]
    return references


def execute(store, document, operation, args, revision):
    import _workbench_imaging as imaging
    if operation == "registration.inspect":
        image = next((image for image in document["images"] if image["id"] == args["imageId"]), None)
        if image is None:
            fail("image-not-found", "Image is not part of this project.")
        return inspect(image, document)
    if operation == "registration.estimate":
        return estimate(store, document, args)
    imaging.require("numpy", "scipy", "PIL")
    import numpy as np
    metadata, fixed, moving = inputs(store, document, args)
    fixed_support, moving_support = input_support(store, document, metadata, fixed.shape, moving.shape)
    shift = copy.deepcopy(args["shiftPx"])
    interpolation = args.get("interpolation", "linear")
    fill = args.get("fillValue", 0)
    result, valid, support = resample(moving, fixed.shape, shift, interpolation, fill, moving_support, fixed_support)
    if not np.isfinite(result).all():
        fail("invalid-pixels", "Registration produced non-finite pixels; no image was saved.")
    registration = {**metadata, "engineVersion": ENGINE_VERSION, "shiftPx": shift,
                    "interpolation": interpolation, "fillValue": fill,
                    "outputGrid": {"width": fixed.shape[1], "height": fixed.shape[0],
                                   "voxelSizeUm": {**metadata["fixed"]["voxelSizeUm"], "z": None}},
                    "intensityUnits": "processed-source", "resampled": True,
                    "quality": {"correlationAfter": correlation(fixed, result, valid),
                                "validPixelCount": support["validPixelCount"],
                                "overlapFraction": support["overlapFraction"]}}
    if operation == "registration.preview":
        return {**registration, "validSupport": support,
                **previews(fixed, result, valid, args.get("maxSize", 768))}
    if len(document["images"]) >= image_capacity(document):
        fail("project-too-large", "A project can retain at most 1,000 image identities.")
    from _workbench_store import utc_now
    tifffile, = imaging.require("tifffile")
    tiff_metadata = {"axes": "YX"}
    spacing = registration["outputGrid"]["voxelSizeUm"]
    for axis in "xy":
        if spacing[axis] is not None:
            tiff_metadata["PhysicalSize" + axis.upper()] = spacing[axis]
            tiff_metadata["PhysicalSize" + axis.upper() + "Unit"] = "µm"
    buffer = io.BytesIO()
    tifffile.imwrite(buffer, result, ome=True, photometric="minisblack", metadata=tiff_metadata)
    content = buffer.getvalue()
    path, hashed = store.put_bytes(content, ".registered.ome.tif")
    mask_buffer = io.BytesIO()
    np.save(mask_buffer, valid.astype(np.uint8), allow_pickle=False)
    mask_path, mask_hash = store.put_bytes(mask_buffer.getvalue(), ".support.npy")
    support.update({"path": mask_path, "hash": mask_hash, "dtype": "uint8", "shape": list(valid.shape),
                    "policy": "exclude-unsupported-samples-v1"})
    created = utc_now()
    registration.update({"createdRevision": revision, "createdAt": created, "outputHash": hashed})
    derivation = {"kind": "registration", "engineVersion": ENGINE_VERSION,
                  "sourceImageId": metadata["movingImageId"], "sourceHash": metadata["moving"]["sourceHash"],
                  "selection": metadata["movingSelection"], "sourceFingerprint": digest(metadata["moving"]),
                  "registration": registration, "validSupport": support,
                  "createdRevision": revision, "createdAt": created, "outputHash": hashed,
                  "intensityUnits": "processed-source"}
    fixed_image = next(image for image in document["images"] if image["id"] == metadata["fixedImageId"])
    moving_image = next(image for image in document["images"] if image["id"] == metadata["movingImageId"])
    derived = {"id": str(uuid.uuid4()), "name": args.get("name", moving_image["name"][:155] + " · registered"),
               "sourcePath": path, "sourceHash": hashed, "sourceBytes": len(content),
               "width": int(result.shape[1]), "height": int(result.shape[0]), "channels": 1,
               "axes": "YX", "shape": list(result.shape), "dtype": "float64", "zCount": 1, "timeCount": 1,
               "pxPerUm": fixed_image["pxPerUm"], "voxelSizeUm": spacing, "timeStepSeconds": None,
               "calibrationSource": "frozen-registration-fixed-grid", "importedAt": created,
               "undoStack": [], "derivation": derivation, "validSupport": support}
    document["images"].append(derived)
    return {"derivedImageId": derived["id"], "fixedImageId": metadata["fixedImageId"],
            "movingImageId": metadata["movingImageId"], "registration": registration, "validSupport": support,
            "image": {key: value for key, value in derived.items() if key != "sourcePath"}}
