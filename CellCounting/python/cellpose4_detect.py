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
     `download_url_to_file(url, dst, progress=True)` — not torch.hub.
     `_cellpose_common.model_loading_progress` swaps in CellCounter's own
     verified, resumable downloader (`_model_downloads.py`), which reports
     progress to stderr in the `[cellpose_detect]` format that the
     ccDetectionStage UI shows.

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
  * `pretrained_model=` constructor + alias stripping, and a refusal of
    model names the installed Cellpose does not know (`check_model_name`).
  * eval without `channels=` (v4 infers channels from array shape).
  * `image_stats["runtime"]`: what ran (`_cellpose_runtime.py`).
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
    """Keep the existing public entry point; both Cellpose versions share it."""
    cc.install_tqdm_progress_bridge()


_MODEL_CACHE = {}

# Cellpose-DINO checkpoints need the `dinov3` package, which Cellpose does not
# declare and CellCounter does not install.
_DINO_MODELS = ("cpdino", "cpdino-vitb")


def check_model_name(cp_models, model_name: str, cellpose_version: str):
    """``(error, hint)`` when this Cellpose cannot load `model_name`, else None.

    Cellpose itself loads its default model, with only a log warning, for a
    name it does not know (4.1.1: cpsam; 4.2: cpsam_v2), so a result would
    silently come from another model. A name is accepted when it is an
    existing path, a model the Cellpose GUI registered (``get_user_models``)
    or one of this Cellpose's ``MODEL_NAMES``.
    """
    import importlib.util

    if os.path.exists(model_name):
        return None
    get_user_models = getattr(cp_models, "get_user_models", None)
    if callable(get_user_models):
        try:
            if model_name in (get_user_models() or ()):
                return None
        except Exception:  # noqa: BLE001
            pass
    # A Cellpose 4 without MODEL_NAMES predates every model but cpsam.
    known = list(getattr(cp_models, "MODEL_NAMES", None) or ("cpsam",))
    if model_name not in known:
        listed = ", ".join(known) if known else "none"
        return ("model-not-in-cellpose",
                f"The installed Cellpose {cellpose_version} does not include the model "
                f"'{model_name}' (it includes: {listed}). Open Models and update "
                "Cellpose-SAM, or choose another model.")
    if model_name in _DINO_MODELS and importlib.util.find_spec("dinov3") is None:
        return ("model-needs-dinov3",
                f"Cellpose-DINO ('{model_name}') needs the dinov3 package, which "
                "Cellographer does not install. Choose Cellpose-SAM or Cellpose-SAM v2.")
    return None


def cellpose_default_model(cp_models) -> str:
    """The built-in model Cellpose loads by default (4.1.1: cpsam; 4.2: cpsam_v2)."""
    import inspect

    try:
        default = inspect.signature(cp_models.CellposeModel.__init__).parameters["pretrained_model"].default
    except Exception:  # noqa: BLE001
        default = None
    known = getattr(cp_models, "MODEL_NAMES", None) or ()
    return default if isinstance(default, str) and default in known else "cpsam"


def parse_args(argv=None):
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
    return parser.parse_args(argv)


# ---------------------------------------------------------------------------
# Main pipeline.
# ---------------------------------------------------------------------------

def main(argv=None) -> None:
    args = parse_args(argv)
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

    # Bit-identical speedups of Cellpose's mask post-processing (idempotent;
    # stays stock unless the exact verified Cellpose version is installed).
    try:
        import _cellpose_accel
        _cellpose_accel.install()
    except ImportError:
        pass

    # Confirm we're talking to v4 — refuse early on a 3.x venv.
    cp_ver = "unknown"
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
            "using 'cpsam' (Cellographer's Cellpose-SAM default).")
        model_name = "cpsam"

    # Refuse a name this Cellpose does not know instead of letting it load
    # its default model under the requested name.
    refusal = check_model_name(cp_models, model_name, str(cp_ver))
    if refusal is not None:
        log(f"[cellpose_detect] {refusal[1]}")
        emit_error(refusal[0], hint=refusal[1], exit_code=4)
        return

    # Open + preprocess image.
    img = cc.open_image_for_detection(args.image, channels, args)

    # QC metrics + shared image_stats dict.
    image_stats: dict = {}
    image_stats.update(cc.compute_qc_metrics(img))
    # Expose the calibration read from the image file's own metadata
    # (px/µm). Reported only — --pxPerUm still drives every measurement.
    image_stats.update(cc.detected_calibration_stats(args))

    height_px, width_px = int(img.shape[0]), int(img.shape[1])
    log(f"[cellpose_detect] image is {width_px}x{height_px} (ndim={img.ndim}); "
        f"model={model_name}; channels={channels}")

    # Device introspection + explicit override.
    import torch as _torch
    cc.apply_cpu_thread_limit(_torch)
    override_device, use_gpu_kw = cc.resolve_device(args, _torch)

    # Model construction (triggers the 1.15 GB CPSAM weights download on
    # first run; the tqdm bridge installed above streams progress).
    model_key = (model_name, str(override_device), bool(use_gpu_kw))
    model = _MODEL_CACHE.get(model_key)
    if model is None:
        log(f"[cellpose_detect] constructing CellposeModel(pretrained_model={model_name!r}, "
            f"gpu={use_gpu_kw}) — may download weights on first run")
        def _construct():
            if override_device is not None:
                return cp_models.CellposeModel(
                    gpu=use_gpu_kw,
                    pretrained_model=model_name,
                    device=override_device,
                )
            return cp_models.CellposeModel(
                gpu=use_gpu_kw,
                pretrained_model=model_name,
            )

        try:
            with cc.model_loading_progress() as models_dir:
                # Names are checked above; the default only mirrors what
                # this Cellpose itself would load for an unknown name.
                managed = cc.managed_cellpose_weights(
                    cp_models, model_name, default=cellpose_default_model(cp_models))
                model = cc.build_with_weight_recovery(_construct, managed, models_dir)
        except cc.ModelDownloadError as exc:
            emit_error("model-download-failed", hint=str(exc), exit_code=4)
            return
        except Exception as exc:  # noqa: BLE001
            log(f"[cellpose_detect] model load failed: {exc!r}")
            emit_error("model-load-failed", hint=str(exc), exit_code=4)
            return
        _MODEL_CACHE.clear()
        _MODEL_CACHE[model_key] = model
    else:
        log("[cellpose_detect] reusing initialized model")

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

    # What actually ran: versions, device, dtype, weights, speed patches.
    try:
        import _cellpose_runtime
        image_stats["runtime"] = _cellpose_runtime.runtime_block(
            model=model, requested_model=args.model, device=resolved_device)
    except ImportError:
        pass

    cc.emit_payload(width_px, height_px, cells, image_stats)


if __name__ == "__main__":
    # SIGTERM unwinds the request (the ~1.2 GB weight download keeps its
    # resumable .cellcounter-part file), then ends the process by SIGTERM as before.
    if "--serve" in sys.argv[1:]:
        # Memory is released after each response is sent, so it never
        # delays a result. The cached model stays loaded.
        cc.run_sidecar(lambda: cc.serve_ndjson(main, after_response=cc.release_request_memory))
    else:
        cc.run_sidecar(main)
