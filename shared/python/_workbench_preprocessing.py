"""Versioned preprocessing recipes that create immutable derived acquisitions.

SciPy/skimage implementations match the algorithms already used by host
sidecars. A selected source plane or volume is processed in native sample units;
the result is retained separately and its intensity transformation is explicit.
"""
from __future__ import annotations

from _workbench_indexed import image_capacity

import copy
import hashlib
import io
import math
import uuid

ENGINE_VERSION = "preprocessing-1"


def recipe_schema():
    from _workbench_schema import _object
    number = {"type": "number"}
    return {"type": "array", "minItems": 1, "maxItems": 8, "items": _object({
        "method": {"type": "string", "enum": [
            "gaussian", "median", "rolling-ball", "clahe", "normalize", "anisotropic-diffusion",
            "subtract-constant", "white-tophat", "unsharp-mask", "richardson-lucy"]},
        "sigma": {**number, "exclusiveMinimum": 0, "maximum": 32},
        "size": {"type": "integer", "minimum": 1, "maximum": 15},
        "radius": {**number, "minimum": 1, "maximum": 128},
        "downsample": {"type": "integer", "minimum": 1, "maximum": 16},
        "clipLimit": {**number, "exclusiveMinimum": 0, "maximum": 1},
        "lowerPercentile": {**number, "minimum": 0, "maximum": 100},
        "upperPercentile": {**number, "minimum": 0, "maximum": 100},
        "iterations": {"type": "integer", "minimum": 1, "maximum": 50},
        "conductance": {**number, "exclusiveMinimum": 0, "maximum": 1},
        "level": number,
        "clipAtZero": {"type": "boolean"},
        "amount": {**number, "minimum": 0, "maximum": 5},
        "psfSigmaXY": {**number, "exclusiveMinimum": 0, "maximum": 16},
        "psfSigmaZ": {**number, "exclusiveMinimum": 0, "maximum": 16},
    }, ["method"])}


def operations():
    from _workbench_schema import _object, _ID, _PARAMETERS, _op
    arguments = {"imageId": _ID, "recipe": recipe_schema(),
                 "target": {"type": "string", "enum": ["plane", "volume"]},
                 "sourceParameters": _PARAMETERS,
                 "timeIndex": {"type": "integer", "minimum": 0},
                 "channel": {"type": "integer", "minimum": 0, "maximum": 31}}
    return [
        _op("preprocessing.catalogue", "Discover reproducible filters, dimensional support and intensity transformations.",
            _object(), project=False),
        _op("preprocessing.preview", "Preview a recipe on a selected source without changing its acquisition or masks.",
            _object({**arguments, "maxSize": {"type": "integer", "minimum": 64, "maximum": 2048}}, ["imageId", "recipe"])),
        _op("preprocessing.run", "Retain a new processed TIFF acquisition and its complete recipe without overwriting source pixels.",
            _object({**arguments, "name": {"type": "string", "minLength": 1, "maxLength": 200}},
                    ["imageId", "recipe"]), True),
        _op("preprocessing.inspect", "Inspect a derived acquisition's frozen source selection, calibration and recipe.",
            _object({"imageId": _ID}, ["imageId"])),
    ]


def catalogue():
    return {"engineVersion": ENGINE_VERSION, "recipeSchema": recipe_schema(),
            "output": "new-immutable-derived-image", "outputDtype": "float64",
            "filters": [
                {"method": "gaussian", "name": "Gaussian smoothing", "dimensions": [2, 3], "defaults": {"sigma": 1},
                 "parameterUnits": {"sigma": "pixels-or-voxels"}, "intensityEffect": "smoothed-source-values"},
                {"method": "median", "name": "Median smoothing", "dimensions": [2, 3], "defaults": {"size": 3},
                 "parameterUnits": {"size": "odd-pixel-or-voxel-neighborhood"}, "intensityEffect": "local-median-values"},
                {"method": "rolling-ball", "name": "Rolling-ball background", "dimensions": [2], "defaults": {"radius": 25, "downsample": 4},
                 "parameterUnits": {"radius": "source-pixels", "downsample": "background-estimation-factor"},
                 "intensityEffect": "background-subtracted-clipped-at-zero"},
                {"method": "clahe", "name": "Local contrast", "dimensions": [2], "defaults": {"clipLimit": .02},
                 "intensityEffect": "local-contrast-transformed-within-input-range"},
                {"method": "normalize", "name": "Percentile normalization", "dimensions": [2, 3],
                 "defaults": {"lowerPercentile": 1, "upperPercentile": 99},
                 "intensityEffect": "percentile-clipped-values-in-zero-to-one-range"},
                {"method": "anisotropic-diffusion", "name": "Anisotropic diffusion", "dimensions": [2],
                 "defaults": {"iterations": 10, "conductance": .10},
                 "intensityEffect": "edge-preserving-smoothed-values-within-input-range"},
                {"method": "subtract-constant", "name": "Constant background subtraction", "dimensions": [2, 3],
                 "defaults": {"level": 0, "clipAtZero": True},
                 "parameterUnits": {"level": "input-source-intensity"},
                 "intensityEffect": "constant-subtracted; optional clipping at zero",
                 "notes": ["The background level is supplied explicitly, not inferred from empty or negative-control samples.",
                           "Clipping is recorded because it changes the lower intensity distribution."]},
                {"method": "white-tophat", "name": "White top-hat background correction", "dimensions": [2, 3],
                 "defaults": {"radius": 8}, "parameterUnits": {"radius": "pixels-or-voxels"},
                 "intensityEffect": "input minus a grayscale morphological opening",
                 "notes": ["A discrete circular or spherical flat footprint estimates background beneath bright structures.",
                           "Radius uses pixel or voxel coordinates; anisotropic physical spacing is not inferred.",
                           "Reflecting boundaries and a bounded footprint-work budget are used."]},
                {"method": "unsharp-mask", "name": "Unsharp masking", "dimensions": [2, 3],
                 "defaults": {"sigma": 1, "amount": 1},
                 "parameterUnits": {"sigma": "pixels-or-voxels", "amount": "dimensionless"},
                 "intensityEffect": "input + amount × (input − Gaussian-smoothed input)",
                 "notes": ["This is contrast enhancement, not an optical reconstruction.",
                           "Negative output values and overshoot are retained; reflecting Gaussian boundaries are used."]},
                {"method": "richardson-lucy", "name": "Richardson–Lucy deconvolution", "dimensions": [2, 3],
                 "defaults": {"iterations": 10, "psfSigmaXY": 1.5, "psfSigmaZ": 1.5},
                 "parameterUnits": {"psfSigmaXY": "pixels-or-voxels", "psfSigmaZ": "Z-voxels"},
                 "intensityEffect": "nonnegative Richardson–Lucy estimate in input intensity units",
                 "notes": ["The separable Gaussian PSF is synthetic; its sigmas are explicit assumptions, not measured optical calibration.",
                           "psfSigmaZ is ignored for a 2D plane. Both sigmas use voxel indices rather than micrometres.",
                           "Requires nonnegative supported samples. Gaussian kernels are normalized, truncated at four sigmas, with reflecting boundaries.",
                           "Iteration count controls the restoration and may amplify noise; no data-driven stopping or accuracy claim is made.",
                           "Partial support uses a completely supported rectangular crop with its own reflecting boundary."]},
            ],
            "limits": {"steps": 8, "rollingBallKernelVisits": 500000000,
                       "medianKernelVisits": 500000000, "diffusionPixelIterations": 200000000,
                       "topHatFootprintSamples": 2000000, "topHatKernelVisits": 500000000,
                       "deconvolutionSamples": 2000000, "deconvolutionKernelVisits": 1000000000},
            "notes": ["Volume filters use voxel neighborhoods; they do not infer isotropic physical spacing.",
                      "Derived intensities represent processed samples, not the original acquisition's fluorescence.",
                      "The original acquisition, calibration and corrected masks remain available."]}


def _fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def normalize_recipe(recipe, dimensions):
    from _workbench_schema import validate_value
    validate_value(recipe, recipe_schema(), "recipe")
    filters = {item["method"]: item for item in catalogue()["filters"]}
    result = []
    for item in recipe:
        descriptor = filters[item["method"]]
        if dimensions not in descriptor["dimensions"]:
            _fail("unsupported-preprocessing-dimensions", f"{item['method']} supports a 2D source plane only.")
        allowed = set(descriptor["defaults"]) | {"method"}
        if set(item) - allowed:
            _fail("invalid-arguments", "Recipe step contains controls for another filter.")
        step = {"method": item["method"], **descriptor["defaults"], **item}
        if step["method"] == "median" and step["size"] % 2 != 1:
            _fail("invalid-arguments", "Median neighborhood size must be odd.")
        if step["method"] == "normalize" and step["lowerPercentile"] >= step["upperPercentile"]:
            _fail("invalid-arguments", "Normalization lower percentile must be below its upper percentile.")
        result.append(step)
    return result


def _normalize_values(data, valid_support=None):
    from _workbench_imaging import require
    np, = require("numpy")
    samples = data if valid_support is None else data[valid_support]
    low, high = float(np.min(samples)), float(np.max(samples))
    if high == low:
        return np.zeros_like(data), low, high
    if not math.isfinite(high - low):
        _fail("invalid-pixels", "Source dynamic range is too large for finite preprocessing arithmetic.")
    return (data - low) / (high - low), low, high


def _diffuse(data, iterations, conductance, valid_support=None):
    """The existing native Perona–Malik rule with zero-flux image boundaries."""
    from _workbench_imaging import require
    np, = require("numpy")
    values, low, high = _normalize_values(data, valid_support)
    if high == low:
        return data.copy()
    for _ in range(iterations):
        # One directional difference/update at a time bounds temporary storage;
        # pairwise flux updates preserve the native four-neighbor rule.
        update = np.zeros_like(values)
        vertical = values[1:, :] - values[:-1, :]
        flux = vertical * np.exp(-((vertical / conductance) ** 2))
        update[:-1, :] += flux
        update[1:, :] -= flux
        horizontal = values[:, 1:] - values[:, :-1]
        flux = horizontal * np.exp(-((horizontal / conductance) ** 2))
        update[:, :-1] += flux
        update[:, 1:] -= flux
        values = np.clip(values + .16 * update, 0, 1)
    return values * (high - low) + low


def _richardson_lucy_gaussian(values, item):
    """Separable symmetric-PSF Richardson–Lucy with an explicit edge model."""
    from _workbench_imaging import require
    np, = require("numpy")
    from scipy import ndimage
    if values.size > 2_000_000:
        _fail("preprocessing-limit", "Richardson–Lucy supports at most 2 million selected samples.")
    if (values < 0).any():
        _fail("nonnegative-source-required", "Richardson–Lucy requires nonnegative supported source samples; subtract or clip an explicit background first.")
    sigmas = ([item["psfSigmaZ"]] if values.ndim == 3 else []) + [item["psfSigmaXY"]] * 2
    radii = [int(4 * sigma + .5) for sigma in sigmas]
    visits = 2 * item["iterations"] * values.size * sum(2 * radius + 1 for radius in radii)
    if visits > 1_000_000_000:
        _fail("preprocessing-limit", "Reduce Richardson–Lucy iterations or Gaussian PSF width to stay within one billion separable-kernel sample visits.")
    maximum = float(values.max())
    details = {"psf": {"kind": "synthetic-separable-Gaussian", "sigmaArrayOrder": sigmas,
                       "axes": "ZYX" if values.ndim == 3 else "YX", "kernelRadii": radii,
                       "normalized": True, "truncateSigma": 4},
               "boundaryPolicy": "reflect", "iterationCount": item["iterations"],
               "kernelSampleVisits": visits, "normalizationScale": maximum,
               "relativeDenominatorFloor": float(np.finfo(np.float64).eps)}
    if maximum == 0:
        return values.copy(), details
    observations = values / maximum
    estimate = np.full_like(observations, float(observations.mean()))
    floor = np.finfo(np.float64).eps
    for _ in range(item["iterations"]):
        blurred = ndimage.gaussian_filter(estimate, sigma=sigmas, mode="reflect", truncate=4)
        ratio = observations / np.maximum(blurred, floor)
        estimate *= ndimage.gaussian_filter(ratio, sigma=sigmas, mode="reflect", truncate=4)
    return estimate * maximum, details


def apply(raw, recipe, valid_support=None, support_output=None):
    from _workbench_imaging import require
    np, = require("numpy")
    require("scipy", "skimage")
    from scipy import ndimage
    from skimage import exposure, restoration
    from skimage.transform import resize
    values = np.asarray(raw, dtype=np.float64)
    if values.ndim not in (2, 3) or not values.size or not np.isfinite(values).all():
        _fail("invalid-pixels", "Preprocessing requires a finite source plane or volume.")
    recipe = normalize_recipe(recipe, values.ndim)
    valid = None if valid_support is None else valid_support.copy()
    if valid is not None:
        values = np.where(valid, values, 0.)
    steps = []
    for item in recipe:
        method = item["method"]
        partial = valid is not None and not valid.all()
        if partial and method in ("rolling-ball", "clahe", "richardson-lucy"):
            from _workbench_support import rectangular_crop
            region = rectangular_crop(valid)
            cropped, _, crop_steps = apply(values[region], [item])
            values = np.zeros_like(values)
            values[region] = cropped
            steps.append({**crop_steps[0], "validSamples": int(valid.sum()),
                          "supportCrop": [[part.start, part.stop] for part in region],
                          "supportBoundaryPolicy": "algorithm applied only within the supported rectangle"})
            continue
        erosion = 0
        details = {}
        if method == "gaussian":
            values = ndimage.gaussian_filter(values, sigma=item["sigma"], mode="reflect")
            erosion = math.ceil(4 * item["sigma"])
        elif method == "median":
            if values.size * item["size"] ** values.ndim > 500000000:
                _fail("preprocessing-limit", "Reduce the median neighborhood or select a smaller source to stay within the filter budget.")
            values = ndimage.median_filter(values, size=item["size"], mode="reflect")
            erosion = item["size"] // 2
        elif method == "rolling-ball":
            factor = item["downsample"]
            small_shape = tuple(max(1, math.ceil(size / factor)) for size in values.shape)
            radius = item["radius"] / factor
            if math.prod(small_shape) * (2 * math.ceil(radius) + 1) ** 2 > 500000000:
                _fail("preprocessing-limit", "Reduce the rolling-ball radius or increase background downsampling.")
            small = (values if factor == 1 else resize(values, small_shape, order=1, preserve_range=True,
                                                       anti_aliasing=True, mode="reflect"))
            background = restoration.rolling_ball(small, radius=radius)
            if factor != 1:
                background = resize(background, values.shape, order=1, preserve_range=True,
                                    anti_aliasing=False, mode="edge")
            values = np.maximum(values - background, 0)
        elif method == "clahe":
            normalized, low, high = _normalize_values(values)
            values = (values.copy() if high == low else
                      exposure.equalize_adapthist(normalized, clip_limit=item["clipLimit"]) * (high - low) + low)
        elif method == "normalize":
            samples = values if valid is None else values[valid]
            low, high = np.percentile(samples, (item["lowerPercentile"], item["upperPercentile"]))
            if not math.isfinite(float(high - low)):
                _fail("invalid-pixels", "Percentile range exceeds finite preprocessing arithmetic.")
            values = np.zeros_like(values) if high <= low else np.clip((values - low) / (high - low), 0, 1)
        elif method == "anisotropic-diffusion":
            if values.size * item["iterations"] > 200000000:
                _fail("preprocessing-limit", "Reduce diffusion iterations or select a smaller source.")
            values = _diffuse(values, item["iterations"], item["conductance"], valid)
            erosion = item["iterations"]
        elif method == "subtract-constant":
            values = values - item["level"]
            if item["clipAtZero"]:
                values = np.maximum(values, 0)
            details = {"backgroundLevel": item["level"], "clipAtZero": item["clipAtZero"]}
        elif method == "unsharp-mask":
            smooth = ndimage.gaussian_filter(values, sigma=item["sigma"], mode="reflect", truncate=4)
            values = values + item["amount"] * (values - smooth)
            erosion = math.ceil(4 * item["sigma"])
            details = {"boundaryPolicy": "reflect", "clipped": False}
        elif method == "white-tophat":
            radius = math.ceil(item["radius"])
            if (2 * radius + 1) ** values.ndim > 2_000_000:
                _fail("preprocessing-limit", "White top-hat footprint exceeds two million bounding-box samples.")
            grid = np.ogrid[tuple(slice(-radius, radius + 1) for _ in range(values.ndim))]
            footprint = sum(axis * axis for axis in grid) <= item["radius"] ** 2
            visits = 2 * values.size * int(footprint.sum())
            if visits > 500000000:
                _fail("preprocessing-limit", "Reduce the white top-hat radius or selected source size to stay within 500 million footprint visits.")
            values = ndimage.white_tophat(values, footprint=footprint, mode="reflect")
            erosion = 2 * radius
            details = {"footprint": "disk" if values.ndim == 2 else "ball",
                       "footprintSamples": int(footprint.sum()), "kernelSampleVisits": visits,
                       "boundaryPolicy": "reflect"}
        else:
            values, details = _richardson_lucy_gaussian(values, item)
        if partial and erosion:
            # Reflecting image boundaries only reuse existing source samples;
            # exclude neighborhoods touching internal unsupported samples.
            valid = ndimage.minimum_filter(valid, size=2 * erosion + 1, mode="constant", cval=1).astype(bool)
        if valid is not None:
            if not valid.any():
                _fail("no-valid-support", "The filter recipe leaves no uncontaminated supported samples.")
            values[~valid] = 0
        if not np.isfinite(values).all():
            _fail("invalid-pixels", "Preprocessing produced non-finite values; no derived acquisition was saved.")
        samples = values if valid is None else values[valid]
        steps.append({"method": method, "minimum": float(samples.min()), "maximum": float(samples.max()),
                      "supportErosionRadiusPx": erosion if partial else 0,
                      "validSamples": int(values.size if valid is None else valid.sum()), **details})
    if support_output is not None:
        support_output["mask"] = valid
    return np.asarray(values, dtype=np.float64), recipe, steps


def _source_fingerprint(image, selection):
    from _workbench_store import canonical
    import _workbench_support as support
    value = {"sourceHash": image["sourceHash"], "shape": image["shape"], "selection": selection,
             "pxPerUm": image["pxPerUm"], "voxelSizeUm": image.get("voxelSizeUm")}
    if support.descriptor(image):
        value["validSupport"] = support.fingerprint(image)
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def inspect(image, document):
    derivation = image.get("derivation")
    if not derivation:
        return {"imageId": image["id"], "derived": False}
    if derivation.get("kind") == "workspace":
        from _workbench_workspace import inspect_materialized
        return {**inspect_materialized(document, image), "derived": True, "derivation": copy.deepcopy(derivation)}
    if derivation.get("kind") == "registration":
        from _workbench_registration import inspect as inspect_registration
        return {**inspect_registration(image, document), "derived": True,
                "derivation": copy.deepcopy(derivation), "geometry": "translated-into-fixed-grid"}
    from _workbench_indexed import image_index
    parent = image_index(document).get(derivation["sourceImageId"])
    current = _source_fingerprint(parent, derivation["selection"]) if parent else None
    return {"imageId": image["id"], "derived": True, "derivation": copy.deepcopy(derivation),
            "parentInputsCurrent": current == derivation["sourceFingerprint"],
            "intensityUnits": "processed-source", "geometry": "unchanged-source-grid"}


def execute(store, document, operation, arguments, revision, hooks):
    from _workbench_imaging import require, preview_data
    from _workbench_schema import analysis_parameters
    from _workbench_store import utc_now
    import _workbench_volume as volume
    import _workbench_support as support
    image = hooks["image"](document, arguments["imageId"])
    if operation == "preprocessing.inspect":
        return inspect(image, document)
    target = arguments.get("target", "plane")
    if target == "volume":
        if "timeIndex" not in arguments or "channel" not in arguments or "sourceParameters" in arguments:
            _fail("invalid-arguments", "Volume preprocessing requires timeIndex and channel without plane sourceParameters.")
        selection = {"target": target, "timeIndex": arguments["timeIndex"], "channel": arguments["channel"]}
        raw = volume.load_source(store, image, arguments["timeIndex"], arguments["channel"])
    else:
        if "timeIndex" in arguments or "channel" in arguments:
            _fail("invalid-arguments", "Plane preprocessing uses sourceParameters for its source selection.")
        parameters = analysis_parameters({"parameters": {
            **image.get("preferredSourceParameters", {}), **arguments.get("sourceParameters", {})}})
        selection = {"target": target, "sourceParameters": parameters}
        raw = hooks["source"](store, image, parameters)
    valid = support.load(store, image, raw.shape, selection.get("sourceParameters"))
    propagated = {}
    filtered, recipe, ranges = apply(raw, arguments["recipe"], valid, propagated)
    output_valid = propagated.get("mask")
    source_samples = raw if valid is None else raw[valid]
    output_samples = filtered if output_valid is None else filtered[output_valid]
    summary = {"sourceMinimum": float(source_samples.min()), "sourceMaximum": float(source_samples.max()),
               "outputMinimum": float(output_samples.min()), "outputMaximum": float(output_samples.max()),
               "validSupport": support.summary(image, output_valid, filtered.shape),
               "steps": ranges, "intensityUnits": "processed-source", "shape": list(filtered.shape)}
    if operation == "preprocessing.preview":
        preview = filtered if filtered.ndim == 2 else filtered[filtered.shape[0] // 2]
        result = {"imageId": image["id"], "selection": selection, "recipe": recipe, "summary": summary,
                  "previewPlane": "xy", "previewIndex": 0 if filtered.ndim == 2 else filtered.shape[0] // 2,
                  **preview_data(preview, max_size=arguments.get("maxSize", 768))}
        if filtered.ndim == 3:
            result["display"] = volume.display(filtered, None, image, arguments["timeIndex"], arguments["channel"])
        return result
    if operation != "preprocessing.run":
        _fail("unknown-operation", "Unknown preprocessing operation.")
    if len(document["images"]) >= image_capacity(document):
        _fail("project-too-large", "A project can retain at most 1,000 acquisitions.")
    tifffile, = require("tifffile")
    axes = "YX" if filtered.ndim == 2 else "ZYX"
    voxels = dict(volume.calibration(image))
    if filtered.ndim == 2:
        voxels["z"] = None
    metadata = {"axes": axes}
    for axis in "xyz":
        if voxels[axis] is not None and (axis != "z" or filtered.ndim == 3):
            metadata["PhysicalSize" + axis.upper()] = voxels[axis]
            metadata["PhysicalSize" + axis.upper() + "Unit"] = "µm"
    output = io.BytesIO()
    tifffile.imwrite(output, filtered, ome=True, photometric="minisblack", metadata=metadata)
    contents = output.getvalue()
    path, checksum = store.put_bytes(contents, ".processed.ome.tif")
    created = utc_now()
    derivation = {"engineVersion": ENGINE_VERSION, "sourceImageId": image["id"],
                  "sourceHash": image["sourceHash"], "selection": selection,
                  "sourceFingerprint": _source_fingerprint(image, selection),
                  "sourceCalibration": volume.calibration(image), "recipe": recipe,
                  "createdRevision": revision, "createdAt": created, "outputHash": checksum,
                  "intensityUnits": "processed-source"}
    if "sourceRegion" in image:
        derivation["sourceRegion"] = copy.deepcopy(image["sourceRegion"])
    name = arguments.get("name", image["name"][:160] + " · processed")
    derived = {"id": str(uuid.uuid4()), "name": name, "sourcePath": path, "sourceHash": checksum,
               "sourceBytes": len(contents), "width": filtered.shape[-1], "height": filtered.shape[-2],
               "channels": 1, "axes": axes, "shape": list(filtered.shape), "dtype": "float64",
               "zCount": filtered.shape[0] if filtered.ndim == 3 else 1, "timeCount": 1,
               "pxPerUm": image["pxPerUm"], "voxelSizeUm": voxels, "timeStepSeconds": None,
               "calibrationSource": "frozen-parent", "importedAt": created, "undoStack": [],
               "derivation": derivation}
    if output_valid is not None:
        retained = support.retain(store, output_valid, {"sourceSupport": support.fingerprint(image),
                                                       "recipe": recipe, "steps": ranges})
        derived["validSupport"] = retained
        derivation["validSupport"] = retained
        summary["validSupport"] = support.summary(derived, output_valid, filtered.shape)
    if "sourceRegion" in image:
        # Every recipe preserves the pixel grid, so its original-source origin
        # remains valid even though the derived intensity values are different.
        derived["sourceRegion"] = copy.deepcopy(image["sourceRegion"])
    document["images"].append(derived)
    return {"derivedImageId": derived["id"], "sourceImageId": image["id"],
            "image": {key: value for key, value in derived.items() if key != "sourcePath"},
            "summary": summary, "recipe": recipe}
