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

``--serve`` keeps one interpreter, with micro_sam imported and the SAM
predictor loaded, for many requests. Requests use the `serve_ndjson` protocol
in `_cellpose_common`. Each request runs the same `main` a one-shot process
runs, so the payload is the same; only the work a new process would repeat is
skipped. The host starts one worker per model type for automatic detection
and a separate one for point/box prompts.

For prompts (``--prompts interactive``) a worker also keeps, for the last
``_PROMPT_CACHE_LIMIT`` images it was asked about, the decoded image and the
image embedding. A second click on an image then runs only SAM's prompt
decoder. Embeddings are still written to and read from ``--embedding-cache``
exactly as before, so a new worker or a one-shot run starts from the cache on
disk. A prompt refines one cell, so it skips the per-image QC and colony
statistics; its payload carries an empty ``image_stats``.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import uuid
from collections import OrderedDict


# Loaded SAM predictors keyed by (model_type, device); device None means
# micro_sam's default. A serve worker keeps one entry; a one-shot run fills it
# once and exits.
_MODEL_CACHE: dict = {}

# Prompt mode only, most recent last. Decoded images keyed by file stamp, and
# image embeddings keyed by (predictor key, file stamp, preprocessing,
# embedding cache path). Each holds at most `_PROMPT_CACHE_LIMIT` images.
_PROMPT_CACHE_LIMIT = 2
_PROMPT_IMAGES: OrderedDict = OrderedDict()
_PROMPT_EMBEDDINGS: OrderedDict = OrderedDict()

# The arguments `_preprocessing.apply` reads; they change the image a prompt
# embedding is computed from.
_PREPROCESSING_FIELDS = ("bg_subtract", "rolling_ball_radius", "clahe",
                         "anisotropic_diffusion", "gpu_preprocess")


def log(*args, **kwargs) -> None:
    print(*args, file=sys.stderr, **kwargs)


def emit_error(error: str, hint: str = "", exit_code: int = 2) -> None:
    payload = {"error": error}
    if hint:
        payload["hint"] = hint
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()
    sys.exit(exit_code)


def parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="SAM-family detection sidecar for CellCounter")
    p.add_argument("--image", required=True, help="Path to input image.")
    p.add_argument("--model", required=True,
                   help="micro_sam model_type: vit_t | vit_b_lm | vit_b_em_organelles | vit_b_histopathology")
    p.add_argument("--pxPerUm", type=float, required=True,
                   help="Pixels per micrometer.")
    p.add_argument("--conf", type=float, default=0.5,
                   help="Confidence threshold (kept as metadata, host filters).")
    p.add_argument("--prompts", default="auto", choices=("auto", "interactive"),
                   help="Automatic instances or one point/box-prompted mask.")
    p.add_argument("--prompt-point", nargs=2, type=float, metavar=("X", "Y"))
    p.add_argument("--prompt-box", nargs=4, type=float,
                   metavar=("X0", "Y0", "X1", "Y1"))
    p.add_argument("--embedding-cache", default=None,
                   help="Optional reusable micro_sam image-embedding zarr path.")
    p.add_argument("--bg-subtract", dest="bg_subtract", action="store_true",
                   help="Apply rolling-ball background subtraction before detection.")
    p.add_argument("--rolling-ball-radius", dest="rolling_ball_radius", type=int, default=50,
                   help="Radius for rolling-ball background subtraction (default 50).")
    p.add_argument("--clahe", action="store_true")
    p.add_argument("--anisotropic-diffusion", dest="anisotropic_diffusion", action="store_true")
    p.add_argument("--gpu-preprocess", dest="gpu_preprocess", action="store_true")
    p.add_argument("--no-gpu", dest="no_gpu", action="store_true",
                   help="Force the SAM predictor onto CPU.")
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
    return p.parse_args(argv)


def _ensure_sidecar_path() -> None:
    """Make the sibling helpers (_preprocessing, _watershed, …) importable."""
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)


def load_predictor(model_type: str, device=None):
    """The SAM predictor for `model_type` on `device`, loaded at most once.

    `device` None leaves the choice to micro_sam. Loading a different model
    first releases the current one and the prompt embeddings made with it,
    so a worker never holds two.
    """
    key = (model_type, device)
    predictor = _MODEL_CACHE.get(key)
    if predictor is not None:
        log("[sam_detect] reusing initialized predictor")
        return predictor
    _MODEL_CACHE.clear()
    _PROMPT_EMBEDDINGS.clear()
    from micro_sam import util

    log(f"[sam_detect] loading predictor for model_type={model_type} ...")
    kwargs = {"model_type": model_type}
    if device is not None:
        kwargs["device"] = device
    predictor = util.get_sam_model(**kwargs)
    _MODEL_CACHE[key] = predictor
    return predictor


def _file_stamp(path: str):
    """Identity of the file at `path` as it is now, or None if it can't be read."""
    try:
        info = os.stat(path)
    except OSError:
        return None
    return (os.path.realpath(path), info.st_size, info.st_mtime_ns, info.st_ino)


def _remember(cache: OrderedDict, key, value) -> None:
    """Store `value` as the most recent entry, dropping the oldest past the limit."""
    cache[key] = value
    cache.move_to_end(key)
    while len(cache) > _PROMPT_CACHE_LIMIT:
        cache.popitem(last=False)


def _preprocessing_signature(args) -> tuple:
    return tuple((name, getattr(args, name, None)) for name in _PREPROCESSING_FIELDS)


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
    from micro_sam import automatic_segmentation as ms_seg

    # Automatic mode has always used micro_sam's default device; `--no-gpu`
    # only reaches prompt mode.
    predictor = load_predictor(model_type)

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


def run_prompt_segmentation(image, model_type: str, args, image_stamp=None):
    """Return a one-label map from a point and/or box prompt.

    `precompute_image_embeddings(..., save_path=...)` loads a valid existing
    cache instead of running the image encoder again. A serve worker also
    keeps the embedding in memory (`_PROMPT_EMBEDDINGS`), so a later click on
    the same image, with the same preprocessing and cache path, skips that
    call and runs only the prompt decoder. `image_stamp` identifies the image
    file; None turns the in-memory reuse off.
    """
    import numpy as np
    from micro_sam import util

    device = "cpu" if getattr(args, "no_gpu", False) else None
    predictor = load_predictor(model_type, device)

    save_path = getattr(args, "embedding_cache", None)
    key = None
    if image_stamp is not None:
        key = ((model_type, device), image_stamp, _preprocessing_signature(args), save_path)
    embeddings = _PROMPT_EMBEDDINGS.get(key) if key is not None else None
    if embeddings is not None and save_path and not os.path.exists(save_path):
        # The cache on disk was removed: compute and write it again, as a
        # new process would.
        embeddings = None
    if embeddings is not None:
        _PROMPT_EMBEDDINGS.move_to_end(key)
        log("[sam_detect] reusing interactive image embedding from memory")
    else:
        if save_path:
            os.makedirs(os.path.dirname(save_path), exist_ok=True)
        log(f"[sam_detect] {'loading/reusing' if save_path and os.path.exists(save_path) else 'computing'} "
            "interactive image embedding")
        try:
            embeddings = util.precompute_image_embeddings(
                predictor, image, save_path=save_path, ndim=2)
        except TypeError:
            embeddings = util.precompute_image_embeddings(
                predictor, image, save_path=save_path)
        if key is not None:
            _remember(_PROMPT_EMBEDDINGS, key, embeddings)
    util.set_precomputed(predictor, embeddings)

    kwargs = {"multimask_output": True}
    if args.prompt_point is not None:
        kwargs["point_coords"] = np.asarray([args.prompt_point], dtype=np.float32)
        kwargs["point_labels"] = np.asarray([1], dtype=np.int32)
    if args.prompt_box is not None:
        x0, y0, x1, y1 = args.prompt_box
        kwargs["box"] = np.asarray([min(x0, x1), min(y0, y1),
                                    max(x0, x1), max(y0, y1)], dtype=np.float32)
    if "point_coords" not in kwargs and "box" not in kwargs:
        raise ValueError("interactive prompt mode needs --prompt-point or --prompt-box")

    masks, scores, _ = predictor.predict(**kwargs)
    best = int(np.argmax(scores))
    label_map = masks[best].astype(np.int32)
    return label_map, [float(scores[best])]


def measure_instances(label_map, img, args, width_px, height_px, scores) -> list[dict]:
    """Per-cell measurements for a SAM label map.

    ``scores`` are per-instance confidences in label order (empty after a
    watershed re-label). Each cell is measured on a crop around its bounding
    box (``_cellpose_common.label_crops``), which gives the same numbers as a
    full-image mask.
    """
    import numpy as np

    _here = os.path.dirname(os.path.abspath(__file__))
    if _here not in sys.path:
        sys.path.insert(0, _here)
    from _cellpose_common import label_crops

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

    # `mask` is the cell's crop, (row0, col0) its top-left corner; ys/xs are
    # full-image coordinates.
    for idx, (label, mask, row0, col0) in enumerate(label_crops(label_map, label_ids)):
        crop_ys, crop_xs = np.nonzero(mask)
        area_px = int(crop_ys.size)
        if area_px < 4:
            continue
        ys = crop_ys + row0
        xs = crop_xs + col0
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
                # scikit-image renamed `neighbourhood` → `neighborhood` in 0.26
                # (older releases accept only the British spelling). The old
                # call used only the British spelling, so on current releases
                # it raised, and perimeter and circularity were always missing.
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

        mean_intensity = float(img_gray[ys, xs].mean()) if area_px else None
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
                    # Shift from crop to full-image pixels.
                    best_contour = max(contours, key=len) + np.array(
                        [row0, col0], dtype=np.float64)
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


def qc_metrics(img) -> dict:
    """C3: QC metrics on the RAW image (before any preprocessing). Non-fatal."""
    import numpy as np

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
    return _image_stats


def colony_stats(label_map, px_per_um, height_px: int, width_px: int) -> dict:
    """C2 (pass 6): per-image colony + spatial statistics. Non-fatal."""
    _image_stats: dict = {}
    try:
        import _colony
        _image_stats.update(
            _colony.compute(label_map, px_per_um, (int(height_px), int(width_px)))
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
    return _image_stats


def main(argv=None) -> None:
    args = parse_args(argv)

    try:
        import numpy as np  # noqa: F401
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

    interactive = args.prompts == "interactive"
    # A serve worker keeps recently prompted images decoded (see the module
    # docstring). The stamp changes when the file does.
    image_stamp = _file_stamp(args.image) if interactive else None
    img = _PROMPT_IMAGES.get(image_stamp) if image_stamp is not None else None

    log(f"[sam_detect] loading image: {args.image}")
    if img is not None:
        _PROMPT_IMAGES.move_to_end(image_stamp)
        log("[sam_detect] reusing decoded image")
    else:
        try:
            pil = Image.open(args.image)
            pil.load()
        except Exception as exc:  # noqa: BLE001
            log(f"[sam_detect] could not open image: {exc!r}")
            emit_error("image-open-failed", hint=str(exc), exit_code=3)
            return

        img = load_image_array(pil)
        if image_stamp is not None:
            # Shared by later requests: nothing may write into it.
            # Preprocessing below works on a copy.
            img.setflags(write=False)
            _remember(_PROMPT_IMAGES, image_stamp, img)

    # --- C3: QC metrics on RAW image (before any preprocessing) ---
    # A prompt refines one cell; the host does not use per-image statistics
    # for it.
    _image_stats: dict = {} if interactive else qc_metrics(img)

    # --- Background subtraction (A2 preprocessing block) ---
    _ensure_sidecar_path()
    import _preprocessing
    img = _preprocessing.apply(img, args)
    # --------------------------------------------------------

    height_px, width_px = int(img.shape[0]), int(img.shape[1])
    log(f"[sam_detect] image is {width_px}x{height_px}; model={args.model}; prompts={args.prompts}")

    try:
        if interactive:
            label_map, scores = run_prompt_segmentation(img, args.model, args,
                                                        image_stamp=image_stamp)
        else:
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

    # --- C2 (pass 6): per-image colony + spatial statistics ---
    # Runs AFTER detect+watershed, BEFORE the per-cell measure loop. Merges into
    # the shared `_image_stats` dict alongside C3's QC metrics.
    if not interactive:
        _image_stats.update(colony_stats(label_map, args.pxPerUm, height_px, width_px))

    cells = measure_instances(label_map, img, args, width_px, height_px, scores)

    payload = {"width": width_px, "height": height_px, "cells": cells,
               "image_stats": _image_stats}
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()
    log(f"[sam_detect] emitted {len(cells)} cells")


def serve() -> None:
    _ensure_sidecar_path()
    import _cellpose_common as cc

    log("[sam_detect] worker ready; the model loads with the first request")
    cc.serve_ndjson(main, after_response=cc.release_request_memory)


if __name__ == "__main__":
    if "--serve" in sys.argv[1:]:
        serve()
    else:
        main()
