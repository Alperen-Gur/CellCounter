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

Pass-24 (persistent worker): a second entry mode, ``--serve``, builds the
CellposeModel ONCE from the model-determining argv (model / gpu / device /
restore / channels), announces ``{"type":"ready"}`` on stdout, then services
NDJSON requests from stdin — each request carrying the PER-IMAGE params — and
replies with one framed ``{"type":"result",...}`` (or ``{"type":"error",...}``)
line per request. It reuses the *same* detection + measurement code as the
one-shot path (``run_detection_once``), so results are byte-for-byte identical
to the fallback. The original one-shot mode is preserved unchanged and remains
the Rust host's fallback when the worker path fails.
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any

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
        help="Explicit expected cell diameter in µm for the Cellpose size prior. "
             "0 (default) derives it from the size bins ((small+large)/2), "
             "decoupling the prior from the bins when set.",
    )
    parser.add_argument(
        "--serve", action="store_true",
        help="Persistent-worker mode: build the model ONCE from the "
             "model-determining args, print {\"type\":\"ready\"}, then service "
             "one NDJSON request per stdin line (each carrying per-image params) "
             "and reply with one framed JSON result line. Exits on stdin EOF. "
             "When omitted, runs the original one-shot detection on --image.",
    )
    # In serve mode --image is supplied per-request over stdin, not on argv, so
    # relax the parser's `required` on --image when --serve is present. argparse
    # has already been built by build_arg_parser(); we flip the flag here.
    if "--serve" in sys.argv:
        for action in parser._actions:
            if action.dest == "image":
                action.required = False
    return parser.parse_args()


def build_model(cp_models, model_type: str, args, torch_mod):
    """Construct the CellposeModel ONCE and move it to the resolved device.

    Shared by the one-shot path and the persistent-worker path — in serve mode
    this is called a single time, before the request loop, so the (expensive)
    weight load and device placement happen once for the whole batch.

    Returns ``(model, override_device)`` where ``override_device`` is the
    torch.device the net was moved to (or ``None`` for plain CPU). Raises on
    hard model-load failure; callers translate that into a structured error.
    """
    override_device, use_gpu_kw = cc.resolve_device(args, torch_mod)

    def _build(**extra_kw):
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

    if getattr(args, "restore", False):
        log("[cellpose_detect] enabling restore_type='denoise_cyto3'")
        try:
            model = _build(model_type=model_type, restore_type="denoise_cyto3")
        except TypeError:
            # Older cellpose builds don't accept restore_type on CellposeModel; degrade gracefully.
            log("[cellpose_detect] CellposeModel doesn't accept restore_type; "
                "falling back to plain model")
            model = _build(model_type=model_type)
    else:
        model = _build(model_type=model_type)

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
    log(f"[cellpose_detect] using device: {resolved_device} (torch {torch_mod.__version__})")

    return model, override_device


def run_detection_once(model, model_type: str, args, channels: list[int]) -> dict:
    """Run the full detect + measure flow for one image and return its payload.

    This is the single source of truth for detection: BOTH the one-shot mode
    and the persistent-worker mode call it, so a served result is identical to
    a one-shot result for the same params. It reuses ``model`` (already built)
    and reads the per-image params off ``args`` (image path, conf, pxPerUm,
    thresholds, bg-subtract, watershed, …).

    Returns a dict of the exact shape ``emit_payload`` writes:
        {"width", "height", "cells", "image_stats"}.
    On a recoverable eval failure it retries at half resolution (as before); on
    an unrecoverable failure it raises ``DetectionRunError`` so the caller can
    surface a structured ``eval-failed`` error without crashing the worker.
    """
    import numpy as np  # noqa: F401  — used by load_image_array / retry path

    # Open image, preprocess (bg-subtract etc.).
    img = cc.open_image_for_detection(args.image, channels, args)

    # QC metrics on the (now possibly preprocessed) array. These match the
    # contract that the Swift host reads from `image_stats` in the payload.
    image_stats: dict = {}
    image_stats.update(cc.compute_qc_metrics(img))

    height_px, width_px = int(img.shape[0]), int(img.shape[1])
    log(f"[cellpose_detect] image is {width_px}x{height_px} (ndim={img.ndim}); "
        f"model={model_type}; channels={channels}")

    # Pass-13: derive an explicit expected diameter (in pixels) from an explicit
    # user diameter when set, else the bin thresholds, and calibration. Without
    # this, cellpose 3.x runs its size predictor (size_cyto3.npy) to auto-estimate
    # diameter; that codepath has a known IndexError on larger images (e.g.
    # 2880x2048). Passing an explicit `diameter` skips the size predictor entirely.
    if args.diameter > 0:
        expected_diam_um = float(args.diameter)
        diam_source = f"user diameter {expected_diam_um:g}µm"
    else:
        expected_diam_um = (float(args.small_threshold) + float(args.large_threshold)) / 2.0
        diam_source = f"bins {args.small_threshold}-{args.large_threshold}µm"
    expected_diam_px = max(15.0, expected_diam_um * float(args.pxPerUm))
    log(f"[cellpose_detect] using fixed diameter={expected_diam_px:.1f}px "
        f"(from {diam_source} @ {args.pxPerUm}px/µm)")

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

            # Also upsample the cellprob map (flows[2]) so measure_cells can
            # still read per-cell confidence. Without this, flows[2] stays at
            # half resolution, the `candidate.shape == masks.shape` guard in
            # measure_cells fails, and every cell falls back to the flat 0.85
            # default confidence. Bilinear preserves the continuous prob field.
            flows_small = eval_out[1] if len(eval_out) > 1 else None
            if flows_small is not None:
                try:
                    cellprob_small = flows_small[2]
                    if (hasattr(cellprob_small, "shape")
                            and cellprob_small.shape == masks_small.shape):
                        cellprob_full = _np.array(
                            _PILImage.fromarray(
                                cellprob_small.astype(_np.float32)).resize(
                                (img.shape[1], img.shape[0]),
                                _PILImage.BILINEAR),
                            dtype=_np.float32)
                        flows_full = list(flows_small)
                        flows_full[2] = cellprob_full
                        eval_out = ((masks_full, flows_full)
                                    + tuple(eval_out[2:]))
                except Exception as exc3:  # noqa: BLE001
                    log("[cellpose_detect] could not upsample cellprob map; "
                        f"per-cell confidence unavailable: {exc3!r}")
            log("[cellpose_detect] half-resolution retry succeeded")
        except Exception as exc2:  # noqa: BLE001
            log(f"[cellpose_detect] half-resolution retry also failed: {exc2!r}")
            raise DetectionRunError(
                "eval-failed",
                hint=f"{exc!r} (half-res retry: {exc2!r})",
            ) from exc2

    masks = eval_out[0]
    flows = eval_out[1] if len(eval_out) > 1 else None

    # A3: optional distance-transform watershed split (between detect + measure).
    masks = cc.apply_watershed_if_requested(masks, args)

    # C2: per-image colony + spatial statistics.
    image_stats.update(cc.compute_colony_stats(masks, args, height_px, width_px))

    # Per-cell measurement loop.
    cells = cc.measure_cells(masks, img, args, flows=flows)

    return {
        "width": width_px,
        "height": height_px,
        "cells": cells,
        "image_stats": image_stats,
    }


class DetectionRunError(Exception):
    """Recoverable per-image failure carrying a structured error + hint.

    In one-shot mode the caller turns this into ``emit_error(...)`` + exit; in
    serve mode it becomes a framed ``{"type":"error",...}`` line and the worker
    keeps running for the next request.
    """

    def __init__(self, error: str, hint: str = ""):
        super().__init__(error)
        self.error = error
        self.hint = hint


# ---------------------------------------------------------------------------
# Serve mode — build the model once, then service NDJSON requests over stdin.
# ---------------------------------------------------------------------------

# The per-image request keys the Rust host may send. Anything present overrides
# the argv-parsed default on a shallow copy of the base Namespace; anything
# absent keeps the argv value. Model-determining keys (model/gpu/device/restore/
# channels) are intentionally NOT here — they are fixed at model-build time and
# the host keys its worker pool by them.
_PER_IMAGE_KEYS = (
    "image",
    "conf",
    "pxPerUm",
    "small_threshold",
    "large_threshold",
    "diameter",
    "bg_subtract",
    "rolling_ball_radius",
    "watershed",
    "watershed_min_distance",
)


def _merge_request_args(base_args, request: dict):
    """Return a shallow copy of *base_args* with per-image request fields applied.

    Uses ``argparse.Namespace`` semantics: we copy the base namespace (so the
    model-determining fields survive) and overwrite only the per-image keys the
    request supplies. Missing keys fall back to the argv defaults.
    """
    import argparse
    merged = argparse.Namespace(**vars(base_args))
    for key in _PER_IMAGE_KEYS:
        if key in request and request[key] is not None:
            setattr(merged, key, request[key])
    return merged


def _write_frame(obj: dict) -> None:
    """Write one NDJSON frame to stdout and flush (worker protocol)."""
    sys.stdout.write(json.dumps(obj))
    sys.stdout.write("\n")
    sys.stdout.flush()


class _EmitErrorShield:
    """Context manager that neutralises ``cc.emit_error`` for a served request.

    The shared helpers in ``_cellpose_common`` (e.g. ``open_image_for_detection``
    on a bad file) signal fatal errors by calling ``emit_error``, which writes a
    RAW ``{"error":…}`` object to stdout (no ``type``/``id`` frame, no trailing
    newline) and then ``sys.exit()``. Inside the persistent worker BOTH of those
    are wrong: the raw write corrupts the NDJSON result stream, and the
    ``SystemExit`` (a ``BaseException``, so it slips past ``except Exception``)
    would kill the worker on a single bad image.

    We can't edit ``_cellpose_common``, so for the duration of a request we swap
    ``cc.emit_error`` for a shim that raises ``DetectionRunError`` instead —
    which the request loop catches and reframes as a proper ``{"type":"error"}``
    line, keeping the worker alive and the stream clean. The original is always
    restored on exit. (``open_image_for_detection`` resolves ``emit_error`` as a
    module global at call time, so rebinding ``cc.emit_error`` intercepts it.)
    """

    def __enter__(self):
        self._orig = cc.emit_error

        def _raise_instead(error, hint="", exit_code=2):
            raise DetectionRunError(error, hint=hint)

        cc.emit_error = _raise_instead
        return self

    def __exit__(self, exc_type, exc, tb):
        cc.emit_error = self._orig
        return False  # never suppress


def serve(base_args, channels: list[int]) -> None:
    """Persistent-worker loop.

    Build the model once, announce readiness, then loop over stdin lines. Each
    line is one NDJSON request ``{"id":…, <per-image params>}``. We reply with
    exactly one framed line per request and never crash the worker on a single
    bad image — a failed request yields ``{"type":"error",...}`` and the loop
    continues. Exits cleanly on stdin EOF.

    Human-readable progress continues to go to STDERR exactly as in one-shot
    mode, so the host's stderr progress pump is unchanged.
    """
    # Lazy imports mirror one-shot main() so an import failure emits a
    # structured error instead of a bare traceback. In serve mode the failure
    # is fatal (we cannot build a model), so we exit like the one-shot path.
    try:
        import numpy as np  # noqa: F401
        from cellpose import models as cp_models
        import torch as _torch
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] import failed: {exc!r}")
        emit_error("cellpose-not-installed",
                   hint="Run scripts/install_python.sh",
                   exit_code=2)
        return

    # Map any app-level "cp-*" alias down to the canonical cellpose name.
    model_type = base_args.model
    if model_type.startswith("cp-"):
        model_type = model_type[3:]

    try:
        model, _override_device = build_model(cp_models, model_type, base_args, _torch)
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] model load failed: {exc!r}")
        emit_error("model-load-failed", hint=str(exc), exit_code=4)
        return

    log(f"[cellpose_detect] serve mode ready; model={model_type}; channels={channels}")
    # Readiness handshake — the host blocks on this exact line before it starts
    # writing requests. Keep it a bare object on its own line.
    _write_frame({"type": "ready"})

    # Request loop. Use readline() rather than `for line in sys.stdin`: the
    # iterator form buffers read-ahead and can withhold a single already-written
    # line until its buffer fills, which would deadlock this request/response
    # protocol (host waits for the result; worker waits for more input).
    # readline() returns as soon as it sees a newline; "" means EOF.
    while True:
        raw_line = sys.stdin.readline()
        if raw_line == "":
            break  # stdin EOF — clean shutdown
        line = raw_line.strip()
        if not line:
            continue
        req_id: Any = None
        try:
            request = json.loads(line)
            req_id = request.get("id")
        except Exception as exc:  # noqa: BLE001
            # Un-parseable request line: we may not even know the id. Report and
            # keep serving so one malformed line doesn't kill the batch.
            log(f"[cellpose_detect] serve: bad request line: {exc!r}")
            _write_frame({
                "type": "error",
                "id": req_id,
                "error": "bad-request",
                "hint": f"could not parse request JSON: {exc!r}",
            })
            continue

        try:
            merged = _merge_request_args(base_args, request)
            if not getattr(merged, "image", None):
                raise DetectionRunError("bad-request", hint="missing 'image' in request")
            # Shield the shared helpers' emit_error() so a bad image raises
            # DetectionRunError (caught below) instead of writing a raw
            # unframed error to stdout and SystemExit-ing the worker.
            with _EmitErrorShield():
                payload = run_detection_once(model, model_type, merged, channels)
            _write_frame({"type": "result", "id": req_id, "payload": payload})
        except DetectionRunError as exc:
            log(f"[cellpose_detect] serve: request {req_id} failed: {exc.error} ({exc.hint})")
            _write_frame({
                "type": "error",
                "id": req_id,
                "error": exc.error,
                "hint": exc.hint,
            })
        except SystemExit as exc:
            # Belt-and-suspenders: if any code path still reaches sys.exit()
            # despite the shield, reframe it rather than let the worker die.
            # (SystemExit is a BaseException, so `except Exception` misses it.)
            log(f"[cellpose_detect] serve: request {req_id} raised SystemExit "
                f"(code={exc.code!r}); reframing and continuing")
            _write_frame({
                "type": "error",
                "id": req_id,
                "error": "detect-failed",
                "hint": f"sidecar attempted to exit (code={exc.code!r}); worker kept alive",
            })
        except Exception as exc:  # noqa: BLE001
            # Any other per-image error (decode failure, OOM, cellpose bug, …)
            # must NOT crash the worker — reframe and keep serving.
            log(f"[cellpose_detect] serve: request {req_id} unexpected error: {exc!r}")
            _write_frame({
                "type": "error",
                "id": req_id,
                "error": "detect-failed",
                "hint": repr(exc),
            })

    log("[cellpose_detect] serve: stdin EOF — exiting cleanly")


def main() -> None:
    args = parse_args()
    channels = cc.parse_channels(args.channels)

    # Persistent-worker mode: hand off to the serve loop, which builds the model
    # once and services NDJSON requests. The one-shot path below is untouched
    # and remains the host's fallback.
    if getattr(args, "serve", False):
        serve(args, channels)
        return

    # Lazy imports — so the import-error branch can emit a structured error
    # without crashing on bare ImportError.
    try:
        import numpy as np  # noqa: F401  — used by load_image_array
        from cellpose import models as cp_models
        import torch as _torch
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

    try:
        model, _override_device = build_model(cp_models, model_type, args, _torch)
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] model load failed: {exc!r}")
        emit_error("model-load-failed", hint=str(exc), exit_code=4)
        return

    try:
        payload = run_detection_once(model, model_type, args, channels)
    except DetectionRunError as exc:
        emit_error(exc.error, hint=exc.hint, exit_code=5)
        return

    # One-shot emission stays byte-for-byte identical to before: a single
    # `json.dumps(payload)` with no trailing newline (emit_payload's contract).
    cc.emit_payload(
        payload["width"], payload["height"],
        payload["cells"], payload["image_stats"],
    )


if __name__ == "__main__":
    main()
