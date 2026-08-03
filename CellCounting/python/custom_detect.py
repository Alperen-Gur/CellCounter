#!/usr/bin/env python3
"""
custom_detect.py — CellCounter sidecar for user-supplied ("bring your own")
models.

A lab that has already fine-tuned a segmentation model should not have to
re-train inside CellCounter to use it. This sidecar loads a model from an
absolute path on disk and runs it through the identical measurement +
JSON-emission path as the built-in detectors, so a custom model's results are
directly comparable with (and exportable alongside) everything else.

Two kinds are supported:

  --custom-kind cellpose
      `--model` is the path to a Cellpose checkpoint FILE (the artefact
      `cellpose train`/`model.train()` writes into `models/`, e.g.
      `CP_20240612_143210`). Loaded as:

          CellposeModel(pretrained_model='/abs/path')

  --custom-kind stardist
      `--model` is the path to a StarDist model DIRECTORY — the folder that
      contains `config.json` plus `weights_best.h5` (or `weights_last.h5` /
      a `.keras` file). Loaded as:

          StarDist2D(None, name=<basename>, basedir=<parent dir>)

Validation happens on BOTH sides. The Swift host
(`CustomModelDetectionService`) refuses to launch when the path no longer
looks like a model, and this script re-checks before importing anything heavy
so a path that went stale between registration and run produces a clear
`custom-model-invalid` error instead of a framework stack trace.

Stdout contract: see `_cellpose_common.emit_payload` — byte-for-byte identical
to the Cellpose sidecars. All logging goes to stderr.

CLI: the full shared flag set plus `--custom-kind`, `--prob-thresh`,
`--nms-thresh`, `--diameter`.
"""

from __future__ import annotations

import contextlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _cellpose_common as cc  # noqa: E402
from _cellpose_common import log, emit_error  # noqa: E402


# A StarDist model directory always carries a config.json; the weights file
# name varies by how the model was saved.
_STARDIST_WEIGHT_NAMES = (
    "weights_best.h5",
    "weights_last.h5",
    "weights_now.h5",
    "weights.h5",
)


def parse_args():
    parser = cc.build_arg_parser(
        description="Custom (user-supplied) model detection sidecar for CellCounter",
        default_model="",
    )
    parser.add_argument(
        "--custom-kind", dest="custom_kind", required=True,
        choices=("cellpose", "stardist"),
        help="Which framework loads --model. 'cellpose' expects a checkpoint "
             "file; 'stardist' expects a model directory.",
    )
    parser.add_argument(
        "--prob-thresh", dest="prob_thresh", type=float, default=0.5,
        help="StarDist prob_thresh (custom-kind stardist only). Default 0.5.",
    )
    parser.add_argument(
        "--nms-thresh", dest="nms_thresh", type=float, default=0.4,
        help="StarDist nms_thresh (custom-kind stardist only). Default 0.4.",
    )
    parser.add_argument(
        "--diameter", type=float, default=0.0,
        help="Explicit expected cell diameter in micrometers (Cellpose only). "
             "Default 0 = derive the prior from the size bins, matching "
             "cellpose_detect.py.",
    )
    return parser.parse_args()


def validate_path(path: str, kind: str) -> str | None:
    """Return an error string when `path` isn't a plausible model, else None.

    Deliberately mirrors `CustomModelStore.validate` on the Swift side. Keeping
    both is not redundancy for its own sake: the Swift check gives the user an
    immediate answer in the picker, and this one catches a model that was moved
    or deleted after it was registered.
    """
    if not path:
        return "no model path was supplied"
    if kind == "cellpose":
        if not os.path.exists(path):
            return f"no file at {path}"
        if os.path.isdir(path):
            return (f"{path} is a directory; a Cellpose custom model is a "
                    "single checkpoint file")
        if os.path.getsize(path) < 1024:
            return (f"{path} is only {os.path.getsize(path)} bytes — that is "
                    "not a Cellpose checkpoint")
        return None
    # stardist
    if not os.path.isdir(path):
        return (f"{path} is not a directory; a StarDist model is the folder "
                "containing config.json and the weights file")
    if not os.path.isfile(os.path.join(path, "config.json")):
        return f"{path} has no config.json — not a StarDist model directory"
    has_weights = any(
        os.path.isfile(os.path.join(path, name)) for name in _STARDIST_WEIGHT_NAMES
    )
    if not has_weights:
        try:
            has_weights = any(
                entry.endswith((".h5", ".keras"))
                for entry in os.listdir(path)
            )
        except OSError:
            has_weights = False
    if not has_weights:
        return (f"{path} has config.json but no weights file "
                "(weights_best.h5 / weights_last.h5 / *.keras)")
    return None


# ---------------------------------------------------------------------------
# Cellpose branch
# ---------------------------------------------------------------------------

def run_cellpose(args, channels) -> None:
    try:
        import numpy as np  # noqa: F401
        from cellpose import models as cp_models
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] cellpose import failed: {exc!r}")
        emit_error("cellpose-not-installed",
                   hint="Run scripts/install_python.sh",
                   exit_code=2)
        return

    img = cc.open_image_for_detection(args.image, channels, args)
    image_stats: dict = {}
    image_stats.update(cc.compute_qc_metrics(img))
    # Expose the calibration read from the image file's own metadata
    # (px/µm). Reported only — --pxPerUm still drives every measurement.
    image_stats.update(cc.detected_calibration_stats(args))
    height_px, width_px = int(img.shape[0]), int(img.shape[1])
    log(f"[cellpose_detect] image is {width_px}x{height_px}; "
        f"custom cellpose checkpoint={args.model}")

    import torch as _torch
    override_device, use_gpu_kw = cc.resolve_device(args, _torch)

    try:
        try:
            model = cp_models.CellposeModel(gpu=use_gpu_kw,
                                            pretrained_model=args.model)
        except TypeError:
            model = cp_models.CellposeModel(pretrained_model=args.model)
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] custom checkpoint load failed: {exc!r}")
        emit_error(
            "custom-model-load-failed",
            hint=f"Cellpose could not load {args.model}: {exc}",
            exit_code=4,
        )
        return

    if override_device is not None:
        try:
            if getattr(model, "net", None) is not None:
                model.net.to(override_device)
            try:
                model.device = override_device
            except Exception:  # noqa: BLE001
                pass
        except Exception as exc:  # noqa: BLE001
            log(f"[cellpose_detect] could not move model to {override_device}: {exc!r}")

    resolved_device = str(override_device) if override_device is not None else "cpu"
    log(f"[cellpose_detect] using device: {resolved_device} (torch {_torch.__version__})")

    # Same diameter policy as cellpose_detect.py: an explicit --diameter wins,
    # otherwise fall back to the midpoint of the size bins. A fine-tuned model
    # usually carries its own trained diameter, but Cellpose still needs a
    # pixel value here to skip the size predictor (which IndexErrors on large
    # images).
    if args.diameter > 0:
        expected_diam_um = float(args.diameter)
        source = f"explicit --diameter={expected_diam_um:.2f}µm"
    else:
        expected_diam_um = (float(args.small_threshold) + float(args.large_threshold)) / 2.0
        source = f"bins {args.small_threshold}-{args.large_threshold}µm"
    expected_diam_px = max(15.0, expected_diam_um * float(args.pxPerUm))
    log(f"[cellpose_detect] using fixed diameter={expected_diam_px:.1f}px (from {source})")

    log("[cellpose_detect] running eval ...")
    try:
        try:
            eval_out = model.eval(img, diameter=expected_diam_px, channels=channels)
        except TypeError:
            # cellpose 4.x dropped the `channels=` kwarg.
            log("[cellpose_detect] eval() rejected channels=; retrying without it")
            eval_out = model.eval(img, diameter=expected_diam_px)
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] eval failed: {exc!r}")
        emit_error("eval-failed", hint=str(exc), exit_code=5)
        return

    masks = eval_out[0]
    flows = eval_out[1] if len(eval_out) > 1 else None

    masks = cc.apply_watershed_if_requested(masks, args)
    image_stats.update(cc.compute_colony_stats(masks, args, height_px, width_px))
    cells = cc.measure_cells(masks, img, args, flows=flows)
    cc.emit_payload(width_px, height_px, cells, image_stats)


# ---------------------------------------------------------------------------
# StarDist branch
# ---------------------------------------------------------------------------

def run_stardist(args, channels) -> None:
    try:
        import numpy as np
        from csbdeep.utils import normalize
        from stardist.models import StarDist2D
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] stardist import failed: {exc!r}")
        emit_error(
            "stardist-not-installed",
            hint="Install a StarDist model from the Models tab first — that "
                 "pulls in stardist + tensorflow, which a custom StarDist "
                 "model also needs.",
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

    basedir = os.path.dirname(os.path.abspath(args.model.rstrip(os.sep)))
    name = os.path.basename(os.path.abspath(args.model.rstrip(os.sep)))
    log(f"[cellpose_detect] image is {width_px}x{height_px}; "
        f"custom stardist model name={name} basedir={basedir}")
    log("[cellpose_detect] using device: cpu/tf-managed (TensorFlow selects its own)")

    # csbdeep/stardist print straight to STDOUT with bare `print()` calls —
    # "Loading network weights from 'weights_best.h5'." and "Loading thresholds
    # from 'thresholds.json'." — which lands in the middle of this sidecar's
    # JSON protocol and made EVERY custom-StarDist run fail to decode. stdout
    # belongs to the payload; everything the library says goes to stderr with
    # the rest of the log.
    try:
        with contextlib.redirect_stdout(sys.stderr):
            model = StarDist2D(None, name=name, basedir=basedir)
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] custom StarDist load failed: {exc!r}")
        emit_error(
            "custom-model-load-failed",
            hint=f"StarDist could not load {args.model}: {exc}",
            exit_code=4,
        )
        return

    # StarDist wants float input; a 3-channel model gets RGB, everything else
    # gets luminance. `config.n_channel_in` tells us which without guessing.
    n_channel_in = 1
    try:
        n_channel_in = int(getattr(model.config, "n_channel_in", 1))
    except Exception:  # noqa: BLE001
        pass
    arr = img.astype(np.float32)
    if n_channel_in >= 3 and arr.ndim == 2:
        arr = np.stack([arr, arr, arr], axis=-1)
    elif n_channel_in == 1 and arr.ndim == 3:
        arr = arr.mean(axis=2)
    log(f"[cellpose_detect] model expects n_channel_in={n_channel_in}; "
        f"input ndim={arr.ndim}")

    try:
        arr_n = normalize(arr, 1, 99.8)
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] normalize failed: {exc!r}")
        emit_error("image-normalize-failed", hint=str(exc), exit_code=3)
        return

    log("[cellpose_detect] running predict_instances ...")
    try:
        # Same stdout guard as the model load above — predict_instances prints
        # a progress bar / tiling notes on some stardist builds.
        with contextlib.redirect_stdout(sys.stderr):
            labels, _details = model.predict_instances(
                arr_n,
                prob_thresh=float(args.prob_thresh),
                nms_thresh=float(args.nms_thresh),
            )
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] predict_instances failed: {exc!r}")
        emit_error("eval-failed", hint=str(exc), exit_code=5)
        return

    labels = cc.apply_watershed_if_requested(labels, args)
    image_stats.update(cc.compute_colony_stats(labels, args, height_px, width_px))
    # `measure_cells` measures intensity against the ORIGINAL (unnormalised)
    # array so mean_intensity stays in the image's own units, matching every
    # other detector.
    cells = cc.measure_cells(labels, img, args, flows=None)
    cc.emit_payload(width_px, height_px, cells, image_stats)


def main() -> None:
    args = parse_args()
    channels = cc.parse_channels(args.channels)

    problem = validate_path(args.model, args.custom_kind)
    if problem is not None:
        log(f"[cellpose_detect] custom model rejected: {problem}")
        emit_error(
            "custom-model-invalid",
            hint=problem,
            exit_code=6,
        )
        return

    if args.custom_kind == "cellpose":
        run_cellpose(args, channels)
    else:
        run_stardist(args, channels)


if __name__ == "__main__":
    main()
