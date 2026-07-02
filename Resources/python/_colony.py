"""
_colony.py — CellCounter pass-6 colony / spatial statistics (C2).

Exposes:

    compute(labels, px_per_um, image_shape) -> dict

`labels` is a 2-D integer mask: 0 = background, 1..N = per-cell labels. The
function returns a flat dict of per-image scalars (all `float` or `int`) so it
can be merged directly into a single `"image_stats"` JSON namespace shared
with C3 (QC metrics — focus_score, illumination_residual).

Stem-cell-enrichment readout: keratinocyte stem cells form holoclones (dense
colonies of round small cells). The five colony statistics quantify that
density / clustering so the user can compare populations across conditions.

Failure mode: never raises — on any unexpected input the function returns a
dict of zero-valued metrics so the calling sidecar can keep emitting cells.
"""

from __future__ import annotations

from typing import Any


_ZERO_STATS: dict[str, float] = {
    "confluency_pct": 0.0,
    "n_colonies": 0,
    "mean_colony_size_cells": 0.0,
    "largest_colony_size_cells": 0,
    "largest_colony_area_um2": 0.0,
    "mean_nn_distance_um": 0.0,
}


def compute(labels: Any, px_per_um: float, image_shape: tuple[int, int]) -> dict[str, float]:
    """
    Compute per-image colony + spatial statistics from a labeled mask.

    Parameters
    ----------
    labels : 2-D integer numpy array
        0 = background; positive integers = individual cell labels.
    px_per_um : float
        Pixels per micrometer (must be > 0 for µm conversions to be meaningful).
    image_shape : (H, W)
        Source image height/width in pixels. Used as a tie-break if `labels`
        is missing; metrics fall back to `labels.shape` when available.

    Returns
    -------
    dict[str, float] with these keys (always present, never None):
        - confluency_pct          : % image area covered by cells (mask > 0)
        - n_colonies              : # connected components with >= 3 cells
                                    after a ~4 µm binary dilation
        - mean_colony_size_cells  : mean cells/colony across qualifying colonies
        - largest_colony_size_cells : max # cells in any colony
        - largest_colony_area_um2 : largest colony's component pixel area
                                    (within the original mask) / pxPerUm^2
        - mean_nn_distance_um     : mean nearest-neighbour centroid distance
                                    (µm); 0 if fewer than 2 cells.
    """
    try:
        import numpy as np
    except Exception:
        return dict(_ZERO_STATS)

    if labels is None:
        return dict(_ZERO_STATS)

    arr = np.asarray(labels)
    if arr.ndim != 2 or arr.size == 0:
        return dict(_ZERO_STATS)

    pxu = float(px_per_um) if px_per_um and px_per_um > 0 else 1.0
    h, w = arr.shape

    # ------------------------------------------------------------------
    # 1) Confluency: fraction of image area covered by cells.
    # ------------------------------------------------------------------
    binary = (arr > 0)
    confluency_pct = 100.0 * float(binary.sum()) / float(arr.size)

    # ------------------------------------------------------------------
    # 2) Per-cell centroids (label -> centroid in pixel coords).
    # ------------------------------------------------------------------
    label_ids = np.unique(arr)
    label_ids = label_ids[label_ids != 0]
    centroids: list[tuple[float, float]] = []  # (y, x)
    label_to_centroid: dict[int, tuple[float, float]] = {}
    for lab in label_ids:
        ys, xs = np.where(arr == lab)
        if ys.size == 0:
            continue
        cy = float(ys.mean())
        cx = float(xs.mean())
        centroids.append((cy, cx))
        label_to_centroid[int(lab)] = (cy, cx)

    # ------------------------------------------------------------------
    # 3) Colony detection: dilate ~4 µm and find connected components.
    #    Spec: dilate by int(8 * pxPerUm / 2) pixels with disk SE; label;
    #    count cell centroids in each component; keep components with >=3.
    # ------------------------------------------------------------------
    n_colonies = 0
    mean_colony_size = 0.0
    largest_colony_cells = 0
    largest_colony_area_um2 = 0.0

    if len(label_ids) >= 1:
        try:
            from skimage.morphology import binary_dilation, disk
            from skimage.measure import label as cc_label

            dilate_radius = max(1, int(8 * pxu / 2))  # ~4 µm radius
            se = disk(dilate_radius)
            dilated = binary_dilation(binary, footprint=se)
            cc = cc_label(dilated, connectivity=2)
            n_components = int(cc.max())

            if n_components > 0 and centroids:
                # Map each centroid to the component it falls into.
                component_cell_counts = np.zeros(n_components + 1, dtype=np.int64)
                for (cy, cx) in centroids:
                    iy = int(min(max(round(cy), 0), h - 1))
                    ix = int(min(max(round(cx), 0), w - 1))
                    comp_id = int(cc[iy, ix])
                    if comp_id > 0:
                        component_cell_counts[comp_id] += 1

                qualifying = [c for c in component_cell_counts[1:] if c >= 3]
                n_colonies = len(qualifying)
                if qualifying:
                    mean_colony_size = float(sum(qualifying)) / float(len(qualifying))
                    largest_colony_cells = int(max(qualifying))

                    # Largest-colony area: find the component id with the most
                    # cells, then sum *original mask* pixels inside it.
                    counts_arr = component_cell_counts.copy()
                    counts_arr[0] = 0
                    largest_comp_id = int(np.argmax(counts_arr))
                    if largest_comp_id > 0:
                        comp_mask = (cc == largest_comp_id) & binary
                        largest_pixels = int(comp_mask.sum())
                        largest_colony_area_um2 = float(largest_pixels) / (pxu * pxu)
        except Exception:
            # skimage missing or failed — fall through with zero colony stats.
            pass

    # ------------------------------------------------------------------
    # 4) Mean nearest-neighbour centroid distance (µm).
    # ------------------------------------------------------------------
    mean_nn_um = 0.0
    if len(centroids) >= 2:
        try:
            from scipy.spatial import cKDTree
            pts = np.array(centroids, dtype=np.float64)  # (N, 2) in (y, x)
            tree = cKDTree(pts)
            # k=2 → self + nearest; take column 1.
            dists, _ = tree.query(pts, k=2)
            nn_px = dists[:, 1]
            mean_nn_um = float(nn_px.mean()) / pxu
        except Exception:
            # scipy missing — fall back to a brute-force O(N^2) computation
            # so we still emit a value rather than silently zeroing it.
            try:
                import numpy as np  # noqa: F811 — already imported, but local for clarity
                pts = np.array(centroids, dtype=np.float64)
                diff = pts[:, None, :] - pts[None, :, :]
                d2 = (diff * diff).sum(axis=-1)
                # Mask the diagonal (self-distances) with +inf.
                np.fill_diagonal(d2, np.inf)
                nn_px = np.sqrt(d2.min(axis=1))
                mean_nn_um = float(nn_px.mean()) / pxu
            except Exception:
                mean_nn_um = 0.0

    return {
        "confluency_pct": float(confluency_pct),
        "n_colonies": int(n_colonies),
        "mean_colony_size_cells": float(mean_colony_size),
        "largest_colony_size_cells": int(largest_colony_cells),
        "largest_colony_area_um2": float(largest_colony_area_um2),
        "mean_nn_distance_um": float(mean_nn_um),
    }


def zero_stats() -> dict[str, float]:
    """Return the canonical zero-valued stats dict (used by yolo_detect fallback)."""
    return dict(_ZERO_STATS)
