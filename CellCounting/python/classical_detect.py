#!/usr/bin/env python3
"""
classical_detect.py — CellCounter sidecar for the deep-learning-free detector.

Threshold → distance transform → watershed → label. scikit-image only: no
weights, no download, no GPU, no network. Deterministic — the same image and
the same arguments always produce the same labels, which makes this the
detector to reach for when a run has to be reproducible (or when nothing else
is installed).

Pipeline
--------
 1. Load + preprocess the image through the shared `_cellpose_common` helpers
    (identical rolling-ball background subtraction as every other sidecar).
 2. Pick a global (or local/adaptive) threshold — Otsu, triangle, Li, Yen,
    mean, adaptive, or an explicit manual value.
 3. Decide polarity: are the objects brighter or darker than the background?
    `auto` compares the image mean against the threshold, which is the
    standard heuristic (fluorescence → bright objects, brightfield → dark).
 4. Clean the binary mask: fill holes, drop specks below `--min-area-px`.
 5. Distance-transform watershed via the shared `_watershed.label_binary`,
    seeded by `peak_local_max` at `--watershed-min-distance` µm × `--pxPerUm`.
 6. Measure every label through `_cellpose_common.measure_cells`, so the JSON
    contract (including per-cell `contour_px`) is byte-for-byte identical to
    the Cellpose / Cellpose-SAM sidecars.

Confidence
----------
A deterministic detector has no learned objectness score, so a constant 0.85
for every cell would make the app's confidence slider inert. Instead we build
a pseudo cell-probability map from the *contrast above threshold*:

    prob_logit = (intensity - threshold) / (0.25 * (peak - threshold))

`measure_cells` runs a sigmoid over each label's mean, so an object well clear
of the threshold lands near 1.0 while a faint, marginal blob lands near 0.5.
That is honest — it reports how confidently the pixel intensities separated
from the background, and nothing more.

Stdout contract: see `_cellpose_common.emit_payload`. All logging goes to
stderr so stdout stays parseable by the Swift host.

CLI: accepts the full shared flag set (`--image`, `--model`, `--pxPerUm`,
`--conf`, `--channels`, `--bg-subtract`, `--rolling-ball-radius`,
`--watershed`, `--watershed-min-distance`, `--small-threshold`,
`--large-threshold`, `--no-gpu`, `--device`) so it is drop-in compatible with
the existing runner, plus the classical-only flags documented below.
"""

from __future__ import annotations

import os
import sys

# Ensure the shared helpers (_cellpose_common, _preprocessing, _watershed,
# _colony) are importable whether we run from the staged python dir or in-tree.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _cellpose_common as cc  # noqa: E402
from _cellpose_common import log, emit_error  # noqa: E402


# Catalog id → threshold method. Keeps the Swift side free to pass either
# `--model cw-otsu` (the app-level id) or an explicit `--threshold-method`.
_MODEL_METHOD = {
    "cw-otsu": "otsu",
    "cw-triangle": "triangle",
    "cw-adaptive": "adaptive",
    "cw-li": "li",
    "cw-yen": "yen",
    "cw-mean": "mean",
    "cw-manual": "manual",
}

_METHODS = ("otsu", "triangle", "li", "yen", "mean", "adaptive", "manual")


def parse_args():
    parser = cc.build_arg_parser(
        description="Classical threshold + watershed detection sidecar for CellCounter",
        default_model="cw-otsu",
    )
    parser.add_argument(
        "--threshold-method", dest="threshold_method", default=None,
        choices=_METHODS,
        help="Thresholding algorithm. When omitted it is derived from --model "
             "(cw-otsu → otsu, cw-triangle → triangle, …). Default otsu.",
    )
    parser.add_argument(
        "--threshold-value", dest="threshold_value", type=float, default=0.0,
        help="Explicit threshold in the image's own intensity units (0–255 for "
             "8-bit). Only used when --threshold-method manual. Default 0 "
             "(which falls back to Otsu so a misconfigured manual run still "
             "produces something sane).",
    )
    parser.add_argument(
        "--polarity", default="auto", choices=("auto", "bright", "dark"),
        help="Are the objects brighter or darker than the background? "
             "'auto' (default) picks bright when the image mean sits below the "
             "threshold (fluorescence) and dark otherwise (brightfield).",
    )
    parser.add_argument(
        "--block-size", dest="block_size", type=int, default=51,
        help="Neighbourhood size in pixels for --threshold-method adaptive. "
             "Forced odd and >= 3. Default 51.",
    )
    parser.add_argument(
        "--adaptive-offset", dest="adaptive_offset", type=float, default=0.0,
        help="How far (in intensity units) a pixel must clear its local "
             "background to count as signal, for --threshold-method adaptive. "
             "Default 0 = auto (half the standard deviation of the local "
             "residual, i.e. half the local noise level).",
    )
    parser.add_argument(
        "--min-area-px", dest="min_area_px", type=int, default=16,
        help="Drop connected components smaller than this many pixels before "
             "the watershed. Default 16.",
    )
    parser.add_argument(
        "--no-fill-holes", dest="fill_holes", action="store_false",
        help="Skip binary hole filling. Holes are filled by default because a "
             "ring-shaped nucleus otherwise watersheds into two crescents.",
    )
    parser.set_defaults(fill_holes=True)
    # Accepted for CLI parity with the Cellpose sidecars (the host adds
    # --diameter whenever the user pins an expected diameter). A classical
    # threshold has no size prior, so we log it and move on.
    parser.add_argument(
        "--diameter", type=float, default=0.0,
        help="Accepted for CLI compatibility with the Cellpose sidecars. "
             "A threshold has no size prior, so this only widens the watershed "
             "seed spacing when > 0.",
    )
    return parser.parse_args()


def _resolve_method(args) -> str:
    if args.threshold_method:
        return args.threshold_method
    return _MODEL_METHOD.get(args.model, "otsu")


def _global_threshold(gray, method: str, args) -> float:
    """Scalar threshold for every method except `adaptive`."""
    from skimage import filters

    if method == "manual":
        if args.threshold_value > 0:
            return float(args.threshold_value)
        log("[cellpose_detect] manual threshold requested but --threshold-value "
            "is 0; falling back to Otsu")
        return float(filters.threshold_otsu(gray))
    if method == "triangle":
        return float(filters.threshold_triangle(gray))
    if method == "li":
        return float(filters.threshold_li(gray))
    if method == "yen":
        return float(filters.threshold_yen(gray))
    if method == "mean":
        return float(filters.threshold_mean(gray))
    return float(filters.threshold_otsu(gray))


def _adaptive_threshold(gray, polarity: str, args):
    """Local threshold surface, offset in the direction of `polarity`.

    A bare `threshold_local` surface is (approximately) a smoothed copy of the
    image, so `gray > surface` splits the frame roughly in half and segments
    noise. The surface only becomes a detector once it is offset: a pixel must
    clear its local background by some margin to count as signal.

    The margin defaults to half the standard deviation of the residual
    `gray - surface`, i.e. half the local noise level — so it adapts to the
    image instead of being a magic constant. `--adaptive-offset` overrides it.
    """
    import numpy as np
    from skimage import filters

    block = max(3, int(args.block_size))
    if block % 2 == 0:
        block += 1
    surface = filters.threshold_local(gray, block_size=block)
    residual = gray - surface
    if args.adaptive_offset > 0:
        offset = float(args.adaptive_offset)
        source = "--adaptive-offset"
    else:
        offset = max(1.0, 0.5 * float(np.std(residual)))
        source = "auto (0.5 × residual std)"
    log(f"[cellpose_detect] adaptive block_size={block} offset={offset:.2f} ({source})")
    # Bright objects must sit ABOVE the local background, dark ones BELOW.
    return surface + offset if polarity == "bright" else surface - offset


def _resolve_polarity(gray, threshold, requested: str) -> str:
    """'bright' when objects sit above the threshold, 'dark' when below.

    Auto-detection uses the MEDIAN, not the mean. The median tracks the
    background — the dominant pixel population — whereas a handful of very
    bright cells drags the mean above a low Otsu threshold and flips the
    answer. (Measured on a synthetic 3-disc image: mean 27.1 > Otsu 10.8 would
    have selected the background as "objects"; median 6 < 10.8 gets it right.)

    So: background below the threshold → objects are the bright side, and
    vice-versa. That is correct for both conventions we care about —
    fluorescence (bright cells, dark field) and brightfield (dark cells,
    bright field).

    A final guard catches the remaining pathological flips: a "foreground"
    covering >90% of the frame is not a segmentation, so if the other side is
    a plausible fraction we take that instead and say so in the log.
    """
    import numpy as np

    if requested in ("bright", "dark"):
        return requested

    median = float(np.median(gray))
    thr = float(np.mean(threshold))
    polarity = "bright" if median < thr else "dark"

    frac = float((gray > thr).mean()) if polarity == "bright" else float((gray < thr).mean())
    if frac > 0.9:
        other = 1.0 - frac
        if 0.0005 < other < 0.5:
            flipped = "dark" if polarity == "bright" else "bright"
            log(f"[cellpose_detect] auto-polarity '{polarity}' would mark "
                f"{frac * 100:.1f}% of the image as one object; using "
                f"'{flipped}' instead ({other * 100:.1f}% foreground). "
                "Pass --polarity to override.")
            return flipped
    return polarity


def main() -> None:
    args = parse_args()
    channels = cc.parse_channels(args.channels)
    method = _resolve_method(args)

    try:
        import numpy as np
        from scipy import ndimage as ndi  # noqa: F401 — used below
        import skimage  # noqa: F401
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] import failed: {exc!r}")
        emit_error(
            "classical-deps-missing",
            hint="scikit-image + scipy are required. Run scripts/install_python.sh.",
            exit_code=2,
        )
        return

    # Shared loader: opens the file, honours the channel selection, and runs
    # the same rolling-ball preprocessing every other sidecar uses.
    img = cc.open_image_for_detection(args.image, channels, args)

    image_stats: dict = {}
    image_stats.update(cc.compute_qc_metrics(img))
    # Expose the calibration read from the image file's own metadata
    # (px/µm). Reported only — --pxPerUm still drives every measurement.
    image_stats.update(cc.detected_calibration_stats(args))

    height_px, width_px = int(img.shape[0]), int(img.shape[1])
    log(f"[cellpose_detect] image is {width_px}x{height_px} (ndim={img.ndim}); "
        f"classical threshold method={method}")
    # The host's device label reads this line; a classical run is always CPU.
    log("[cellpose_detect] using device: cpu (scikit-image, no GPU required)")

    gray = img.astype(np.float64) if img.ndim == 2 else img.mean(axis=2).astype(np.float64)

    # --- 1. Threshold -------------------------------------------------------
    # Polarity is resolved FIRST, from a global threshold, because the adaptive
    # surface has to be offset in the direction of the objects — which means it
    # needs to know the polarity before it can be computed.
    try:
        global_thr = _global_threshold(gray, "otsu" if method == "adaptive" else method, args)
        polarity = _resolve_polarity(gray, global_thr, args.polarity)
        if method == "adaptive":
            threshold = _adaptive_threshold(gray, polarity, args)
            is_local = True
        else:
            threshold = global_thr
            is_local = False
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] threshold failed: {exc!r}")
        emit_error("threshold-failed", hint=str(exc), exit_code=5)
        return

    thr_repr = ("local surface" if is_local else f"{float(threshold):.2f}")
    log(f"[cellpose_detect] threshold={thr_repr} polarity={polarity}")

    if polarity == "bright":
        binary = gray > threshold
        contrast = gray - threshold
    else:
        binary = gray < threshold
        contrast = threshold - gray

    if not binary.any():
        log("[cellpose_detect] threshold produced an empty mask — 0 cells")
        cc.emit_payload(width_px, height_px, [], image_stats)
        return

    # --- 2. Clean the binary mask ------------------------------------------
    from scipy import ndimage as ndi
    from skimage import morphology

    if args.fill_holes:
        try:
            binary = ndi.binary_fill_holes(binary)
        except Exception as exc:  # noqa: BLE001
            log(f"[cellpose_detect] fill_holes failed (non-fatal): {exc!r}")

    min_area = max(0, int(args.min_area_px))
    if min_area > 0:
        try:
            binary = morphology.remove_small_objects(binary, min_size=min_area)
        except Exception as exc:  # noqa: BLE001
            log(f"[cellpose_detect] remove_small_objects failed (non-fatal): {exc!r}")

    if not binary.any():
        log(f"[cellpose_detect] mask empty after cleanup (min_area_px={min_area}) — 0 cells")
        cc.emit_payload(width_px, height_px, [], image_stats)
        return

    # --- 3. Distance-transform watershed -----------------------------------
    # Seed spacing comes from the same µm-denominated flag the other sidecars
    # use, so "split touching cells at 8 µm" means the same thing everywhere.
    min_d_um = float(getattr(args, "watershed_min_distance", 8))
    if args.diameter > 0:
        # An explicit expected diameter is a better seed-spacing prior than the
        # watershed default: two cells of diameter D cannot have centres closer
        # than roughly D/2 without being one object.
        min_d_um = max(min_d_um, args.diameter / 2.0)
        log(f"[cellpose_detect] --diameter {args.diameter:.1f}µm widens watershed "
            f"seed spacing to {min_d_um:.1f}µm")
    min_d_px = max(1, int(round(min_d_um * float(args.pxPerUm))))
    log(f"[cellpose_detect] watershed seed min_distance_px={min_d_px}")

    try:
        import _watershed
        labels = _watershed.label_binary(binary, min_distance_px=min_d_px)
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] watershed failed: {exc!r}; falling back to "
            "connected components")
        labels, _ = ndi.label(binary)

    n_labels = int(labels.max())
    log(f"[cellpose_detect] found {n_labels} objects after watershed")

    # --- 4. Pseudo cell-probability map ------------------------------------
    # `measure_cells` applies a sigmoid to each label's mean of flows[2], so we
    # hand it a contrast-above-threshold logit. Scale so an object a quarter of
    # the way to the image peak reads as ~0.73 and a saturated one as ~1.0.
    prob_map = None
    try:
        peak = float(np.percentile(contrast[binary], 95)) if binary.any() else 0.0
        scale = max(1e-6, 0.25 * peak)
        prob_map = (contrast / scale).astype(np.float64)
        # Clip so a blown-out highlight can't overflow the exp in the sigmoid.
        prob_map = np.clip(prob_map, -20.0, 20.0)
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] confidence map failed (non-fatal): {exc!r}")
        prob_map = None
    flows_stub = (None, None, prob_map) if prob_map is not None else None

    # NOTE: we deliberately do NOT call `cc.apply_watershed_if_requested` here.
    # The watershed is intrinsic to this detector, so honouring `--watershed`
    # a second time would re-run the identical distance transform for nothing.
    if getattr(args, "watershed", False):
        log("[cellpose_detect] --watershed is implied by the classical "
            "pipeline; not re-running it")

    image_stats.update(cc.compute_colony_stats(labels, args, height_px, width_px))
    image_stats["classical_threshold"] = (
        float(np.mean(threshold)) if not is_local else float(np.mean(threshold))
    )

    cells = cc.measure_cells(labels, img, args, flows=flows_stub)
    cc.emit_payload(width_px, height_px, cells, image_stats)


if __name__ == "__main__":
    main()
