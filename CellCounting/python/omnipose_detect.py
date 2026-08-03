#!/usr/bin/env python3
"""
omnipose_detect.py — CellCounter sidecar for Omnipose.

Omnipose (Cutler et al., Nature Methods 2022) replaces Cellpose's flow field
with a distance-field formulation that does not assume roughly round cells.
That makes it the right tool for bacteria and anything filamentous or
elongated — the exact population where Cellpose's diameter prior falls apart.
MIT licensed.

Runtime isolation
-----------------
Omnipose ships its own Cellpose fork (`cellpose_omni`) and pins an older
numpy/torch tail that conflicts with `cellpose>=4`. It therefore lives in its
OWN virtualenv (`python/venv_omni/`), exactly like Cellpose-SAM lives in
`venv4/`. `OmniposeDownloader.swift` creates and populates that venv; nothing
here is shared with `venv/` or `venv4/` beyond these .py helper files.

Stdout contract
---------------
Identical to every other sidecar — see `_cellpose_common.emit_payload`. We go
through the shared `measure_cells`, so per-cell fields (including
`contour_px`) match the Cellpose payload field for field.

CLI: accepts the full shared flag set (`--image`, `--model`, `--pxPerUm`,
`--conf`, `--channels`, `--bg-subtract`, `--rolling-ball-radius`,
`--watershed`, `--watershed-min-distance`, `--small-threshold`,
`--large-threshold`, `--no-gpu`, `--device`) so the existing runner works
unchanged, plus the Omnipose-specific flags below.

All logging goes to stderr; stdout carries only the JSON result.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _cellpose_common as cc  # noqa: E402
from _cellpose_common import log, emit_error  # noqa: E402


# Catalog id → Omnipose pretrained model name. `resolve_model_name` also
# accepts a bare Omnipose name so a future id can be added Swift-side alone.
_MODEL_MAP = {
    "omni-bact-phase": "bact_phase_omni",
    "omni-bact-fluor": "bact_fluor_omni",
    "omni-cyto2": "cyto2_omni",
    "omni-worm": "worm_omni",
    "omni-plant": "plant_omni",
}

_KNOWN_NAMES = set(_MODEL_MAP.values())


def resolve_model_name(raw: str) -> str:
    if raw in _MODEL_MAP:
        return _MODEL_MAP[raw]
    if raw in _KNOWN_NAMES:
        return raw
    log(f"[cellpose_detect] unknown Omnipose model '{raw}'; "
        "defaulting to bact_phase_omni")
    return "bact_phase_omni"


def parse_args():
    parser = cc.build_arg_parser(
        description="Omnipose detection sidecar for CellCounter",
        default_model="omni-bact-phase",
    )
    parser.add_argument(
        "--mask-threshold", dest="mask_threshold", type=float, default=0.0,
        help="Omnipose mask_threshold. Lower values keep more (and larger) "
             "masks. Default 0.0; -1.0 is a common permissive setting for "
             "dim phase-contrast bacteria.",
    )
    parser.add_argument(
        "--flow-threshold", dest="flow_threshold", type=float, default=0.0,
        help="Omnipose flow_threshold. 0.0 (the default, and what the "
             "Omnipose authors recommend for the omni models) disables the "
             "flow-error QC filter, which is tuned for round cells.",
    )
    parser.add_argument(
        "--cluster", action="store_true",
        help="Enable Omnipose's DBSCAN mask reconstruction. Slower, but "
             "noticeably better on dense, touching filaments.",
    )
    parser.add_argument(
        "--diameter", type=float, default=0.0,
        help="Explicit expected cell diameter in micrometers. Default 0 = let "
             "Omnipose infer it. Unlike Cellpose, Omnipose does NOT need a "
             "diameter prior for elongated cells, so the default is usually "
             "the right choice.",
    )
    return parser.parse_args()


def _eval_with_degradation(model, img, kwargs):
    """Call model.eval, dropping kwargs the installed build doesn't accept.

    Omnipose's eval signature has drifted across releases (`omni=`, `cluster=`,
    `transparency=`, `mask_threshold=` vs the older `mask_threshold` spelling).
    Rather than pin one version, we retry without whichever keyword the
    TypeError names until the call goes through.
    """
    attempt = dict(kwargs)
    for _ in range(len(kwargs) + 1):
        try:
            return model.eval(img, **attempt)
        except TypeError as exc:
            message = str(exc)
            dropped = None
            for key in list(attempt.keys()):
                if key in message:
                    dropped = key
                    break
            if dropped is None:
                break
            log(f"[cellpose_detect] eval() rejected '{dropped}' "
                f"({message}); retrying without it")
            attempt.pop(dropped, None)
    # Last resort: the most conservative call any cellpose-derived API accepts.
    log("[cellpose_detect] falling back to a minimal eval() call")
    return model.eval(img)


def main() -> None:
    args = parse_args()
    channels = cc.parse_channels(args.channels)
    model_name = resolve_model_name(args.model)

    # Lazy imports so the not-installed branch can emit a structured error.
    try:
        import numpy as np  # noqa: F401
        from cellpose_omni import models as omni_models
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] omnipose import failed: {exc!r}")
        emit_error(
            "omnipose-not-installed",
            hint="Open Models and install Omnipose — it needs its own Python "
                 "environment (python/venv_omni).",
            exit_code=2,
        )
        return

    img = cc.open_image_for_detection(args.image, channels, args)

    image_stats: dict = {}
    image_stats.update(cc.compute_qc_metrics(img))
    # Expose the calibration read from the image file's own metadata
    # (px/µm). Reported only — --pxPerUm still drives every measurement.
    image_stats.update(cc.detected_calibration_stats(args))

    height_px, width_px = int(img.shape[0]), int(img.shape[1])
    log(f"[cellpose_detect] image is {width_px}x{height_px} (ndim={img.ndim}); "
        f"omnipose model={model_name}; channels={channels}")

    import torch as _torch
    override_device, use_gpu_kw = cc.resolve_device(args, _torch)

    # --- Build the model ---------------------------------------------------
    def _build():
        kw = {"model_type": model_name, "omni": True}
        try:
            return omni_models.CellposeModel(gpu=use_gpu_kw, **kw)
        except TypeError:
            return omni_models.CellposeModel(**kw)

    try:
        model = _build()
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] model load failed: {exc!r}")
        emit_error("model-load-failed", hint=str(exc), exit_code=4)
        return

    if override_device is not None:
        try:
            if getattr(model, "net", None) is not None:
                model.net.to(override_device)
                try:
                    model.net.device = override_device
                except Exception:  # noqa: BLE001
                    pass
            try:
                model.device = override_device
            except Exception:  # noqa: BLE001
                pass
            try:
                model.mkldnn = False
            except Exception:  # noqa: BLE001
                pass
        except Exception as exc:  # noqa: BLE001
            log(f"[cellpose_detect] could not move model to {override_device}: {exc!r}")

    resolved_device = "cpu"
    try:
        if override_device is not None:
            resolved_device = str(override_device)
        elif getattr(model, "device", None) is not None:
            resolved_device = str(model.device)
    except Exception:  # noqa: BLE001
        pass
    log(f"[cellpose_detect] using device: {resolved_device} (torch {_torch.__version__})")

    # --- Evaluate ----------------------------------------------------------
    eval_kwargs = {
        "channels": channels,
        "omni": True,
        "mask_threshold": float(args.mask_threshold),
        "flow_threshold": float(args.flow_threshold),
        "resample": True,
        "cluster": bool(args.cluster),
        "verbose": False,
    }
    # Only pass a diameter when the user pinned one. Omnipose's whole point is
    # that elongated cells have no meaningful "diameter"; forcing the Cellpose
    # bin-derived prior in here would re-introduce the bug it exists to avoid.
    if args.diameter > 0:
        diam_px = max(5.0, float(args.diameter) * float(args.pxPerUm))
        eval_kwargs["diameter"] = diam_px
        log(f"[cellpose_detect] using explicit diameter={diam_px:.1f}px "
            f"({args.diameter:.1f}µm @ {args.pxPerUm}px/µm)")
    else:
        log("[cellpose_detect] no diameter prior (recommended for omni models)")

    log("[cellpose_detect] running eval ...")
    try:
        eval_out = _eval_with_degradation(model, img, eval_kwargs)
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] eval failed: {exc!r}")
        emit_error("eval-failed", hint=str(exc), exit_code=5)
        return

    masks = eval_out[0] if isinstance(eval_out, (tuple, list)) else eval_out
    flows = None
    if isinstance(eval_out, (tuple, list)) and len(eval_out) > 1:
        flows = eval_out[1]

    masks = cc.apply_watershed_if_requested(masks, args)
    image_stats.update(cc.compute_colony_stats(masks, args, height_px, width_px))

    cells = cc.measure_cells(masks, img, args, flows=flows)
    cc.emit_payload(width_px, height_px, cells, image_stats)


if __name__ == "__main__":
    main()
