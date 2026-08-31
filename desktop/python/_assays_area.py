"""
_assays_area.py — Area / region assays for CellCounter: confluence (% area
coverage), scratch / wound-healing gap measurement, and spheroid / organoid
sizing.

These three assays measure AREA and REGIONS, not per-cell properties. They
work off a segmentation mask OR a plain intensity threshold, so they are
INDEPENDENT of the per-cell measurement pipeline (`_cellpose_common.py`'s
`measure_cells`) — none of the functions here require Cellpose / StarDist /
SAM to have run at all, and this module imports nothing from the detection
sidecars.

Public API — every function is PURE: (mask or image array, px_per_um,
params) -> dict. Note the calibration unit is `px_per_um` (PIXELS PER
MICROMETRE, matching the app's `--pxPerUm` convention everywhere else) — NOT
`pixel_size_um`, which is its reciprocal and is what `_imageio.load_planes`
reports in its metadata. Passing one where the other is expected silently
rescales every measurement. No argparse, no sys.exit, no stdout/stderr writes, no
sidecar plumbing. That makes them directly unit-testable and reusable from
any future sidecar. See `area_assays_detect.py` for a standalone CLI that
wraps them using the same stderr-log / single-stdout-JSON contract as the
other detect scripts (`cellpose_detect.py`, `stardist_detect.py`,
`sam_detect.py`).

    confluence(mask=None, image=None, px_per_um=1.0, **params) -> dict
    scratch_wound(image, px_per_um=1.0, **params) -> dict
    scratch_wound_series(images, px_per_um=1.0, timepoints_hours=None, **params) -> dict
    spheroids(image, px_per_um=1.0, **params) -> dict

Failure mode mirrors `_colony.py`: never raise. Every function returns a
dict with an `"ok": bool` and a `"message": str`. On a degraded/unmet
precondition (e.g. a degenerate flat image) `ok` is False; where "nothing
found" is actually a legitimate result (e.g. a fully closed wound has zero
gap area) `ok` stays True with an explanatory message instead. Numeric
fields always default to 0/empty rather than being omitted, so a caller can
merge the dict straight into a JSON payload without type-checking first.
"""

from __future__ import annotations

import math
from typing import Any, Sequence

__all__ = ["confluence", "scratch_wound", "scratch_wound_series", "spheroids"]


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

def _safe_px_per_um(px_per_um: float) -> float:
    """Coerce to a positive float; falls back to 1.0 (px == µm) on bad input,
    matching `_colony.compute`'s guard."""
    try:
        v = float(px_per_um)
    except (TypeError, ValueError):
        return 1.0
    return v if v > 0 else 1.0


def _to_gray(image: Any):
    """Any array (HxW or HxWx3/HxWx4) -> float64 HxW grayscale."""
    import numpy as np
    arr = np.asarray(image)
    if arr.ndim == 3:
        arr = arr[..., :3].mean(axis=2)
    return arr.astype(np.float64)


def _safe_otsu(arr) -> float | None:
    """`threshold_otsu`, but never raises AND never returns a meaningless
    threshold. Some skimage versions raise ValueError on a perfectly flat
    (single-valued) input; others silently return that constant value as
    "the threshold" (which then classifies either everything or nothing as
    foreground depending on the `>` vs `<=` comparison — not a real
    threshold). We check for no-variation explicitly so the degenerate case
    behaves the same way regardless of skimage version, and return None."""
    try:
        import numpy as np
        lo, hi = float(np.min(arr)), float(np.max(arr))
        if not (hi > lo):
            return None
        from skimage.filters import threshold_otsu
        return float(threshold_otsu(arr))
    except Exception:  # noqa: BLE001
        return None


def _clean_binary(binary, min_size_px: int):
    """`remove_small_objects` + `remove_small_holes`; never raises — falls
    back to the input unchanged if skimage is unavailable or errors."""
    try:
        from skimage.morphology import remove_small_objects, remove_small_holes
        cleaned = remove_small_objects(binary, min_size=max(1, min_size_px))
        cleaned = remove_small_holes(cleaned, area_threshold=max(1, min_size_px))
        return cleaned
    except Exception:  # noqa: BLE001
        return binary


def _equivalent_diameter_px(prop) -> float:
    """regionprops equivalent diameter (pixels), tolerant of the skimage
    API rename (`equivalent_diameter` -> `equivalent_diameter_area`)."""
    for attr in ("equivalent_diameter_area", "equivalent_diameter"):
        val = getattr(prop, attr, None)
        if val is not None:
            return float(val)
    return float(2.0 * math.sqrt(prop.area / math.pi))


def _circularity(area: float, perimeter: float) -> float:
    """4*pi*area / perimeter^2, clamped to [0, 1] (1.0 = perfect circle)."""
    if perimeter <= 0:
        return 0.0
    return float(min(1.0, max(0.0, 4.0 * math.pi * area / (perimeter ** 2))))


def _smoothed(gray, sigma: float):
    """Optional light Gaussian pre-blur; returns the input unchanged if
    sigma <= 0 or skimage isn't available."""
    if not sigma or sigma <= 0:
        return gray
    try:
        from skimage.filters import gaussian
        return gaussian(gray, sigma=sigma, preserve_range=True)
    except Exception:  # noqa: BLE001
        return gray


# ---------------------------------------------------------------------------
# 1) Confluence / % area coverage
# ---------------------------------------------------------------------------

def _confluence_zero(message: str, mode: str = "") -> dict:
    return {
        "ok": False,
        "message": message,
        "mode": mode,
        "width_px": 0, "height_px": 0,
        "coverage_pct": 0.0,
        "covered_area_um2": 0.0,
        "uncovered_area_um2": 0.0,
        "total_area_um2": 0.0,
        "threshold_method": "",
        "threshold_value": None,
    }


def confluence(mask=None,
                image=None,
                px_per_um: float = 1.0,
                threshold_method: str = "otsu",
                fixed_threshold: float = 128.0,
                invert: bool = False,
                smooth_sigma_px: float = 1.0,
                min_object_size_um2: float = 0.0) -> dict:
    """% area coverage ("confluence") — the most-used readout after counting.

    Two mutually exclusive modes, matched on which keyword is given:

    * Mask mode (`mask=`): `mask` is a labeled (0=bg, 1..N=cell id) or plain
      binary (0 / nonzero) 2-D array — typically a detector's segmentation
      output. Coverage = (mask > 0).sum() / mask.size. This is the same
      formula `_colony.compute()` uses for its `confluency_pct` field
      (kept independently here, on purpose — this module never imports
      `_colony`, so it works with zero coupling to the per-cell pipeline).

    * Threshold mode (`image=`, no `mask`): grayscale-thresholds the raw
      image directly, for callers who don't want to run a segmentation
      model at all. `threshold_method` is `"otsu"` (default, automatic) or
      `"fixed"` (uses `fixed_threshold`, in the image's own ~0-255 scale).
      `invert=True` treats BELOW-threshold pixels as foreground (dark cells
      on a light field); the default treats AT/ABOVE-threshold pixels as
      foreground (bright signal on a dark field, e.g. fluorescence).

    `min_object_size_um2` (mask OR threshold mode, default 0 = off) removes
    specks and fills small holes below that area before counting — an
    opt-in cleanup step so the raw pixel count is the default behaviour.

    Returns (always all keys present):
        ok, message, mode ("mask" | "threshold"), width_px, height_px,
        coverage_pct, covered_area_um2, uncovered_area_um2, total_area_um2,
        threshold_method, threshold_value (None in mask mode).

    Never raises.
    """
    import numpy as np
    px_per_um = _safe_px_per_um(px_per_um)

    try:
        if mask is not None:
            arr = np.asarray(mask)
            if arr.ndim != 2 or arr.size == 0:
                return _confluence_zero("mask must be a non-empty 2-D array", mode="mask")
            binary = arr > 0
            mode = "mask"
            threshold_method_out = ""
            threshold_value_out = None

        elif image is not None:
            gray = _to_gray(image)
            if gray.ndim != 2 or gray.size == 0:
                return _confluence_zero("image must be a non-empty 2-D/3-D array", mode="threshold")
            gray = _smoothed(gray, smooth_sigma_px)

            if threshold_method == "fixed":
                thresh = float(fixed_threshold)
                threshold_method_out = "fixed"
            else:
                thresh = _safe_otsu(gray)
                threshold_method_out = "otsu"
                if thresh is None:
                    # Degenerate (perfectly flat) image — every pixel is
                    # identical, so there's no threshold that means
                    # anything. Report as a clean failure rather than guess.
                    return _confluence_zero(
                        "image has no intensity variation; cannot threshold",
                        mode="threshold")
            binary = (gray <= thresh) if invert else (gray > thresh)
            mode = "threshold"
            threshold_value_out = thresh

        else:
            return _confluence_zero("must provide either mask= or image=")

        if min_object_size_um2 and min_object_size_um2 > 0:
            min_px = int(round(min_object_size_um2 * (px_per_um ** 2)))
            binary = _clean_binary(binary, min_px)

        h, w = binary.shape
        total_px = binary.size
        covered_px = int(binary.sum())
        coverage_pct = 100.0 * covered_px / total_px if total_px else 0.0
        pxu2 = px_per_um ** 2
        covered_area_um2 = covered_px / pxu2
        total_area_um2 = total_px / pxu2

        return {
            "ok": True,
            "message": "",
            "mode": mode,
            "width_px": int(w), "height_px": int(h),
            "coverage_pct": float(coverage_pct),
            "covered_area_um2": float(covered_area_um2),
            "uncovered_area_um2": float(total_area_um2 - covered_area_um2),
            "total_area_um2": float(total_area_um2),
            "threshold_method": threshold_method_out,
            "threshold_value": threshold_value_out,
        }
    except Exception as exc:  # noqa: BLE001 — degrade, never raise.
        return _confluence_zero(f"confluence failed: {exc!r}")


# ---------------------------------------------------------------------------
# 2) Scratch / wound-healing assay
# ---------------------------------------------------------------------------

def _wound_zero(message: str, ok: bool = False) -> dict:
    return {
        "ok": ok,
        "message": message,
        "width_px": 0, "height_px": 0,
        "gap_area_um2": 0.0,
        "gap_fraction_pct": 0.0,
        "total_area_um2": 0.0,
        "wound_bbox_px": None,
    }


def scratch_wound(image,
                   px_per_um: float = 1.0,
                   texture_window_px: int | None = None,
                   min_gap_size_um2: float = 200.0,
                   smooth_sigma_px: float = 1.0,
                   flat_region_ratio: float = 0.25) -> dict:
    """Detect the cell-free "wound" (gap) region in ONE scratch/wound-healing
    image and report its area — the classic keratinocyte migration readout.

    Modality-agnostic by design: segments on local TEXTURE (variance)
    rather than raw intensity, since the gap (bare substrate/media) is
    smooth/low-texture while a confluent cell layer is not — this works
    whether cells read darker or brighter than the gap under a given optical
    setup, with no light/dark flag to get wrong.

    Algorithm: grayscale -> light Gaussian smoothing -> local standard
    deviation over a `texture_window_px` window (auto-derived from
    `px_per_um` when omitted, ~10 µm) -> a BIMODALITY GATE decides whether
    any region is genuinely flat enough to be bare substrate at all (see
    below) -> if so, Otsu-threshold the texture map and take the LOW-
    texture side as the gap candidate -> drop specks / fill holes smaller
    than `min_gap_size_um2` -> the LARGEST remaining connected component is
    reported as THE wound (a scratch assay has exactly one wound region by
    construction).

    Bimodality gate (`flat_region_ratio`, default 0.25): Otsu always finds
    *some* split point, even across a single, uniformly-textured population
    with no real gap — comparing the 10th to the 90th percentile of the
    texture map (`p_low / p_high`) is what actually distinguishes "a truly
    flat sub-region exists" (ratio ~0.05-0.15: even the quietest patches of
    real cell texture don't approach zero) from "this is all one texture,
    Otsu just bisected it arbitrarily" (ratio typically >= 0.35). Below
    `flat_region_ratio` we trust the Otsu split; at/above it we report NO
    wound rather than a statistically meaningless blob. (A frame with zero
    texture anywhere — `p_high ~= 0` — is the one exception: that can't be
    "cells everywhere", so the whole frame counts as gap.)

    Practical resolution limit: a gap much narrower than `texture_window_px`
    gets smeared by the windowing itself (cell texture bleeds in from both
    sides) and may fail the bimodality gate entirely — widen the window (in
    µm, via `px_per_um`) or narrow `texture_window_px` for thin wounds.

    A frame with no qualifying low-texture region (e.g. a fully confluent
    monolayer, late in a closing wound) is a legitimate, non-error result:
    `ok=True`, `gap_area_um2=0.0`, with a "no open wound detected" message —
    callers should treat that as 100% closure, not a failure.

    Returns: ok, message, width_px, height_px, gap_area_um2,
    gap_fraction_pct, total_area_um2, wound_bbox_px ([x0,y0,x1,y1] or None).

    Never raises.
    """
    import numpy as np
    px_per_um = _safe_px_per_um(px_per_um)

    try:
        gray = _to_gray(image)
        if gray.ndim != 2 or gray.size == 0:
            return _wound_zero("image must be a non-empty 2-D/3-D array")
        h, w = gray.shape
        total_area_um2 = gray.size / (px_per_um ** 2)

        gray = _smoothed(gray, smooth_sigma_px)

        window = texture_window_px
        if not window or window < 3:
            window = int(round(10 * px_per_um))
            window = max(5, min(51, window))
        if window % 2 == 0:
            window += 1

        from scipy.ndimage import uniform_filter
        local_mean = uniform_filter(gray, size=window)
        local_sqmean = uniform_filter(gray * gray, size=window)
        local_var = np.clip(local_sqmean - local_mean * local_mean, 0, None)
        local_std = np.sqrt(local_var)

        p_low = float(np.percentile(local_std, 10))
        p_high = float(np.percentile(local_std, 90))

        no_open_wound = {
            "ok": True,
            "message": "no open wound detected (fully confluent or no qualifying gap)",
            "width_px": int(w), "height_px": int(h),
            "gap_area_um2": 0.0,
            "gap_fraction_pct": 0.0,
            "total_area_um2": float(total_area_um2),
            "wound_bbox_px": None,
        }

        if p_high < 1e-9:
            # No texture ANYWHERE, not even the busiest 10% — can't be
            # "cells everywhere"; the whole frame reads as bare/open wound.
            gap_candidate = np.ones((h, w), dtype=bool)
        elif (p_low / p_high) >= flat_region_ratio:
            # Even the quietest 10% of the frame is still substantially
            # textured — no sub-region reads as genuinely bare substrate.
            # Don't trust an Otsu split of what is really one texture
            # population; report no wound instead of an arbitrary blob.
            return no_open_wound
        else:
            t = _safe_otsu(local_std)
            if t is None:
                return no_open_wound
            gap_candidate = local_std <= t

        min_px = max(1, int(round(min_gap_size_um2 * (px_per_um ** 2))))
        gap_candidate = _clean_binary(gap_candidate, min_px)

        from skimage.measure import label, regionprops
        labeled = label(gap_candidate, connectivity=2)
        if int(labeled.max()) == 0:
            return no_open_wound

        props = regionprops(labeled)
        largest = max(props, key=lambda p: p.area)
        gap_area_px = int(largest.area)
        min_row, min_col, max_row, max_col = largest.bbox

        return {
            "ok": True,
            "message": "",
            "width_px": int(w), "height_px": int(h),
            "gap_area_um2": float(gap_area_px / (px_per_um ** 2)),
            "gap_fraction_pct": float(100.0 * gap_area_px / gray.size),
            "total_area_um2": float(total_area_um2),
            "wound_bbox_px": [int(min_col), int(min_row), int(max_col), int(max_row)],
        }
    except Exception as exc:  # noqa: BLE001
        return _wound_zero(f"scratch_wound failed: {exc!r}")


def scratch_wound_series(images: Sequence[Any],
                          px_per_um: float = 1.0,
                          timepoints_hours: Sequence[float] | None = None,
                          **wound_params: Any) -> dict:
    """Run `scratch_wound` over an ORDERED list of images (a time series) and
    report a per-timepoint table plus % closure relative to t=0 and an
    overall closure rate.

    `timepoints_hours`, if given, must be the same length as `images`;
    `closure_rate_um2_per_hr` is then the least-squares slope of gap area
    vs. time, negated so a SHRINKING gap reads as a POSITIVE closure rate.
    Without `timepoints_hours`, the table still reports per-frame gap area
    and % closure (indexed by `frame`), but `closure_rate_um2_per_hr` is
    None — there's no time axis to rate against.

    A single-image list degrades to a one-row table (frame 0, 0% closure,
    no rate — there's nothing to close relative to). `**wound_params` are
    forwarded verbatim to `scratch_wound` for every frame (e.g.
    `texture_window_px=`, `min_gap_size_um2=`, `smooth_sigma_px=`).

    Returns: ok, message, timepoints (list of per-frame dicts: frame,
    time_hours, ok, message, gap_area_um2, gap_fraction_pct, pct_closure),
    initial_gap_area_um2, final_gap_area_um2, total_pct_closure,
    closure_rate_um2_per_hr (float or None).

    Never raises.
    """
    px_per_um = _safe_px_per_um(px_per_um)

    def _empty(message: str) -> dict:
        return {
            "ok": False, "message": message,
            "timepoints": [],
            "initial_gap_area_um2": 0.0,
            "final_gap_area_um2": 0.0,
            "total_pct_closure": 0.0,
            "closure_rate_um2_per_hr": None,
        }

    if not images:
        return _empty("no images provided")

    times: list[float] | None = None
    if timepoints_hours is not None:
        try:
            times = [float(t) for t in timepoints_hours]
        except (TypeError, ValueError) as exc:
            return _empty(f"invalid timepoints_hours: {exc!r}")
        if len(times) != len(images):
            return _empty(
                f"timepoints_hours length ({len(times)}) != images length ({len(images)})")

    try:
        rows: list[dict] = []
        for i, img in enumerate(images):
            r = scratch_wound(img, px_per_um=px_per_um, **wound_params)
            rows.append({
                "frame": i,
                "time_hours": times[i] if times is not None else None,
                "ok": r["ok"],
                "message": r["message"],
                "gap_area_um2": r["gap_area_um2"],
                "gap_fraction_pct": r["gap_fraction_pct"],
                "pct_closure": 0.0,
            })

        t0_area = rows[0]["gap_area_um2"]
        for row in rows:
            if t0_area > 0:
                row["pct_closure"] = float(100.0 * (t0_area - row["gap_area_um2"]) / t0_area)
            # else: t0 already had no measurable gap — closure is undefined
            # relative to nothing, leave at 0.0 rather than divide-by-zero.

        closure_rate = None
        if times is not None and len(times) >= 2:
            try:
                import numpy as np
                t_arr = np.asarray(times, dtype=np.float64)
                a_arr = np.asarray([row["gap_area_um2"] for row in rows], dtype=np.float64)
                if float(t_arr.max() - t_arr.min()) > 0:
                    slope, _intercept = np.polyfit(t_arr, a_arr, 1)
                    closure_rate = float(-slope)
            except Exception:  # noqa: BLE001
                closure_rate = None

        any_ok = any(row["ok"] for row in rows)
        return {
            "ok": any_ok,
            "message": "" if any_ok else "no frame produced a usable result",
            "timepoints": rows,
            "initial_gap_area_um2": float(t0_area),
            "final_gap_area_um2": float(rows[-1]["gap_area_um2"]),
            "total_pct_closure": float(rows[-1]["pct_closure"]),
            "closure_rate_um2_per_hr": closure_rate,
        }
    except Exception as exc:  # noqa: BLE001
        return _empty(f"scratch_wound_series failed: {exc!r}")


# ---------------------------------------------------------------------------
# 3) Spheroid / organoid size
# ---------------------------------------------------------------------------

def _spheroid_zero(message: str) -> dict:
    return {
        "ok": False, "message": message,
        "width_px": 0, "height_px": 0,
        "count": 0, "objects": [],
        "threshold_method": "",
    }


def spheroids(image,
              px_per_um: float = 1.0,
              threshold_method: str = "otsu",
              fixed_threshold: float = 128.0,
              invert: bool = True,
              smooth_sigma_px: float = 1.5,
              min_object_area_um2: float = 500.0,
              min_circularity: float = 0.0,
              max_objects: int = 50) -> dict:
    """Detect large round object(s) — spheroid(s) / organoid(s) — in a
    (typically low-magnification) image and report area, equivalent
    diameter, perimeter, and circularity per object.

    `invert=True` (default) assumes a dense spheroid reads DARKER than its
    surrounding media under brightfield/phase optics — the common case at
    low mag. Pass `invert=False` for fluorescence (bright object on a dark
    field). Holes inside a detected object are filled BEFORE the size
    filter, so a bright/textured spheroid core under a dark rim registers
    as one solid disc rather than a ring. `min_object_area_um2` discards
    debris/noise specks; `min_circularity` (0 disables) optionally discards
    non-round survivors (e.g. folded/torn media edges).

    Returns: ok, message, width_px, height_px, count, threshold_method,
    objects — a list sorted by area descending, each:
        label, area_um2, equivalent_diameter_um, perimeter_um, circularity,
        major_axis_um, minor_axis_um, centroid_x_px, centroid_y_px, bbox_px.

    Never raises.
    """
    px_per_um = _safe_px_per_um(px_per_um)

    try:
        gray = _to_gray(image)
        if gray.ndim != 2 or gray.size == 0:
            return _spheroid_zero("image must be a non-empty 2-D/3-D array")
        h, w = gray.shape
        gray = _smoothed(gray, smooth_sigma_px)

        if threshold_method == "fixed":
            thresh = float(fixed_threshold)
            method_out = "fixed"
        else:
            thresh = _safe_otsu(gray)
            method_out = "otsu"
            if thresh is None:
                return _spheroid_zero("image has no intensity variation; cannot threshold")

        binary = (gray <= thresh) if invert else (gray > thresh)

        # Fill holes FIRST (a bright/textured core under a dark rim would
        # otherwise register as a ring, undercounting area), THEN drop specks.
        try:
            from scipy.ndimage import binary_fill_holes
            binary = binary_fill_holes(binary)
        except Exception:  # noqa: BLE001
            pass
        min_px = max(1, int(round(min_object_area_um2 * (px_per_um ** 2))))
        binary = _clean_binary(binary, min_px)

        from skimage.measure import label, regionprops
        labeled = label(binary, connectivity=2)
        objs: list[dict] = []
        for prop in regionprops(labeled):
            area_px = float(prop.area)
            if area_px < min_px:
                continue
            perim_px = float(getattr(prop, "perimeter", 0.0) or 0.0)
            area_um2 = area_px / (px_per_um ** 2)
            perim_um = perim_px / px_per_um
            circ = _circularity(area_um2, perim_um)
            if min_circularity and circ < min_circularity:
                continue
            min_row, min_col, max_row, max_col = prop.bbox
            objs.append({
                "label": int(prop.label),
                "area_um2": float(area_um2),
                "equivalent_diameter_um": float(_equivalent_diameter_px(prop) / px_per_um),
                "perimeter_um": float(perim_um),
                "circularity": float(circ),
                "major_axis_um": float(getattr(prop, "major_axis_length", 0.0) / px_per_um),
                "minor_axis_um": float(getattr(prop, "minor_axis_length", 0.0) / px_per_um),
                "centroid_x_px": float(prop.centroid[1]),
                "centroid_y_px": float(prop.centroid[0]),
                "bbox_px": [int(min_col), int(min_row), int(max_col), int(max_row)],
            })

        objs.sort(key=lambda o: o["area_um2"], reverse=True)
        if max_objects and max_objects > 0:
            objs = objs[:max_objects]

        return {
            "ok": True,
            "message": "" if objs else "no qualifying object found",
            "width_px": int(w), "height_px": int(h),
            "count": len(objs),
            "objects": objs,
            "threshold_method": method_out,
        }
    except Exception as exc:  # noqa: BLE001
        return _spheroid_zero(f"spheroids failed: {exc!r}")
