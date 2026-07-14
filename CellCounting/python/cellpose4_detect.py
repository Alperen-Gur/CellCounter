#!/usr/bin/env python3
"""
cellpose4_detect.py — CellCounter sidecar for **cellpose 4.x (CPSAM)**.

The v4 sibling of `cellpose_detect.py`. Obeys the *same* stdout JSON
contract so the Swift host can swap between them based on the active model
id alone, with zero per-version branching upstream.

Why a separate file? Cellpose 4 introduces breaking API changes from 3.x:

  1. `model_type=` is silently ignored. The constructor only honours
     `pretrained_model=` (e.g. `cpsam`, `cpdino`, `cpdino-vitb`, `cpsam_v2`)
     or a path to a user-trained checkpoint.

  2. `CellposeModel(pretrained_model="cpsam")` downloads ~1.15 GB of weights
     on first construction from
     https://huggingface.co/mouseland/cellpose-sam/resolve/main/ and stores
     them at ~/.cellpose/models/. cellpose/utils.py calls
     `download_url_to_file(url, dst, progress=True)` via urllib+tqdm — not
     torch.hub. We monkey-patch tqdm so the download progresses to stderr in
     our `[cellpose_detect]` format that the ccDetectionStage UI parses.

  3. No size predictor exists. v3.x's `diameter=None` consulted a separate
     size_cyto3.npy checkpoint to auto-estimate cell diameter in pixels.
     v4's `diameter` is just a resize hint — None means "don't resize", so
     we still compute an explicit diameter prior from the user's size-class
     thresholds.

  4. eval() returns *three* values, not four:
       return masks, [plot.dx_to_circ(dP), dP, cellprob], styles
     flows[2] is still cellprob (same index as v3.x), but the surrounding
     tuple is shorter.

Pass-18 (K4) consolidation: shared helpers live in `_cellpose_common.py`.
This file only owns the v4-specific bits:

  * tqdm progress bridge (weights download).
  * `pretrained_model=` constructor + alias stripping.
  * eval without `channels=` (v4 infers channels from array shape).
"""

from __future__ import annotations

import os
import sys

# Ensure local helpers (_cellpose_common, _preprocessing, …) are importable.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _cellpose_common as cc  # noqa: E402
from _cellpose_common import log, emit_error  # noqa: E402


# ---------------------------------------------------------------------------
# tqdm patch — bridge cellpose's weight-download progress to our stderr UI.
# ---------------------------------------------------------------------------

def install_tqdm_progress_bridge() -> None:
    try:
        import tqdm as _tqdm_mod
    except ImportError:
        log("[cellpose_detect] tqdm not importable; weight-download progress "
            "will be silent")
        return

    _orig_init = _tqdm_mod.tqdm.__init__
    _orig_update = _tqdm_mod.tqdm.update
    _orig_close = _tqdm_mod.tqdm.close

    def _is_byte_bar(self) -> bool:
        # cellpose's download bar uses unit="B" / unit_scale=True. Filter on
        # those so we don't spam stderr for unrelated tqdm bars (segmentation
        # progress for example) — those are bounded and short.
        return (getattr(self, "unit", "") == "B"
                and bool(getattr(self, "unit_scale", False)))

    def _patched_init(self, *args, **kwargs):
        _orig_init(self, *args, **kwargs)
        if _is_byte_bar(self):
            total = self.total or 0
            log(f"[cellpose_detect] downloading weights: 0 / "
                f"{total / (1024 * 1024):.1f} MB (starting…)")
            self._cc_last_log_pct = -1

    def _patched_update(self, n=1):
        ret = _orig_update(self, n)
        if _is_byte_bar(self):
            total = self.total or 0
            done = self.n or 0
            if total > 0:
                pct = int(done * 100 / total)
                if pct != getattr(self, "_cc_last_log_pct", -1) and pct % 5 == 0:
                    log(f"[cellpose_detect] downloading weights: "
                        f"{done / (1024 * 1024):.1f} / "
                        f"{total / (1024 * 1024):.1f} MB ({pct}%)")
                    self._cc_last_log_pct = pct
        return ret

    def _patched_close(self):
        if _is_byte_bar(self) and (self.total or 0) > 0:
            log(f"[cellpose_detect] downloading weights: done "
                f"({(self.total or 0) / (1024 * 1024):.1f} MB)")
        return _orig_close(self)

    _tqdm_mod.tqdm.__init__ = _patched_init
    _tqdm_mod.tqdm.update = _patched_update
    _tqdm_mod.tqdm.close = _patched_close
    log("[cellpose_detect] tqdm progress bridge installed for weight downloads")


def parse_args():
    parser = cc.build_arg_parser(
        description="Cellpose 4 (CPSAM) detection sidecar for CellCounter",
        default_model="cpsam",
    )
    # v4 has no separate restore model — no --restore flag here.
    parser.add_argument(
        "--diameter", type=float, default=0.0,
        help="Explicit expected cell diameter in micrometers (µm), supplied "
             "by the user. When > 0, overrides the diameter prior otherwise "
             "derived from --small-threshold/--large-threshold bins. "
             "Default 0.0 (disabled; falls back to the bins-derived value).",
    )
    return parser.parse_args()


# ---------------------------------------------------------------------------
# Main pipeline.
# ---------------------------------------------------------------------------

def main() -> None:
    args = parse_args()
    channels = cc.parse_channels(args.channels)

    log("[cellpose_detect] cellpose 4 sidecar starting")

    # Install the tqdm bridge BEFORE we import cellpose so its download path
    # picks up the patched class. tqdm itself is imported at the module level
    # by cellpose.utils, so we patch the class-level methods which propagate.
    install_tqdm_progress_bridge()

    # Lazy imports — so the import-error branch can emit a structured error.
    try:
        import numpy as np  # noqa: F401
        from cellpose import models as cp_models
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] import failed: {exc!r}")
        emit_error("cellpose-not-installed",
                   hint="Run scripts/install_python.sh",
                   exit_code=2)
        return

    # Confirm we're talking to v4 — refuse early on a 3.x venv.
    try:
        import cellpose as _cp_pkg
        cp_ver = getattr(_cp_pkg, "version", "unknown")
        log(f"[cellpose_detect] cellpose version: {cp_ver}")
        if not str(cp_ver).startswith("4."):
            log(f"[cellpose_detect] WARNING: expected cellpose 4.x, got {cp_ver}; "
                "model construction may use the v3 API.")
    except Exception:  # noqa: BLE001
        pass

    # Strip app-level aliases. The host may pass `cp4-cpsam` or `cellpose4-cpsam`;
    # cellpose 4 itself wants the bare `cpsam`/`cpdino`/... or a checkpoint path.
    model_name = args.model
    for prefix in ("cp4-", "cellpose4-", "cellpose-", "cp-"):
        if model_name.startswith(prefix):
            model_name = model_name[len(prefix):]
            break
    if model_name in ("cyto3", "cyto2", "nuclei", "cyto"):
        log(f"[cellpose_detect] '{model_name}' is a cellpose 3 model name; "
            "using 'cpsam' (the v4 default).")
        model_name = "cpsam"

    # Open + preprocess image.
    img = cc.open_image_for_detection(args.image, channels, args)

    # QC metrics + shared image_stats dict.
    image_stats: dict = {}
    image_stats.update(cc.compute_qc_metrics(img))

    height_px, width_px = int(img.shape[0]), int(img.shape[1])
    log(f"[cellpose_detect] image is {width_px}x{height_px} (ndim={img.ndim}); "
        f"model={model_name}; channels={channels}")

    # Device introspection + explicit override.
    import torch as _torch
    override_device, use_gpu_kw = cc.resolve_device(args, _torch)

    # Model construction (triggers the 1.15 GB CPSAM weights download on
    # first run; the tqdm bridge installed above streams progress).
    log(f"[cellpose_detect] constructing CellposeModel(pretrained_model={model_name!r}, "
        f"gpu={use_gpu_kw}) — may download weights on first run")
    try:
        if override_device is not None:
            model = cp_models.CellposeModel(
                gpu=use_gpu_kw,
                pretrained_model=model_name,
                device=override_device,
            )
        else:
            model = cp_models.CellposeModel(
                gpu=use_gpu_kw,
                pretrained_model=model_name,
            )
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] model load failed: {exc!r}")
        emit_error("model-load-failed", hint=str(exc), exit_code=4)
        return

    # Belt-and-brace: move the net to the requested device if cellpose didn't.
    if override_device is not None:
        try:
            if hasattr(model, "net") and model.net is not None:
                model.net.to(override_device)
                if hasattr(model.net, "device"):
                    try:
                        model.net.device = override_device
                    except Exception:  # noqa: BLE001
                        pass
            if hasattr(model, "device"):
                try:
                    model.device = override_device
                except Exception:  # noqa: BLE001
                    pass
        except Exception as exc:  # noqa: BLE001
            log(f"[cellpose_detect] could not move model to {override_device}: {exc!r}")

    # Explicit diameter — v4 has no size predictor, and `None` means "no resize".
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

    # eval — v4 does NOT take `channels=` the way v3 did. Channels are
    # inferred from the array shape. Retry with channels= as a courtesy for
    # an older 4.0 release where the kwarg still existed.
    log("[cellpose_detect] running eval ...")
    try:
        eval_out = model.eval(img, diameter=expected_diam_px)
    except TypeError:
        log("[cellpose_detect] eval rejected zero-kwarg call; retrying with "
            "channels= (older 4.0 release?)")
        try:
            eval_out = model.eval(img, diameter=expected_diam_px, channels=channels)
        except Exception as exc:  # noqa: BLE001
            log(f"[cellpose_detect] eval failed: {exc!r}")
            emit_error("eval-failed", hint=str(exc), exit_code=5)
            return
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] eval failed: {exc!r}")
        emit_error("eval-failed", hint=str(exc), exit_code=5)
        return

    # Cellpose 4: (masks, flows, styles).
    masks = eval_out[0]
    flows = eval_out[1] if len(eval_out) > 1 else None

    # Optional watershed split.
    masks = cc.apply_watershed_if_requested(masks, args)

    # Colony + spatial statistics.
    image_stats.update(cc.compute_colony_stats(masks, args, height_px, width_px))

    # Per-cell measurement loop.
    cells = cc.measure_cells(masks, img, args, flows=flows)

    cc.emit_payload(width_px, height_px, cells, image_stats)


if __name__ == "__main__":
    main()
