#!/usr/bin/env python3
"""
puncta_detect.py — CellCounter sidecar: sub-cellular puncta/foci detection.

Detects diffraction-limited spots (γH2AX DNA-damage foci, FISH probes,
stress granules, …) in one fluorescence channel of a (possibly
multi-channel, possibly z-stacked) image, assigns each spot to the cell
whose mask/polygon contains it, and reports per-cell spot counts alongside
per-spot size/intensity so results can be filtered downstream.

All the actual math lives in `_assays_puncta.py` (pure functions, no I/O) —
this script is a thin CLI: parse args, load the image via `_imageio` (the
shared multi-channel loader — `load_planes(path, *, z_project="max",
channel=None) -> (HxWxC float32, meta)`), optionally rasterize stored cell
polygons into a label map, call `_assays_puncta.compute()`, print one JSON
object to stdout.

Stdout contract (success):
    {
      "spots": [...], "cells": [...], "summary": {...},
      "params_used": {...}, "message": str | None,
      "width": <int>, "height": <int>
    }
On a known failure, prints `{"error": ..., "hint": ...}` and exits non-zero
— the same convention every CellCounter sidecar follows
(`_cellpose_common.emit_error`). `log`/`emit_error` are re-implemented
locally (a few lines) instead of imported from `_cellpose_common.py` so this
script has zero import-time coupling to a file owned by a different,
concurrently-in-flight pass — see the top-level task notes for this file's
ownership boundary.

Progress/log lines go to stderr (prefixed "[puncta_detect]"); stdout is
reserved for the final JSON so the Swift host can parse it directly.

--cells-json accepts a JSON array; each entry is auto-detected as one of:
    {"label": "<cell-id>", "polygon": [[x, y], ...]}   (preferred — exact mask assignment)
    {"label": "<cell-id>", "cx": <x_px>, "cy": <y_px>} (fallback — nearest-centroid assignment)
`label` may be any JSON scalar (CellCounter's own cell ids are UUID
strings); it is echoed back verbatim on each spot/cell in the output. Mixing
shapes is fine: any entry with a polygon is rasterized into the label map;
entries without one are dropped (a cell needs SOME shape info to receive an
exact assignment) — logged to stderr, never a hard failure.
"""

from __future__ import annotations

import argparse
import json
import os
import sys


def log(*args, **kwargs) -> None:
    """Stderr logger — stdout is reserved for the final JSON result."""
    print(*args, file=sys.stderr, **kwargs)


def emit_error(error: str, hint: str = "", exit_code: int = 2) -> None:
    """Write a structured error JSON to stdout and exit."""
    payload: dict = {"error": error}
    if hint:
        payload["hint"] = hint
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()
    sys.exit(exit_code)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="CellCounter puncta/foci detection sidecar")
    parser.add_argument("--image", required=True, help="Path to the source image.")
    parser.add_argument("--channel", type=int, default=0,
                        help="Index into the loaded planes to detect spots in (default 0).")
    # No "min": `_imageio.Z_PROJECT_MODES` has never implemented it, and
    # offering it here meant `--z-project min` was accepted, silently downgraded
    # to max (a near-opposite image on a real Z-stack) and exited 0.
    parser.add_argument("--z-project", dest="z_project", default="max",
                        choices=["max", "mean", "sum", "none"],
                        help="Z-projection method forwarded to _imageio.load_planes "
                             "(default max).")
    parser.add_argument("--pxPerUm", type=float, required=True,
                        help="Pixels per micrometer.")
    parser.add_argument("--cells-json", dest="cells_json", default=None,
                        help="Path to a JSON file with per-cell polygon or centroid "
                             "data (see module docstring). Omit to only detect spots "
                             "without per-cell assignment.")
    parser.add_argument("--max-assign-distance-um", dest="max_assign_distance_um",
                        type=float, default=None,
                        help="Centroid-fallback assignment cutoff in µm (only used "
                             "when cells lack polygons). Default: unlimited.")
    parser.add_argument("--method", default="log", choices=["log", "dog"],
                        help="Blob detector: Laplacian- or Difference-of-Gaussian.")
    parser.add_argument("--min-diameter-um", dest="min_diameter_um",
                        type=float, default=0.3)
    parser.add_argument("--max-diameter-um", dest="max_diameter_um",
                        type=float, default=3.0)
    parser.add_argument("--threshold", type=float, default=0.10,
                        help="Absolute blob-detection threshold on the "
                             "normalized [0,1] channel.")
    parser.add_argument("--overlap", type=float, default=0.5)
    parser.add_argument("--num-sigma", dest="num_sigma", type=int, default=10)
    parser.add_argument("--sigma-ratio", dest="sigma_ratio", type=float, default=1.6)
    parser.add_argument("--focus-count-threshold", dest="focus_count_threshold",
                        type=float, default=5,
                        help="Per-cell spot count at/above which a cell counts "
                             "toward the %% positive/high-foci summary metric.")
    return parser.parse_args()


def _load_cells_json(path: str):
    """Read --cells-json into (polygons, centroids) — see module docstring.

    Each entry is routed to `polygons` when it carries a usable polygon
    (>= 3 points), else to `centroids` when it carries cx/cy (or x/y).
    Never raises — logs and returns ([], []) on a read/parse failure.
    """
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as exc:  # noqa: BLE001
        log(f"[puncta_detect] could not read --cells-json {path!r}: {exc!r}")
        return [], []

    if not isinstance(data, list):
        log(f"[puncta_detect] --cells-json must be a JSON array; got {type(data).__name__}")
        return [], []

    polygons = []
    centroids = []
    for i, entry in enumerate(data):
        if not isinstance(entry, dict):
            continue
        label = entry.get("label", entry.get("id", i))
        poly = entry.get("polygon") or entry.get("contour_px")
        if poly and len(poly) >= 3:
            polygons.append({"label": label, "polygon": poly})
        elif "cx" in entry and "cy" in entry:
            centroids.append({"label": label, "cx": entry["cx"], "cy": entry["cy"]})
        elif "x" in entry and "y" in entry:
            centroids.append({"label": label, "cx": entry["x"], "cy": entry["y"]})
    return polygons, centroids


def main() -> None:
    args = parse_args()

    _here = os.path.dirname(os.path.abspath(__file__))
    if _here not in sys.path:
        sys.path.insert(0, _here)

    try:
        import _imageio  # noqa: E402 — the shared multi-channel loader contract.
    except Exception as exc:  # noqa: BLE001
        log(f"[puncta_detect] _imageio import failed: {exc!r}")
        emit_error("imageio-not-available",
                   hint=f"Multi-channel image loader (_imageio.py) is not available: {exc!r}",
                   exit_code=2)
        return

    try:
        import _assays_puncta
    except Exception as exc:  # noqa: BLE001
        log(f"[puncta_detect] _assays_puncta import failed: {exc!r}")
        emit_error("puncta-module-not-available", hint=str(exc), exit_code=2)
        return

    try:
        planes, meta = _imageio.load_planes(args.image, z_project=args.z_project, channel=None)
    except Exception as exc:  # noqa: BLE001
        log(f"[puncta_detect] load_planes failed: {exc!r}")
        emit_error("image-load-failed", hint=str(exc), exit_code=3)
        return

    try:
        import numpy as np
        arr = np.asarray(planes)
    except Exception as exc:  # noqa: BLE001
        emit_error("image-decode-failed", hint=str(exc), exit_code=3)
        return

    if arr.ndim != 3 or arr.shape[2] == 0:
        emit_error("image-shape-unexpected",
                   hint=f"Expected HxWxC from load_planes, got shape {arr.shape}.",
                   exit_code=3)
        return

    n_channels = int(arr.shape[2])
    if not (0 <= args.channel < n_channels):
        emit_error("channel-out-of-range",
                   hint=f"--channel {args.channel} but image has {n_channels} channel(s).",
                   exit_code=3)
        return

    channel_img = arr[:, :, args.channel]
    height_px, width_px = int(arr.shape[0]), int(arr.shape[1])
    log(f"[puncta_detect] image {width_px}x{height_px}, {n_channels} channel(s), "
        f"detecting in channel {args.channel}")

    label_map = None
    label_id_map = None
    centroids = None
    if args.cells_json:
        polygons, centroid_entries = _load_cells_json(args.cells_json)
        if polygons:
            label_map, label_id_map = _assays_puncta.rasterize_polygons(
                polygons, (height_px, width_px))
            log(f"[puncta_detect] rasterized {len(polygons)} cell polygon(s) into a label map")
            if centroid_entries:
                log(f"[puncta_detect] {len(centroid_entries)} cell(s) had no polygon and were "
                    "excluded (no shape to rasterize) — pass polygons for every cell, or omit "
                    "polygons entirely to use centroid-fallback assignment for all cells.")
        elif centroid_entries:
            centroids = centroid_entries
            log(f"[puncta_detect] no cell polygons given; using nearest-centroid assignment "
                f"for {len(centroids)} cell(s)")
        else:
            log("[puncta_detect] --cells-json had no usable polygon or centroid entries")

    params = {
        "method": args.method,
        "min_diameter_um": args.min_diameter_um,
        "max_diameter_um": args.max_diameter_um,
        "threshold": args.threshold,
        "overlap": args.overlap,
        "num_sigma": args.num_sigma,
        "sigma_ratio": args.sigma_ratio,
        "focus_count_threshold": args.focus_count_threshold,
    }

    result = _assays_puncta.compute(
        channel_img, args.pxPerUm, params,
        label_map=label_map, centroids=centroids,
        max_assign_distance_um=args.max_assign_distance_um,
        label_id_map=label_id_map,
    )
    result["width"] = width_px
    result["height"] = height_px

    # `_imageio` already parsed a real µm/pixel calibration out of the file's
    # own metadata (CZI / ND2 / LIF / OIF / OME-TIFF / ImageJ) and nothing used
    # to read it, so users kept typing --pxPerUm by hand. Report it — spot sizes
    # are still computed from the --pxPerUm the caller passed, unchanged.
    # MIND THE RECIPROCAL: pixel_size_um is µm/pixel, we report PIXELS per µm.
    try:
        _px_um = float((meta or {}).get("pixel_size_um"))
    except (TypeError, ValueError):
        _px_um = float("nan")
    if _px_um == _px_um and _px_um > 0:
        result["detected_px_per_um"] = 1.0 / _px_um
        result["detected_pixel_size_um"] = _px_um
        log(f"[puncta_detect] calibration in file: {1.0 / _px_um:.4f} px/µm "
            f"({_px_um:.6g} µm/px); --pxPerUm in use: {args.pxPerUm}")

    # Wire contract: cell_label is always a string (or null) on the way out,
    # even though the pure `_assays_puncta` functions stay label-type-agnostic
    # internally (int raster ids, UUID strings, whatever the caller passed).
    # Matches this app's existing convention of string cell ids everywhere
    # (`DetectedCell.id`, `SidecarCell.id`) so the Swift decoder can use a
    # plain `String?` instead of a polymorphic JSON-scalar type.
    for spot in result.get("spots", []):
        if spot.get("cell_label") is not None:
            spot["cell_label"] = str(spot["cell_label"])
    for cell in result.get("cells", []):
        if cell.get("cell_label") is not None:
            cell["cell_label"] = str(cell["cell_label"])

    log(f"[puncta_detect] {len(result.get('spots', []))} spot(s), "
        f"{len(result.get('cells', []))} cell(s)")

    sys.stdout.write(json.dumps(result))
    sys.stdout.flush()


if __name__ == "__main__":
    main()
