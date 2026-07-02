#!/usr/bin/env python3
"""
sam_detect.py — CellCounter SAM-family sidecar.

Routes detection through micro_sam.automatic_segmentation for any of the
supported model_types:

    vit_t                  -> MobileSAM
    vit_b_lm               -> uSAM LM-generalist (also substitutes for CellSAM,
                              SAMCell-Generalist, SAMCell-Cyto)
    vit_b_em_organelles    -> uSAM EM-generalist
    vit_b_histopathology   -> patho-sam

CellViT is NOT routed here — the Swift host falls back to mock for it.

Stdout contract (same as the other sidecars):
  {
    "width":  <int>,
    "height": <int>,
    "cells": [{"id","cx","cy","diameter_um","diameter_px","confidence"}, ...]
  }

On ImportError or any failure, emits a structured error JSON on stdout and exits non-zero.
All progress/log output goes to stderr.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import uuid


def log(*args, **kwargs) -> None:
    print(*args, file=sys.stderr, **kwargs)


def emit_error(error: str, hint: str = "", exit_code: int = 2) -> None:
    payload = {"error": error}
    if hint:
        payload["hint"] = hint
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()
    sys.exit(exit_code)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="SAM-family detection sidecar for CellCounter")
    p.add_argument("--image", required=True, help="Path to input image.")
    p.add_argument("--model", required=True,
                   help="micro_sam model_type: vit_t | vit_b_lm | vit_b_em_organelles | vit_b_histopathology")
    p.add_argument("--pxPerUm", type=float, required=True,
                   help="Pixels per micrometer.")
    p.add_argument("--conf", type=float, default=0.5,
                   help="Confidence threshold (kept as metadata, host filters).")
    p.add_argument("--prompts", default="auto",
                   help="Prompt mode (only 'auto' is supported — instance segmentation).")
    p.add_argument("--bg-subtract", dest="bg_subtract", action="store_true",
                   help="Apply rolling-ball background subtraction before detection.")
    p.add_argument("--rolling-ball-radius", dest="rolling_ball_radius", type=int, default=50,
                   help="Radius for rolling-ball background subtraction (default 50).")
    p.add_argument("--watershed", action="store_true",
                   help="Run a distance-transform watershed on the SAM instance label "
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


def load_image_array(pil_image):
    """Return a 2-D grayscale uint8 ndarray (micro_sam auto-seg works on grayscale)."""
    import numpy as np
    mode = pil_image.mode
    if mode == "L":
        return np.array(pil_image, dtype=np.uint8)
    if mode in ("I", "F"):
        arr = np.array(pil_image, dtype=np.float32)
        lo, hi = float(arr.min()), float(arr.max())
        if hi > lo:
            arr = (arr - lo) / (hi - lo) * 255.0
        return arr.astype(np.uint8)
    rgb = pil_image.convert("L")
    return np.array(rgb, dtype=np.uint8)


def run_automatic_segmentation(image, model_type: str):
    """
    Use micro_sam's automatic instance segmentation. Returns a 2-D integer
    label map plus an optional list of per-instance confidence/iou scores.
    """
    from micro_sam.util import get_sam_model
    from micro_sam import automatic_segmentation as ms_seg

    log(f"[sam_detect] loading predictor for model_type={model_type} ...")
    predictor = get_sam_model(model_type=model_type)

    # micro_sam exposes a high-level helper that builds the instance segmenter
    # (AMG or AIS depending on the checkpoint) and runs it in one call.
    # The exact signature varies between releases — try the modern one first.
    try:
        log("[sam_detect] running automatic_instance_segmentation ...")
        instances = ms_seg.automatic_instance_segmentation(
            predictor=predictor,
            image=image,
            ndim=2,
        )
    except TypeError:
        log("[sam_detect] modern signature failed; trying legacy automatic_instance_segmentation ...")
        instances = ms_seg.automatic_instance_segmentation(predictor, image)
    except AttributeError:
        # Very old releases call it differently.
        log("[sam_detect] automatic_instance_segmentation missing; falling back to get_amg + AMG.generate")
        segmenter = ms_seg.get_amg(predictor, is_tiled=False)
        segmenter.initialize(image)
        masks = segmenter.generate()
        # Convert list-of-dicts into a label map.
        import numpy as np
        label_map = np.zeros(image.shape[:2], dtype=np.int32)
        scores = []
        for i, m in enumerate(masks, start=1):
            seg = m["segmentation"] if isinstance(m, dict) else m
            label_map[seg.astype(bool)] = i
            if isinstance(m, dict) and "predicted_iou" in m:
                scores.append(float(m["predicted_iou"]))
        return label_map, scores

    # instances is typically a 2-D int label map (numpy array).
    return instances, []


def main() -> None:
    args = parse_args()

    try:
        import numpy as np
        from PIL import Image
    except Exception as exc:  # noqa: BLE001
        log(f"[sam_detect] basic imports failed: {exc!r}")
        emit_error("python-deps-missing",
                   hint="numpy / Pillow not importable in venv",
                   exit_code=2)
        return

    try:
        import micro_sam  # noqa: F401
    except Exception as exc:  # noqa: BLE001
        log(f"[sam_detect] micro_sam import failed: {exc!r}")
        emit_error("micro_sam-not-installed",
                   hint="pip install micro_sam (the SAMDownloader runs this for you)",
                   exit_code=2)
        return

    log(f"[sam_detect] loading image: {args.image}")
    try:
        pil = Image.open(args.image)
        pil.load()
    except Exception as exc:  # noqa: BLE001
        log(f"[sam_detect] could not open image: {exc!r}")
        emit_error("image-open-failed", hint=str(exc), exit_code=3)
        return

    img = load_image_array(pil)

    # --- C3: QC metrics on RAW image (before any preprocessing) ---
    _image_stats: dict = {}
    try:
        _qc_gray = img.astype(np.float64) if img.ndim == 2 else img.mean(axis=2).astype(np.float64)

        # Focus score: Laplacian variance / 10000, clamped [0, 1].
        # Typical well-focused images → lap_var ≥ 1000; blurry → < 200.
        # Dividing by 10000 maps "sharp enough" images to ≥ 0.5 on a 0–1 scale.
        try:
            import cv2 as _cv2
            _lap_var = float(_cv2.Laplacian(_qc_gray, _cv2.CV_64F).var())
        except ImportError:
            from scipy.ndimage import laplace as _sp_laplace
            _lap_var = float(_sp_laplace(_qc_gray).var())
        _focus_score = min(1.0, max(0.0, _lap_var / 10000.0))
        _image_stats["focus_score"] = _focus_score
        log(f"[sam_detect] QC focus_score={_focus_score:.4f} (lap_var={_lap_var:.1f})")

        _H, _W = _qc_gray.shape
        _DS = 128
        _ys_g = np.linspace(0, _H - 1, _DS)
        _xs_g = np.linspace(0, _W - 1, _DS)
        _xv, _yv = np.meshgrid(_xs_g, _ys_g)
        _xv_f = _xv.ravel(); _yv_f = _yv.ravel()
        _yi = np.clip(np.round(_yv_f).astype(int), 0, _H - 1)
        _xi = np.clip(np.round(_xv_f).astype(int), 0, _W - 1)
        _z = _qc_gray[_yi, _xi]
        _A = np.column_stack([_xv_f ** 2, _yv_f ** 2, _xv_f * _yv_f,
                               _xv_f, _yv_f, np.ones(len(_xv_f))])
        _coeffs, _, _, _ = np.linalg.lstsq(_A, _z, rcond=None)
        _fitted = _A @ _coeffs
        _lum_mean = float(_z.mean())
        _illumination_residual = float((_z - _fitted).std()) / _lum_mean if _lum_mean > 1e-6 else 0.0
        _image_stats["illumination_residual"] = _illumination_residual
        log(f"[sam_detect] QC illumination_residual={_illumination_residual:.4f}")
    except Exception as _qc_exc:  # noqa: BLE001
        log(f"[sam_detect] QC metrics failed (non-fatal): {_qc_exc!r}")
    # --- end C3 QC metrics ---

    # --- Background subtraction (A2 preprocessing block) ---
    import os as _os
    import sys as _sys
    _sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
    import _preprocessing
    img = _preprocessing.apply(img, args)
    # --------------------------------------------------------

    height_px, width_px = int(img.shape[0]), int(img.shape[1])
    log(f"[sam_detect] image is {width_px}x{height_px}; model={args.model}; prompts={args.prompts}")

    try:
        label_map, scores = run_automatic_segmentation(img, args.model)
    except Exception as exc:  # noqa: BLE001
        log(f"[sam_detect] segmentation failed: {exc!r}")
        emit_error("segmentation-failed", hint=str(exc), exit_code=5)
        return

    # A3 (middle-of-script): optional distance-transform watershed split.
    # Runs BETWEEN detect (above) and per-cell measure (below). After a watershed
    # re-label the original `scores` array is misaligned with the new labels —
    # invalidate it so the measure loop falls back to the default confidence.
    if getattr(args, "watershed", False):
        try:
            import _watershed
            min_d_px = max(1, int(round(args.watershed_min_distance * args.pxPerUm)))
            log(f"[sam_detect] watershed split with min_distance_px={min_d_px}")
            label_map = _watershed.split(label_map, min_distance_px=min_d_px)
            scores = []
        except Exception as exc:  # noqa: BLE001
            log(f"[sam_detect] watershed split failed: {exc!r}; using original label_map")

    px_per_um = float(args.pxPerUm) if args.pxPerUm > 0 else 1.0

    # --- C2 (pass 6): per-image colony + spatial statistics ---
    # Runs AFTER detect+watershed, BEFORE the per-cell measure loop. Merges into
    # the shared `_image_stats` dict alongside C3's QC metrics.
    try:
        import _colony
        _image_stats.update(
            _colony.compute(label_map, args.pxPerUm, (int(height_px), int(width_px)))
        )
        log(f"[sam_detect] colony: n_colonies={_image_stats.get('n_colonies', 0)} "
            f"confluency={_image_stats.get('confluency_pct', 0):.1f}%")
    except Exception as _col_exc:  # noqa: BLE001
        log(f"[sam_detect] colony stats failed (non-fatal): {_col_exc!r}")
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

    payload = {"width": width_px, "height": height_px, "cells": cells,
               "image_stats": _image_stats}
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()
    log(f"[sam_detect] emitted {len(cells)} cells")


if __name__ == "__main__":
    main()
