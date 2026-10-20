"""Shared deterministic 2D threshold kernels; no file or runtime side effects.

Threshold values and adaptive offsets use source intensity units. Automatic
polarity is a documented median-background heuristic, not a learned decision.
"""
from __future__ import annotations

import math

METHODS = ("otsu", "triangle", "li", "yen", "mean", "adaptive", "manual")
ENGINE_VERSION = "classical-threshold-1"


def global_threshold(samples, method, threshold=None):
    import numpy as np
    from skimage import filters
    samples = np.asarray(samples, dtype=np.float64)
    if not samples.size or not np.isfinite(samples).all():
        raise ValueError("Threshold estimation requires finite acquired source samples.")
    if method == "manual":
        if threshold is None or isinstance(threshold, bool) or not math.isfinite(float(threshold)):
            raise ValueError("A finite manual threshold in source intensity units is required.")
        return float(threshold)
    if method not in METHODS or method == "adaptive":
        raise ValueError("Select a supported global threshold method.")
    if float(samples.max()) == float(samples.min()):
        return float(samples.min())
    value = float(getattr(filters, "threshold_" + method)(samples))
    if not math.isfinite(value):
        raise ValueError("This threshold method could not estimate a finite threshold; choose another method or a manual value.")
    return value


def resolve_polarity(samples, threshold, requested):
    import numpy as np
    if requested in ("bright", "dark"):
        return requested
    if requested != "auto":
        raise ValueError("Foreground polarity must be bright, dark, or auto.")
    scalar = float(np.mean(threshold))
    resolved = "bright" if float(np.median(samples)) < scalar else "dark"
    fraction = float(np.mean(samples > scalar if resolved == "bright" else samples < scalar))
    other = 1.0 - fraction
    if fraction > 0.9 and 0.0005 < other < 0.5:
        resolved = "dark" if resolved == "bright" else "bright"
    return resolved


def adaptive_threshold(plane, polarity, block_size=51, offset_mode="auto", offset=None, *, minimum_auto_offset=0.0):
    import numpy as np
    from skimage.filters import threshold_local
    if type(block_size) is not int or not 3 <= block_size <= 501 or block_size % 2 == 0:
        raise ValueError("Adaptive neighbourhood size must be an odd integer from 3 to 501 pixels.")
    surface = threshold_local(plane, block_size=block_size, method="gaussian", mode="reflect")
    if offset_mode == "auto":
        resolved_offset = max(float(minimum_auto_offset), 0.5 * float(np.std(plane - surface)))
    elif offset_mode == "manual" and offset is not None and not isinstance(offset, bool) and math.isfinite(float(offset)) and offset >= 0:
        resolved_offset = float(offset)
    else:
        raise ValueError("A finite nonnegative adaptive offset is required in manual offset mode.")
    return surface + resolved_offset if polarity == "bright" else surface - resolved_offset, resolved_offset


def clean_binary(binary, min_area, fill_holes=False, valid_support=None):
    import numpy as np
    from scipy import ndimage as ndi
    binary = np.asarray(binary, dtype=bool)
    if fill_holes:
        binary = ndi.binary_fill_holes(binary)
    if valid_support is not None:
        binary &= valid_support
    components, count = ndi.label(binary)
    if count and min_area > 0:
        sizes = np.bincount(components.ravel())
        keep = sizes >= min_area
        keep[0] = False
        binary = keep[components]
    return binary


def threshold_mask(plane, parameters, valid_support=None):
    """Return binary foreground, public scalar stats, and a contrast array.

    Local estimation uses one entirely acquired rectangle and reflecting edges;
    unsupported fill never enters its neighbourhood or automatic offset.
    """
    import numpy as np
    plane = np.asarray(plane, dtype=np.float64)
    if plane.ndim != 2:
        raise ValueError("Classical threshold segmentation requires a two-dimensional source plane.")
    support = np.ones(plane.shape, dtype=bool) if valid_support is None else np.asarray(valid_support, dtype=bool)
    if support.shape != plane.shape:
        raise ValueError("Source support and plane dimensions differ.")
    samples = plane[support]
    if not samples.size or not np.isfinite(samples).all():
        raise ValueError("Segmentation requires finite acquired source samples.")
    method = parameters.get("method", "otsu")
    requested = parameters.get("polarity", "bright")
    threshold = global_threshold(samples, "otsu" if method == "adaptive" else method, parameters.get("threshold"))
    polarity = resolve_polarity(samples, threshold, requested)
    stats = {"threshold": threshold, "method": method, "requestedPolarity": requested,
             "resolvedPolarity": polarity, "fillHoles": parameters.get("fillHoles", False),
             "thresholdEngineVersion": ENGINE_VERSION,
             "intensityUnits": "source", "polarityConvention": "explicit" if requested != "auto" else "median-background-with-majority-guard"}
    constant_auto = method != "manual" and float(samples.max()) == float(samples.min())
    if method == "adaptive" and not constant_auto:
        occupied = np.nonzero(support)
        region = tuple(slice(int(values.min()), int(values.max()) + 1) for values in occupied)
        if not support[region].all():
            raise ValueError("Adaptive thresholding requires one completely acquired rectangular region; crop to valid support first.")
        surface, offset = adaptive_threshold(plane[region], polarity,
            parameters.get("adaptiveBlockSize", 51), parameters.get("adaptiveOffsetMode", "auto"),
            parameters.get("adaptiveOffset"))
        threshold = np.zeros(plane.shape, dtype=np.float64)
        threshold[region] = surface
        stats.update(threshold=float(np.mean(surface)), thresholdRange=[float(surface.min()), float(surface.max())],
                     adaptiveBlockSize=parameters.get("adaptiveBlockSize", 51),
                     adaptiveOffsetMode=parameters.get("adaptiveOffsetMode", "auto"), adaptiveOffset=offset,
                     adaptiveOffsetConvention="half-source-residual-standard-deviation" if parameters.get("adaptiveOffsetMode", "auto") == "auto" else "explicit-source-units",
                     boundaryMode="reflect", acquiredRegion={"x": region[1].start, "y": region[0].start,
                     "width": region[1].stop-region[1].start, "height": region[0].stop-region[0].start})
    contrast = plane - threshold if polarity == "bright" else threshold - plane
    contrast = np.where(support, contrast, 0.0)
    binary = (contrast > 0) & support
    if constant_auto:
        binary[:] = False
        stats["constantSource"] = True
    binary = clean_binary(binary, parameters.get("minAreaPx", 9), parameters.get("fillHoles", False), support)
    stats["foregroundPixels"] = int(np.count_nonzero(binary))
    return binary, stats, contrast
