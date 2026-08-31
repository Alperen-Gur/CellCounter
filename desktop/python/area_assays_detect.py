#!/usr/bin/env python3
"""
area_assays_detect.py — standalone CLI sidecar for CellCounter's area/region
assays: confluence (% coverage), scratch / wound-healing, and spheroid /
organoid sizing.

Wraps the pure functions in `_assays_area.py` with argument parsing and the
same stderr-log / single-stdout-JSON contract as the other detect sidecars
(`cellpose_detect.py`, `stardist_detect.py`, `sam_detect.py`) — see
`_cellpose_common.py` for the shared `log()`/`emit_error()` helpers this
script imports and reuses read-only (nothing here modifies that module).

Unlike the other sidecars, this one is INTENTIONALLY independent of any
detector: it never imports cellpose / stardist / torch, so it runs with just
numpy + scikit-image + scipy + Pillow — already installed for every model
family (see scripts/install_python.sh's CC_PIP_PACKAGES). No detection model
needs to be installed to run an area assay; it shares the same venv/python3
the other sidecars use (`FileStore.pythonInterpreterURL` on the Swift side)
purely because that's where those packages already live.

Stdout contract (single JSON object, written once, flushed):
    {"ok": bool, "mode": "confluence"|"scratch-wound"|"spheroid", "result": {...}}
`result` is exactly what the matching `_assays_area` function returned (see
that module's docstrings for each mode's result shape) — this script never
reshapes it, so the two stay in lockstep by construction.

On a hard failure BEFORE a mode-specific function could even run (bad args,
unreadable image), prints the same structured-error shape the other
sidecars use and exits non-zero:
    {"error": "...", "hint": "..."}

Usage:
    # Confluence — mask mode (an existing binary/label mask image on disk):
    area_assays_detect.py --mode confluence --pxPerUm 2.6 --mask mask.png

    # Confluence — mask-free threshold mode:
    area_assays_detect.py --mode confluence --pxPerUm 2.6 --image field.png \\
        --threshold-method otsu

    # Scratch wound — single image:
    area_assays_detect.py --mode scratch-wound --pxPerUm 2.6 --image t0.png

    # Scratch wound — ordered time series (repeat --image; order = time order):
    area_assays_detect.py --mode scratch-wound --pxPerUm 2.6 \\
        --image t0.png --image t1.png --image t2.png --timepoints-hours 0,6,12

    # Spheroid / organoid sizing:
    area_assays_detect.py --mode spheroid --pxPerUm 0.5 --image well.png
"""

from __future__ import annotations

import argparse
import json
import os
import sys

# Ensure local helpers (_assays_area, _cellpose_common) are importable both
# when launched from the staged python dir AND when launched in-tree.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _assays_area as assays  # noqa: E402
from _cellpose_common import log, emit_error  # noqa: E402 — read-only reuse.


# ---------------------------------------------------------------------------
# Image / mask loading — deliberately self-contained (does NOT call
# `_cellpose_common.open_image_for_detection`, which is tailored to the
# cellpose preprocessing pipeline's `--bg-subtract` / channel-selection
# flags). This sidecar has no detector dependency, by design.
# ---------------------------------------------------------------------------

def _load_image_array(path: str):
    """Open an image file -> uint8 numpy array (HxW gray, or HxWx3 RGB)."""
    import numpy as np
    from PIL import Image

    # Trusted, user-chosen local files — see the matching guard in
    # `_cellpose_common.open_image_for_detection` for why this is raised
    # above PIL's conservative default.
    Image.MAX_IMAGE_PIXELS = 2_000_000_000
    pil = Image.open(path)
    pil.load()
    mode = pil.mode
    if mode == "L":
        return np.array(pil, dtype=np.uint8)
    if mode in ("I", "F"):
        arr = np.array(pil, dtype=np.float64)
        lo, hi = float(arr.min()), float(arr.max())
        if hi > lo:
            arr = (arr - lo) / (hi - lo) * 255.0
        return arr.astype(np.uint8)
    return np.array(pil.convert("RGB"), dtype=np.uint8)


def _load_mask_array(path: str):
    """Open a mask/label image file -> int numpy array (0 = background).
    Any nonzero pixel is foreground; multi-valued (labeled) PNGs work
    unchanged since `_assays_area.confluence` only tests `> 0`."""
    import numpy as np
    from PIL import Image

    Image.MAX_IMAGE_PIXELS = 2_000_000_000
    pil = Image.open(path)
    pil.load()
    if pil.mode == "P":
        pil = pil.convert("I")
    elif pil.mode not in ("L", "I", "I;16"):
        pil = pil.convert("L")
    return np.array(pil, dtype=np.int64)


# ---------------------------------------------------------------------------
# Argument parsing — every mode-specific numeric/flag default is `None` so
# an omitted flag falls through to `_assays_area`'s own function defaults
# (the single source of truth for defaults) rather than argparse silently
# re-asserting a possibly-mismatched value (confluence's and spheroid's
# `invert` defaults are intentionally OPPOSITE, for example).
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="CellCounter area/region assays: confluence, scratch-wound, spheroid.")
    p.add_argument("--mode", required=True,
                   choices=["confluence", "scratch-wound", "spheroid"],
                   help="Which assay to run.")
    p.add_argument("--pxPerUm", type=float, required=True,
                   help="Pixels per micrometer; converts pixel measurements to µm.")

    # Repeatable rather than a comma-joined list: a microscopy filename can
    # legitimately contain a comma ("Donor A, Day 3.tif"), which a
    # delimiter-split would silently corrupt. One `--image` = single-image
    # mode (confluence threshold mode, spheroid, scratch-wound single
    # frame); 2+ occurrences = a scratch-wound series, in the order given.
    p.add_argument("--image", dest="images", action="append", default=None,
                   help="Input image path. Repeat, IN CHRONOLOGICAL ORDER, "
                        "for a scratch-wound time series.")
    p.add_argument("--mask", default=None,
                   help="Mask/label image path (confluence mask mode).")
    p.add_argument("--timepoints-hours", dest="timepoints_hours", default=None,
                   help="Comma-separated hours, same length as --images.")

    # Confluence + spheroid share these names/semantics; each mode's own
    # function default applies when the flag is omitted (see module docstring).
    p.add_argument("--threshold-method", dest="threshold_method",
                   default=None, choices=["otsu", "fixed"])
    p.add_argument("--fixed-threshold", dest="fixed_threshold", type=float, default=None)
    p.add_argument("--invert", dest="invert", action=argparse.BooleanOptionalAction, default=None,
                   help="Flip default foreground polarity. Confluence default: "
                        "bright=foreground. Spheroid default: dark object=foreground. "
                        "Omit to use the mode's own default.")
    p.add_argument("--smooth-sigma-px", dest="smooth_sigma_px", type=float, default=None)

    # Confluence-only cleanup.
    p.add_argument("--min-object-size-um2", dest="min_object_size_um2", type=float, default=None,
                   help="Confluence cleanup: drop/fill specks smaller than this (0 = off).")

    # Scratch-wound-only.
    p.add_argument("--texture-window-px", dest="texture_window_px", type=int, default=None)
    p.add_argument("--min-gap-size-um2", dest="min_gap_size_um2", type=float, default=None)
    p.add_argument("--flat-region-ratio", dest="flat_region_ratio", type=float, default=None,
                   help="Bimodality gate: p10/p90 of local texture must be below this to "
                        "trust a wound detection at all (0-1, default 0.25 — see "
                        "_assays_area.scratch_wound's docstring).")

    # Spheroid-only.
    p.add_argument("--min-object-area-um2", dest="min_object_area_um2", type=float, default=None)
    p.add_argument("--min-circularity", dest="min_circularity", type=float, default=None)
    p.add_argument("--max-objects", dest="max_objects", type=int, default=None)

    return p.parse_args()


def _kwargs(args: argparse.Namespace, names: list[str]) -> dict:
    """Pick non-None values for `names` out of the parsed namespace, so
    omitted flags fall through to the callee's own defaults."""
    d = vars(args)
    return {n: d[n] for n in names if d.get(n) is not None}


CONFLUENCE_PARAM_NAMES = [
    "threshold_method", "fixed_threshold", "invert", "smooth_sigma_px",
    "min_object_size_um2",
]
WOUND_PARAM_NAMES = ["texture_window_px", "min_gap_size_um2", "smooth_sigma_px", "flat_region_ratio"]
SPHEROID_PARAM_NAMES = [
    "threshold_method", "fixed_threshold", "invert", "smooth_sigma_px",
    "min_object_area_um2", "min_circularity", "max_objects",
]


def main() -> None:
    args = parse_args()

    try:
        import numpy as np  # noqa: F401
    except Exception as exc:  # noqa: BLE001
        log(f"[area_assays_detect] numpy import failed: {exc!r}")
        emit_error("numpy-not-installed", hint="Run scripts/install_python.sh", exit_code=2)
        return

    result: dict
    images = args.images or []  # dest="images" via action="append" on --image

    if args.mode == "confluence":
        if args.mask:
            log(f"[area_assays_detect] confluence (mask mode): {args.mask}")
            try:
                mask_arr = _load_mask_array(args.mask)
            except Exception as exc:  # noqa: BLE001
                log(f"[area_assays_detect] could not open mask: {exc!r}")
                emit_error("image-open-failed", hint=str(exc), exit_code=3)
                return
            kwargs = _kwargs(args, ["min_object_size_um2"])
            result = assays.confluence(mask=mask_arr, px_per_um=args.pxPerUm, **kwargs)
        elif images:
            log(f"[area_assays_detect] confluence (threshold mode): {images[0]}")
            try:
                img_arr = _load_image_array(images[0])
            except Exception as exc:  # noqa: BLE001
                log(f"[area_assays_detect] could not open image: {exc!r}")
                emit_error("image-open-failed", hint=str(exc), exit_code=3)
                return
            kwargs = _kwargs(args, CONFLUENCE_PARAM_NAMES)
            result = assays.confluence(image=img_arr, px_per_um=args.pxPerUm, **kwargs)
        else:
            emit_error("missing-input", hint="confluence needs --mask or --image", exit_code=2)
            return

    elif args.mode == "scratch-wound":
        if not images:
            emit_error("missing-input", hint="scratch-wound needs at least one --image", exit_code=2)
            return
        try:
            arrs = [_load_image_array(p) for p in images]
        except Exception as exc:  # noqa: BLE001
            log(f"[area_assays_detect] could not open a series image: {exc!r}")
            emit_error("image-open-failed", hint=str(exc), exit_code=3)
            return
        if len(images) > 1:
            log(f"[area_assays_detect] scratch-wound series: {len(images)} frame(s)")
            tps = None
            if args.timepoints_hours:
                try:
                    tps = [float(x.strip()) for x in args.timepoints_hours.split(",") if x.strip() != ""]
                except ValueError as exc:
                    emit_error("bad-timepoints", hint=str(exc), exit_code=2)
                    return
            kwargs = _kwargs(args, WOUND_PARAM_NAMES)
            result = assays.scratch_wound_series(
                arrs, px_per_um=args.pxPerUm, timepoints_hours=tps, **kwargs)
        else:
            log(f"[area_assays_detect] scratch-wound single image: {images[0]}")
            kwargs = _kwargs(args, WOUND_PARAM_NAMES)
            result = assays.scratch_wound(arrs[0], px_per_um=args.pxPerUm, **kwargs)

    else:  # spheroid
        if not images:
            emit_error("missing-input", hint="spheroid needs --image", exit_code=2)
            return
        log(f"[area_assays_detect] spheroid: {images[0]}")
        try:
            img_arr = _load_image_array(images[0])
        except Exception as exc:  # noqa: BLE001
            log(f"[area_assays_detect] could not open image: {exc!r}")
            emit_error("image-open-failed", hint=str(exc), exit_code=3)
            return
        kwargs = _kwargs(args, SPHEROID_PARAM_NAMES)
        result = assays.spheroids(img_arr, px_per_um=args.pxPerUm, **kwargs)

    payload = {"ok": bool(result.get("ok", False)), "mode": args.mode, "result": result}
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()
    log(f"[area_assays_detect] done: mode={args.mode} ok={payload['ok']}")


if __name__ == "__main__":
    main()
