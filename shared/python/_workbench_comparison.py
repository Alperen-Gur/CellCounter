"""Descriptive, dimensionality-independent disagreement between exact masks."""
from __future__ import annotations

import base64
import copy
import io

CHUNK_SAMPLES = 1_000_000
MAX_OVERLAP_PAIRS = 250_000
MAX_OBJECTS = 20_000
MAX_RETURNED_ITEMS = 1000
MATCHING_IOU = .5


def operations():
    from _workbench_schema import _object, _ID, _op
    return [_op("mask.compare", "Compare exact supported masks with descriptive overlap and instance agreement, without designating either as truth.",
                _object({
                    "leftImageId": _ID, "rightImageId": _ID,
                    "target": {"type": "string", "enum": ["plane", "volume"]},
                    "timeIndex": {"type": "integer", "minimum": 0, "maximum": 64000000},
                    "channel": {"type": "integer", "minimum": 0, "maximum": 31},
                    "plane": {"type": "string", "enum": ["xy", "xz", "yz"]},
                    "index": {"type": "integer", "minimum": 0, "maximum": 64000000},
                    "maxSize": {"type": "integer", "minimum": 64, "maximum": 2048},
                }, ["leftImageId", "rightImageId"]))]


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def compare_arrays(left, right, valid_support=None):
    """Exact sparse overlaps, using bounded chunks rather than a dense IoU table."""
    import _workbench_imaging as imaging
    imaging.require("numpy", "scipy")
    import numpy as np
    from scipy.sparse import csr_matrix
    from scipy.sparse.csgraph import maximum_bipartite_matching
    if left.shape != right.shape or left.ndim not in (2, 3) or left.dtype != np.uint32 or right.dtype != np.uint32:
        fail("comparison-geometry-mismatch", "Comparison requires matching 2D or 3D uint32 source-grid masks.")
    if valid_support is not None and valid_support.shape != left.shape:
        fail("invalid-support", "Comparison support differs from the mask geometry.")
    a, b = left.reshape(-1), right.reshape(-1)
    support = valid_support.reshape(-1) if valid_support is not None else None
    counts_left, counts_right, overlap_counts = {}, {}, {}
    foreground_left = foreground_right = foreground_both = 0
    acquired = 0
    for start in range(0, a.size, CHUNK_SAMPLES):
        stop = min(start + CHUNK_SAMPLES, a.size)
        first, second = a[start:stop], b[start:stop]
        if support is not None:
            keep = support[start:stop]
            first, second = first[keep], second[keep]
        acquired += first.size
        first_fg, second_fg = first > 0, second > 0
        foreground_left += int(np.count_nonzero(first_fg))
        foreground_right += int(np.count_nonzero(second_fg))
        both = first_fg & second_fg
        foreground_both += int(np.count_nonzero(both))
        for samples, foreground, counts in ((first, first_fg, counts_left), (second, second_fg, counts_right)):
            labels, sizes = np.unique(samples[foreground], return_counts=True)
            for identifier, size in zip(labels, sizes):
                key = int(identifier)
                counts[key] = counts.get(key, 0) + int(size)
            if len(counts) > MAX_OBJECTS:
                fail("comparison-too-many-objects", "Mask comparison supports at most 20,000 objects per mask.")
        if both.any():
            # Pair packing is exact even for arbitrary sparse uint32 IDs.
            packed = (first[both].astype(np.uint64) << np.uint64(32)) | second[both].astype(np.uint64)
            keys, sizes = np.unique(packed, return_counts=True)
            for key, size in zip(keys, sizes):
                pair = int(key)
                if pair not in overlap_counts and len(overlap_counts) >= MAX_OVERLAP_PAIRS:
                    fail("comparison-overlap-limit", "The masks exceed 250,000 distinct overlapping label pairs.")
                overlap_counts[pair] = overlap_counts.get(pair, 0) + int(size)
    left_ids, right_ids = sorted(counts_left), sorted(counts_right)
    left_indexes = {identifier: index for index, identifier in enumerate(left_ids)}
    right_indexes = {identifier: index for index, identifier in enumerate(right_ids)}
    rows, columns, matching_ious = [], [], {}
    for packed, intersection in overlap_counts.items():
        left_id, right_id = packed >> 32, packed & 0xffffffff
        union = counts_left[left_id] + counts_right[right_id] - intersection
        # Integer comparison avoids numerical ambiguity at exactly IoU 0.5.
        if 2 * intersection >= union:
            rows.append(left_indexes[left_id])
            columns.append(right_indexes[right_id])
            matching_ious[(left_id, right_id)] = intersection / union
    matches = []
    matched_left, matched_right = set(), set()
    if rows:
        graph = csr_matrix((np.ones(len(rows), dtype=np.int8), (rows, columns)),
                           shape=(len(left_ids), len(right_ids)))
        graph.sort_indices()
        assignment = maximum_bipartite_matching(graph, perm_type="column")
        for left_index, right_index in enumerate(assignment):
            if right_index < 0:
                continue
            left_id, right_id = left_ids[left_index], right_ids[int(right_index)]
            matched_left.add(left_id)
            matched_right.add(right_id)
            if len(matches) < MAX_RETURNED_ITEMS:
                matches.append({"leftLabelId": left_id, "rightLabelId": right_id,
                                "iou": matching_ious[(left_id, right_id)]})
    match_count = len(matched_left)
    left_unmatched = [identifier for identifier in left_ids if identifier not in matched_left]
    right_unmatched = [identifier for identifier in right_ids if identifier not in matched_right]
    object_sum = len(left_ids) + len(right_ids)
    instance_union = object_sum - match_count
    foreground_sum = foreground_left + foreground_right
    foreground_union = foreground_sum - foreground_both
    return {
        "metrics": {"leftObjects": len(left_ids), "rightObjects": len(right_ids),
                    "matchedObjects": match_count, "unmatchedLeft": len(left_unmatched),
                    "unmatchedRight": len(right_unmatched),
                    "instanceF1": 2 * match_count / object_sum if object_sum else 1.,
                    "instanceJaccard": match_count / instance_union if instance_union else 1.,
                    "foregroundDice": 2 * foreground_both / foreground_sum if foreground_sum else 1.,
                    "foregroundJaccard": foreground_both / foreground_union if foreground_union else 1.,
                    "foregroundLeft": foreground_left, "foregroundRight": foreground_right,
                    "foregroundBoth": foreground_both, "supportedSamples": acquired},
        "pairs": matches, "unmatchedLeftLabelIds": left_unmatched[:MAX_RETURNED_ITEMS],
        "unmatchedRightLabelIds": right_unmatched[:MAX_RETURNED_ITEMS],
        "truncated": max(match_count, len(left_unmatched), len(right_unmatched)) > MAX_RETURNED_ITEMS,
        "matchingThresholdIoU": MATCHING_IOU, "metricDimension": left.ndim,
        "limits": {"chunkSamples": CHUNK_SAMPLES, "distinctOverlapPairs": MAX_OVERLAP_PAIRS,
                   "objectsPerMask": MAX_OBJECTS, "returnedItemsPerList": MAX_RETURNED_ITEMS},
        "notes": [
            "This is descriptive disagreement between two masks; neither mask is designated as truth or a reference.",
            "Objects correspond by maximum-cardinality bipartite matching at IoU ≥ 0.5; label numbers do not affect overlaps.",
            "If several maximum-cardinality assignments exist, the reported pairs are one deterministic assignment, not a maximum-total-IoU claim.",
            "Jointly empty masks have instance and foreground agreement 1 by convention; this is not evidence that an image contains no missed objects.",
            "Metrics use all supported source samples. Response lists are capped at 1,000 entries each; totals are never truncated.",
        ],
    }


def render(raw, left, right, valid, maximum):
    import _workbench_imaging as imaging
    imaging.require("numpy", "PIL")
    import numpy as np
    from PIL import Image
    height, width = raw.shape
    ratio = min(1., maximum / max(width, height))
    preview_width, preview_height = max(1, round(width * ratio)), max(1, round(height * ratio))
    xs = np.floor((np.arange(preview_width) + .5) * width / preview_width).astype(np.int64).clip(0, width - 1)
    ys = np.floor((np.arange(preview_height) + .5) * height / preview_height).astype(np.int64).clip(0, height - 1)
    selected = np.ix_(ys, xs)
    shown_support = np.ones((preview_height, preview_width), dtype=bool) if valid is None else valid[selected]
    if valid is None:
        low, high = float(raw.min()), float(raw.max())
    elif valid.any():
        low = float(np.min(raw, where=valid, initial=np.inf))
        high = float(np.max(raw, where=valid, initial=-np.inf))
    else:
        # An orthogonal display slice may have no support, while other slices
        # contribute to the exact full-volume metrics.
        low = high = 0.
    if low == high:
        gray = np.zeros((preview_height, preview_width), dtype=np.uint8)
    else:
        scale = max(abs(low), abs(high), 1.)
        normalized = (raw[selected] / scale - low / scale) / (high / scale - low / scale)
        gray = np.rint(normalized * 255).clip(0, 255).astype(np.uint8)
    base = np.repeat(gray[:, :, None], 3, axis=2)
    base[~shown_support] = (40, 40, 40)
    overlay = (base.astype(np.float64) * .4).astype(np.uint8)
    first, second = (left[selected] > 0) & shown_support, (right[selected] > 0) & shown_support
    overlay[first & ~second] = (0, 225, 235)
    overlay[second & ~first] = (240, 60, 220)
    overlay[first & second] = (70, 220, 95)
    overlay[~shown_support] = (40, 40, 40)
    def encoded(pixels):
        buffer = io.BytesIO()
        Image.fromarray(pixels).save(buffer, format="PNG")
        return "data:image/png;base64," + base64.b64encode(buffer.getvalue()).decode("ascii")
    return {"dataUrl": encoded(base), "overlayDataUrl": encoded(overlay),
            "width": width, "height": height, "previewWidth": preview_width, "previewHeight": preview_height,
            "displaySource": "left", "displayRange": [low, high], "displaySampling": "nearest; visualization only",
            "overlayLegend": {"leftOnly": "cyan", "rightOnly": "magenta", "bothForeground": "green",
                              "unsupported": "dark gray"},
            "displayTransform": {"scale": {"x": width / preview_width, "y": height / preview_height},
                                 "coordinateSpace": "source pixel or voxel edges"}}


def execute(store, document, args):
    import _workbench_core as core
    import _workbench_volume as volume
    import _workbench_support as support
    left_image = core._image(document, args["leftImageId"])
    right_image = core._image(document, args["rightImageId"])
    if any(left_image[key] != right_image[key] for key in ("sourceHash", "width", "height", "axes", "shape")):
        fail("comparison-source-mismatch", "Compare independent masks of the same immutable source bytes, dimensions and axes.")
    if support.fingerprint(left_image) != support.fingerprint(right_image):
        fail("comparison-support-mismatch", "Both masks must refer to the same exact valid-support mask.")
    target = args.get("target", "plane")
    if target == "plane":
        if any(key in args for key in ("timeIndex", "channel", "plane", "index")):
            fail("invalid-selection", "Plane mask comparison uses each saved source selection; time and orthogonal plane controls apply only to volume comparison.")
        left_analysis, right_analysis = core._current_analysis(store, left_image), core._current_analysis(store, right_image)
        if left_analysis["parameters"]["zProjection"] != right_analysis["parameters"]["zProjection"]:
            fail("comparison-projection-mismatch", "Both plane analyses must use the same saved Z projection.")
        left_labels, right_labels = core._labels(store, left_image), core._labels(store, right_image)
        chosen = {"zProjection": left_analysis["parameters"]["zProjection"],
                  "leftChannel": left_analysis["parameters"]["channel"],
                  "rightChannel": right_analysis["parameters"]["channel"]}
        valid = support.load(store, left_image, left_labels.shape, left_analysis["parameters"])
        comparison = compare_arrays(left_labels, right_labels, valid)
        raw = core._source(store, left_image, left_analysis["parameters"])
        display = render(raw, left_labels, right_labels, valid, args.get("maxSize", 768))
    else:
        time_index, channel = args.get("timeIndex", 0), args.get("channel", 0)
        volume.selection(left_image, time_index, channel)
        volume.selection(right_image, time_index, channel)
        left_analysis = volume.current_frame(store, left_image, time_index, channel)
        right_analysis = volume.current_frame(store, right_image, time_index, channel)
        left_labels = volume.read_labels(store, left_image, left_analysis)
        right_labels = volume.read_labels(store, right_image, right_analysis)
        valid = support.load(store, left_image, left_labels.shape)
        comparison = compare_arrays(left_labels, right_labels, valid)
        raw = volume.load_source(store, left_image, time_index, channel)
        plane = args.get("plane", "xy")
        axis = {"xy": 0, "xz": 1, "yz": 2}[plane]
        index = args.get("index", raw.shape[axis] // 2)
        chosen = {"timeIndex": time_index, "channel": channel, "plane": plane, "index": index}
        display = render(volume.plane_array(raw, plane, index),
                         volume.plane_array(left_labels, plane, index), volume.plane_array(right_labels, plane, index),
                         volume.plane_array(valid, plane, index) if valid is not None else None,
                         args.get("maxSize", 768))
        display.update({"plane": plane, "index": index, "sliceCount": raw.shape[axis]})
        comparison["notes"].append("The preview shows one selected orthogonal slice; agreement metrics use the full saved 3D masks.")
    if target == "plane" and chosen["leftChannel"] != chosen["rightChannel"]:
        comparison["notes"].append("The saved masks use different source channels. They share the source grid; the background preview uses the left channel.")
    comparison["notes"].append("Green indicates shared foreground, even when object boundaries or object identities differ.")
    def describe(image, analysis):
        return {"imageId": image["id"], "name": image["name"], "analysisRevision": analysis["analysisRevision"],
                "measurementRevision": analysis["measurementRevision"], "parameters": copy.deepcopy(analysis["parameters"]),
                "labelsHash": analysis["labelsHash"], "inputFingerprint": analysis["inputFingerprint"]}
    return {"left": describe(left_image, left_analysis), "right": describe(right_image, right_analysis),
            "target": target, "selection": chosen, **comparison, **display,
            "validSupport": support.summary(left_image, valid, left_labels.shape)}
