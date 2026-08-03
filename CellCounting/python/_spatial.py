"""
_spatial.py — CellCounter cell-centroid spatial statistics.

Exposes:

    compute(centroids, px_per_um, image_shape, params=None) -> dict
    centroids_from_label_map(label_map) -> list[(label, x_px, y_px)]

Derives per-cell nearest-neighbour distance, local neighbour density, and
the Clark-Evans nearest-neighbour clustering index (R) from cell centroids
that already exist — this module never (re)segments anything. Centroids
normally come straight from an existing detection (`DetectedCell.cx/.cy` on
the Swift side, or the per-cell dicts `_cellpose_common.measure_cells()`
already emits); `centroids_from_label_map()` is a convenience for the rarer
case where only a raw label mask is on hand.

Relationship to `_colony.py`: `_colony.compute()` already folds ONE scalar
(`mean_nn_distance_um`) into the shared `image_stats` namespace read by
`ColoniesPanel`. This module is intentionally separate — it returns a rich
per-cell breakdown (nearest-neighbour distance AND local density per cell)
plus an optional density heatmap, none of which fits that flat
`image_stats: [String: Double]` shape. It backs its own results panel
(`Views/Results/SpatialStatsPanel.swift`) and does not write into
`image_stats`.

Clark-Evans nearest-neighbour index (Clark & Evans, 1954):

    R = mean(observed NND) / mean(expected NND under complete spatial
        randomness),  where expected NND = 1 / (2 * sqrt(N / A))

    R < 1  ->  clustered  (cells sit closer together than a random layout)
    R = 1  ->  random     (indistinguishable from complete spatial randomness)
    R > 1  ->  dispersed  (cells are more evenly spaced than random), up to
               a theoretical max of ~2.1491 for a perfect hexagonal grid

We also compute the standard z-score against the expected NND's standard
error (same 1954 paper) and use THAT — not an arbitrary band around R=1 —
to decide whether to actually call the result "random": R alone is noisy
for small N, and the z-score is the textbook way to say so. This is the
classic, uncorrected form: it does NOT apply an edge/boundary correction
(e.g. Donnelly 1978), so R trends slightly "clustered" for cells that sit
near the image border. That's a fine tradeoff for a fast, no-code readout;
it is not a substitute for a dedicated spatial-stats package if you need
publication-grade rigor on boundary effects.

Failure mode: every public function is defensive. Bad/missing input (too
few cells, missing numpy/scipy/skimage, a degenerate image_shape, ...)
produces a well-formed dict with a human-readable "message" and null/empty
numeric fields — never an exception.
"""

from __future__ import annotations

import math
from typing import Any


DEFAULT_PARAMS: dict[str, Any] = {
    "radius_um": 50.0,        # local-density neighbour search radius
    "heatmap": False,         # also compute a density-heatmap grid?
    "heatmap_bin_um": 25.0,   # target heatmap bin size (µm per side)
    "heatmap_max_bins": 64,   # cap grid resolution per axis (payload size)
}


def _resolve_params(params: dict | None) -> dict:
    out = dict(DEFAULT_PARAMS)
    if params:
        out.update({k: v for k, v in params.items() if v is not None})
    return out


def _normalize_centroids(cells) -> list[tuple[Any, float, float]]:
    """Normalize `cells` into a list of (label, x_px, y_px) triples.

    Accepts, per entry:
      - a dict with 'cx'/'cy' (or 'x'/'y') keys and an optional
        'label'/'id' — mirrors `DetectedCell`/`SidecarCell` field names so a
        caller can pass its existing cell list straight through. Falls back
        to the entry's 0-based index when no label/id is present.
      - a (label, x, y) triple (e.g. from `centroids_from_label_map`).
      - a bare (x, y) pair — labelled by its 0-based index.

    Never raises — unparseable entries are silently skipped.
    """
    out: list[tuple[Any, float, float]] = []
    if not cells:
        return out
    for i, item in enumerate(cells):
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


def centroids_from_label_map(label_map) -> list[tuple[Any, float, float]]:
    """Extract (label, x_px, y_px) centroids from a 2-D integer label mask.

    0 = background; each distinct positive integer is one cell. Returns one
    centroid per distinct label, sorted by label id ascending. Never raises
    — returns [] on any failure (missing numpy/skimage, bad shape, ...).
    """
    try:
        import numpy as np
    except Exception:
        return []

    try:
        arr = np.asarray(label_map)
        if arr.ndim != 2 or arr.size == 0:
            return []
        try:
            from skimage.measure import regionprops
            props = sorted(regionprops(arr.astype(np.int64, copy=False)),
                           key=lambda pr: pr.label)
            return [(int(pr.label), float(pr.centroid[1]), float(pr.centroid[0]))
                    for pr in props]
        except Exception:
            out: list[tuple[Any, float, float]] = []
            for lab in sorted(int(v) for v in np.unique(arr) if v != 0):
                ys, xs = np.where(arr == lab)
                if ys.size == 0:
                    continue
                out.append((lab, float(xs.mean()), float(ys.mean())))
            return out
    except Exception:
        return []


def _interpret_clark_evans(r: float, z: float) -> str:
    if abs(z) < 1.96:
        return (f"Random — R={r:.2f}, not significantly different from a random "
                f"arrangement (|z|={abs(z):.2f} < 1.96, p>0.05).")
    if r < 1.0:
        return (f"Clustered — R={r:.2f}; cells sit closer together than expected "
                f"under a random arrangement (z={z:.2f}).")
    return (f"Dispersed — R={r:.2f}; cells are more evenly spaced than expected "
            f"under a random arrangement (z={z:.2f}).")


def _density_heatmap(xy, pxu: float, image_shape, p: dict) -> dict | None:
    """2-D histogram of cell centroids over the image extent (µm-binned).

    Returns a JSON-friendly dict with `grid[row][col]` (row=y top-to-bottom,
    col=x left-to-right) — cheap enough to compute per-image and small
    enough (capped at `heatmap_max_bins` per axis) for the UI to render
    directly as a heatmap. Returns None on a degenerate image_shape.
    """
    import numpy as np

    height_px, width_px = float(image_shape[0]), float(image_shape[1])
    width_um = width_px / pxu
    height_um = height_px / pxu
    if width_um <= 0 or height_um <= 0:
        return None

    bin_um = max(1e-6, float(p.get("heatmap_bin_um", 25.0)))
    max_bins = max(1, int(p.get("heatmap_max_bins", 64)))
    nx = int(min(max_bins, max(1, round(width_um / bin_um))))
    ny = int(min(max_bins, max(1, round(height_um / bin_um))))

    xs_um = xy[:, 0] / pxu
    ys_um = xy[:, 1] / pxu
    counts, _xedges, _yedges = np.histogram2d(
        xs_um, ys_um, bins=[nx, ny], range=[[0, width_um], [0, height_um]])

    # counts is (nx, ny) indexed [xbin, ybin]; transpose to row-major image
    # orientation so grid[row][col] reads like the image (row=y, col=x).
    grid = counts.T.tolist()
    return {
        "grid": grid,
        "nx": nx,
        "ny": ny,
        "cell_width_um": width_um / nx,
        "cell_height_um": height_um / ny,
        "x0_um": 0.0,
        "y0_um": 0.0,
        "orientation": "grid[row][col]; row=y (top-to-bottom), col=x (left-to-right)",
    }


def compute(centroids, px_per_um: float, image_shape,
           params: dict | None = None) -> dict:
    """Compute per-cell + per-image spatial statistics from cell centroids.

    Parameters
    ----------
    centroids : sequence
        Cell centroids — see `_normalize_centroids` for every accepted
        shape (dicts with cx/cy, (label,x,y) triples, bare (x,y) pairs). Use
        `centroids_from_label_map()` first if all you have is a label mask.
    px_per_um : float
        Pixels per micrometer (matches the `_colony.py` / `_cellpose_common.py`
        convention — pixels-per-micron, NOT micron-per-pixel).
    image_shape : (height_px, width_px)
        Source image size in pixels. Drives the Clark-Evans expected density
        and (when requested) the heatmap extent.
    params : dict, optional
        See `DEFAULT_PARAMS`. Missing keys fall back to the default.

    Returns
    -------
    dict, always JSON-serialisable, never raises:
        n_cells                        : int
        per_cell                       : [{index, label, cx_px, cy_px,
                                           nn_distance_um, nn_index, nn_label,
                                           local_density}, ...]
        mean_nnd_um / median_nnd_um /
        min_nnd_um / max_nnd_um        : float | None (image-level NND stats)
        density_radius_um              : float (echoes the resolved param)
        mean_local_density             : float | None
        clark_evans_R                  : float | None
        clark_evans_z                  : float | None
        clark_evans_interpretation     : str | None (plain-language readout)
        heatmap                        : dict | None (see `_density_heatmap`)
        message                        : str | None — set whenever the
                                          result is degraded (e.g. <2 cells).
    """
    p = _resolve_params(params)
    pxu = float(px_per_um) if px_per_um and px_per_um > 0 else 1.0

    triples = _normalize_centroids(centroids)
    n = len(triples)

    result: dict[str, Any] = {
        "n_cells": n,
        "per_cell": [],
        "mean_nnd_um": None,
        "median_nnd_um": None,
        "min_nnd_um": None,
        "max_nnd_um": None,
        "density_radius_um": float(p["radius_um"]),
        "mean_local_density": None,
        "clark_evans_R": None,
        "clark_evans_z": None,
        "clark_evans_interpretation": None,
        "heatmap": None,
        "message": None,
    }

    if n == 0:
        result["message"] = "No cells to analyze."
        return result
    if n == 1:
        label, x, y = triples[0]
        result["per_cell"] = [{
            "index": 0, "label": label, "cx_px": x, "cy_px": y,
            "nn_distance_um": None, "nn_index": None, "nn_label": None,
            "local_density": 0,
        }]
        result["message"] = "Only 1 cell — nearest-neighbour statistics need at least 2."
        return result

    try:
        import numpy as np

        labels = [t[0] for t in triples]
        xy = np.array([(t[1], t[2]) for t in triples], dtype=np.float64)  # (N,2) as (x,y) px
        radius_px = float(p["radius_um"]) * pxu

        try:
            from scipy.spatial import cKDTree
            tree = cKDTree(xy)
            dists, idxs = tree.query(xy, k=2)
            nn_dist_px = dists[:, 1]
            nn_idx = idxs[:, 1].astype(np.int64)
            neighbor_lists = tree.query_ball_point(xy, r=radius_px)
            local_density = np.array([max(0, len(lst) - 1) for lst in neighbor_lists])
        except Exception:
            diff = xy[:, None, :] - xy[None, :, :]
            d = np.sqrt((diff * diff).sum(axis=-1))
            np.fill_diagonal(d, np.inf)
            nn_idx = d.argmin(axis=1)
            nn_dist_px = d[np.arange(n), nn_idx]
            local_density = (d <= radius_px).sum(axis=1)

        nn_dist_um = nn_dist_px / pxu

        per_cell = []
        for i in range(n):
            j = int(nn_idx[i])
            per_cell.append({
                "index": i,
                "label": labels[i],
                "cx_px": float(xy[i, 0]),
                "cy_px": float(xy[i, 1]),
                "nn_distance_um": float(nn_dist_um[i]),
                "nn_index": j,
                "nn_label": labels[j] if 0 <= j < n else None,
                "local_density": int(local_density[i]),
            })
        result["per_cell"] = per_cell
        result["mean_nnd_um"] = float(np.mean(nn_dist_um))
        result["median_nnd_um"] = float(np.median(nn_dist_um))
        result["min_nnd_um"] = float(np.min(nn_dist_um))
        result["max_nnd_um"] = float(np.max(nn_dist_um))
        result["mean_local_density"] = float(np.mean(local_density))

        # ---- Clark-Evans R --------------------------------------------------
        height_px, width_px = float(image_shape[0]), float(image_shape[1])
        area_um2 = (width_px / pxu) * (height_px / pxu)
        if area_um2 > 0:
            density = n / area_um2
            expected_nnd_um = 1.0 / (2.0 * math.sqrt(density))
            observed_nnd_um = result["mean_nnd_um"]
            if expected_nnd_um > 0:
                r_value = observed_nnd_um / expected_nnd_um
                se = 0.26136 / math.sqrt(n * density)
                z = (observed_nnd_um - expected_nnd_um) / se if se > 0 else 0.0
                result["clark_evans_R"] = float(r_value)
                result["clark_evans_z"] = float(z)
                result["clark_evans_interpretation"] = _interpret_clark_evans(r_value, z)
        if result["clark_evans_R"] is None:
            result["message"] = "Image dimensions are too small to estimate an expected density."

        # ---- optional density heatmap ---------------------------------------
        if p.get("heatmap"):
            result["heatmap"] = _density_heatmap(xy, pxu, image_shape, p)

    except Exception as exc:  # noqa: BLE001
        result["message"] = f"Spatial statistics failed: {exc!r}"

    return result
