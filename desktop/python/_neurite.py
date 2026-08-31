"""
_neurite.py — CellCounter neurite outgrowth measurement.

Exposes:

    analyze(neurite_mask, soma, px_per_um, params=None) -> dict

Pure function, no file/network/subprocess I/O — matches the pattern of
`_colony.compute()` / `_watershed.split()` elsewhere in this package: given
in-memory inputs it returns a plain JSON-serialisable dict, and it NEVER
raises (see "Never raises" below). `neurite_outgrowth.py` is the thin
CLI/JSON front door that calls this from a subprocess context.

Calibration convention: `px_per_um` is PIXELS PER MICROMETRE, matching
`args.pxPerUm` used by every Cellpose sidecar in this package — see
`_tracking.py`'s module docstring for the same note; both new modules use
the identical convention on purpose so a caller can pass the same
calibration value to either one.

Inputs
------
`neurite_mask` : 2-D array-like (bool or int)
    Nonzero pixels = neurite/process foreground. May or may not include the
    soma pixels themselves — either way we explicitly remove the soma
    footprint from the mask before counting primary processes (see
    "Algorithm" below), so it works whether the mask is neurite-only or a
    plain whole-cell threshold that happens to include the cell body.

`soma` : one of
  * a 2-D integer label mask (0 = background, 1..N = one soma per cell,
    e.g. the `masks` array a Cellpose sidecar already produces) — preferred:
    gives pixel-accurate nearest-soma attribution via a distance transform,
    so irregularly shaped somas are handled correctly.
  * a list of {"id", "cx", "cy"} dicts (centroids only — e.g. straight from
    a `DetectedCell` list with no separate soma segmentation available).
    Attribution falls back to nearest centroid; a synthetic disc of radius
    `params["soma_radius_um"]` (default 8.0 µm, a typical soma radius)
    stands in for the (unknown) soma footprint everywhere the algorithm
    needs one.
  * None / empty — no per-cell breakdown is possible; we still report
    whole-image skeleton totals rather than nothing.

Algorithm
---------
  1. Skeletonize the boolean neurite mask with
     `skimage.morphology.skeletonize` (thins to a ~1-pixel-wide medial-axis
     network).
  2. Remove every skeleton pixel inside (or within 1 px of) a soma footprint.
     This is what turns "one connected skeleton blob per cell, soma
     included" into a forest of separate per-process components rooted at
     the soma boundary — without this step a mask that includes the cell
     body would skeletonize into one component per cell regardless of how
     many processes it has, making "number of primary processes" impossible
     to recover.
  3. Label the remaining skeleton's 8-connected components
     (`scipy.ndimage.label`). Each component is one PRIMARY process — it
     originates where it touched the (now-removed) soma and may bifurcate
     any number of times downstream; those bifurcations are branch points
     WITHIN that same primary process, not separate processes. This matches
     how neurite outgrowth is conventionally scored (e.g. Sholl analysis /
     NeuronJ / SNT): a primary process is counted once, at its point of
     origin from the cell body.
  4. Attribute each component to the nearest soma by majority vote: for
     every pixel in the component, look up the nearest soma id (precomputed
     once for the whole image via `scipy.ndimage.distance_transform_edt`'s
     `return_indices` — an exact discrete Voronoi diagram over the soma
     labels) and assign the whole component to whichever soma id wins the
     most pixel votes. Majority vote (rather than e.g. the component's
     centroid alone) is more robust when a process curves across a Voronoi
     boundary partway along its length.
  5. Per soma: total length = sum of per-pixel-pair Euclidean edge lengths
     across every attributed skeleton pixel (a raw pixel COUNT would
     undercount a diagonal-heavy path's true length by up to sqrt(2) — see
     `_skeleton_length_um`); branch points = skeleton pixels with >= 3
     skeleton neighbours (8-connectivity), summed across the soma's
     attributed components; primary processes = number of attributed
     components.

KNOWN LIMITATION — read before trusting per-cell numbers in a dense field
--------------------------------------------------------------------------
Nearest-soma attribution (step 4) is a Voronoi partition: it cannot tell
that two DIFFERENT cells' neurites have grown into and physically merged
with each other in the mask (one connected skeleton component that
geometrically belongs to two somas at once). In that situation the whole
fused component is handed to whichever soma wins the majority vote, silently
over-counting that cell's length/branch points and under-counting the
other's. There is no reliable way to split a physically overlapping/fused
neurite mask back into per-cell contributions from 2-D shape alone — that
needs either a cell-specific marker per neurite (not available from a single
mask) or manual correction. Treat per-cell numbers as approximate in
crowded/overlapping fields. This caveat is surfaced verbatim in the
`caveat` field of every dict this module returns, and the UI (NeuritePanel)
displays it, unconditionally, next to the per-cell table — see that file's
`NeuriteOverlapCaveat` view.

Never raises: any unexpected failure is caught and reported via `message`
with empty per-cell stats, matching `_colony.compute`'s contract.
"""

from __future__ import annotations

import math
from typing import Any


_DEFAULT_SOMA_RADIUS_UM = 8.0

_CAVEAT = (
    "Overlapping or touching neurites from different cells cannot be "
    "reliably separated: branches are attributed to whichever cell body is "
    "nearest (a Voronoi partition of the skeleton), so a process that has "
    "physically merged with a neighbouring cell's process is credited "
    "entirely to whichever soma wins the majority of its pixels. Treat "
    "per-cell numbers as approximate in dense or overlapping fields."
)


def _safe_float(value: Any, default: float) -> float:
    """`float(value)` if finite and positive, else `default` — see `_tracking._safe_float`."""
    try:
        v = float(value)
    except (TypeError, ValueError):
        return default
    if not math.isfinite(v) or v <= 0:
        return default
    return v


def _empty_result(message: str, params: dict) -> dict:
    """The canonical degenerate/error result — mirrors `_colony.zero_stats()`."""
    return {
        "n_cells": 0,
        "cells": [],
        "mean_neurite_length_um": 0.0,
        "total_skeleton_length_um": 0.0,
        "soma_skeleton_length_um": 0.0,
        "unattributed_length_um": 0.0,
        "unattributed_component_length_um": 0.0,
        "caveat": _CAVEAT,
        "message": message,
        "params": params,
    }


def _skeleton_length_um(skel: Any, px_per_um: float) -> float:
    """Sum of Euclidean pixel-to-pixel edge lengths along a thin (~1px) skeleton.

    A raw pixel COUNT underestimates a diagonal-heavy path's true length by
    up to a factor of sqrt(2) (a 45-degree line of N pixels spans
    (N-1)*sqrt(2) px of real distance, not N-1 px) — so we sum edges between
    8-connected skeleton-pixel pairs instead of counting pixels. Each
    unordered pair is counted exactly once by only looking at 4 of the 8
    neighbour directions per pixel (the other 4 are the same pairs seen from
    the other pixel in the pair).
    """
    import numpy as np

    ys, xs = np.where(skel)
    if ys.size == 0:
        return 0.0
    coords = set(zip(ys.tolist(), xs.tolist()))
    total_px = 0.0
    # right, down, down-right, down-left — covers all 8 neighbour directions
    # without double-counting when swept over every pixel.
    half_offsets = ((0, 1), (1, 0), (1, 1), (1, -1))
    for (y, x) in coords:
        for dy, dx in half_offsets:
            if (y + dy, x + dx) in coords:
                total_px += math.hypot(dy, dx)
    return total_px / px_per_um


def _skeleton_neighbor_counts(skel: Any):
    """8-connected neighbour count for every skeleton pixel (0 elsewhere).

    Used to find branch points (>= 3 neighbours = a bifurcation).
    """
    import numpy as np
    from scipy import ndimage as ndi

    kernel = np.array([[1, 1, 1], [1, 0, 1], [1, 1, 1]], dtype=np.int64)
    counts = ndi.convolve(skel.astype(np.int64), kernel, mode="constant", cval=0)
    return counts * skel  # zero out non-skeleton pixels — only they matter.


def _build_soma_label_map(soma: Any, shape: tuple, px_per_um: float,
                           soma_radius_um: float):
    """Normalise `soma` into (labeled_mask, {label_int: soma_id_str}).

    Returns (None, {}) when there is no usable soma information (None,
    empty list, or a mask whose shape doesn't match `neurite_mask` — a size
    mismatch means we cannot align pixel-for-pixel, so we refuse to guess
    rather than silently attributing against misaligned coordinates).
    """
    import numpy as np

    if soma is None:
        return None, {}

    # Labeled mask input: 2-D array-like.
    if hasattr(soma, "ndim") and getattr(soma, "ndim", None) == 2:
        arr = np.asarray(soma)
        if arr.shape != tuple(shape):
            return None, {}
        label_ids = np.unique(arr)
        label_ids = label_ids[label_ids != 0]
        if label_ids.size == 0:
            return None, {}
        id_map = {int(lab): str(int(lab)) for lab in label_ids.tolist()}
        return arr.astype(np.int64), id_map

    # List of {"id", "cx", "cy"} centroid dicts -> synthetic soma discs.
    try:
        entries = list(soma)
    except TypeError:
        return None, {}
    if not entries:
        return None, {}

    labeled = np.zeros(shape, dtype=np.int64)
    id_map: dict[int, str] = {}
    yy, xx = np.mgrid[0:shape[0], 0:shape[1]]
    radius_px = max(1.0, soma_radius_um * px_per_um)
    next_lab = 1
    for c in entries:
        try:
            cx = c.get("cx")
            cy = c.get("cy")
        except AttributeError:
            continue
        if cx is None or cy is None:
            continue
        try:
            cx = float(cx)
            cy = float(cy)
        except (TypeError, ValueError):
            continue
        lab = next_lab
        next_lab += 1
        disc = (yy - cy) ** 2 + (xx - cx) ** 2 <= radius_px ** 2
        labeled[disc] = lab
        id_map[lab] = str(c.get("id", lab))
    if not id_map:
        return None, {}
    return labeled, id_map


def analyze(neurite_mask: Any, soma: Any, px_per_um: float,
            params: dict | None = None) -> dict:
    """Skeletonize `neurite_mask` and attribute branches to `soma`. See module docstring.

    Parameters
    ----------
    neurite_mask : 2-D array-like
        Nonzero = neurite/process foreground.
    soma : 2-D label array, list of {"id","cx","cy"} dicts, or None.
    px_per_um : float
        Pixels per micrometre.
    params : dict, optional
        "soma_radius_um" (float, default 8.0) — synthetic soma disc radius,
        used only when `soma` is centroids rather than a label mask.

    Returns
    -------
    dict — never raises. See module docstring for the full schema.

    Length accounting: ``total_skeleton_length_um`` is the whole skeleton, and
    it is partitioned exactly into ``attributed_length_um`` (the sum of the
    per-cell ``total_length_um`` values), ``soma_skeleton_length_um`` (the
    skeleton inside the punched-out soma footprints, which by construction can
    belong to no single process) and ``unattributed_length_um`` (process
    components no soma won, plus the edges straddling the soma boundary that
    fall in neither partition). Those three sum to the total; before this was
    made explicit, the per-cell sum alone was compared against the total and
    ~20% of the skeleton looked unaccounted for.
    """
    params = dict(params or {})
    pxu = _safe_float(px_per_um, 1.0)
    soma_radius_um = _safe_float(params.get("soma_radius_um"), _DEFAULT_SOMA_RADIUS_UM)
    out_params = {"px_per_um": pxu, "soma_radius_um": soma_radius_um}

    try:
        import numpy as np
        from scipy import ndimage as ndi
        from skimage.morphology import skeletonize

        mask = np.asarray(neurite_mask)
        if mask.ndim != 2 or mask.size == 0:
            return _empty_result("Neurite mask is empty or not 2-D — nothing to measure.", out_params)
        mask_bool = mask.astype(bool)
        if not mask_bool.any():
            return _empty_result("Neurite mask has no foreground pixels — nothing to measure.", out_params)

        soma_labeled, soma_id_by_label = _build_soma_label_map(
            soma, mask_bool.shape, pxu, soma_radius_um)

        skel = skeletonize(mask_bool)
        total_skel_len_um = _skeleton_length_um(skel, pxu)

        if soma_labeled is None:
            return {
                "n_cells": 0,
                "cells": [],
                "mean_neurite_length_um": 0.0,
                "total_skeleton_length_um": total_skel_len_um,
                "soma_skeleton_length_um": 0.0,
                "unattributed_length_um": total_skel_len_um,
                "unattributed_component_length_um": total_skel_len_um,
                "caveat": _CAVEAT,
                "message": ("No soma / cell-body positions were provided — "
                            "reporting whole-image skeleton totals only, no "
                            "per-cell breakdown."),
                "params": out_params,
            }

        # Punch the soma footprint (+1px margin) out of the skeleton so each
        # remaining connected component is one primary process rooted at the
        # (removed) soma boundary rather than one blob per cell.
        soma_fg = soma_labeled > 0
        soma_fg_dilated = ndi.binary_dilation(soma_fg, iterations=1)
        process_skel = skel & ~soma_fg_dilated
        # The punched-out interior is real skeleton that is still counted in
        # `total_skel_len_um` but can never appear in any per-cell total. Measure
        # it explicitly so the four reported lengths add up instead of leaving a
        # silent ~20% hole between the per-cell sum and the total.
        soma_skel_len_um = _skeleton_length_um(skel & soma_fg_dilated, pxu)

        # Exact discrete Voronoi: nearest soma-labeled pixel for every pixel
        # in the image, via the coordinates of the nearest zero in ~soma_fg.
        _, nearest_idx = ndi.distance_transform_edt(~soma_fg, return_indices=True)
        nearest_y, nearest_x = nearest_idx[0], nearest_idx[1]
        nearest_label = soma_labeled[nearest_y, nearest_x]

        components, n_components = ndi.label(process_skel, structure=np.ones((3, 3)))
        neighbor_count = _skeleton_neighbor_counts(process_skel)

        cell_stats: dict[int, dict] = {
            lab: {
                "soma_id": soma_id_by_label[lab],
                "total_length_um": 0.0,
                "n_primary_processes": 0,
                "n_branch_points": 0,
                "skeleton_px_count": 0,
            }
            for lab in soma_id_by_label
        }
        unattributed_len_um = 0.0

        for comp_id in range(1, n_components + 1):
            comp_mask = components == comp_id
            comp_size = int(comp_mask.sum())
            if comp_size == 0:
                continue

            labels_in_comp = nearest_label[comp_mask]
            labels_in_comp = labels_in_comp[labels_in_comp > 0]
            comp_len_um = _skeleton_length_um(comp_mask, pxu)
            if labels_in_comp.size == 0:
                unattributed_len_um += comp_len_um
                continue

            votes = np.bincount(labels_in_comp)
            winner = int(np.argmax(votes))
            if winner not in cell_stats:
                unattributed_len_um += comp_len_um
                continue

            comp_branch_pts = int(((neighbor_count >= 3) & comp_mask).sum())
            cell_stats[winner]["total_length_um"] += comp_len_um
            cell_stats[winner]["n_primary_processes"] += 1
            cell_stats[winner]["n_branch_points"] += comp_branch_pts
            cell_stats[winner]["skeleton_px_count"] += comp_size

        cells_out = [cell_stats[lab] for lab in sorted(cell_stats.keys())]
        n_cells = len(cells_out)
        attributed_len_um = sum(c["total_length_um"] for c in cells_out)
        mean_len = (attributed_len_um / n_cells) if n_cells else 0.0

        # Closed-book accounting:
        #     total = per-cell + soma-interior + unattributed
        # `unattributed` therefore absorbs BOTH the process components that no
        # soma won AND the skeleton edges that straddle the soma boundary — those
        # edges exist in the full skeleton but in neither partition of it, since
        # `_skeleton_length_um` measures edges between pixel pairs and splitting
        # the skeleton cuts the pairs that cross the cut. The component-only
        # figure is kept alongside as `unattributed_component_length_um`.
        residual = total_skel_len_um - attributed_len_um - soma_skel_len_um
        unattributed_total_um = max(0.0, residual)

        return {
            "n_cells": n_cells,
            "cells": cells_out,
            "mean_neurite_length_um": mean_len,
            "attributed_length_um": attributed_len_um,
            "total_skeleton_length_um": total_skel_len_um,
            "soma_skeleton_length_um": soma_skel_len_um,
            "unattributed_length_um": unattributed_total_um,
            "unattributed_component_length_um": unattributed_len_um,
            "caveat": _CAVEAT,
            "message": None,
            "params": out_params,
        }
    except Exception as exc:  # noqa: BLE001 — pure function must never raise.
        return _empty_result(f"Neurite analysis failed (non-fatal): {exc!r}", out_params)
