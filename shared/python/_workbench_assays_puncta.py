"""
_assays_puncta.py — CellCounter puncta / foci detection (spot-counting assay).

Exposes:

    detect_spots(channel_img, px_per_um, params=None) -> list[dict]
    assign_spots_to_cells(spots, label_map=None, centroids=None, ...) -> None
    rasterize_polygons(polygons, shape) -> (label_map, index_to_label)
    compute(channel_img, px_per_um, params=None, *, label_map=None, ...) -> dict

Counts sub-cellular spots — γH2AX DNA-damage foci, FISH probes, stress
granules, and similar puncta — inside a single fluorescence channel, and
assigns each spot to the cell whose mask contains it. Detection uses a
Laplacian-of-Gaussian ("log") or Difference-of-Gaussian ("dog") blob
detector (`skimage.feature.blob_log` / `blob_dog`) with user-settable
min/max spot size (µm) and a detection threshold.

This module never (re)segments cells — cell identity comes from a
`label_map` (preferred: an integer mask, 0=background — exact
mask-containment assignment) or, when only cell centroids are known (e.g.
legacy detections with no stored mask/polygon), a nearest-centroid fallback
gated by a maximum distance. `rasterize_polygons()` bridges the common case
where the only thing on hand is CellCounter's own stored per-cell polygon
contours (`DetectedCell.contourPx` / the sidecars' `contour_px` field) —
turning them into a label_map without needing the original segmentation
mask.

Failure mode: every public function is defensive — bad/missing inputs
produce an empty/zeroed result (with a `message` field on `compute()`
explaining why), never an exception.
"""

from __future__ import annotations

import math
import sys
import uuid
from typing import Any


DEFAULT_PARAMS: dict[str, Any] = {
    # `dog` (Difference-of-Gaussian) is the default because it is the only one
    # of the two that finishes in reasonable time on a real field. `blob_log`
    # convolves the whole image once PER SIGMA (num_sigma times) and then runs a
    # 3-D maximum filter over the stacked scale space; on a 2048x2048 field with
    # the default 10 scales that is tens of seconds, which reads as a hang.
    # `blob_dog` approximates the same Laplacian response with a pair of
    # gaussian blurs per octave, at very similar spot recall. `log` stays
    # selectable for users who want the reference implementation.
    "method": "dog",              # "dog" (Difference-of-Gaussian) | "log" (Laplacian-of-Gaussian)
    "min_diameter_um": 0.3,
    "max_diameter_um": 3.0,
    # blob_log only. None = derive from the width of the requested diameter
    # window (see `_resolve_num_sigma`): a narrow window needs far fewer scales
    # than the old fixed 10, and scales are the dominant cost.
    "num_sigma": None,
    "sigma_ratio": 1.6,            # blob_dog only
    "threshold": 0.10,             # applied to the normalized-to-[0,1] channel image
    "overlap": 0.5,
    "focus_count_threshold": 5,    # per-cell spot count considered "high-foci" / positive
}


def _resolve_params(params: dict | None) -> dict:
    out = dict(DEFAULT_PARAMS)
    if params:
        out.update({k: v for k, v in params.items() if v is not None})
    return out


#: How far outside the requested diameter window the blob search runs.
#:
#: `blob_log`/`blob_dog` do not REJECT a blob outside their sigma range — they
#: return it clamped to the boundary sigma. Searching a slightly wider window
#: than the user asked for means an out-of-range spot comes back at a sigma
#: that is still recognisably out of range, so the post-filter in
#: `detect_spots` can drop it instead of reporting it at a fabricated,
#: boundary-valued diameter.
_SEARCH_WIDEN = 1.2


def _log(msg: str) -> None:
    """Progress line on STDERR, in the prefix the GUI already parses.

    stdout carries the single JSON payload and must stay clean.
    """
    try:
        sys.stderr.write(f"[cellpose_detect] puncta: {msg}\n")
        sys.stderr.flush()
    except Exception:
        pass


#: Scale count for `blob_log` when the caller didn't pin one.
#:
#: Cost is linear in the number of scales, and the old fixed 10 was generous:
#: the user has already bounded the diameter window, so the search only has to
#: resolve that window. ~3 scales per octave (a factor-2 change in sigma) is
#: plenty to localise a blob, clamped to [3, 10] so a very wide window still
#: behaves like the old default and a very narrow one costs almost nothing.
def _resolve_num_sigma(p: dict, min_sigma_px: float, max_sigma_px: float) -> int:
    explicit = p.get("num_sigma")
    if explicit is not None:
        try:
            return max(1, int(explicit))
        except Exception:
            pass
    try:
        octaves = math.log2(max(1.0, max_sigma_px / max(1e-6, min_sigma_px)))
    except Exception:
        octaves = 1.0
    return int(max(3, min(10, round(3.0 * octaves) or 3)))


def _sigma_range_px(params: dict, px_per_um: float,
                    widen: float = 1.0) -> tuple[float, float]:
    """µm spot-diameter params -> (min_sigma_px, max_sigma_px) for blob_log/blob_dog.

    skimage's documented relationship for a 2-D blob is radius ~= sigma *
    sqrt(2), so sigma = radius / sqrt(2) = (diameter / 2) / sqrt(2).

    `widen` > 1 expands the range symmetrically (min ÷ widen, max × widen) to
    produce the SEARCH range — see `_SEARCH_WIDEN`. Leave it at 1.0 to get the
    exact range the user's µm params describe.
    """
    pxu = float(px_per_um) if px_per_um and px_per_um > 0 else 1.0
    w = float(widen) if widen and widen > 0 else 1.0
    min_d = max(1e-6, float(params["min_diameter_um"]))
    max_d = max(min_d, float(params["max_diameter_um"]))
    min_sigma_px = max(0.5, (min_d / 2.0) / math.sqrt(2.0) * pxu / w)
    max_sigma_px = max(min_sigma_px + 0.1, (max_d / 2.0) / math.sqrt(2.0) * pxu * w)
    return min_sigma_px, max_sigma_px


def _normalize_channel(channel_img):
    """Return (normalized, raw) as 2-D float64 arrays, or (None, None) on failure.

    `normalized` is clipped to [0, 1] using a robust 0.1/99.9 percentile
    stretch (resistant to a handful of hot/dead pixels) — blob detection
    runs on this copy so `threshold` behaves consistently across images
    regardless of source bit depth or exposure. `raw` is the same array
    (NaN/Inf swapped for 0) in its ORIGINAL intensity units — every
    intensity value reported to the caller (peak/mean spot intensity) is
    measured on `raw`, never on the normalized copy, so numbers stay
    meaningful to the user.

    A defensive H×W×C input is mean-collapsed across channels; callers
    should normally already pass a single selected plane.
    """
    import numpy as np

    try:
        arr = np.asarray(channel_img)
        if arr.ndim == 3:
            arr = arr.mean(axis=-1)
        if arr.ndim != 2 or arr.size == 0:
            return None, None
        raw = arr.astype(np.float64, copy=True)
        if not np.isfinite(raw).all():
            raw = np.nan_to_num(raw, nan=0.0, posinf=0.0, neginf=0.0)
        lo = float(np.percentile(raw, 0.1))
        hi = float(np.percentile(raw, 99.9))
        if hi <= lo:
            hi = lo + 1.0
        norm = np.clip((raw - lo) / (hi - lo), 0.0, 1.0)
        return norm, raw
    except Exception:
        return None, None


def detect_spots(channel_img, px_per_um: float, params: dict | None = None,
                 *, size_rejects: list | None = None) -> list[dict]:
    """Detect diffraction-limited spots in a single fluorescence channel.

    Parameters
    ----------
    channel_img : 2-D array (H, W)
        Raw or preprocessed intensities for ONE channel — e.g. a plane from
        `_imageio.load_planes(...)` already sliced to the channel of
        interest. An H×W×C array is accepted defensively (mean-collapsed);
        callers should normally pass a single already-selected plane.
    px_per_um : float
        Pixels per micrometer. Converts the µm size params below into the
        pixel-space sigma range `blob_log`/`blob_dog` need.
    params : dict, optional
        See `DEFAULT_PARAMS`: method ("log"|"dog"), min_diameter_um,
        max_diameter_um, num_sigma, sigma_ratio, threshold, overlap.
    size_rejects : list, optional
        Out-parameter; the number of blobs dropped by the size filter below is
        appended to it (used by `compute()` for `n_spots_rejected_by_size`).

    Size filtering
    --------------
    `min_diameter_um`/`max_diameter_um` are a real SIZE FILTER here, not just
    the blob detector's search range. skimage's `blob_log`/`blob_dog` CLAMP an
    out-of-range blob to the boundary sigma rather than rejecting it, so a
    narrow window used to return MORE spots, every one of them labelled with a
    fabricated boundary diameter: on an image containing only 2.0 µm spots
    (4 of them), a 0.3–0.6 µm window returned 7 spots all labelled Ø0.6, and a
    3.5–5.0 µm window returned 4 spots all labelled Ø3.5. The search therefore
    runs over a `_SEARCH_WIDEN`-widened sigma range and every blob whose
    measured diameter falls outside the REQUESTED window is dropped afterwards.

    Returns
    -------
    list[dict] — one entry per detected spot, sorted by (y_px, x_px) for a
    deterministic, reproducible order. Each has a UUID `id`, pixel + µm
    coordinates, `sigma_px`, `radius_um`/`diameter_um`, `peak_intensity` and
    `mean_intensity` (both measured on the RAW image — see
    `_normalize_channel`), and `cell_label` (None until
    `assign_spots_to_cells` runs). Never raises: returns [] if skimage is
    unavailable or the image/params are degenerate.
    """
    p = _resolve_params(params)
    pxu = float(px_per_um) if px_per_um and px_per_um > 0 else 1.0

    norm, raw = _normalize_channel(channel_img)
    if norm is None:
        return []

    try:
        from skimage.feature import blob_dog, blob_log
        from skimage.draw import disk
    except Exception:
        return []

    min_sigma_px, max_sigma_px = _sigma_range_px(p, pxu, widen=_SEARCH_WIDEN)
    threshold = float(p["threshold"])
    overlap = min(1.0, max(0.0, float(p["overlap"])))
    want_min_d = max(1e-6, float(p["min_diameter_um"]))
    want_max_d = max(want_min_d, float(p["max_diameter_um"]))

    method = str(p.get("method", "dog")).lower()
    try:
        if method == "dog":
            _log(f"detecting spots (dog, sigma {min_sigma_px:.2f}-{max_sigma_px:.2f} px)")
            blobs = blob_dog(norm, min_sigma=min_sigma_px, max_sigma=max_sigma_px,
                             sigma_ratio=float(p.get("sigma_ratio", 1.6)),
                             threshold=threshold, overlap=overlap)
        else:
            n_sigma = _resolve_num_sigma(p, min_sigma_px, max_sigma_px)
            _log(f"detecting spots (log, {n_sigma} scales over sigma "
                 f"{min_sigma_px:.2f}-{max_sigma_px:.2f} px) - this is the slow path")
            blobs = blob_log(norm, min_sigma=min_sigma_px, max_sigma=max_sigma_px,
                             num_sigma=n_sigma,
                             threshold=threshold, overlap=overlap)
    except Exception:
        return []
    _log(f"blob detector returned {0 if blobs is None else len(blobs)} candidate(s)")

    if blobs is None or len(blobs) == 0:
        return []

    h, w = raw.shape
    spots: list[dict] = []
    n_rejected = 0
    for row in blobs:
        y, x, sigma = float(row[0]), float(row[1]), float(row[2])
        radius_px = sigma * math.sqrt(2.0)

        # SIZE FILTER (see the docstring): the detector clamps rather than
        # rejects, so anything outside the window the caller actually asked for
        # is dropped here — reporting it at its clamped boundary diameter would
        # be inventing a measurement.
        diameter_um = 2.0 * radius_px / pxu
        if not (want_min_d <= diameter_um <= want_max_d):
            n_rejected += 1
            continue

        iy = min(max(int(round(y)), 0), h - 1)
        ix = min(max(int(round(x)), 0), w - 1)
        peak_intensity = float(raw[iy, ix])
        try:
            rr, cc = disk((y, x), max(1.0, radius_px), shape=raw.shape)
            mean_intensity = float(raw[rr, cc].mean()) if rr.size else peak_intensity
        except Exception:
            mean_intensity = peak_intensity

        spots.append({
            "id": str(uuid.uuid4()),
            "x_px": x, "y_px": y,
            "x_um": x / pxu, "y_um": y / pxu,
            "sigma_px": sigma,
            "radius_um": radius_px / pxu,
            "diameter_um": diameter_um,
            "peak_intensity": peak_intensity,
            "mean_intensity": mean_intensity,
            "cell_label": None,
        })

    if size_rejects is not None:
        size_rejects.append(n_rejected)
    spots.sort(key=lambda s: (s["y_px"], s["x_px"]))
    return spots


def _normalize_labeled_centroids(centroids) -> list[tuple[Any, float, float]]:
    """(label, x_px, y_px) triples from dicts / (label,x,y) / (x,y) inputs.

    Same shapes `_spatial._normalize_centroids` accepts — kept as an
    independent, tiny copy so this module has no import-time dependency on
    `_spatial.py` (each stays a standalone, individually testable unit, per
    this pass's "pure functions, no plumbing" design).
    """
    out: list[tuple[Any, float, float]] = []
    if not centroids:
        return out
    for i, item in enumerate(centroids):
        try:
            if isinstance(item, dict):
                cx = item.get("cx", item.get("x"))
                cy = item.get("cy", item.get("y"))
                if cx is None or cy is None:
                    continue
                label = item.get("label", item.get("id", i))
                out.append((label, float(cx), float(cy)))
            elif hasattr(item, "__len__") and not isinstance(item, (str, bytes)):
                if len(item) >= 3:
                    out.append((item[0], float(item[1]), float(item[2])))
                elif len(item) == 2:
                    out.append((i, float(item[0]), float(item[1])))
        except Exception:
            continue
    return out


def assign_spots_to_cells(spots: list[dict], *, label_map=None, centroids=None,
                          max_distance_um: float | None = None,
                          px_per_um: float = 1.0) -> None:
    """Assign each spot to a cell IN PLACE (sets spot["cell_label"]).

    `label_map` takes priority when given: a spot is assigned to
    `label_map[round(y_px), round(x_px)]` — exact mask containment. Spots
    landing on background (0) or outside the array bounds stay unassigned
    (`cell_label=None`).

    When `label_map` is None, falls back to nearest-centroid assignment
    using `centroids` (see `_normalize_labeled_centroids` for accepted
    shapes). A spot is only assigned when its nearest centroid is within
    `max_distance_um` — pass None for "always assign to the nearest
    centroid" (only sensible for sparse, well-separated cells; the default
    CLI/UI should set a real radius).

    With neither `label_map` nor `centroids`, every spot's `cell_label` is
    left as detected (None). Never raises.
    """
    if not spots:
        return

    if label_map is not None:
        try:
            import numpy as np
            arr = np.asarray(label_map)
            if arr.ndim == 2 and arr.size > 0:
                h, w = arr.shape
                for s in spots:
                    iy = int(round(s["y_px"]))
                    ix = int(round(s["x_px"]))
                    if 0 <= iy < h and 0 <= ix < w:
                        lab = int(arr[iy, ix])
                        s["cell_label"] = lab if lab != 0 else None
                    else:
                        s["cell_label"] = None
                return
        except Exception:
            pass  # fall through to the centroid path below

    norm_centroids = _normalize_labeled_centroids(centroids)
    if not norm_centroids:
        return

    try:
        import numpy as np
        pxu = float(px_per_um) if px_per_um and px_per_um > 0 else 1.0
        labels = [c[0] for c in norm_centroids]
        pts = np.array([(c[1], c[2]) for c in norm_centroids], dtype=np.float64)
        max_dist_px = (float(max_distance_um) * pxu) if max_distance_um is not None else None

        try:
            from scipy.spatial import cKDTree
            tree = cKDTree(pts)
            for s in spots:
                d, idx = tree.query([s["x_px"], s["y_px"]], k=1)
                if max_dist_px is None or d <= max_dist_px:
                    s["cell_label"] = labels[int(idx)]
        except Exception:
            for s in spots:
                sx, sy = s["x_px"], s["y_px"]
                d2 = [(sx - px) ** 2 + (sy - py) ** 2 for (_, px, py) in norm_centroids]
                j = min(range(len(d2)), key=lambda k: d2[k])
                d = math.sqrt(d2[j])
                if max_dist_px is None or d <= max_dist_px:
                    s["cell_label"] = labels[j]
    except Exception:
        return


def rasterize_polygons(polygons, shape: tuple[int, int]):
    """Build an integer label map from per-cell polygon contours.

    Parameters
    ----------
    polygons : iterable
        Either `(label, [(x, y), (x, y), ...])` pairs, or dicts with
        `label`/`id` + `polygon` (or `contour_px`) keys — the latter
        mirrors the `contour_px` field the detection sidecars already emit
        (`[[x, y], ...]` in image-pixel space; see `_cellpose_common.py`'s
        `measure_cells()` for the producing side — this module only reads
        that shape by convention and does not import that file).
    shape : (height_px, width_px)
        Target label-map size.

    Returns
    -------
    (label_map, index_to_label) :
        label_map : int32 ndarray, `shape`, 0=background, 1..N = synthetic
            per-polygon ids assigned in input order (1-based) — NOT
            necessarily the caller's own `label`/`id` (which is often a
            non-integer, e.g. a UUID string).
        index_to_label : dict[int, Any] mapping each synthetic id back to
            the caller-supplied `label`/`id`, so downstream results can be
            reported against the caller's own cell identifiers. Pass this
            straight through to `compute(..., label_id_map=index_to_label)`.

    Later polygons overwrite earlier ones where they overlap (real cell
    segmentations shouldn't overlap in practice), so a fully-covered polygon
    can end up with ZERO pixels in `label_map`. It still gets an id in
    `index_to_label` — pass that map to `compute(..., label_id_map=...)` and
    such a cell stays in the cell count (with zero spots) instead of silently
    vanishing from the "% cells above threshold" denominator;
    `summary["n_cells_with_no_pixels"]` reports how many that was. Polygons
    that fail to parse (too few points, non-numeric) are skipped. Never raises
    — returns an all-zero array + empty map if skimage/numpy are unavailable,
    `shape` is degenerate, or `polygons` is empty.
    """
    import numpy as np

    h, w = int(shape[0]), int(shape[1])
    out = np.zeros((max(h, 0), max(w, 0)), dtype=np.int32)
    index_to_label: dict[int, Any] = {}
    if not polygons or h <= 0 or w <= 0:
        return out, index_to_label

    try:
        from skimage.draw import polygon as sk_polygon
    except Exception:
        return out, index_to_label

    next_id = 1
    for i, item in enumerate(polygons):
        try:
            if isinstance(item, dict):
                orig_label = item.get("label", item.get("id", i))
                pts = item.get("polygon") or item.get("contour_px") or []
            else:
                orig_label, pts = item
            if not pts or len(pts) < 3:
                continue
            xs = np.array([float(pt[0]) for pt in pts])
            ys = np.array([float(pt[1]) for pt in pts])
            rr, cc = sk_polygon(ys, xs, shape=out.shape)
            if rr.size == 0:
                continue
            sid = next_id
            next_id += 1
            out[rr, cc] = sid
            index_to_label[sid] = orig_label
        except Exception:
            continue
    return out, index_to_label


def compute(channel_img, px_per_um: float, params: dict | None = None, *,
           label_map=None, centroids=None,
           max_assign_distance_um: float | None = None,
           label_id_map: dict | None = None) -> dict:
    """Detect spots, assign them to cells, and summarize — the top-level entry point.

    Parameters
    ----------
    channel_img : 2-D array — see `detect_spots`.
    px_per_um : float — pixels per micrometer.
    params : dict, optional — see `DEFAULT_PARAMS`.
    label_map : 2-D int array, optional
        0=background, 1..N=cell ids. Preferred cell source (exact
        mask-containment assignment). Build one from stored polygons with
        `rasterize_polygons()` (pass its `index_to_label` as `label_id_map`
        below so the output uses your own cell ids).
    centroids : sequence, optional
        Used only when `label_map` is None — see `assign_spots_to_cells`.
    max_assign_distance_um : float, optional
        Cutoff for the centroid-fallback path. Ignored when `label_map` is given.
    label_id_map : dict[int, Any], optional
        Translates the synthetic integer ids from `rasterize_polygons()`
        back to the caller's own cell ids in the returned `spots`/`cells`.

    Returns
    -------
    dict, always JSON-serialisable, never raises:
        spots         : list of per-spot dicts (see `detect_spots`; `cell_label`
                        resolved through `label_id_map` when given).
        cells         : [{cell_label, spot_count, mean_spot_intensity}, ...] —
                        one entry per KNOWN cell, including zero-spot cells.
        summary       : {total_spots, n_cells, n_cells_with_no_pixels,
                        n_assigned_spots, n_unassigned_spots,
                        mean_spots_per_cell, median_spots_per_cell,
                        focus_count_threshold, n_cells_above_threshold,
                        pct_cells_above_threshold}
        params_used   : resolved numeric params (the requested sigma window,
                        the widened window actually searched, and
                        n_spots_rejected_by_size) for transparency/debugging.
        message       : str | None — set whenever the result is degraded
                        (no cell source, zero cells, zero spots, ...).
    """
    p = _resolve_params(params)
    pxu = float(px_per_um) if px_per_um and px_per_um > 0 else 1.0

    size_rejects: list[int] = []
    spots = detect_spots(channel_img, pxu, p, size_rejects=size_rejects)
    min_sigma_px, max_sigma_px = _sigma_range_px(p, pxu)
    search_min_sigma_px, search_max_sigma_px = _sigma_range_px(
        p, pxu, widen=_SEARCH_WIDEN)

    result: dict[str, Any] = {
        "spots": spots,
        "cells": [],
        "summary": None,
        "params_used": {
            "method": p["method"],
            "min_diameter_um": float(p["min_diameter_um"]),
            "max_diameter_um": float(p["max_diameter_um"]),
            "threshold": float(p["threshold"]),
            "overlap": float(p["overlap"]),
            "focus_count_threshold": float(p["focus_count_threshold"]),
            # The sigma window the requested µm diameters map to …
            "min_sigma_px": min_sigma_px,
            "max_sigma_px": max_sigma_px,
            # … and the widened window the blob detector actually searched,
            # before the size filter dropped anything outside the requested one.
            "search_min_sigma_px": search_min_sigma_px,
            "search_max_sigma_px": search_max_sigma_px,
            "search_widen": _SEARCH_WIDEN,
            "n_spots_rejected_by_size": int(size_rejects[0]) if size_rejects else 0,
        },
        "message": None,
    }

    have_cell_source = label_map is not None or centroids is not None
    n_cells_with_no_pixels = 0

    try:
        # ---- cell universe --------------------------------------------------
        # The DENOMINATOR of "% cells above threshold" is this list, so it has
        # to be every cell the caller told us about — not every cell still
        # visible in the raster. `rasterize_polygons` lets a later polygon
        # overwrite an earlier one, so a fully-overlapped cell has zero pixels
        # left in `label_map` and used to disappear from the denominator
        # entirely (silently shrinking it). When the caller supplied
        # `label_id_map` we take the universe from there and report how many of
        # those cells ended up with no pixels.
        cell_ids: list[Any] = []
        if label_map is not None:
            import numpy as np
            arr = np.asarray(label_map)
            raster_ids = sorted(int(v) for v in np.unique(arr) if v != 0)
            if label_id_map:
                known = sorted(int(rid) for rid in label_id_map)
                present = set(raster_ids)
                n_cells_with_no_pixels = sum(1 for rid in known
                                             if rid not in present)
                cell_ids = [label_id_map[rid] for rid in known]
            else:
                cell_ids = list(raster_ids)
        elif centroids is not None:
            cell_ids = [c[0] for c in _normalize_labeled_centroids(centroids)]

        # ---- assignment -------------------------------------------------------
        assign_spots_to_cells(spots, label_map=label_map, centroids=centroids,
                              max_distance_um=max_assign_distance_um, px_per_um=pxu)
        if label_map is not None and label_id_map:
            for s in spots:
                if s["cell_label"] is not None:
                    s["cell_label"] = label_id_map.get(s["cell_label"], s["cell_label"])

        # ---- per-cell aggregation ----------------------------------------------
        per_cell_spots: dict[Any, list[dict]] = {cid: [] for cid in cell_ids}
        n_unassigned = 0
        for s in spots:
            cl = s["cell_label"]
            if cl is None:
                n_unassigned += 1
                continue
            per_cell_spots.setdefault(cl, []).append(s)

        all_ids = list(cell_ids)
        for cid in per_cell_spots:
            if cid not in all_ids:
                all_ids.append(cid)

        cells_out = []
        for cid in all_ids:
            spot_list = per_cell_spots.get(cid, [])
            mean_intensity = (sum(sp["mean_intensity"] for sp in spot_list) / len(spot_list)
                              if spot_list else None)
            cells_out.append({
                "cell_label": cid,
                "spot_count": len(spot_list),
                "mean_spot_intensity": mean_intensity,
            })
        result["cells"] = cells_out

        # ---- summary -------------------------------------------------------
        n_cells = len(cells_out)
        total_spots = len(spots)
        focus_threshold = float(p["focus_count_threshold"])

        if n_cells > 0:
            counts_list = [c["spot_count"] for c in cells_out]
            counts_sorted = sorted(counts_list)
            mean_spc = sum(counts_list) / n_cells
            mid = n_cells // 2
            median_spc = (counts_sorted[mid] if n_cells % 2 == 1
                         else (counts_sorted[mid - 1] + counts_sorted[mid]) / 2.0)
            n_above = sum(1 for c in counts_list if c >= focus_threshold)
            pct_above = 100.0 * n_above / n_cells
        else:
            mean_spc = None
            median_spc = None
            n_above = 0
            pct_above = None

        result["summary"] = {
            "total_spots": total_spots,
            "n_cells": n_cells,
            "n_cells_with_no_pixels": n_cells_with_no_pixels,
            "n_assigned_spots": total_spots - n_unassigned,
            "n_unassigned_spots": n_unassigned,
            "mean_spots_per_cell": mean_spc,
            "median_spots_per_cell": median_spc,
            "focus_count_threshold": focus_threshold,
            "n_cells_above_threshold": n_above,
            "pct_cells_above_threshold": pct_above,
        }

        notes: list[str] = []
        if not have_cell_source:
            notes.append(f"No cell boundaries or centroids were provided — detected "
                         f"{total_spots} spot(s) but could not assign them to cells.")
        elif n_cells == 0:
            notes.append("No cells found — spots were detected but there are no "
                         "cells to assign them to.")
        elif total_spots == 0:
            notes.append("No spots detected with the current parameters.")
        if n_cells_with_no_pixels:
            notes.append(
                f"{n_cells_with_no_pixels} of {n_cells} cell(s) have no pixels "
                f"left in the rasterised mask — their polygons are fully "
                f"covered by later ones. They stay in the denominator with zero "
                f"spots, so any spots inside them are attributed to the "
                f"covering cell.")
        result["message"] = " ".join(notes) if notes else None

    except Exception as exc:  # noqa: BLE001
        # Keep whatever spots we already found; degrade the rest.
        result["cells"] = []
        result["summary"] = {
            "total_spots": len(spots),
            "n_cells": 0,
            "n_cells_with_no_pixels": n_cells_with_no_pixels,
            "n_assigned_spots": 0,
            "n_unassigned_spots": len(spots),
            "mean_spots_per_cell": None,
            "median_spots_per_cell": None,
            "focus_count_threshold": float(p["focus_count_threshold"]),
            "n_cells_above_threshold": 0,
            "pct_cells_above_threshold": None,
        }
        result["message"] = f"Cell assignment/summary failed: {exc!r}"

    return result
