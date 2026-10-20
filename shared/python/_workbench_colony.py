"""Shared colony grouping and centroid statistics; legacy caller adapter below."""
from __future__ import annotations

import math

_ZERO_STATS = {"confluency_pct": 0., "n_colonies": 0, "mean_colony_size_cells": 0.,
               "largest_colony_size_cells": 0, "largest_colony_area_um2": 0., "mean_nn_distance_um": 0.}


def measure(labels, *, dilation_radius_px=4, minimum_cells=3, spacing_yx=None, valid_support=None):
    """Group 8-connected dilated foreground; count source cell centroids.

    Sparse IDs never determine an allocation size. Physical centroid distances
    use the supplied Y/X spacing; dilation remains explicitly in source pixels.
    """
    import numpy as np
    from scipy import ndimage as ndi
    from scipy.spatial import cKDTree

    arr = np.asarray(labels)
    if arr.ndim != 2 or not arr.size or arr.dtype.kind not in "ui" or np.any(arr < 0):
        raise ValueError("Colony measurements require a non-empty 2D nonnegative integer label map.")
    valid = np.ones(arr.shape, bool) if valid_support is None else np.asarray(valid_support, dtype=bool)
    if valid.shape != arr.shape or not valid.any() or np.any((arr != 0) & ~valid):
        raise ValueError("Cell labels must lie inside the acquired support.")
    if type(dilation_radius_px) is not int or not 0 <= dilation_radius_px <= 4096 or type(minimum_cells) is not int or minimum_cells < 1:
        raise ValueError("Choose a bounded nonnegative dilation radius and at least one cell per colony.")
    if spacing_yx is not None and (len(spacing_yx) != 2 or any(not math.isfinite(float(v)) or float(v) <= 0 for v in spacing_yx)):
        raise ValueError("Physical spacing must contain positive Y/X values.")
    binary = arr != 0
    yy, xx = np.nonzero(binary)
    ids, inverse = np.unique(arr[binary], return_inverse=True)
    counts = np.bincount(inverse, minlength=len(ids))
    points = np.column_stack((np.bincount(inverse, weights=yy, minlength=len(ids)) / counts,
                              np.bincount(inverse, weights=xx, minlength=len(ids)) / counts)) if len(ids) else np.empty((0, 2))
    # Euclidean distance implements the same integer disk without allocating
    # or repeatedly applying a large footprint.
    dilated = ((ndi.distance_transform_edt(~binary) <= dilation_radius_px) & valid
               if dilation_radius_px and binary.any() else binary)
    components, count = ndi.label(dilated, structure=np.ones((3, 3), bool))
    component_cells = np.zeros(count + 1, np.int64)
    if len(points):
        indices = np.rint(points).astype(np.intp)
        ids_at_centroid = components[indices[:, 0], indices[:, 1]]
        component_cells += np.bincount(ids_at_centroid, minlength=count + 1)
    component_cells[0] = 0
    qualifying = np.flatnonzero(component_cells >= minimum_cells)
    foreground_area = np.bincount(components[binary], minlength=count + 1)
    largest = int(qualifying[np.argmax(component_cells[qualifying])]) if len(qualifying) else 0
    nearest_px = float(cKDTree(points).query(points, k=2)[0][:, 1].mean()) if len(points) > 1 else None
    nearest_um = (float(cKDTree(points * spacing_yx).query(points * spacing_yx, k=2)[0][:, 1].mean())
                  if spacing_yx is not None and len(points) > 1 else None)
    area_scale = math.prod(spacing_yx) if spacing_yx is not None else None
    rows = [{"componentId": int(index), "cellCount": int(component_cells[index]),
             "foregroundAreaPx": int(foreground_area[index]),
             "foregroundAreaUm2": int(foreground_area[index]) * area_scale if area_scale is not None else None}
            for index in qualifying[:1000]]
    return {"measurements": rows, "truncated": len(qualifying) > len(rows), "summary": {
        "objectCount": len(ids), "colonyCount": len(qualifying),
        "coveragePct": float(binary.sum()) / int(valid.sum()) * 100.,
        "meanCellsPerColony": float(component_cells[qualifying].mean()) if len(qualifying) else 0.,
        "largestColonyCellCount": int(component_cells[largest]),
        "largestColonyAreaPx": int(foreground_area[largest]) if largest else 0,
        "largestColonyAreaUm2": (int(foreground_area[largest]) if largest else 0) * area_scale if area_scale is not None else None,
        "meanNearestCentroidDistancePx": nearest_px, "meanNearestCentroidDistanceUm": nearest_um,
    }, "notes": [
        "Colonies are 8-connected components of foreground dilated by the specified source-pixel radius; cell centroids determine component membership.",
        "Reported colony area contains original cell foreground, not the dilated envelope. Unsupported samples are excluded.",
        "These geometric groups are descriptive and do not establish clonal origin. A centroid outside a component is not assigned to a colony.",
    ]}


def compute(labels, px_per_um, image_shape):
    """Legacy flat schema and nonfatal fallback, using the same numerical kernel."""
    try:
        pxu = float(px_per_um) if px_per_um and math.isfinite(float(px_per_um)) and float(px_per_um) > 0 else 1.
        result = measure(labels, dilation_radius_px=max(1, int(4 * pxu)), minimum_cells=3,
                         spacing_yx=(1 / pxu, 1 / pxu))["summary"]
        return {"confluency_pct": result["coveragePct"], "n_colonies": result["colonyCount"],
                "mean_colony_size_cells": result["meanCellsPerColony"],
                "largest_colony_size_cells": result["largestColonyCellCount"],
                "largest_colony_area_um2": result["largestColonyAreaUm2"],
                "mean_nn_distance_um": result["meanNearestCentroidDistanceUm"] or 0.}
    except Exception:
        return zero_stats()


def zero_stats():
    return dict(_ZERO_STATS)
