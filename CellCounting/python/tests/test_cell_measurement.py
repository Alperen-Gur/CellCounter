"""Per-cell measurement on bounding-box crops matches the whole-image version.

`_cellpose_common.measure_cells`, `stardist_detect.measure_instances` and
`sam_detect.measure_instances` measure each cell on a small crop around it
(`_cellpose_common.label_crops`) instead of a full-image mask. The
`reference_*` functions at the bottom of this file are the previous
whole-image loops, copied unchanged. Every test runs the old and the new code
on the same label map and requires identical output: same cells in the same
order, same keys in the same order, same value types and the same float bits.
"""

from __future__ import annotations

import contextlib
import io
import itertools
import json
import math
import struct
import sys
import types
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import _cellpose_common as cc  # noqa: E402
import sam_detect  # noqa: E402
import stardist_detect  # noqa: E402

log = cc.log


# ---------------------------------------------------------------------------
# Running and comparing.
# ---------------------------------------------------------------------------

@contextlib.contextmanager
def _deterministic_ids():
    """Number the uuid4 ids 1, 2, 3, ... and silence the stderr progress log."""
    counter = itertools.count(1)
    with patch("uuid.uuid4", side_effect=lambda: uuid.UUID(int=next(counter))), \
            contextlib.redirect_stderr(io.StringIO()):
        yield


def run_old_and_new(old_fn, new_fn, *args, **kwargs):
    with _deterministic_ids():
        old = old_fn(*args, **kwargs)
    with _deterministic_ids():
        new = new_fn(*args, **kwargs)
    return old, new


def first_difference(old, new, path="cells"):
    """Describe the first difference between two outputs, or return None.

    Floats are compared bit for bit, dict keys by order, and types exactly
    (so a numpy float64 never passes for a Python float).
    """
    if type(old) is not type(new):
        return f"{path}: type {type(old).__name__} != {type(new).__name__}"
    if isinstance(old, dict):
        if list(old) != list(new):
            return f"{path}: keys {list(old)} != {list(new)}"
        for key in old:
            found = first_difference(old[key], new[key], f"{path}.{key}")
            if found:
                return found
        return None
    if isinstance(old, (list, tuple)):
        if len(old) != len(new):
            return f"{path}: length {len(old)} != {len(new)}"
        for i, (a, b) in enumerate(zip(old, new)):
            found = first_difference(a, b, f"{path}[{i}]")
            if found:
                return found
        return None
    if isinstance(old, float):
        if struct.pack("<d", old) != struct.pack("<d", new):
            return f"{path}: {old!r} != {new!r}"
        return None
    if old != new:
        return f"{path}: {old!r} != {new!r}"
    return None


class IdenticalOutputTestCase(unittest.TestCase):
    def assertIdentical(self, old, new):
        self.assertIsNone(first_difference(old, new))
        self.assertEqual(json.dumps(old), json.dumps(new))


@contextlib.contextmanager
def british_perimeter_keyword():
    """Let `skimage.measure.perimeter` accept ``neighbourhood=``.

    The StarDist and SAM loops pass that spelling, which current
    scikit-image rejects (so those detectors omit perimeter). This shim makes
    their perimeter path run so the crop version of it is compared too.
    """
    import skimage.measure as measure
    real = measure.perimeter

    def perimeter(image, neighbourhood=4):
        return real(image, neighbourhood)

    with patch.object(measure, "perimeter", perimeter):
        yield


def _args(px_per_um=2.0, **extra):
    return types.SimpleNamespace(pxPerUm=px_per_um, small_threshold=4.0,
                                 large_threshold=7.0, **extra)


# ---------------------------------------------------------------------------
# Label maps.
# ---------------------------------------------------------------------------

def handmade_labels():
    """Edge cases drawn by hand on a 48 x 64 grid (int32)."""
    m = np.zeros((48, 64), np.int32)
    m[0:5, 0:6] = 1                       # top-left corner
    m[10:15, 59:64] = 2                   # right edge
    m[44:48, 20:31] = 3                   # bottom edge
    m[18:27, 18:27] = 4                   # ring ...
    m[20:25, 20:25] = 0                   # ... with a 5 x 5 hole
    m[22, 22] = 5                         # single pixel inside the hole
    m[30:32, 40:42] = 6                   # 2 x 2: smallest measured area
    m[35, 5] = 7                          # single pixel
    m[35, 8:11] = 8                       # 3 pixels: skipped
    m[5:15, 30:36] = 9                    # two touching cells
    m[5:15, 36:42] = 10
    m[30:34, 2:6] = 11                    # one label in two pieces
    m[38:42, 10:14] = 11
    for i in range(8):                    # 8-connected diagonal line
        m[2 + i, 46 + i] = 12
    m[28, :] = 13                         # 1 px line touching left and right
    m[40:48, 50:64] = 14                  # U shape in the bottom-right
    m[42:48, 53:61] = 0                   # corner, open to the bottom edge
    m[16:20, 44:52] = 40                  # non-consecutive label id
    return m


def tessellated_labels(rng, shape, n_seeds, radius, dtype):
    """Touching cells (nearest seed within `radius`), holes and tiny cells."""
    h, w = shape
    seeds = rng.uniform((0, 0), (h, w), size=(n_seeds, 2))
    rows, cols = np.mgrid[0:h, 0:w]
    d2 = ((rows[..., None] - seeds[:, 0]) ** 2
          + (cols[..., None] - seeds[:, 1]) ** 2)
    labels = d2.argmin(axis=2) + 1
    labels[d2.min(axis=2) > radius ** 2] = 0
    for _ in range(n_seeds // 3):         # 3 x 3 holes and notches
        r, c = int(rng.integers(0, h)), int(rng.integers(0, w))
        labels[max(r - 1, 0):r + 2, max(c - 1, 0):c + 2] = 0
    background = np.argwhere(labels == 0)
    picks = rng.choice(len(background), size=min(12, len(background)),
                       replace=False)
    for offset, (r, c) in enumerate(background[picks]):
        labels[r, c] = n_seeds + 1 + offset   # single-pixel cells
    return labels.astype(dtype)


def blob_labels(rng, shape, sigma, dtype=np.int32):
    """Irregular connected blobs with holes, many touching the border."""
    from scipy import ndimage as ndi
    noise = ndi.gaussian_filter(rng.standard_normal(shape), sigma)
    labels, _ = ndi.label(noise > 0.05 * noise.std())
    return labels.astype(dtype)


def comb_labels():
    """Cells with long contours, so the point-thinning paths run."""
    m = np.zeros((40, 300), np.int32)
    m[10:13, 2:290] = 1
    m[3:10, 2:290:2] = 1                  # 144 one-pixel teeth
    m[20:38, 5:295] = 2
    m[20:30, 6:294:3] = 0                 # notches cut into the top
    return m


def channel_stack(rng, shape, n):
    return rng.normal(500.0, 120.0, size=shape + (n,)).astype(np.float32)


# ---------------------------------------------------------------------------
# Tests.
# ---------------------------------------------------------------------------

class LabelCropsTests(unittest.TestCase):
    def test_crop_is_the_bounding_box_plus_one_pixel_inside_the_image(self):
        masks = handmade_labels()
        height, width = masks.shape
        label_ids = np.unique(masks)
        label_ids = label_ids[label_ids != 0]
        seen = []
        for label, crop, row0, col0 in cc.label_crops(masks, label_ids):
            seen.append(int(label))
            full = masks == label
            ys, xs = np.nonzero(full)
            self.assertEqual(crop.dtype, np.bool_)
            self.assertEqual(row0, max(int(ys.min()) - 1, 0))
            self.assertEqual(col0, max(int(xs.min()) - 1, 0))
            self.assertEqual(row0 + crop.shape[0], min(int(ys.max()) + 2, height))
            self.assertEqual(col0 + crop.shape[1], min(int(xs.max()) + 2, width))
            pasted = np.zeros_like(full)
            pasted[row0:row0 + crop.shape[0], col0:col0 + crop.shape[1]] = crop
            np.testing.assert_array_equal(pasted, full)
            self.assertLess(crop.size, full.size)
        self.assertEqual(seen, [int(v) for v in label_ids])

    def test_label_maps_without_usable_boxes_use_the_whole_image(self):
        masks = handmade_labels()
        cases = {
            "float": masks.astype(np.float64),
            "negative": np.where(masks == 9, -3, masks).astype(np.int32),
            "sparse": np.where(masks == 40, 300_000, masks).astype(np.int64),
        }
        for name, case in cases.items():
            with self.subTest(name):
                label_ids = np.unique(case)
                label_ids = label_ids[label_ids != 0]
                crops = list(cc.label_crops(case, label_ids))
                odd = {"float": None, "negative": -3, "sparse": 300_000}[name]
                for label, crop, row0, col0 in crops:
                    if odd is None or label == odd:
                        self.assertEqual(crop.shape, case.shape)
                        self.assertEqual((row0, col0), (0, 0))
                    np.testing.assert_array_equal(
                        crop, (case == label)[row0:row0 + crop.shape[0],
                                              col0:col0 + crop.shape[1]])


class MeasureCellsTests(IdenticalOutputTestCase):
    def check(self, masks, img, args, **kwargs):
        old, new = run_old_and_new(reference_measure_cells, cc.measure_cells,
                                   masks, img, args, **kwargs)
        self.assertIdentical(old, new)
        return new

    def test_handmade_edge_cases_with_every_optional_output(self):
        rng = np.random.default_rng(1)
        masks = handmade_labels()
        shape = masks.shape
        bright = rng.integers(225, 256, size=shape + (3,), dtype=np.uint8)
        cellprob = rng.normal(0.0, 2.0, size=shape).astype(np.float32)
        stack = channel_stack(rng, shape, 3)
        everything = []
        for px_per_um in (2.0, 0.0, 0.05):
            with self.subTest(px_per_um=px_per_um):
                cells = self.check(masks, bright, _args(px_per_um),
                                   flows=(None, None, cellprob),
                                   channel_stack=stack,
                                   channel_names=["DAPI", None, "  "])
                # Labels 5, 7 and 8 are smaller than 4 px and are skipped.
                self.assertEqual(len(cells), 12)
                everything.extend(cells)
        self.assertTrue(any(c["edge_touching"] for c in everything))
        self.assertFalse(all(c["edge_touching"] for c in everything))
        self.assertTrue(any(c["likely_debris"] for c in everything))
        self.assertTrue(any(c["likely_clump"] for c in everything))
        self.assertEqual({c["size_class"] for c in everything},
                         {"small", "intermediate", "large"})
        for key in ("perimeter_um", "circularity", "solidity", "eccentricity",
                    "mean_intensity", "contour_px", "channel_intensities"):
            self.assertTrue(all(key in c for c in everything), key)
        self.assertEqual([ch["name"] for ch in everything[0]["channel_intensities"]],
                         ["DAPI", "Ch1", "Ch2"])

    def test_touching_cells_with_holes_in_every_label_dtype(self):
        rng = np.random.default_rng(7)
        for dtype in (np.uint8, np.uint16, np.int32, np.int64, np.uint32):
            for shape in ((96, 128), (61, 47)):
                with self.subTest(dtype=np.dtype(dtype).name, shape=shape):
                    masks = tessellated_labels(rng, shape, 40, 14, dtype)
                    img = rng.integers(0, 256, size=shape, dtype=np.uint8)
                    cellprob = rng.normal(size=shape).astype(np.float32)
                    cells = self.check(masks, img, _args(1.5),
                                       flows=(None, None, cellprob))
                    self.assertGreater(len(cells), 20)

    def test_irregular_blobs_with_multichannel_intensities(self):
        rng = np.random.default_rng(11)
        for sigma, shape in ((1.5, (120, 90)), (3.0, (200, 160))):
            with self.subTest(sigma=sigma):
                masks = blob_labels(rng, shape, sigma)
                img = rng.integers(0, 256, size=shape + (3,), dtype=np.uint8)
                stack = channel_stack(rng, shape, 4)
                args = _args(1.0, _cc_channel_stack=stack,
                             _cc_channel_names=["a", "b"])
                cells = self.check(masks, img, args)
                self.assertGreater(len(cells), 5)
                self.assertTrue(all(len(c["channel_intensities"]) == 4
                                    for c in cells))

    def test_long_contours_are_thinned_identically(self):
        rng = np.random.default_rng(3)
        masks = comb_labels()
        img = rng.integers(0, 256, size=masks.shape, dtype=np.uint8)
        cells = self.check(masks, img, _args(1.0))
        self.assertTrue(any(len(c["contour_px"]) > 100 for c in cells))

    def test_whole_image_cells_and_very_thin_images(self):
        rng = np.random.default_rng(5)
        for shape in ((1, 20), (20, 1), (2, 2), (3, 50), (50, 3)):
            with self.subTest(shape=shape):
                img = rng.integers(0, 256, size=shape, dtype=np.uint8)
                self.check(np.ones(shape, np.int32), img, _args())
                halves = np.zeros(shape, np.int32)
                halves.flat[: halves.size // 2] = 1
                halves.flat[halves.size // 2:] = 2
                self.check(halves, img, _args())

    def test_label_maps_that_fall_back_to_the_whole_image(self):
        rng = np.random.default_rng(9)
        masks = handmade_labels()
        img = rng.integers(0, 256, size=masks.shape, dtype=np.uint8)
        cases = {
            "float": masks.astype(np.float64),
            "negative": np.where(masks == 9, -3, masks).astype(np.int32),
            "sparse": np.where(masks == 40, 300_000, masks).astype(np.int64),
            "bool": masks == 4,
        }
        for name, case in cases.items():
            with self.subTest(name):
                self.check(case, img, _args())

    def test_mismatched_or_single_channel_inputs_are_ignored_the_same_way(self):
        rng = np.random.default_rng(13)
        masks = handmade_labels()
        img = rng.integers(0, 256, size=masks.shape, dtype=np.uint8)
        wrong = rng.normal(size=(10, 10)).astype(np.float32)
        self.check(masks, img, _args(), flows=(None, None, wrong),
                   channel_stack=channel_stack(rng, (10, 10), 3))
        self.check(masks, img, _args(),
                   channel_stack=channel_stack(rng, masks.shape, 1))

    def test_without_scikit_image_or_scipy(self):
        rng = np.random.default_rng(17)
        masks = tessellated_labels(rng, (64, 80), 25, 12, np.int32)
        img = rng.integers(0, 256, size=masks.shape, dtype=np.uint8)
        stack = channel_stack(rng, masks.shape, 2)
        hidden = (
            {"skimage.measure": None},
            {"scipy.ndimage": None},
            {"skimage.measure": None, "scipy.ndimage": None},
        )
        for modules in hidden:
            with self.subTest(hidden=sorted(modules)), \
                    patch.dict(sys.modules, modules):
                self.check(masks, img, _args(), channel_stack=stack)


class StarDistMeasureTests(IdenticalOutputTestCase):
    def check(self, labels, img, args, points=None, probs=None):
        height, width = labels.shape
        old, new = run_old_and_new(
            reference_stardist_measure, stardist_detect.measure_instances,
            labels, img, args, width, height, points=points, probs=probs)
        self.assertIdentical(old, new)
        return new

    def test_points_probs_and_plain_centroids(self):
        rng = np.random.default_rng(21)
        masks = handmade_labels()
        img = rng.uniform(0, 255, size=masks.shape).astype(np.float32)
        n = len(np.unique(masks)) - 1
        points = [tuple(p) for p in rng.integers(0, 48, size=(n - 3, 2))]
        points[4] = 7                     # malformed entry: mask centroid used
        probs = list(rng.uniform(-0.2, 1.2, size=n - 2))
        probs[2] = "not a number"
        self.check(masks, img, _args(), points=points, probs=probs)
        self.check(masks, img, _args())

    def test_rgb_float_images_and_random_masks(self):
        rng = np.random.default_rng(23)
        for shape in ((96, 128), (61, 47)):
            with self.subTest(shape=shape):
                masks = tessellated_labels(rng, shape, 40, 14, np.int32)
                img = rng.uniform(0, 255, size=shape + (3,)).astype(np.float32)
                self.check(masks, img, _args(1.5))
                self.check(blob_labels(rng, shape, 2.0), img, _args(0.05))

    def test_perimeter_path_when_scikit_image_accepts_the_keyword(self):
        rng = np.random.default_rng(25)
        img = rng.uniform(0, 255, size=(48, 64)).astype(np.float32)
        with british_perimeter_keyword():
            cells = self.check(handmade_labels(), img, _args())
        self.assertTrue(all("perimeter_um" in c and "circularity" in c
                            for c in cells))

    def test_without_scikit_image(self):
        rng = np.random.default_rng(27)
        masks = tessellated_labels(rng, (64, 80), 25, 12, np.int32)
        img = rng.uniform(0, 255, size=masks.shape).astype(np.float32)
        with patch.dict(sys.modules, {"skimage.measure": None,
                                      "scipy.ndimage": None}):
            self.check(masks, img, _args())


class SamMeasureTests(IdenticalOutputTestCase):
    def check(self, labels, img, args, scores):
        height, width = labels.shape
        old, new = run_old_and_new(
            reference_sam_measure, sam_detect.measure_instances,
            labels, img, args, width, height, scores)
        self.assertIdentical(old, new)
        return new

    def test_scores_contours_and_edge_cases(self):
        rng = np.random.default_rng(31)
        masks = handmade_labels()
        img = rng.integers(0, 256, size=masks.shape, dtype=np.uint8)
        n = len(np.unique(masks)) - 1
        scores = list(rng.uniform(-0.2, 1.2, size=n - 2))
        scores[1] = "bad"
        cells = self.check(masks, img, _args(), scores)
        self.assertTrue(all("contour_px" in c for c in cells))
        self.check(masks, img, _args(0.05), [])

    def test_random_masks_and_long_contours(self):
        rng = np.random.default_rng(33)
        for masks in (tessellated_labels(rng, (96, 128), 40, 14, np.uint16),
                      blob_labels(rng, (120, 90), 1.5), comb_labels()):
            with self.subTest(shape=masks.shape):
                img = rng.integers(0, 256, size=masks.shape, dtype=np.uint8)
                self.check(masks, img, _args(1.0), [])

    def test_perimeter_path_when_scikit_image_accepts_the_keyword(self):
        rng = np.random.default_rng(35)
        img = rng.integers(0, 256, size=(48, 64), dtype=np.uint8)
        with british_perimeter_keyword():
            cells = self.check(handmade_labels(), img, _args(), [])
        self.assertTrue(all("perimeter_um" in c for c in cells))

    def test_without_scikit_image(self):
        rng = np.random.default_rng(37)
        masks = tessellated_labels(rng, (64, 80), 25, 12, np.int32)
        img = rng.integers(0, 256, size=masks.shape, dtype=np.uint8)
        with patch.dict(sys.modules, {"skimage.measure": None}):
            self.check(masks, img, _args(), [])


# ---------------------------------------------------------------------------
# Reference implementations: the whole-image code before the crop change,
# copied unchanged apart from the function names and docstrings. The StarDist
# and SAM loops used to sit inside `main()`; they are wrapped here in a
# function together with the `px_per_um` line that preceded them in `main()`.
# ---------------------------------------------------------------------------

def reference_measure_cells(masks, img, args, flows=None, channel_stack=None,
                  channel_names=None) -> list[dict]:
    """`_cellpose_common.measure_cells` before the crop change."""
    import numpy as np

    # Cellprob map for per-cell confidence — same index for v3.x and v4.x.
    cellprob_map = None
    if flows is not None:
        try:
            candidate = flows[2]
            if hasattr(candidate, "shape") and candidate.shape == masks.shape:
                cellprob_map = candidate
        except Exception:  # noqa: BLE001
            cellprob_map = None

    px_per_um = float(args.pxPerUm) if args.pxPerUm > 0 else 1.0

    # skimage helpers (optional — perimeter/eccentricity/contours omitted otherwise).
    try:
        from skimage.measure import (perimeter as sk_perimeter,
                                     regionprops,
                                     find_contours as sk_find_contours,
                                     approximate_polygon as sk_approx_polygon)
        _skimage_ok = True
    except ImportError:
        _skimage_ok = False
        sk_perimeter = None  # type: ignore
        regionprops = None  # type: ignore
        sk_find_contours = None  # type: ignore
        sk_approx_polygon = None  # type: ignore
        log("[cellpose_detect] skimage not available — perimeter/eccentricity/"
            "contours will be omitted")

    if img.ndim == 2:
        img_gray = img.astype(np.float64)
    else:
        img_gray = img.mean(axis=2).astype(np.float64)

    height_px, width_px = int(img.shape[0]), int(img.shape[1])

    # --- Per-channel planes for the "channel_intensities" contract ----------
    # Only engaged when the source really had >1 channel AND the stack lines up
    # with the mask grid (a half-resolution retry, a crop, or a caller that
    # never went through open_image_for_detection all land here as "no stack",
    # which just means the key is omitted — never a crash).
    if channel_stack is None:
        channel_stack = getattr(args, "_cc_channel_stack", None)
    if channel_names is None:
        channel_names = getattr(args, "_cc_channel_names", None)

    channel_planes: list = []
    resolved_names: list[str] = []
    if channel_stack is not None:
        try:
            stack_arr = np.asarray(channel_stack)
            if (stack_arr.ndim == 3 and stack_arr.shape[2] > 1
                    and stack_arr.shape[:2] == masks.shape):
                n_ch = int(stack_arr.shape[2])
                raw_names = list(channel_names or [])
                for c in range(n_ch):
                    name = (str(raw_names[c]).strip()
                            if c < len(raw_names) and raw_names[c] is not None
                            else "")
                    resolved_names.append(name if name else f"Ch{c}")
                    channel_planes.append(
                        np.ascontiguousarray(stack_arr[..., c],
                                             dtype=np.float64))
                log(f"[cellpose_detect] measuring per-cell intensities in "
                    f"{n_ch} channels: {resolved_names}")
            elif stack_arr.ndim == 3 and stack_arr.shape[2] > 1:
                log("[cellpose_detect] channel stack "
                    f"{stack_arr.shape[:2]} does not match masks "
                    f"{masks.shape}; omitting channel_intensities")
        except Exception as exc:  # noqa: BLE001
            log(f"[cellpose_detect] per-channel setup failed (non-fatal): "
                f"{exc!r}")
            channel_planes = []
            resolved_names = []

    if _skimage_ok:
        try:
            props_by_label = {p.label: p for p in regionprops(masks)}
        except Exception:  # noqa: BLE001
            props_by_label = {}
    else:
        props_by_label = {}

    label_ids = np.unique(masks)
    label_ids = label_ids[label_ids != 0]
    n_total = len(label_ids)
    log(f"[cellpose_detect] found {n_total} masks; measuring per-cell properties…")

    progress_every = max(50, n_total // 10) if n_total else 1
    cells: list[dict] = []

    small_t = float(getattr(args, "small_threshold", 20))
    large_t = float(getattr(args, "large_threshold", 30))
    EDGE_MARGIN_PX = 16

    for cell_idx, label in enumerate(label_ids):
        if cell_idx > 0 and cell_idx % progress_every == 0:
            log(f"[cellpose_detect] measured {cell_idx}/{n_total} cells…")
        mask = (masks == label)
        ys, xs = np.where(mask)
        area_px = int(mask.sum())
        if area_px < 4:
            continue
        cy = float(ys.mean())
        cx = float(xs.mean())
        diameter_px = 2.0 * math.sqrt(area_px / math.pi)
        diameter_um = diameter_px / px_per_um

        if cellprob_map is not None:
            try:
                raw = float(cellprob_map[ys, xs].mean())
                conf = 1.0 / (1.0 + math.exp(-raw))
            except Exception:  # noqa: BLE001
                conf = 0.85
        else:
            conf = 0.85

        area_um2 = area_px / (px_per_um ** 2)

        perimeter_um = None
        circularity = None
        if _skimage_ok:
            try:
                # scikit-image renamed `neighbourhood` → `neighborhood` in 0.26.
                # Try the new spelling, fall back to the old one.
                try:
                    perim_px = sk_perimeter(mask, neighborhood=8)
                except TypeError:
                    perim_px = sk_perimeter(mask, neighbourhood=8)
                if perim_px > 0:
                    perimeter_um = perim_px / px_per_um
                    circularity = min(1.0, max(0.0,
                        4 * math.pi * area_um2 / (perimeter_um ** 2)))
            except Exception:  # noqa: BLE001
                pass

        eccentricity = None
        if _skimage_ok and int(label) in props_by_label:
            try:
                eccentricity = float(props_by_label[int(label)].eccentricity)
            except Exception:  # noqa: BLE001
                pass

        mean_intensity = float(img_gray[mask].mean()) if mask.any() else None
        integrated_density = ((area_px * mean_intensity)
                              if mean_intensity is not None else None)

        centroid_um_x = cx / px_per_um
        centroid_um_y = cy / px_per_um

        aspect_ratio = 1.0
        if _skimage_ok and int(label) in props_by_label:
            try:
                prop = props_by_label[int(label)]
                minor = float(prop.minor_axis_length)
                if minor > 0:
                    aspect_ratio = float(prop.major_axis_length) / minor
            except Exception:  # noqa: BLE001
                pass

        solidity = None
        if _skimage_ok and int(label) in props_by_label:
            try:
                solidity = float(props_by_label[int(label)].solidity)
            except Exception:  # noqa: BLE001
                pass

        edge_touching = (
            cx < EDGE_MARGIN_PX or cy < EDGE_MARGIN_PX
            or cx > (width_px - EDGE_MARGIN_PX)
            or cy > (height_px - EDGE_MARGIN_PX)
        )

        likely_clump = diameter_um > 80.0
        likely_debris = (
            solidity is not None and solidity < 0.7
            and diameter_um < 8.0
            and mean_intensity is not None and mean_intensity > 220.0
        )

        if diameter_um < small_t:
            size_class = "small"
        elif diameter_um < large_t:
            size_class = "intermediate"
        else:
            size_class = "large"

        cell_dict: dict = {
            "id": str(uuid.uuid4()),
            "cx": cx,
            "cy": cy,
            "diameter_um": diameter_um,
            "diameter_px": diameter_px,
            "confidence": conf,
            "area_um2": area_um2,
            "centroid_um_x": centroid_um_x,
            "centroid_um_y": centroid_um_y,
            "aspect_ratio": aspect_ratio,
            "edge_touching": edge_touching,
            "likely_clump": likely_clump,
            "likely_debris": likely_debris,
            "size_class": size_class,
            "is_manual": False,
        }
        if solidity is not None:
            cell_dict["solidity"] = solidity
        if perimeter_um is not None:
            cell_dict["perimeter_um"] = perimeter_um
        if circularity is not None:
            cell_dict["circularity"] = circularity
        if eccentricity is not None:
            cell_dict["eccentricity"] = eccentricity
        if mean_intensity is not None:
            cell_dict["mean_intensity"] = mean_intensity
        if integrated_density is not None:
            cell_dict["integrated_density"] = integrated_density

        # Per-cell, per-channel intensities. Key omitted entirely when the
        # source was single-channel (channel_planes stays empty).
        if channel_planes:
            try:
                per_channel: list[dict] = []
                for c, plane in enumerate(channel_planes):
                    values = plane[ys, xs]
                    ch_mean = float(values.mean())
                    per_channel.append({
                        "channel": c,
                        "name": resolved_names[c],
                        "mean": ch_mean,
                        "integrated": ch_mean * area_px,
                        "median": float(np.median(values)),
                    })
                cell_dict["channel_intensities"] = per_channel
            except Exception as exc:  # noqa: BLE001
                log("[cellpose_detect] channel intensities failed for label "
                    f"{int(label)} (non-fatal): {exc!r}")

        # Per-cell polygon contour for filled overlay rendering.
        # find_contours returns (row, col) pairs at 0.5 iso-level — flip to
        # (x=col, y=row) and downsample with Ramer–Douglas–Peucker so a
        # 1000-point boundary collapses to ≤200 points without losing shape.
        if _skimage_ok and sk_find_contours is not None:
            try:
                contours = sk_find_contours(mask.astype(np.uint8), 0.5)
                if contours:
                    best = max(contours, key=len)
                    if sk_approx_polygon is not None and len(best) > 4:
                        approx = sk_approx_polygon(best, tolerance=0.5)
                    else:
                        approx = best
                    if len(approx) > 200:
                        stride = int(math.ceil(len(approx) / 200.0))
                        approx = approx[::stride]
                    cell_dict["contour_px"] = [
                        [float(pt[1]), float(pt[0])] for pt in approx
                    ]
            except Exception:  # noqa: BLE001
                pass

        cells.append(cell_dict)

    log(f"[cellpose_detect] measured {len(cells)}/{n_total} cells; serializing JSON…")
    return cells


def reference_stardist_measure(labels, img, args, width_px, height_px, points=None, probs=None):
    """The inline StarDist loop from `stardist_detect.main` before the crop change."""
    import numpy as np

    px_per_um = float(args.pxPerUm) if args.pxPerUm > 0 else 1.0

    # A1: per-cell measurement helpers.
    try:
        from skimage.measure import perimeter as sk_perimeter, regionprops
        _skimage_ok = True
    except ImportError:
        _skimage_ok = False
        log("[stardist_detect] skimage not available — perimeter/eccentricity will be omitted")

    # Grayscale image for intensity measurements (img is already 2-D float32 for single-channel).
    if img.ndim == 2:
        img_gray = img.astype(np.float64)
    else:
        img_gray = img.mean(axis=2).astype(np.float64)

    # Build regionprops once for eccentricity.
    if _skimage_ok:
        try:
            props_by_label = {p.label: p for p in regionprops(labels)}
        except Exception:  # noqa: BLE001
            props_by_label = {}
    else:
        props_by_label = {}

    cells: list[dict] = []
    label_ids = np.unique(labels)
    label_ids = label_ids[label_ids != 0]
    log(f"[stardist_detect] found {len(label_ids)} instances")

    for idx, label in enumerate(label_ids):
        mask = (labels == label)
        ys, xs = np.where(mask)
        area_px = int(mask.sum())
        if area_px < 4:
            continue

        # Prefer the centroid from details['points'] (in (y, x) order per StarDist
        # convention) when available, otherwise fall back to the mask centroid.
        cx: float
        cy: float
        if points is not None and idx < len(points):
            try:
                py, px = points[idx]
                cy = float(py)
                cx = float(px)
            except Exception:  # noqa: BLE001
                cy = float(ys.mean())
                cx = float(xs.mean())
        else:
            cy = float(ys.mean())
            cx = float(xs.mean())

        diameter_px = 2.0 * math.sqrt(area_px / math.pi)
        diameter_um = diameter_px / px_per_um

        conf: float
        if probs is not None and idx < len(probs):
            try:
                raw = float(probs[idx])
                # StarDist prob is already in [0,1]; clamp defensively.
                conf = max(0.0, min(1.0, raw))
            except Exception:  # noqa: BLE001
                conf = 0.85
        else:
            conf = 0.85

        # --- A1: morphology + intensity measurements ---
        area_um2 = area_px / (px_per_um ** 2)

        perimeter_um = None
        circularity = None
        if _skimage_ok:
            try:
                try:
                    perim_px = sk_perimeter(mask, neighborhood=8)
                except TypeError:
                    perim_px = sk_perimeter(mask, neighbourhood=8)
                if perim_px > 0:
                    perimeter_um = perim_px / px_per_um
                    circularity = min(1.0, max(0.0, 4 * math.pi * area_um2 / (perimeter_um ** 2)))
            except Exception:  # noqa: BLE001
                pass

        eccentricity = None
        if _skimage_ok and int(label) in props_by_label:
            try:
                eccentricity = float(props_by_label[int(label)].eccentricity)
            except Exception:  # noqa: BLE001
                pass

        mean_intensity = float(img_gray[mask].mean()) if mask.any() else None
        integrated_density = (area_px * mean_intensity) if mean_intensity is not None else None
        # --- end A1 measurements ---

        # --- C1 (pass 6): quality flags ---
        centroid_um_x = cx / px_per_um
        centroid_um_y = cy / px_per_um

        aspect_ratio = 1.0
        if _skimage_ok and int(label) in props_by_label:
            try:
                prop = props_by_label[int(label)]
                minor = float(prop.minor_axis_length)
                if minor > 0:
                    aspect_ratio = float(prop.major_axis_length) / minor
            except Exception:  # noqa: BLE001
                pass

        solidity: float | None = None
        if _skimage_ok and int(label) in props_by_label:
            try:
                solidity = float(props_by_label[int(label)].solidity)
            except Exception:  # noqa: BLE001
                pass

        EDGE_MARGIN_PX = 16
        edge_touching = (
            cx < EDGE_MARGIN_PX or cy < EDGE_MARGIN_PX
            or cx > (width_px - EDGE_MARGIN_PX) or cy > (height_px - EDGE_MARGIN_PX)
        )

        likely_clump = diameter_um > 80.0

        likely_debris = (
            solidity is not None and solidity < 0.7
            and diameter_um < 8.0
            and mean_intensity is not None and mean_intensity > 220.0
        )

        small_t = float(getattr(args, "small_threshold", 20))
        large_t = float(getattr(args, "large_threshold", 30))
        if diameter_um < small_t:
            size_class = "small"
        elif diameter_um < large_t:
            size_class = "intermediate"
        else:
            size_class = "large"

        is_manual = False
        # --- end C1 quality flags ---

        cell_dict: dict = {
            "id": str(uuid.uuid4()),
            "cx": cx,
            "cy": cy,
            "diameter_um": diameter_um,
            "diameter_px": diameter_px,
            "confidence": conf,
            "area_um2": area_um2,
            "centroid_um_x": centroid_um_x,
            "centroid_um_y": centroid_um_y,
            "aspect_ratio": aspect_ratio,
            "edge_touching": edge_touching,
            "likely_clump": likely_clump,
            "likely_debris": likely_debris,
            "size_class": size_class,
            "is_manual": is_manual,
        }
        if solidity is not None:
            cell_dict["solidity"] = solidity
        if perimeter_um is not None:
            cell_dict["perimeter_um"] = perimeter_um
        if circularity is not None:
            cell_dict["circularity"] = circularity
        if eccentricity is not None:
            cell_dict["eccentricity"] = eccentricity
        if mean_intensity is not None:
            cell_dict["mean_intensity"] = mean_intensity
        if integrated_density is not None:
            cell_dict["integrated_density"] = integrated_density
        cells.append(cell_dict)
    return cells


def reference_sam_measure(label_map, img, args, width_px, height_px, scores):
    """The inline SAM loop from `sam_detect.main` before the crop change."""
    import numpy as np

    px_per_um = float(args.pxPerUm) if args.pxPerUm > 0 else 1.0

    # A1: per-cell measurement helpers.
    try:
        from skimage.measure import (perimeter as sk_perimeter, regionprops,
                                     find_contours as sk_find_contours)
        _skimage_ok = True
    except ImportError:
        _skimage_ok = False
        sk_find_contours = None
        log("[sam_detect] skimage not available — perimeter/eccentricity will be omitted")

    # Grayscale image for intensity measurements (img is already uint8 grayscale from load_image_array).
    img_gray = img.astype(np.float64)

    # Build regionprops once for eccentricity.
    if _skimage_ok:
        try:
            props_by_label = {p.label: p for p in regionprops(label_map)}
        except Exception:  # noqa: BLE001
            props_by_label = {}
    else:
        props_by_label = {}

    cells = []
    label_ids = np.unique(label_map)
    label_ids = label_ids[label_ids != 0]
    log(f"[sam_detect] found {len(label_ids)} instances")

    for idx, label in enumerate(label_ids):
        mask = (label_map == label)
        ys, xs = np.where(mask)
        area_px = int(mask.sum())
        if area_px < 4:
            continue
        cy = float(ys.mean())
        cx = float(xs.mean())
        diameter_px = 2.0 * math.sqrt(area_px / math.pi)
        diameter_um = diameter_px / px_per_um

        if idx < len(scores):
            try:
                conf = max(0.0, min(1.0, float(scores[idx])))
            except Exception:  # noqa: BLE001
                conf = 0.85
        else:
            conf = 0.85

        # --- A1: morphology + intensity measurements ---
        area_um2 = area_px / (px_per_um ** 2)

        perimeter_um = None
        circularity = None
        if _skimage_ok:
            try:
                try:
                    perim_px = sk_perimeter(mask, neighborhood=8)
                except TypeError:
                    perim_px = sk_perimeter(mask, neighbourhood=8)
                if perim_px > 0:
                    perimeter_um = perim_px / px_per_um
                    circularity = min(1.0, max(0.0, 4 * math.pi * area_um2 / (perimeter_um ** 2)))
            except Exception:  # noqa: BLE001
                pass

        eccentricity = None
        if _skimage_ok and int(label) in props_by_label:
            try:
                eccentricity = float(props_by_label[int(label)].eccentricity)
            except Exception:  # noqa: BLE001
                pass

        mean_intensity = float(img_gray[mask].mean()) if mask.any() else None
        integrated_density = (area_px * mean_intensity) if mean_intensity is not None else None
        # --- end A1 measurements ---

        # --- C1 (pass 6): quality flags ---
        centroid_um_x = cx / px_per_um
        centroid_um_y = cy / px_per_um

        aspect_ratio = 1.0
        if _skimage_ok and int(label) in props_by_label:
            try:
                prop = props_by_label[int(label)]
                minor = float(prop.minor_axis_length)
                if minor > 0:
                    aspect_ratio = float(prop.major_axis_length) / minor
            except Exception:  # noqa: BLE001
                pass

        solidity: float | None = None
        if _skimage_ok and int(label) in props_by_label:
            try:
                solidity = float(props_by_label[int(label)].solidity)
            except Exception:  # noqa: BLE001
                pass

        EDGE_MARGIN_PX = 16
        edge_touching = (
            cx < EDGE_MARGIN_PX or cy < EDGE_MARGIN_PX
            or cx > (width_px - EDGE_MARGIN_PX) or cy > (height_px - EDGE_MARGIN_PX)
        )

        likely_clump = diameter_um > 80.0

        likely_debris = (
            solidity is not None and solidity < 0.7
            and diameter_um < 8.0
            and mean_intensity is not None and mean_intensity > 220.0
        )

        small_t = float(getattr(args, "small_threshold", 20))
        large_t = float(getattr(args, "large_threshold", 30))
        if diameter_um < small_t:
            size_class = "small"
        elif diameter_um < large_t:
            size_class = "intermediate"
        else:
            size_class = "large"

        is_manual = False
        # --- end C1 quality flags ---

        cell_dict: dict = {
            "id": str(uuid.uuid4()),
            "cx": cx,
            "cy": cy,
            "diameter_um": diameter_um,
            "diameter_px": diameter_px,
            "confidence": conf,
            "area_um2": area_um2,
            "centroid_um_x": centroid_um_x,
            "centroid_um_y": centroid_um_y,
            "aspect_ratio": aspect_ratio,
            "edge_touching": edge_touching,
            "likely_clump": likely_clump,
            "likely_debris": likely_debris,
            "size_class": size_class,
            "is_manual": is_manual,
        }
        if solidity is not None:
            cell_dict["solidity"] = solidity
        if perimeter_um is not None:
            cell_dict["perimeter_um"] = perimeter_um
        if circularity is not None:
            cell_dict["circularity"] = circularity
        if eccentricity is not None:
            cell_dict["eccentricity"] = eccentricity
        if mean_intensity is not None:
            cell_dict["mean_intensity"] = mean_intensity
        if integrated_density is not None:
            cell_dict["integrated_density"] = integrated_density
        if _skimage_ok and sk_find_contours is not None:
            try:
                contours = sk_find_contours(mask.astype(np.uint8), 0.5)
                if contours:
                    best_contour = max(contours, key=len)
                    stride = max(1, int(math.ceil(len(best_contour) / 256)))
                    sampled = best_contour[::stride]
                    if len(sampled) >= 3:
                        cell_dict["contour_px"] = [
                            [float(point[1]), float(point[0])] for point in sampled
                        ]
            except Exception:
                pass
        cells.append(cell_dict)
    return cells


if __name__ == "__main__":
    unittest.main()
