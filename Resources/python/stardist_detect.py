#!/usr/bin/env python3
"""
stardist_detect.py — CellCounter sidecar.

Runs a StarDist 2D pretrained model on an input image and emits a single JSON
object on stdout matching the cellpose_detect.py contract.

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

If stardist (or one of its deps) is not importable, prints:
  {"error": "stardist-not-installed",
   "hint":  "Run scripts/install_python.sh and then activate this model again"}
to stdout and exits with code 2.

All progress / log output is written to stderr so stdout stays parseable by
the Swift host (StarDistDetectionService).
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import uuid


# Known pretrained StarDist 2D model names.
_VALID_MODELS = {
    "2D_versatile_fluo",
    "2D_versatile_he",
    "2D_paper_dsb2018",
}


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
    p = argparse.ArgumentParser(description="StarDist 2D detection sidecar for CellCounter")
    p.add_argument("--image", required=True, help="Path to input image (jpg/png/tif/bmp).")
    p.add_argument("--model", default="2D_versatile_fluo",
                   help="StarDist 2D pretrained model name "
                        "(2D_versatile_fluo, 2D_versatile_he, 2D_paper_dsb2018).")
    p.add_argument("--pxPerUm", type=float, required=True,
                   help="Pixels per micrometer; used to convert pixel diameter to µm.")
    p.add_argument("--conf", type=float, default=0.5,
                   help="Confidence threshold in [0,1]. Reported as-is so the host can filter.")
    p.add_argument("--prob-thresh", dest="prob_thresh", type=float, default=0.5,
                   help="StarDist prob_thresh (default 0.5).")
    p.add_argument("--nms-thresh", dest="nms_thresh", type=float, default=0.4,
                   help="StarDist nms_thresh (default 0.4).")
    p.add_argument("--bg-subtract", dest="bg_subtract", action="store_true",
                   help="Apply rolling-ball background subtraction before detection.")
    p.add_argument("--rolling-ball-radius", dest="rolling_ball_radius", type=int, default=50,
                   help="Radius for rolling-ball background subtraction (default 50).")
    p.add_argument("--watershed", action="store_true",
                   help="Run a distance-transform watershed on the StarDist label "
                        "map to split touching cells (A3 middle-of-script post-process).")
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


def load_image_array(image_path: str):
    """Open an image with PIL and return a numpy array suitable for StarDist.

    - Grayscale (L, I, F)  → 2-D (H, W) float32 in [0, 255].
    - Multi-channel modes  → 3-D (H, W, 3) float32 (converted to RGB).
    """
    import numpy as np
    from PIL import Image

    pil = Image.open(image_path)
    pil.load()

    mode = pil.mode
    if mode == "L":
        return np.array(pil, dtype=np.float32), pil.size  # size = (W, H)
    if mode in ("I", "F"):
        arr = np.array(pil, dtype=np.float32)
        arr_min, arr_max = float(arr.min()), float(arr.max())
        if arr_max > arr_min:
            arr = (arr - arr_min) / (arr_max - arr_min) * 255.0
        return arr.astype(np.float32), pil.size
    rgb = pil.convert("RGB")
    return np.array(rgb, dtype=np.float32), pil.size


def main() -> None:
    args = parse_args()

    model_name = args.model
    if model_name not in _VALID_MODELS:
        log(f"[stardist_detect] unknown model '{model_name}', defaulting to 2D_versatile_fluo")
        model_name = "2D_versatile_fluo"

    # Lazy imports — so the import-error branch can emit a structured error
    # without crashing on bare ImportError.
    try:
        import numpy as np  # noqa: F401
        from csbdeep.utils import normalize
        from stardist.models import StarDist2D
    except Exception as exc:  # noqa: BLE001 — broad on purpose for first-run UX
        log(f"[stardist_detect] import failed: {exc!r}")
        emit_error(
            "stardist-not-installed",
            hint="Run scripts/install_python.sh and then activate this model again",
            exit_code=2,
        )
        return

    log(f"[stardist_detect] loading image: {args.image}")
    try:
        img, (width_px, height_px) = load_image_array(args.image)
    except Exception as exc:  # noqa: BLE001
        log(f"[stardist_detect] could not open image: {exc!r}")
        emit_error("image-open-failed", hint=str(exc), exit_code=3)
        return

    # --- C3: QC metrics on RAW image (before any preprocessing) ---
    _image_stats: dict = {}
    try:
        import numpy as _qc_np
        _qc_gray = img.astype(_qc_np.float64) if img.ndim == 2 else img.mean(axis=2).astype(_qc_np.float64)

        # Focus score: Laplacian variance / 10000, clamped [0, 1].
        # Typical well-focused images → lap_var ≥ 1000; blurry → < 200.
        # Dividing by 10000 gives a convenient [0, 1] scale; ≥ 0.5 = acceptable focus.
        try:
            import cv2 as _cv2
            _lap_var = float(_cv2.Laplacian(_qc_gray, _cv2.CV_64F).var())
        except ImportError:
            from scipy.ndimage import laplace as _sp_laplace
            _lap_var = float(_sp_laplace(_qc_gray).var())
        _focus_score = min(1.0, max(0.0, _lap_var / 10000.0))
        _image_stats["focus_score"] = _focus_score
        log(f"[stardist_detect] QC focus_score={_focus_score:.4f} (lap_var={_lap_var:.1f})")

        _H, _W = _qc_gray.shape
        _DS = 128
        _ys_g = _qc_np.linspace(0, _H - 1, _DS)
        _xs_g = _qc_np.linspace(0, _W - 1, _DS)
        _xv, _yv = _qc_np.meshgrid(_xs_g, _ys_g)
        _xv_f = _xv.ravel(); _yv_f = _yv.ravel()
        _yi = _qc_np.clip(_qc_np.round(_yv_f).astype(int), 0, _H - 1)
        _xi = _qc_np.clip(_qc_np.round(_xv_f).astype(int), 0, _W - 1)
        _z = _qc_gray[_yi, _xi]
        _A = _qc_np.column_stack([_xv_f ** 2, _yv_f ** 2, _xv_f * _yv_f,
                                   _xv_f, _yv_f, _qc_np.ones(len(_xv_f))])
        _coeffs, _, _, _ = _qc_np.linalg.lstsq(_A, _z, rcond=None)
        _fitted = _A @ _coeffs
        _lum_mean = float(_z.mean())
        _illumination_residual = float((_z - _fitted).std()) / _lum_mean if _lum_mean > 1e-6 else 0.0
        _image_stats["illumination_residual"] = _illumination_residual
        log(f"[stardist_detect] QC illumination_residual={_illumination_residual:.4f}")
    except Exception as _qc_exc:  # noqa: BLE001
        log(f"[stardist_detect] QC metrics failed (non-fatal): {_qc_exc!r}")
    # --- end C3 QC metrics ---

    # --- Background subtraction (A2 preprocessing block) ---
    import os as _os
    import sys as _sys
    _sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
    import _preprocessing
    img = _preprocessing.apply(img, args)
    # --------------------------------------------------------

    log(f"[stardist_detect] image is {width_px}x{height_px} (ndim={img.ndim}); model={model_name}")

    # H&E expects RGB; the fluo/dsb models expect single-channel intensity.
    if model_name == "2D_versatile_he":
        if img.ndim == 2:
            # Promote grayscale to 3-channel by stacking.
            import numpy as np
            img = np.stack([img, img, img], axis=-1)
    else:
        if img.ndim == 3:
            # Convert to luminance for fluorescence-style models.
            import numpy as np
            img = img.mean(axis=2)

    try:
        img_n = normalize(img, 1, 99.8)
    except Exception as exc:  # noqa: BLE001
        log(f"[stardist_detect] normalize failed: {exc!r}")
        emit_error("image-normalize-failed", hint=str(exc), exit_code=3)
        return

    try:
        model = StarDist2D.from_pretrained(model_name)
    except Exception as exc:  # noqa: BLE001
        log(f"[stardist_detect] model load failed: {exc!r}")
        emit_error("model-load-failed", hint=str(exc), exit_code=4)
        return

    log("[stardist_detect] running predict_instances ...")
    try:
        labels, details = model.predict_instances(
            img_n,
            prob_thresh=float(args.prob_thresh),
            nms_thresh=float(args.nms_thresh),
        )
    except Exception as exc:  # noqa: BLE001
        log(f"[stardist_detect] predict_instances failed: {exc!r}")
        emit_error("eval-failed", hint=str(exc), exit_code=5)
        return

    import numpy as np

    # A3 (middle-of-script): optional distance-transform watershed split.
    # Runs BETWEEN detect (above) and per-cell measure (below). points/probs
    # are per-original-instance and will be misaligned after a watershed re-label,
    # so we invalidate them when watershed runs and fall back to centroid + mean
    # probability defaults in the measure loop.
    watershed_applied = False
    if getattr(args, "watershed", False):
        try:
            import _watershed
            min_d_px = max(1, int(round(args.watershed_min_distance * args.pxPerUm)))
            log(f"[stardist_detect] watershed split with min_distance_px={min_d_px}")
            labels = _watershed.split(labels, min_distance_px=min_d_px)
            watershed_applied = True
        except Exception as exc:  # noqa: BLE001
            log(f"[stardist_detect] watershed split failed: {exc!r}; using original labels")

    points = None if watershed_applied else (details.get("points") if isinstance(details, dict) else None)
    probs = None if watershed_applied else (details.get("prob") if isinstance(details, dict) else None)

    px_per_um = float(args.pxPerUm) if args.pxPerUm > 0 else 1.0

    # --- C2 (pass 6): per-image colony + spatial statistics ---
    # Runs AFTER detect+watershed, BEFORE the per-cell measure loop. Merges into
    # the shared `_image_stats` dict alongside C3's QC metrics.
    try:
        import _colony
        _image_stats.update(
            _colony.compute(labels, args.pxPerUm, (int(height_px), int(width_px)))
        )
        log(f"[stardist_detect] colony: n_colonies={_image_stats.get('n_colonies', 0)} "
            f"confluency={_image_stats.get('confluency_pct', 0):.1f}%")
    except Exception as _col_exc:  # noqa: BLE001
        log(f"[stardist_detect] colony stats failed (non-fatal): {_col_exc!r}")
        try:
            import _colony
            _image_stats.update(_colony.zero_stats())
        except Exception:
            pass
    # --- end C2 colony stats ---

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

    payload = {
        "width": int(width_px),
        "height": int(height_px),
        "cells": cells,
        "image_stats": _image_stats,
    }
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()
    log(f"[stardist_detect] emitted {len(cells)} cells")


if __name__ == "__main__":
    main()
