#!/usr/bin/env python3
"""
omnipose_detect.py — CellCounter sidecar for Omnipose.

Omnipose (Cutler et al., Nature Methods 2022) uses a distance-field
formulation and configurable mask reconstruction. Its published cyto2 model
is an alternative for irregular eukaryotic shapes; suitability depends on
the image modality, scale and training data. MIT licensed.

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
import contextlib
import math
import shutil
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _cellpose_common as cc  # noqa: E402
from _cellpose_common import log, emit_error  # noqa: E402


# Published 2D checkpoints only. The plant model is volumetric and cannot
# be used by this sidecar's 2D image/measurement contract.
# https://omnipose.readthedocs.io/models.html
_MODEL_MAP = {
    "omni-bact-phase": "bact_phase_omni",
    "omni-bact-fluor": "bact_fluor_omni",
    "omni-cyto2": "cyto2_omni",
    "omni-worm": "worm_omni",
}

_KNOWN_NAMES = set(_MODEL_MAP.values())


def resolve_model_name(raw: str) -> str:
    if raw in _MODEL_MAP:
        return _MODEL_MAP[raw]
    if raw in _KNOWN_NAMES:
        return raw
    raise ValueError(f"Unknown 2D Omnipose model: {raw}")


def parse_args(argv=None):
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
        help="Omnipose flow_threshold. 0 disables flow error filtering; "
             "positive values set the maximum accepted flow error.",
    )
    parser.add_argument(
        "--cluster", action="store_true",
        help="Enable Omnipose's clustering reconstruction for thin regions. "
             "May merge neighboring cells with poorly defined flows.",
    )
    parser.add_argument(
        "--diameter", type=float, default=0.0,
        help="Expected cell diameter in micrometers for image rescaling. "
             "0 (default) retains the acquired image scale; this sidecar "
             "does not run Omnipose's separate size estimator.",
    )
    return parser.parse_args(argv)


def build_eval_kwargs(args, channels):
    """Keep requested reconstruction inputs intact, or reject them.

    Unsupported runtime arguments must fail visibly, since dropping omni,
    channels or thresholds would silently change the analysis being saved.
    https://omnipose.readthedocs.io/api/api/cellpose_omni.models.CellposeModel.html
    """
    if not math.isfinite(args.mask_threshold):
        raise ValueError("Omnipose mask threshold must be finite.")
    if not math.isfinite(args.flow_threshold) or args.flow_threshold < 0:
        raise ValueError("Omnipose flow threshold must be zero (off) or positive.")
    if not math.isfinite(args.diameter) or args.diameter < 0:
        raise ValueError("Expected diameter must be zero or positive.")
    if not math.isfinite(args.pxPerUm) or args.pxPerUm <= 0:
        raise ValueError("Pixels per micrometer must be positive.")
    diameter_px = float(args.diameter) * float(args.pxPerUm)
    if not math.isfinite(diameter_px):
        raise ValueError("Expected diameter in pixels must be finite.")
    return {
        "channels": channels,
        "omni": True,
        "mask_threshold": float(args.mask_threshold),
        "flow_threshold": float(args.flow_threshold),
        "resample": True,
        "cluster": bool(args.cluster),
        "verbose": False,
        "diameter": diameter_px,
    }


def configure_model_cache(model_name):
    """Match the Swift inventory path without losing existing checkpoints.

    cellpose_omni otherwise defaults to ~/.cellpose/models, which the base
    Cellpose runtime also owns. Reuse only the exact published Omnipose
    checkpoint filename, without moving or deleting the user's cached copy.
    """
    cache = os.path.join(os.path.expanduser("~"), ".cellpose_omni", "models")
    os.environ["CELLPOSE_LOCAL_MODELS_PATH"] = cache
    basename = f"{model_name}torch_0"
    previous = os.path.join(os.path.expanduser("~"), ".cellpose", "models", basename)
    destination = os.path.join(cache, basename)
    if os.path.isfile(destination) or not os.path.isfile(previous):
        return
    temporary = None
    try:
        if os.path.getsize(previous) == 0:
            return
        os.makedirs(cache, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=cache, prefix=".cc-import-", delete=False) as handle:
            temporary = handle.name
        shutil.copyfile(previous, temporary)
        os.replace(temporary, destination)
        temporary = None
        log(f"[cellpose_detect] reused cached Omnipose checkpoint {basename}")
    except OSError as exc:
        log(f"[cellpose_detect] could not reuse cached checkpoint: {exc!r}")
    finally:
        if temporary is not None:
            with contextlib.suppress(OSError):
                os.unlink(temporary)


def main() -> None:
    args = parse_args()
    channels = cc.parse_channels(args.channels)
    try:
        model_name = resolve_model_name(args.model)
        eval_kwargs = build_eval_kwargs(args, channels)
    except ValueError as exc:
        emit_error("invalid-model-settings", hint=str(exc), exit_code=2)
        return
    configure_model_cache(model_name)

    # Lazy imports so the not-installed branch can emit a structured error.
    try:
        import numpy as np  # noqa: F401
        # The fork prints download paths and import notices to stdout.
        # Keep those off the host's JSON-only result channel.
        with contextlib.redirect_stdout(sys.stderr):
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

    if model_name not in getattr(omni_models, "MODEL_NAMES", []):
        emit_error("unsupported-model", hint=f"The installed Omnipose runtime does not provide {model_name}. Reinstall Omnipose in Models.", exit_code=4)
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
    try:
        with contextlib.redirect_stdout(sys.stderr):
            model = omni_models.CellposeModel(
                gpu=use_gpu_kw, model_type=model_name, omni=True,
                nchan=2, nclasses=3, dim=2,
            )
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
    if args.diameter > 0:
        diam_px = eval_kwargs["diameter"]
        log(f"[cellpose_detect] using explicit diameter={diam_px:.1f}px "
            f"({args.diameter:.1f}µm @ {args.pxPerUm}px/µm)")
    else:
        log("[cellpose_detect] diameter rescaling off; using acquired image scale")

    log(f"[cellpose_detect] Omnipose reconstruction: mask_threshold={args.mask_threshold:g}, "
        f"flow_threshold={args.flow_threshold:g}, cluster={args.cluster}")

    log("[cellpose_detect] running eval ...")
    try:
        with contextlib.redirect_stdout(sys.stderr):
            eval_out = model.eval(img, **eval_kwargs)
    except TypeError as exc:
        log(f"[cellpose_detect] Omnipose runtime rejected requested parameters: {exc!r}")
        emit_error("incompatible-runtime", hint=f"Omnipose could not honor the requested reconstruction settings: {exc}. Reinstall Omnipose in Models.", exit_code=5)
        return
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] eval failed: {exc!r}")
        emit_error("eval-failed", hint=str(exc), exit_code=5)
        return

    masks = eval_out[0] if isinstance(eval_out, (tuple, list)) else eval_out
    flows = None
    if isinstance(eval_out, (tuple, list)) and len(eval_out) > 1:
        flows = eval_out[1]

    masks = cc.apply_watershed_if_requested(masks, args)
    image_stats.update({
        "omnipose_mask_threshold": float(args.mask_threshold),
        "omnipose_flow_threshold": float(args.flow_threshold),
        "omnipose_cluster": float(args.cluster),
        "omnipose_diameter_px": eval_kwargs["diameter"],
    })
    image_stats.update(cc.compute_colony_stats(masks, args, height_px, width_px))

    cells = cc.measure_cells(masks, img, args, flows=flows)
    cc.emit_payload(width_px, height_px, cells, image_stats)


if __name__ == "__main__":
    main()
