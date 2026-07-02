#!/usr/bin/env python3
"""
cellpose_detect.py — CellCounter sidecar.

Reads an image, runs a Cellpose model, prints a single JSON object to stdout
describing detected cells. All progress/log output goes to stderr so stdout
stays parseable by the Swift host (CellposeDetectionService).

Stdout contract:
  {
    "width":  <int>,
    "height": <int>,
    "cells": [
      {
        "id": "<uuid4>",
        "cx": <float pixel>,
        "cy": <float pixel>,
        "diameter_um": <float>,
        "diameter_px": <float>,
        "confidence": <float in [0,1]>
      },
      ...
    ]
  }

If cellpose (or one of its deps) is not importable, prints:
  {"error": "cellpose-not-installed", "hint": "Run scripts/install_python.sh"}
to stdout and exits with code 2.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import uuid


def log(*args, **kwargs) -> None:
    """Stderr logger — stdout is reserved for the JSON result."""
    print(*args, file=sys.stderr, **kwargs)


def emit_error(error: str, hint: str = "", exit_code: int = 2) -> None:
    payload = {"error": error}
    if hint:
        payload["hint"] = hint
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()
    sys.exit(exit_code)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Cellpose detection sidecar for CellCounter")
    p.add_argument("--image", required=True, help="Path to input image (jpg/png/tif/bmp).")
    p.add_argument("--model", default="cyto3",
                   help="Cellpose model_type (cyto3, nuclei, cp-cyto3, cp-nuclei, ...).")
    p.add_argument("--pxPerUm", type=float, required=True,
                   help="Pixels per micrometer; used to convert pixel diameter to µm.")
    p.add_argument("--conf", type=float, default=0.5,
                   help="Confidence threshold in [0,1]. Detections below this are kept "
                        "but the field is reported so the host can filter.")
    p.add_argument("--channels", default="0,0",
                   help="Two comma-separated ints: cyto channel, nuclei channel. "
                        "0=grayscale/none, 1=red, 2=green, 3=blue. Default: 0,0 (grayscale).")
    p.add_argument("--restore", action="store_true",
                   help="Enable Cellpose 3.x image restoration "
                        "(restore_type='denoise_cyto3'). Used by the cp-cyto3-r model.")
    p.add_argument("--bg-subtract", dest="bg_subtract", action="store_true",
                   help="Apply rolling-ball background subtraction before detection.")
    p.add_argument("--rolling-ball-radius", dest="rolling_ball_radius", type=int, default=50,
                   help="Radius for rolling-ball background subtraction (default 50).")
    p.add_argument("--watershed", action="store_true",
                   help="Run a distance-transform watershed on the detected mask to "
                        "split touching cells into separate labels (A3 middle-of-script "
                        "post-process between detect and measure).")
    p.add_argument("--watershed-min-distance", dest="watershed_min_distance",
                   type=int, default=8,
                   help="Minimum distance between watershed seed peaks, in MICROMETERS. "
                        "Multiplied by --pxPerUm before being passed to the splitter. "
                        "Default 8 µm.")
    # C1 (pass 6): configurable size-class thresholds (µm) matching the configured size bins.
    p.add_argument("--small-threshold", dest="small_threshold", type=float, default=20,
                   help="Diameter threshold (µm) below which cells are classified 'small'. "
                        "Default 20.")
    p.add_argument("--large-threshold", dest="large_threshold", type=float, default=30,
                   help="Diameter threshold (µm) at or above which cells are classified 'large'. "
                        "Default 30.")
    return p.parse_args()


def parse_channels(channels_str: str) -> list[int]:
    """Parse '--channels c0,c1' into [c0, c1], clamping to valid range."""
    try:
        parts = [int(x.strip()) for x in channels_str.split(",")]
        if len(parts) != 2:
            raise ValueError("expected exactly 2 values")
        return [max(0, min(3, parts[0])), max(0, min(3, parts[1]))]
    except Exception as exc:
        log(f"[cellpose_detect] invalid --channels '{channels_str}': {exc!r}; falling back to [0,0]")
        return [0, 0]


def load_image_array(pil_image):
    """
    Convert a PIL image to a numpy array suitable for Cellpose multi-channel eval.

    - For grayscale (L, I, F): return 2-D (H, W) uint8.
    - For RGB/RGBA and other multi-channel modes: return 3-D (H, W, C) uint8
      keeping colour information so the caller can choose channels=[cyto, nuclei].
    """
    import numpy as np

    mode = pil_image.mode
    if mode == "L":
        return np.array(pil_image, dtype=np.uint8)
    if mode in ("I", "F"):
        arr = np.array(pil_image, dtype=np.float32)
        arr_min, arr_max = arr.min(), arr.max()
        if arr_max > arr_min:
            arr = (arr - arr_min) / (arr_max - arr_min) * 255.0
        return arr.astype(np.uint8)
    # RGB, RGBA, P, … — convert to RGB to guarantee exactly 3 channels.
    rgb = pil_image.convert("RGB")
    return np.array(rgb, dtype=np.uint8)


def main() -> None:
    args = parse_args()
    channels = parse_channels(args.channels)

    # Lazy imports — so the import-error branch can emit the structured error
    # without crashing on bare ImportError.
    try:
        import numpy as np
        from PIL import Image
        from cellpose import models as cp_models
    except Exception as exc:  # noqa: BLE001 — we want broad capture for first-run UX
        log(f"[cellpose_detect] import failed: {exc!r}")
        emit_error("cellpose-not-installed",
                   hint="Run scripts/install_python.sh",
                   exit_code=2)
        return

    # Map any app-level "cp-*" alias down to the canonical cellpose name.
    model_type = args.model
    if model_type.startswith("cp-"):
        model_type = model_type[3:]

    log(f"[cellpose_detect] loading image: {args.image}")
    try:
        pil = Image.open(args.image)
        pil.load()
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] could not open image: {exc!r}")
        emit_error("image-open-failed", hint=str(exc), exit_code=3)
        return

    # Load image keeping all channels; only convert to grayscale if channels=[0,0].
    is_grayscale_mode = (channels[0] == 0 and channels[1] == 0)
    if is_grayscale_mode:
        img = np.array(pil.convert("L"), dtype=np.uint8)
    else:
        img = load_image_array(pil)

    # --- C3: QC metrics on RAW image (before any preprocessing) ---
    # Scores are computed on the raw pixel data so they reflect true acquisition quality.
    _image_stats: dict = {}
    try:
        # Grayscale conversion for QC: average channels if multi-channel.
        _qc_gray = img.astype(np.float64) if img.ndim == 2 else img.mean(axis=2).astype(np.float64)

        # Focus score: Laplacian variance, normalized to ~[0, 1].
        # Heuristic: a well-focused 8-bit brightfield or fluorescence image typically
        # has a Laplacian variance in the range 1 000–50 000. We divide by 10 000 and
        # clamp to [0, 1], so variance ≥ 10 000 → score ≥ 1.0 (clamped to 1.0).
        # Score < 0.2 reliably indicates blur; score ≥ 0.5 is acceptable focus.
        try:
            import cv2 as _cv2
            _lap_var = float(_cv2.Laplacian(_qc_gray, _cv2.CV_64F).var())
        except ImportError:
            from scipy.ndimage import laplace as _sp_laplace
            _lap_var = float(_sp_laplace(_qc_gray).var())
        _focus_score = min(1.0, max(0.0, _lap_var / 10000.0))
        _image_stats["focus_score"] = _focus_score
        log(f"[cellpose_detect] QC focus_score={_focus_score:.4f} (lap_var={_lap_var:.1f})")

        # Illumination residual: fit a 2-D quadratic to the luminance field.
        # Sample on a 128×128 grid to keep cost O(1) regardless of image size.
        _H, _W = _qc_gray.shape
        _DS = 128
        _ys = np.linspace(0, _H - 1, _DS, dtype=np.float64)
        _xs = np.linspace(0, _W - 1, _DS, dtype=np.float64)
        _xv, _yv = np.meshgrid(_xs, _ys)
        _xv_f = _xv.ravel()
        _yv_f = _yv.ravel()
        # Sample the image at the grid points (nearest-neighbour is fine for a QC metric).
        _yi = np.clip(np.round(_yv_f).astype(int), 0, _H - 1)
        _xi = np.clip(np.round(_xv_f).astype(int), 0, _W - 1)
        _z = _qc_gray[_yi, _xi]
        # Design matrix: [x², y², xy, x, y, 1] for a full quadratic surface.
        _A = np.column_stack([
            _xv_f ** 2, _yv_f ** 2, _xv_f * _yv_f,
            _xv_f, _yv_f, np.ones(len(_xv_f))
        ])
        _coeffs, _, _, _ = np.linalg.lstsq(_A, _z, rcond=None)
        _fitted = (_A @ _coeffs)
        _residual_std = float((_z - _fitted).std())
        _lum_mean = float(_z.mean())
        _illumination_residual = (_residual_std / _lum_mean) if _lum_mean > 1e-6 else 0.0
        _image_stats["illumination_residual"] = _illumination_residual
        log(f"[cellpose_detect] QC illumination_residual={_illumination_residual:.4f}")
    except Exception as _qc_exc:  # noqa: BLE001 — never let QC crash detection
        log(f"[cellpose_detect] QC metrics failed (non-fatal): {_qc_exc!r}")
    # --- end C3 QC metrics ---

    # --- Background subtraction (A2 preprocessing block) ---
    import os as _os
    import sys as _sys
    _sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
    import _preprocessing
    img = _preprocessing.apply(img, args)
    # --------------------------------------------------------

    if img.ndim == 2:
        height_px, width_px = int(img.shape[0]), int(img.shape[1])
    else:
        height_px, width_px = int(img.shape[0]), int(img.shape[1])

    log(f"[cellpose_detect] image is {width_px}x{height_px} (ndim={img.ndim}); "
        f"model={model_type}; channels={channels}")

    try:
        if args.restore:
            log("[cellpose_detect] enabling restore_type='denoise_cyto3'")
            try:
                model = cp_models.CellposeModel(
                    model_type=model_type,
                    restore_type="denoise_cyto3",
                )
            except TypeError:
                # Older cellpose builds don't accept restore_type on CellposeModel; degrade gracefully.
                log("[cellpose_detect] CellposeModel doesn't accept restore_type; falling back to plain model")
                model = cp_models.CellposeModel(model_type=model_type)
        else:
            model = cp_models.CellposeModel(model_type=model_type)
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] model load failed: {exc!r}")
        emit_error("model-load-failed", hint=str(exc), exit_code=4)
        return

    log("[cellpose_detect] running eval ...")
    try:
        eval_out = model.eval(img, diameter=None, channels=channels)
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] eval failed: {exc!r}")
        emit_error("eval-failed", hint=str(exc), exit_code=5)
        return

    # Cellpose returns (masks, flows, styles[, diams]) depending on version.
    masks = eval_out[0]
    flows = eval_out[1] if len(eval_out) > 1 else None

    # A3 (middle-of-script): optional distance-transform watershed split.
    # Runs BETWEEN detect (above) and per-cell measure (below). Leaves masks
    # in the same shape/dtype contract; only the label values may change.
    if getattr(args, "watershed", False):
        try:
            import _watershed
            min_d_px = max(1, int(round(args.watershed_min_distance * args.pxPerUm)))
            log(f"[cellpose_detect] watershed split with min_distance_px={min_d_px}")
            masks = _watershed.split(masks, min_distance_px=min_d_px)
        except Exception as exc:  # noqa: BLE001 — never fail detection over a post-process
            log(f"[cellpose_detect] watershed split failed: {exc!r}; using original masks")

    # --- C2 (pass 6): per-image colony + spatial statistics ---
    # Runs AFTER detect+watershed, BEFORE the per-cell measure loop. Merges
    # into the shared `_image_stats` dict alongside C3's QC metrics so both
    # land under one "image_stats" key in the JSON payload.
    try:
        import _colony
        _image_stats.update(
            _colony.compute(masks, args.pxPerUm, (height_px, width_px))
        )
        log(f"[cellpose_detect] colony: n_colonies={_image_stats.get('n_colonies', 0)} "
            f"confluency={_image_stats.get('confluency_pct', 0):.1f}%")
    except Exception as _col_exc:  # noqa: BLE001 — never fail detection over colony stats
        log(f"[cellpose_detect] colony stats failed (non-fatal): {_col_exc!r}")
        try:
            import _colony
            _image_stats.update(_colony.zero_stats())
        except Exception:
            pass
    # --- end C2 colony stats ---

    # Try to pull a per-pixel flow probability map for confidence estimation.
    # In recent cellpose versions, flows[2] is the cellprob (logits or prob) map.
    cellprob_map = None
    if flows is not None:
        try:
            candidate = flows[2]
            if hasattr(candidate, "shape") and candidate.shape == masks.shape:
                cellprob_map = candidate
        except Exception:  # noqa: BLE001
            cellprob_map = None

    px_per_um = float(args.pxPerUm) if args.pxPerUm > 0 else 1.0

    # A1: per-cell measurement helpers.
    try:
        from skimage.measure import perimeter as sk_perimeter, regionprops
        _skimage_ok = True
    except ImportError:
        _skimage_ok = False
        log("[cellpose_detect] skimage not available — perimeter/eccentricity will be omitted")

    # Grayscale image for intensity measurements.
    if img.ndim == 2:
        img_gray = img.astype(np.float64)
    else:
        img_gray = img.mean(axis=2).astype(np.float64)

    # Build regionprops once for eccentricity (needs the labelled mask array).
    if _skimage_ok:
        try:
            props_by_label = {p.label: p for p in regionprops(masks)}
        except Exception:  # noqa: BLE001
            props_by_label = {}
    else:
        props_by_label = {}

    cells = []
    label_ids = np.unique(masks)
    label_ids = label_ids[label_ids != 0]
    log(f"[cellpose_detect] found {len(label_ids)} masks")

    for label in label_ids:
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
                # cellprob in recent cellpose is roughly in [-6, +6] logit-ish;
                # squash via sigmoid into [0,1]. If already prob, this is still monotone.
                conf = 1.0 / (1.0 + math.exp(-raw))
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
        # centroid in µm
        centroid_um_x = cx / px_per_um
        centroid_um_y = cy / px_per_um

        # aspect ratio from regionprops (major / minor axis length); 1.0 if no regionprops or degenerate.
        aspect_ratio = 1.0
        if _skimage_ok and int(label) in props_by_label:
            try:
                prop = props_by_label[int(label)]
                minor = float(prop.minor_axis_length)
                if minor > 0:
                    aspect_ratio = float(prop.major_axis_length) / minor
            except Exception:  # noqa: BLE001
                pass

        # solidity from regionprops (area / convex_area).
        solidity: float | None = None
        if _skimage_ok and int(label) in props_by_label:
            try:
                solidity = float(props_by_label[int(label)].solidity)
            except Exception:  # noqa: BLE001
                pass

        # edge_touching: centroid within EDGE_MARGIN_PX pixels of any image border.
        EDGE_MARGIN_PX = 16
        edge_touching = (
            cx < EDGE_MARGIN_PX or cy < EDGE_MARGIN_PX
            or cx > (width_px - EDGE_MARGIN_PX) or cy > (height_px - EDGE_MARGIN_PX)
        )

        # likely_clump: diameter_um > 80 µm (tunable).
        likely_clump = diameter_um > 80.0

        # likely_debris: solidity < 0.7 AND diameter_um < 8 AND mean_intensity > 220.
        # All three conditions required to reduce false positives.
        likely_debris = (
            solidity is not None and solidity < 0.7
            and diameter_um < 8.0
            and mean_intensity is not None and mean_intensity > 220.0
        )

        # size_class using caller-supplied thresholds (defaults 20 / 30).
        small_t = float(getattr(args, "small_threshold", 20))
        large_t = float(getattr(args, "large_threshold", 30))
        if diameter_um < small_t:
            size_class = "small"
        elif diameter_um < large_t:
            size_class = "intermediate"
        else:
            size_class = "large"

        # is_manual is always False for sidecar-detected cells.
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

    payload = {
        "width": width_px,
        "height": height_px,
        "cells": cells,
        "image_stats": _image_stats,
    }
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()
    log(f"[cellpose_detect] emitted {len(cells)} cells")


if __name__ == "__main__":
    main()
