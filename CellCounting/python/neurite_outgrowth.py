#!/usr/bin/env python3
"""
neurite_outgrowth.py — CellCounter sidecar entry point for neurite outgrowth.

Thin CLI wrapper around `_neurite.analyze()`. Reads a neurite mask image and
either a labeled soma-mask image or a JSON list of soma centroids, prints
ONE JSON object to stdout with the per-cell neurite measurements. Logging
goes to stderr — the same convention every other sidecar in this package
uses (see `cellpose_detect.py` / `_cellpose_common.py`).

Self-contained like `track_cells.py`: does NOT import `_cellpose_common`
(scoped to the Cellpose 3.x/4.x detection sidecars). `_neurite.analyze()` is
the real, independently-testable deliverable; this is just its CLI front
door for a future SidecarProcessRunner integration.

Inputs:
  --neurite-mask <path>    Any image PIL can open. Nonzero / non-black
                            pixels are treated as neurite foreground.
  --soma-mask <path>       Optional. A LABELED image (distinct integer pixel
                            value per soma — e.g. the "masks" array a
                            Cellpose sidecar already produces, saved as a
                            16/32-bit single-channel TIFF so >255 cell ids
                            survive). Preferred: pixel-accurate attribution.
  --soma-centroids <path>  Optional, alternative to --soma-mask. A JSON file
                            shaped {"cells": [{"id","cx","cy"}, ...]} — falls
                            back to a synthetic soma-disc per centroid (see
                            `_neurite.py` module docstring). If BOTH are
                            given, --soma-mask wins (it's the more accurate
                            source). If NEITHER is given, the result still
                            reports whole-image skeleton totals, just no
                            per-cell breakdown.
  --px-per-um <float>       Required.
  --soma-radius-um <float>  Optional, default 8.0 — only used with
                            --soma-centroids (there is no real soma
                            footprint to measure in that case).

Output JSON: see `_neurite.py`'s module docstring for the full schema
(`cells`, `mean_neurite_length_um`, `caveat`, `message`).

Exit codes: 0 on success, including "no soma given" (reported via `message`,
not an error — a per-image-only report is a legitimate result). 2 on a
malformed --soma-centroids file or missing required arguments. 3 if an image
file cannot be opened.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _neurite  # noqa: E402


def log(*args, **kwargs) -> None:
    """Stderr logger — stdout is reserved for the final JSON result."""
    print(*args, file=sys.stderr, **kwargs)


def emit_error(error: str, hint: str = "", exit_code: int = 2) -> None:
    """Write a structured error JSON to stdout and exit (mirrors _cellpose_common.emit_error)."""
    payload: dict = {"error": error}
    if hint:
        payload["hint"] = hint
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()
    sys.exit(exit_code)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Neurite outgrowth sidecar for CellCounter.")
    p.add_argument("--neurite-mask", dest="neurite_mask", required=True,
                   help="Path to a binary/label neurite mask image.")
    p.add_argument("--soma-mask", dest="soma_mask", default=None,
                   help="Path to a labeled soma mask image (one integer id "
                        "per cell body). Preferred over --soma-centroids.")
    p.add_argument("--soma-centroids", dest="soma_centroids", default=None,
                   help='Path to a JSON file shaped {"cells": [{"id","cx","cy"}]} '
                        "— used only when --soma-mask is not given.")
    p.add_argument("--px-per-um", dest="px_per_um", type=float, required=True,
                   help="Pixels per micrometer.")
    p.add_argument("--soma-radius-um", dest="soma_radius_um", type=float,
                   default=8.0,
                   help="Synthetic soma disc radius (µm), used only with "
                        "--soma-centroids where no real soma footprint is "
                        "available. Default 8.0.")
    return p.parse_args()


def _load_mask_image(path: str):
    """Open an image file as an integer array. Labeled (multi-cell) masks are
    commonly saved as 16/32-bit single-channel TIFFs so >255 distinct cell
    ids survive round-tripping; anything else is coerced to 8-bit grayscale.
    """
    import numpy as np
    from PIL import Image

    Image.MAX_IMAGE_PIXELS = 2_000_000_000
    pil = Image.open(path)
    pil.load()
    if pil.mode in ("I", "I;16", "I;16B", "I;16L"):
        return np.array(pil, dtype=np.int64)
    return np.array(pil.convert("L"), dtype=np.int64)


def main() -> None:
    args = parse_args()

    log(f"[neurite_outgrowth] loading neurite mask: {args.neurite_mask}")
    try:
        neurite_mask = _load_mask_image(args.neurite_mask)
    except Exception as exc:  # noqa: BLE001
        log(f"[neurite_outgrowth] could not open --neurite-mask: {exc!r}")
        emit_error("image-open-failed", hint=str(exc), exit_code=3)
        return

    soma: object = None
    if args.soma_mask:
        log(f"[neurite_outgrowth] loading soma mask: {args.soma_mask}")
        try:
            soma = _load_mask_image(args.soma_mask)
        except Exception as exc:  # noqa: BLE001
            log(f"[neurite_outgrowth] could not open --soma-mask: {exc!r}")
            emit_error("image-open-failed", hint=str(exc), exit_code=3)
            return
    elif args.soma_centroids:
        log(f"[neurite_outgrowth] loading soma centroids: {args.soma_centroids}")
        try:
            with open(args.soma_centroids, "r", encoding="utf-8") as fh:
                payload = json.load(fh)
            soma = payload.get("cells") if isinstance(payload, dict) else payload
        except Exception as exc:  # noqa: BLE001
            log(f"[neurite_outgrowth] could not read --soma-centroids: {exc!r}")
            emit_error("input-read-failed", hint=str(exc), exit_code=2)
            return
    else:
        log("[neurite_outgrowth] no --soma-mask/--soma-centroids given — "
            "whole-image totals only, no per-cell breakdown")

    result = _neurite.analyze(
        neurite_mask, soma, px_per_um=args.px_per_um,
        params={"soma_radius_um": args.soma_radius_um},
    )

    note = f"; {result['message']}" if result.get("message") else ""
    log(f"[neurite_outgrowth] done — {result.get('n_cells', 0)} cell(s), "
        f"total skeleton length {result.get('total_skeleton_length_um', 0):.1f} µm{note}")

    sys.stdout.write(json.dumps(result))
    sys.stdout.flush()


if __name__ == "__main__":
    main()
