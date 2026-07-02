"""
_cellpose_common.py — Shared helpers for the Cellpose 3.x and 4.x sidecars.

Pass-18 (K4): Both `cellpose_detect.py` (3.x) and `cellpose4_detect.py` (4.x /
CPSAM) used to carry verbatim copies of: stderr logging, error emission,
argument parsing, image-array loading, QC metrics, watershed + colony
post-processing dispatch, the per-cell measurement loop, and JSON emission.
This module factors those into reusable functions so the two detect scripts
keep only the version-specific bits:

  * Cellpose 3.x: `restore_type` model construction, channels-aware eval,
    half-resolution retry on size-predictor IndexError.
  * Cellpose 4.x: tqdm progress bridge for the lazy CPSAM weights download,
    `pretrained_model=` constructor, eval without channels.

The Swift host (`Detection/SidecarSchema.swift`) decodes the JSON contract
documented at the top of `cellpose_detect.py` — this module emits identical
keys, in identical types.

Public API (callers in cellpose_detect.py / cellpose4_detect.py):

    log(*args, **kwargs) -> None
    emit_error(error: str, hint: str = "", exit_code: int = 2) -> NoReturn

    build_arg_parser(description: str, default_model: str) -> argparse.ArgumentParser
        Adds every CLI flag both scripts share. Caller adds version-specific
        flags (e.g. --restore) before parse_args() in the script.

    parse_channels(channels_str: str) -> list[int]

    load_image_array(pil_image) -> np.ndarray
        PIL → numpy, uint8, HxW or HxWx3 depending on mode.

    open_image_for_detection(path: str, channels: list[int]) -> np.ndarray
        Opens file, picks grayscale vs RGB based on channel selection,
        applies _preprocessing.apply with args. Caller passes args separately
        because it owns the argparse.Namespace.

    compute_qc_metrics(img: np.ndarray) -> dict
        Returns {"focus_score", "illumination_residual"} (or {} on failure).

    resolve_device(args, torch_mod) -> (override_device | None, use_gpu_kw: bool)

    measure_cells(masks, img, args, flows=None) -> list[dict]
        Runs the full per-cell measurement loop. Returns cell dicts matching
        the SidecarPayload schema.

    apply_watershed_if_requested(masks, args) -> masks
    compute_colony_stats(masks, args, height_px, width_px) -> dict
    emit_payload(width_px, height_px, cells, image_stats) -> None

The logger prefix is "[cellpose_detect]" in both scripts. We keep that exact
spelling so the existing UI parser (ccDetectionStage) doesn't have to learn
two prefixes.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import uuid
from typing import Any


# ---------------------------------------------------------------------------
# stderr logging — stdout is reserved for the final JSON result.
# ---------------------------------------------------------------------------

def log(*args, **kwargs) -> None:
    """Stderr logger. Used by both detect scripts via this module."""
    print(*args, file=sys.stderr, **kwargs)


def emit_error(error: str, hint: str = "", exit_code: int = 2) -> None:
    """Write a structured error JSON to stdout and exit."""
    payload: dict = {"error": error}
    if hint:
        payload["hint"] = hint
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()
    sys.exit(exit_code)


# ---------------------------------------------------------------------------
# Argument parser — the shared shape.
# ---------------------------------------------------------------------------

def build_arg_parser(description: str, default_model: str) -> argparse.ArgumentParser:
    """Build the common CLI for both cellpose detect scripts.

    Caller adds version-specific flags (e.g. ``--restore`` for the 3.x
    script) on the returned parser before calling ``parse_args()``.
    """
    p = argparse.ArgumentParser(description=description)
    p.add_argument("--image", required=True,
                   help="Path to input image (jpg/png/tif/bmp).")
    p.add_argument("--model", default=default_model,
                   help="Cellpose model name or path to a checkpoint.")
    p.add_argument("--pxPerUm", type=float, required=True,
                   help="Pixels per micrometer; converts pixel diameter to µm.")
    p.add_argument("--conf", type=float, default=0.5,
                   help="Confidence threshold in [0,1]. Reported per-cell so "
                        "the host can filter.")
    p.add_argument("--channels", default="0,0",
                   help="Two comma-separated ints: cyto channel, nuclei channel. "
                        "0=grayscale/none, 1=red, 2=green, 3=blue. Default 0,0.")
    p.add_argument("--bg-subtract", dest="bg_subtract", action="store_true",
                   help="Apply rolling-ball background subtraction before detection.")
    p.add_argument("--rolling-ball-radius", dest="rolling_ball_radius", type=int,
                   default=50,
                   help="Radius for rolling-ball background subtraction (default 50).")
    p.add_argument("--watershed", action="store_true",
                   help="Run distance-transform watershed to split touching cells.")
    p.add_argument("--watershed-min-distance", dest="watershed_min_distance",
                   type=int, default=8,
                   help="Watershed seed peak min distance in µm (default 8).")
    p.add_argument("--small-threshold", dest="small_threshold", type=float,
                   default=20,
                   help="Diameter (µm) below which cells are 'small'. Default 20.")
    p.add_argument("--large-threshold", dest="large_threshold", type=float,
                   default=30,
                   help="Diameter (µm) at/above which cells are 'large'. Default 30.")
    p.add_argument("--no-gpu", dest="no_gpu", action="store_true",
                   help="Force CPU inference (no MPS/CUDA).")
    p.add_argument("--device", default=None,
                   help="Optional explicit torch device override (mps, cpu, cuda).")
    return p


# ---------------------------------------------------------------------------
# Channel + image loading.
# ---------------------------------------------------------------------------

def parse_channels(channels_str: str) -> list[int]:
    """Parse '--channels c0,c1' into [c0, c1], clamping to [0,3]."""
    try:
        parts = [int(x.strip()) for x in channels_str.split(",")]
        if len(parts) != 2:
            raise ValueError("expected exactly 2 values")
        return [max(0, min(3, parts[0])), max(0, min(3, parts[1]))]
    except Exception as exc:
        log(f"[cellpose_detect] invalid --channels '{channels_str}': {exc!r}; "
            "falling back to [0,0]")
        return [0, 0]


def load_image_array(pil_image):
    """PIL → numpy in a Cellpose-friendly form (uint8, HxW or HxWx3)."""
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
    # RGB / RGBA / P → coerce to RGB so cellpose can pick channels.
    rgb = pil_image.convert("RGB")
    return np.array(rgb, dtype=np.uint8)


def open_image_for_detection(path: str, channels: list[int], args):
    """Open the image file, pick gray vs RGB based on channels, apply preprocessing.

    Returns the numpy array (uint8). On failure, calls emit_error() and exits.
    """
    import numpy as np
    from PIL import Image

    log(f"[cellpose_detect] loading image: {path}")
    try:
        pil = Image.open(path)
        pil.load()
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] could not open image: {exc!r}")
        emit_error("image-open-failed", hint=str(exc), exit_code=3)

    is_grayscale_mode = (channels[0] == 0 and channels[1] == 0)
    if is_grayscale_mode:
        img = np.array(pil.convert("L"), dtype=np.uint8)
    else:
        img = load_image_array(pil)

    # Make sure _preprocessing is importable from this module's directory.
    _here = os.path.dirname(os.path.abspath(__file__))
    if _here not in sys.path:
        sys.path.insert(0, _here)
    import _preprocessing  # noqa: E402
    img = _preprocessing.apply(img, args)
    return img


# ---------------------------------------------------------------------------
# QC metrics — focus score (Laplacian variance) + illumination residual.
# ---------------------------------------------------------------------------

def compute_qc_metrics(img) -> dict:
    """Compute focus_score and illumination_residual on the raw image array.

    Never raises — returns whatever fields succeed.
    """
    import numpy as np

    stats: dict = {}
    try:
        gray = (img.astype(np.float64) if img.ndim == 2
                else img.mean(axis=2).astype(np.float64))

        # Focus: Laplacian variance, normalised to [0, 1] (cap at lap_var=10000).
        try:
            import cv2 as _cv2
            lap_var = float(_cv2.Laplacian(gray, _cv2.CV_64F).var())
        except ImportError:
            from scipy.ndimage import laplace as _sp_laplace
            lap_var = float(_sp_laplace(gray).var())
        focus_score = min(1.0, max(0.0, lap_var / 10000.0))
        stats["focus_score"] = focus_score
        log(f"[cellpose_detect] QC focus_score={focus_score:.4f} (lap_var={lap_var:.1f})")

        # Illumination: residual std / mean after fitting a quadratic surface on a 128×128 grid.
        H, W = gray.shape
        DS = 128
        ys = np.linspace(0, H - 1, DS, dtype=np.float64)
        xs = np.linspace(0, W - 1, DS, dtype=np.float64)
        xv, yv = np.meshgrid(xs, ys)
        xv_f = xv.ravel()
        yv_f = yv.ravel()
        yi = np.clip(np.round(yv_f).astype(int), 0, H - 1)
        xi = np.clip(np.round(xv_f).astype(int), 0, W - 1)
        z = gray[yi, xi]
        A = np.column_stack([
            xv_f ** 2, yv_f ** 2, xv_f * yv_f,
            xv_f, yv_f, np.ones(len(xv_f))
        ])
        coeffs, _, _, _ = np.linalg.lstsq(A, z, rcond=None)
        fitted = A @ coeffs
        residual_std = float((z - fitted).std())
        lum_mean = float(z.mean())
        illumination_residual = (residual_std / lum_mean) if lum_mean > 1e-6 else 0.0
        stats["illumination_residual"] = illumination_residual
        log(f"[cellpose_detect] QC illumination_residual={illumination_residual:.4f}")
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] QC metrics failed (non-fatal): {exc!r}")
    return stats


# ---------------------------------------------------------------------------
# Device resolution — surfaces use_gpu kwarg + optional explicit override.
# ---------------------------------------------------------------------------

def resolve_device(args, torch_mod):
    """Return (override_device | None, use_gpu_kw: bool).

    * ``use_gpu_kw`` reflects ``--no-gpu`` (the kw is True when GPU allowed).
    * ``override_device`` is a torch.device when either ``--device`` is set
      OR GPU is allowed AND MPS/CUDA is available — passed to model
      construction or applied manually after.
    """
    use_gpu_kw = not getattr(args, "no_gpu", False)
    if not use_gpu_kw:
        log("[cellpose_detect] --no-gpu set; forcing CPU inference")

    mps_avail = bool(getattr(torch_mod.backends, "mps", None)
                     and torch_mod.backends.mps.is_available())
    cuda_avail = bool(torch_mod.cuda.is_available())
    log(f"[cellpose_detect] torch={torch_mod.__version__} "
        f"mps_available={mps_avail} cuda_available={cuda_avail}")

    override = None
    arg_device = getattr(args, "device", None)
    if arg_device:
        try:
            override = torch_mod.device(arg_device)
            log(f"[cellpose_detect] --device override -> {override}")
        except Exception as exc:  # noqa: BLE001
            log(f"[cellpose_detect] invalid --device {arg_device!r}: {exc!r}; ignoring")
            override = None
    elif use_gpu_kw and mps_avail:
        override = torch_mod.device("mps")
    elif use_gpu_kw and cuda_avail:
        override = torch_mod.device("cuda")
    return override, use_gpu_kw


# ---------------------------------------------------------------------------
# Watershed + colony post-process — thin wrappers that never raise.
# ---------------------------------------------------------------------------

def apply_watershed_if_requested(masks, args):
    """Optional distance-transform watershed split. Never raises."""
    if not getattr(args, "watershed", False):
        return masks
    try:
        _here = os.path.dirname(os.path.abspath(__file__))
        if _here not in sys.path:
            sys.path.insert(0, _here)
        import _watershed  # noqa: E402
        min_d_px = max(1, int(round(args.watershed_min_distance * args.pxPerUm)))
        log(f"[cellpose_detect] watershed split with min_distance_px={min_d_px}")
        return _watershed.split(masks, min_distance_px=min_d_px)
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] watershed split failed: {exc!r}; using original masks")
        return masks


def compute_colony_stats(masks, args, height_px: int, width_px: int) -> dict:
    """Per-image colony + spatial statistics. Falls back to zero_stats on error."""
    try:
        _here = os.path.dirname(os.path.abspath(__file__))
        if _here not in sys.path:
            sys.path.insert(0, _here)
        import _colony  # noqa: E402
        out = _colony.compute(masks, args.pxPerUm, (height_px, width_px))
        log(f"[cellpose_detect] colony: n_colonies={out.get('n_colonies', 0)} "
            f"confluency={out.get('confluency_pct', 0):.1f}%")
        return out
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] colony stats failed (non-fatal): {exc!r}")
        try:
            import _colony  # noqa: E402
            return _colony.zero_stats()
        except Exception:  # noqa: BLE001
            return {}


# ---------------------------------------------------------------------------
# Per-cell measurement loop.
# ---------------------------------------------------------------------------

def measure_cells(masks, img, args, flows=None) -> list[dict]:
    """Build the list of per-cell dicts matching SidecarPayload's schema.

    * masks: HxW int label map (0 = background).
    * img:   HxW or HxWx3 uint8 array used for intensity measurements.
    * args:  argparse.Namespace — must have pxPerUm, small_threshold,
             large_threshold.
    * flows: optional eval flows tuple. flows[2] (when present and
             shape-matched) is read as the cellprob/confidence map.
    """
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


# ---------------------------------------------------------------------------
# Final payload writer.
# ---------------------------------------------------------------------------

def emit_payload(width_px: int, height_px: int, cells: list[dict],
                 image_stats: dict) -> None:
    """Write the final JSON payload to stdout and flush."""
    payload = {
        "width": width_px,
        "height": height_px,
        "cells": cells,
        "image_stats": image_stats,
    }
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()
    log(f"[cellpose_detect] emitted {len(cells)} cells")
