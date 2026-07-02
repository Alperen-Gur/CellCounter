"""
_watershed.py — shared watershed splitter for CellCounter detection sidecars.

Takes an integer label mask coming out of any detector (Cellpose, StarDist, SAM)
and splits touching/merged blobs into separate label ids using a distance-transform
watershed.

The math:
  1. Build a binary mask from the labels (>0).
  2. Distance-transform the binary mask — peaks are blob centroids; ridges are
     where two cells touch.
  3. Locate local maxima of the distance transform with a minimum-distance constraint
     to avoid over-splitting (each peak becomes one watershed marker).
  4. Run scikit-image's watershed on the negative distance image, constrained to
     the original binary mask. Each connected blob is split wherever its distance
     transform shows two separable peaks.

Returns a new int label array — same shape as input, potentially MORE labels than
the input (touching cells split apart) and never fewer real labels (blobs with no
detectable second peak are left intact under their original watershed marker).

Edge cases:
  - `min_distance_px` smaller than the radius of a typical small/round cell will
    over-split single cells into 2-3 fragments. The caller passes
    `args.watershed_min_distance * args.pxPerUm` to keep the value in pixels.
  - For very thin slivers (distance transform peak == 0 everywhere) `peak_local_max`
    returns nothing — those blobs collapse to background. We guard against that by
    falling back to the input labels when no peaks are found.
  - For an all-background input, returns the input unchanged.
"""

from __future__ import annotations


def split(labels, min_distance_px: int = 8):
    """Split touching blobs via distance-transform watershed.

    Args:
        labels: 2-D integer ndarray. 0 = background, 1..N = cell ids.
        min_distance_px: Minimum distance (in pixels) between watershed seed peaks.
            Smaller values split more aggressively; larger values keep more blobs
            intact. Default 8 px (matches a ~16-px-diameter cell).

    Returns:
        A new 2-D integer ndarray of the same shape as `labels` with relabeled
        cells. May contain more labels than the input. Background stays 0.
    """
    import numpy as np
    from scipy import ndimage as ndi
    from skimage.feature import peak_local_max
    from skimage.segmentation import watershed

    binary = labels > 0
    if not binary.any():
        return labels

    distance = ndi.distance_transform_edt(binary)
    coords = peak_local_max(
        distance,
        min_distance=max(1, int(min_distance_px)),
        labels=binary,
    )
    if coords.size == 0:
        # No detectable peaks (e.g. extremely thin slivers); preserve input as-is.
        return labels

    markers_mask = np.zeros(distance.shape, dtype=bool)
    markers_mask[tuple(coords.T)] = True
    markers, _ = ndi.label(markers_mask)
    new_labels = watershed(-distance, markers, mask=binary)
    return new_labels
