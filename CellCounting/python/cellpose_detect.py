#!/usr/bin/env python3
"""
cellpose_detect.py — CellCounter sidecar for **cellpose 3.x**.

Reads an image, runs a Cellpose 3.x model, prints a single JSON object to
stdout describing detected cells. All progress/log output goes to stderr so
stdout stays parseable by the Swift host (CellposeDetectionService).

Stdout contract (shared with cellpose4_detect.py — see _cellpose_common.py
for the full schema):
  {
    "width":  <int>,
    "height": <int>,
    "cells":  [ {id, cx, cy, diameter_um, …}, … ],
    "image_stats": { focus_score, illumination_residual, n_colonies, … }
  }

If cellpose (or one of its deps) is not importable, prints:
  {"error": "cellpose-not-installed", "hint": "Run scripts/install_python.sh"}
to stdout and exits with code 2.

Pass-18 (K4) consolidation: argparse, image loading, QC metrics, watershed,
colony stats, per-cell measurement, and JSON emission moved into
`_cellpose_common.py`. This file only owns the 3.x-specific bits:

  * `restore_type="denoise_cyto3"` model construction (the cp-cyto3-r model).
  * Explicit ``diameter`` derived from bin thresholds (skips cellpose's
    size_cyto3.npy auto-estimator that IndexErrors on large images).
  * Half-resolution retry on eval failure.
  * `channels=` kwarg on model.eval() (v4 dropped that signature).
"""

from __future__ import annotations

import os
import sys

# Ensure local helpers (_cellpose_common, _preprocessing, …) are importable
# both when launched from the staged python dir AND when launched in-tree.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _cellpose_common as cc  # noqa: E402
from _cellpose_common import log, emit_error  # noqa: E402


def parse_args():
    """Build the shared parser, then add the v3.x-only --restore flag."""
    parser = cc.build_arg_parser(
        description="Cellpose 3.x detection sidecar for CellCounter",
        default_model="cyto3",
    )
    parser.add_argument(
        "--restore", action="store_true",
        help="Enable Cellpose 3.x image restoration "
             "(restore_type='denoise_cyto3'). Used by the cp-cyto3-r model.",
    )
    parser.add_argument(
        "--diameter", type=float, default=0.0,
        help="Explicit expected cell diameter in micrometers (µm), supplied "
             "by the user. When > 0, overrides the diameter prior otherwise "
             "derived from --small-threshold/--large-threshold bins. "
             "Default 0.0 (disabled; falls back to the bins-derived value).",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    channels = cc.parse_channels(args.channels)

    # Lazy imports — so the import-error branch can emit a structured error
    # without crashing on bare ImportError.
    try:
        import numpy as np  # noqa: F401  — used by load_image_array
        from cellpose import models as cp_models
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] import failed: {exc!r}")
        emit_error("cellpose-not-installed",
                   hint="Run scripts/install_python.sh",
                   exit_code=2)
        return

    # Map any app-level "cp-*" alias down to the canonical cellpose name.
    model_type = args.model
    if model_type.startswith("cp-"):
        model_type = model_type[3:]

    # Open image, preprocess (bg-subtract etc.).
    img = cc.open_image_for_detection(args.image, channels, args)

    # QC metrics on the (now possibly preprocessed) array. These match the
    # contract that the Swift host reads from `image_stats` in the payload.
    image_stats: dict = {}
    image_stats.update(cc.compute_qc_metrics(img))

    height_px, width_px = int(img.shape[0]), int(img.shape[1])
    log(f"[cellpose_detect] image is {width_px}x{height_px} (ndim={img.ndim}); "
        f"model={model_type}; channels={channels}")

    # Device introspection / explicit override.
    import torch as _torch
    override_device, use_gpu_kw = cc.resolve_device(args, _torch)

    def _build_model(**extra_kw):
        # Older cellpose builds don't accept gpu=, so we try with and degrade.
        try:
            m = cp_models.CellposeModel(gpu=use_gpu_kw, **extra_kw)
        except TypeError:
            m = cp_models.CellposeModel(**extra_kw)
        # If we have an override, move the underlying net there and reflect
        # the choice on the model so cellpose's eval-time tensor allocations
        # honour it.
        if override_device is not None:
            try:
                if hasattr(m, "net") and m.net is not None:
                    m.net.to(override_device)
                    if hasattr(m.net, "device"):
                        try:
                            m.net.device = override_device
                        except Exception:  # noqa: BLE001
                            pass
                if hasattr(m, "device"):
                    try:
                        m.device = override_device
                    except Exception:  # noqa: BLE001
                        pass
                if hasattr(m, "mkldnn"):
                    try:
                        m.mkldnn = False
                    except Exception:  # noqa: BLE001
                        pass
            except Exception as exc:  # noqa: BLE001
                log(f"[cellpose_detect] could not move model to {override_device}: {exc!r}")
        return m

    try:
        if args.restore:
            log("[cellpose_detect] enabling restore_type='denoise_cyto3'")
            try:
                model = _build_model(model_type=model_type, restore_type="denoise_cyto3")
            except TypeError:
                # Older cellpose builds don't accept restore_type on CellposeModel; degrade gracefully.
                log("[cellpose_detect] CellposeModel doesn't accept restore_type; "
                    "falling back to plain model")
                model = _build_model(model_type=model_type)
        else:
            model = _build_model(model_type=model_type)
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] model load failed: {exc!r}")
        emit_error("model-load-failed", hint=str(exc), exit_code=4)
        return

    # Pass-13: derive an explicit expected diameter (in pixels) from the user's
    # bin thresholds and calibration. Without this, cellpose 3.x runs its size
    # predictor (size_cyto3.npy) to auto-estimate diameter; that codepath has a
    # known IndexError on larger images (e.g. 2880x2048). Passing an explicit
    # `diameter` skips the size predictor entirely.
    #
    # If the user supplied an explicit --diameter (> 0), it takes priority over
    # the bins-derived prior — the bins are for size classification, not
    # necessarily the segmentation prior the user wants.
    if args.diameter > 0:
        expected_diam_um = float(args.diameter)
        diam_source = f"explicit --diameter={expected_diam_um:.2f}µm"
    else:
        expected_diam_um = (float(args.small_threshold) + float(args.large_threshold)) / 2.0
        diam_source = f"bins {args.small_threshold}-{args.large_threshold}µm"
    expected_diam_px = max(15.0, expected_diam_um * float(args.pxPerUm))
    log(f"[cellpose_detect] using fixed diameter={expected_diam_px:.1f}px "
        f"(from {diam_source} @ {args.pxPerUm}px/µm)")

    # Pass-14: surface the device the model will actually run on. The UI
    # parses this stage line and shows the real device instead of the
    # user-toggle guess. Must be a single line of the form:
    #   [cellpose_detect] using device: <name> (torch <version>)
    resolved_device = "cpu"
    try:
        if override_device is not None:
            resolved_device = str(override_device)
        elif hasattr(model, "device") and model.device is not None:
            resolved_device = str(model.device)
        elif hasattr(model, "net") and hasattr(model.net, "device"):
            resolved_device = str(model.net.device)
    except Exception:  # noqa: BLE001
        pass
    log(f"[cellpose_detect] using device: {resolved_device} (torch {_torch.__version__})")

    log("[cellpose_detect] running eval ...")
    try:
        eval_out = model.eval(img, diameter=expected_diam_px, channels=channels)
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] eval failed with explicit diameter: {exc!r}")
        # Last-ditch retry on a half-resolution copy. Cellpose's own size
        # predictor sometimes survives at lower resolution where the full-size
        # path indexes out of bounds.
        try:
            import numpy as _np
            from PIL import Image as _PILImage
            log("[cellpose_detect] retrying eval at half resolution")
            if img.ndim == 2:
                pil_small = _PILImage.fromarray(img).resize(
                    (img.shape[1] // 2, img.shape[0] // 2), _PILImage.BILINEAR)
                img_small = _np.array(pil_small, dtype=img.dtype)
            else:
                pil_small = _PILImage.fromarray(img).resize(
                    (img.shape[1] // 2, img.shape[0] // 2), _PILImage.BILINEAR)
                img_small = _np.array(pil_small, dtype=img.dtype)
            eval_out = model.eval(img_small,
                                  diameter=expected_diam_px / 2.0,
                                  channels=channels)
            # Upsample the mask back to original resolution (nearest-neighbour
            # to preserve label integers).
            masks_small = eval_out[0]
            masks_full = _np.array(
                _PILImage.fromarray(masks_small.astype(_np.int32)).resize(
                    (img.shape[1], img.shape[0]), _PILImage.NEAREST),
                dtype=_np.int32)
            eval_out = (masks_full,) + tuple(eval_out[1:])
            log("[cellpose_detect] half-resolution retry succeeded")
        except Exception as exc2:  # noqa: BLE001
            log(f"[cellpose_detect] half-resolution retry also failed: {exc2!r}")
            emit_error("eval-failed",
                       hint=f"{exc!r} (half-res retry: {exc2!r})",
                       exit_code=5)
            return

    masks = eval_out[0]
    flows = eval_out[1] if len(eval_out) > 1 else None

    # A3: optional distance-transform watershed split (between detect + measure).
    masks = cc.apply_watershed_if_requested(masks, args)

    # C2: per-image colony + spatial statistics.
    image_stats.update(cc.compute_colony_stats(masks, args, height_px, width_px))

    # Per-cell measurement loop.
    cells = cc.measure_cells(masks, img, args, flows=flows)

    cc.emit_payload(width_px, height_px, cells, image_stats)


if __name__ == "__main__":
    main()
