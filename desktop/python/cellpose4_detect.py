#!/usr/bin/env python3
"""
cellpose4_detect.py — CellCounter sidecar for **cellpose 4.x (CPSAM)**, desktop.

The cross-platform (Tauri/Rust host) sibling of this app's 3.x sidecar
``cellpose_detect.py``. It obeys the *same* stdout JSON contract AND the *same*
CLI + persistent-worker (``--serve``) protocol, so the Rust backend reuses its
existing ``build_argv`` / ``build_serve_argv`` / per-image request JSON
UNCHANGED and merely points them at this script when the active model is
Cellpose-SAM. Shared post-processing (arg parsing, image load, QC, watershed,
colony stats, per-cell measurement, JSON emission, and the ``[cellpose_detect]``
stderr progress prefix) all comes from ``_cellpose_common.py`` exactly as the
3.x sidecar uses it — so the emitted per-cell JSON (circularity / aspect_ratio /
solidity …) and the payload envelope are byte-for-byte the same contract.

Stdout contract (shared with cellpose_detect.py — see _cellpose_common.py):
  {
    "width":  <int>,
    "height": <int>,
    "cells":  [ {id, cx, cy, diameter_um, …}, … ],
    "image_stats": { focus_score, illumination_residual, n_colonies, … }
  }

If cellpose (or one of its deps) is not importable, prints
  {"error": "cellpose-not-installed", "hint": "Run scripts/install_python.sh"}
to stdout and exits with code 2 — identical to the 3.x sidecar.

CLI parity with cellpose_detect.py (what the Rust host may emit):
  * Every shared flag from ``_cellpose_common.build_arg_parser``.
  * ``--diameter <um>`` — explicit size prior; > 0 is honoured, 0/absent = Auto.
  * ``--serve`` — persistent-worker mode (build model once, NDJSON over stdin).
  * ``--restore`` — ACCEPTED for byte-for-byte CLI parity with the 3.x sidecar,
    but PARSED-AND-IGNORED: cellpose 4 has no restore/denoise model.

What differs from the 3.x sidecar (the v4-specific bits this file owns; mirrors
CellCounting/python/cellpose4_detect.py, the native macOS CPSAM sidecar):

  1. ``model_type=`` is ignored by cellpose 4; only ``pretrained_model=`` is
     honoured. App-level aliases (``cp4-``/``cellpose4-``/``cellpose-``/``cp-``)
     are stripped and any 3.x model name (``cyto3``/``cyto2``/``nuclei``/
     ``cyto``) is mapped to ``cpsam``.
  2. First ``CellposeModel(pretrained_model="cpsam")`` downloads ~1.15 GB of
     weights from https://huggingface.co/mouseland/cellpose-sam/resolve/main/
     into ~/.cellpose/models/ via urllib+tqdm (not torch.hub). We monkey-patch
     tqdm so that download streams to stderr in the ``[cellpose_detect]`` format
     the ccDetectionStage UI parses (shown as install/download progress).
  3. No size predictor exists: v4's ``diameter`` is only a resize hint (None =
     "don't resize"), so we still compute an explicit diameter prior from the
     user's ``--diameter`` or the size-class bins. There is NO half-resolution
     retry — the 3.x size-predictor IndexError it guarded against cannot occur.
  4. ``model.eval(img, diameter=…)`` is called WITHOUT ``channels=`` (v4 infers
     channels from the array shape); on ``TypeError`` we retry WITH ``channels=``
     as a courtesy for an older 4.0 release. eval returns three values
     (masks, flows, styles); flows[2] is still cellprob (same index as 3.x).

Like the 3.x sidecar, ``--serve`` builds the CPSAM model ONCE from the
model-determining argv, announces ``{"type":"ready"}`` on stdout, then services
one NDJSON request per stdin line (each carrying the per-image params) via the
*same* ``run_detection_once`` the one-shot path uses — so a served result is
byte-for-byte identical to a one-shot result. The one-shot mode is preserved and
remains the Rust host's fallback when the worker path fails.
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


# ---------------------------------------------------------------------------
# tqdm patch — bridge cellpose's weight-download progress to our stderr UI.
# ---------------------------------------------------------------------------

def install_tqdm_progress_bridge() -> None:
    """Patch tqdm so the lazy CPSAM weight download reports to stderr.

    cellpose 4's ``CellposeModel(pretrained_model="cpsam")`` fetches ~1.15 GB of
    weights on first construction via ``download_url_to_file(url, dst,
    progress=True)`` (urllib + tqdm), not torch.hub. We patch the class-level
    tqdm methods so the *byte* progress bar streams to stderr in our
    ``[cellpose_detect]`` format, which the ccDetectionStage UI parses and shows
    as first-run install/download progress. Non-byte bars (e.g. segmentation
    tiling) are left alone.
    """
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
    """Build the shared parser, then add the v4 flags.

    The flag surface is IDENTICAL to ``cellpose_detect.py`` so the Rust host's
    ``build_argv`` / ``build_serve_argv`` work unchanged: ``--restore`` is
    accepted (but ignored — v4 has no restore model), ``--diameter`` is the
    explicit size prior, and ``--serve`` selects the persistent-worker mode.
    """
    parser = cc.build_arg_parser(
        description="Cellpose 4 (CPSAM) detection sidecar for CellCounter",
        default_model="cpsam",
    )
    parser.add_argument(
        "--restore", action="store_true",
        help="Accepted for CLI parity with the 3.x sidecar; cellpose 4 has no "
             "restore/denoise model, so this flag is parsed and IGNORED.",
    )
    parser.add_argument(
        "--diameter", type=float, default=0.0,
        help="Explicit expected cell diameter in µm for the Cellpose-SAM size "
             "prior. 0 (default) derives it from the size bins "
             "((small+large)/2); a value > 0 overrides the bins.",
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


def _resolve_model_name(raw_model: str) -> str:
    """Map an app-level model id to the bare cellpose 4 ``pretrained_model``.

    The Rust host only strips a leading ``cp-`` before emitting ``--model``, so a
    ``cp4-cpsam`` / ``cellpose4-cpsam`` id still arrives here intact. Strip any of
    the known app prefixes, then map any 3.x model name to ``cpsam`` (cellpose 4
    ignores ``model_type=`` and only honours ``pretrained_model=``).
    """
    model_name = raw_model
    for prefix in ("cp4-", "cellpose4-", "cellpose-", "cp-"):
        if model_name.startswith(prefix):
            model_name = model_name[len(prefix):]
            break
    if model_name in ("cyto3", "cyto2", "nuclei", "cyto"):
        log(f"[cellpose_detect] '{model_name}' is a cellpose 3 model name; "
            "using 'cpsam' (the v4 default).")
        model_name = "cpsam"
    return model_name


def _warn_if_not_v4() -> None:
    """Log the cellpose version and warn if it is not 4.x (never raises).

    Purely informational stderr output — refuses nothing, but surfaces a clear
    warning if this sidecar was pointed at a 3.x venv (model construction would
    then fall back to the v3 API path). Mirrors the native v4 sidecar.
    """
    try:
        import cellpose as _cp_pkg
        cp_ver = getattr(_cp_pkg, "version", "unknown")
        log(f"[cellpose_detect] cellpose version: {cp_ver}")
        if not str(cp_ver).startswith("4."):
            log(f"[cellpose_detect] WARNING: expected cellpose 4.x, got {cp_ver}; "
                "model construction may use the v3 API.")
    except Exception:  # noqa: BLE001
        pass


def build_model(cp_models, model_name: str, args, torch_mod):
    """Construct the Cellpose 4 (CPSAM) model ONCE and place it on the device.

    Mirrors the construction in CellCounting/python/cellpose4_detect.py but is
    shared by BOTH the one-shot and persistent-worker paths, exactly like the
    3.x sidecar's ``build_model``. In serve mode it is called a single time
    before the request loop, so the (expensive) ~1.15 GB CPSAM weight download +
    device placement happen once for the whole batch.

    v4 API notes (differs from the 3.x build_model):
      * Only ``pretrained_model=`` is honoured; ``model_type=`` is ignored, and
        there is NO ``restore_type=``/denoise path — ``--restore`` is
        parsed-but-ignored (logged below for transparency).
      * ``device=`` may be passed straight to the constructor; we still degrade
        gracefully if a given cellpose build rejects a kwarg, always preserving
        ``pretrained_model=``.

    Returns ``(model, override_device)`` where ``override_device`` is the
    torch.device the net was moved to (or ``None`` for plain CPU). Raises on hard
    model-load failure; callers translate that into a structured error.
    """
    override_device, use_gpu_kw = cc.resolve_device(args, torch_mod)

    # v4 has no restore/denoise model. Keep the flag accepted (CLI parity) but
    # make the no-op explicit in the log rather than silently dropping it.
    if getattr(args, "restore", False):
        log("[cellpose_detect] --restore has no effect for cellpose 4 "
            "(no denoise/restore model); ignoring.")

    def _build():
        # v4: pretrained_model= is the only load-bearing kwarg. Try the richest
        # signature first (gpu= + device=), then degrade on TypeError so an
        # older/newer cellpose build that rejects a kwarg still constructs.
        # pretrained_model= is preserved in every attempt.
        if override_device is not None:
            try:
                return cp_models.CellposeModel(
                    gpu=use_gpu_kw,
                    pretrained_model=model_name,
                    device=override_device,
                )
            except TypeError:
                log("[cellpose_detect] CellposeModel rejected device=; retrying "
                    "without it (net moved manually below)")
        try:
            return cp_models.CellposeModel(
                gpu=use_gpu_kw,
                pretrained_model=model_name,
            )
        except TypeError:
            log("[cellpose_detect] CellposeModel rejected gpu=; constructing "
                "with pretrained_model= only")
            return cp_models.CellposeModel(pretrained_model=model_name)

    # Constructing the model triggers the 1.15 GB CPSAM weights download on first
    # run; the tqdm bridge installed by main() streams progress to stderr.
    log(f"[cellpose_detect] constructing CellposeModel(pretrained_model={model_name!r}, "
        f"gpu={use_gpu_kw}) — may download weights on first run")
    model = _build()

    # Belt-and-brace: move the underlying net to the requested device if cellpose
    # didn't honour device= itself, and reflect the choice on the model so
    # eval-time tensor allocations follow it (mirrors the native v4 sidecar).
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

    # Pass-14: surface the device the model will actually run on. The UI parses
    # this stage line and shows the real device. Must be a single line of the
    # form: [cellpose_detect] using device: <name> (torch <version>)
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


def run_detection_once(model, model_name: str, args, channels: list[int]) -> dict:
    """Run the full detect + measure flow for one image and return its payload.

    Single source of truth for detection: BOTH the one-shot mode and the
    persistent-worker mode call it (as in the 3.x sidecar), so a served result is
    identical to a one-shot result for the same params. Reuses ``model`` (already
    built) and reads the per-image params off ``args`` (image path, conf,
    pxPerUm, thresholds, bg-subtract, watershed, …).

    v4 specifics (vs the 3.x run_detection_once):
      * ``model.eval`` is called WITHOUT ``channels=`` (v4 infers channels from
        the array shape); on ``TypeError`` we retry WITH ``channels=`` as a
        courtesy for an older 4.0 release (mirrors the native v4 sidecar).
      * There is NO half-resolution retry — v4 has no size predictor, so the
        3.x IndexError-on-large-images that motivated it cannot occur.
      * Channels still drive the grayscale-vs-RGB image load in
        ``open_image_for_detection`` even though eval ignores them.

    Returns a dict of the exact shape ``emit_payload`` writes:
        {"width", "height", "cells", "image_stats"}.
    On an unrecoverable eval failure it raises ``DetectionRunError`` so the
    caller can surface a structured ``eval-failed`` error without crashing the
    worker.
    """
    # Open image, preprocess (bg-subtract etc.). Channels pick grayscale vs RGB.
    img = cc.open_image_for_detection(args.image, channels, args)

    # QC metrics on the (now possibly preprocessed) array — same contract the
    # Swift/Rust host reads from `image_stats` in the payload.
    image_stats: dict = {}
    image_stats.update(cc.compute_qc_metrics(img))

    height_px, width_px = int(img.shape[0]), int(img.shape[1])
    log(f"[cellpose_detect] image is {width_px}x{height_px} (ndim={img.ndim}); "
        f"model={model_name}; channels={channels}")

    # Explicit diameter prior. v4 has no size predictor and `diameter=None` just
    # means "no resize", so we always pass an explicit value. An explicit
    # --diameter (> 0) takes priority over the bins-derived prior; 0/absent falls
    # back to the size bins — matching cellpose_detect.py's semantics.
    if args.diameter > 0:
        expected_diam_um = float(args.diameter)
        diam_source = f"explicit --diameter={expected_diam_um:.2f}µm"
    else:
        expected_diam_um = (float(args.small_threshold) + float(args.large_threshold)) / 2.0
        diam_source = f"bins {args.small_threshold}-{args.large_threshold}µm"
    expected_diam_px = max(15.0, expected_diam_um * float(args.pxPerUm))
    log(f"[cellpose_detect] using fixed diameter={expected_diam_px:.1f}px "
        f"(from {diam_source} @ {args.pxPerUm}px/µm)")

    # eval — v4 does NOT take `channels=` (channels are inferred from the array
    # shape). Retry WITH channels= as a courtesy for an older 4.0 release where
    # the kwarg still existed. Any hard failure becomes a DetectionRunError so
    # serve mode can reframe it and keep serving the next request.
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
            raise DetectionRunError("eval-failed", hint=str(exc)) from exc
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] eval failed: {exc!r}")
        raise DetectionRunError("eval-failed", hint=str(exc)) from exc

    # Cellpose 4: eval returns (masks, flows, styles). flows[2] is still cellprob
    # (same index as 3.x), read by measure_cells for per-cell confidence.
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
# absent keeps the argv value. Model-determining keys (model/gpu/device/channels)
# are intentionally NOT here — they are fixed at model-build time and the host
# keys its worker pool by them. Matches build_request_json() in the Rust host and
# cellpose_detect.py's _PER_IMAGE_KEYS byte-for-byte.
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
    """Persistent-worker loop (v4).

    Structurally identical to the 3.x sidecar's serve(): build the CPSAM model
    once, announce readiness, then loop over stdin lines. Each line is one NDJSON
    request ``{"id":…, <per-image params>}``. We reply with exactly one framed
    line per request and never crash the worker on a single bad image — a failed
    request yields ``{"type":"error",...}`` and the loop continues. Exits cleanly
    on stdin EOF.

    Human-readable progress continues to go to STDERR exactly as in one-shot
    mode, so the host's stderr progress pump is unchanged. The tqdm weight-
    download bridge is installed by main() before this is called, so first-run
    download progress streams during the one-time model build below.
    """
    # Lazy imports mirror one-shot main() so an import failure emits a structured
    # error instead of a bare traceback. In serve mode the failure is fatal (we
    # cannot build a model), so we exit like the one-shot path.
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

    _warn_if_not_v4()

    # Map any app-level alias down to the bare cellpose 4 pretrained_model.
    model_name = _resolve_model_name(base_args.model)

    try:
        model, _override_device = build_model(cp_models, model_name, base_args, _torch)
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] model load failed: {exc!r}")
        emit_error("model-load-failed", hint=str(exc), exit_code=4)
        return

    log(f"[cellpose_detect] serve mode ready; model={model_name}; channels={channels}")
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
                payload = run_detection_once(model, model_name, merged, channels)
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

    log("[cellpose_detect] cellpose 4 sidecar starting")

    # Install the tqdm bridge BEFORE any cellpose import so the first-run CPSAM
    # weight download streams progress to stderr in our [cellpose_detect] format.
    # Covers BOTH the serve and one-shot paths, since both import cellpose lazily
    # below this point (cellpose.utils imports tqdm at module level, and we patch
    # the class-level methods which propagate to its bound reference).
    install_tqdm_progress_bridge()

    # Persistent-worker mode: hand off to the serve loop, which builds the model
    # once and services NDJSON requests. The one-shot path below is untouched and
    # remains the host's fallback.
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

    _warn_if_not_v4()

    # Map any app-level alias down to the bare cellpose 4 pretrained_model.
    model_name = _resolve_model_name(args.model)

    try:
        model, _override_device = build_model(cp_models, model_name, args, _torch)
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] model load failed: {exc!r}")
        emit_error("model-load-failed", hint=str(exc), exit_code=4)
        return

    try:
        payload = run_detection_once(model, model_name, args, channels)
    except DetectionRunError as exc:
        emit_error(exc.error, hint=exc.hint, exit_code=5)
        return

    # One-shot emission stays byte-for-byte identical to the 3.x sidecar: a
    # single `json.dumps(payload)` with no trailing newline (emit_payload's
    # contract).
    cc.emit_payload(
        payload["width"], payload["height"],
        payload["cells"], payload["image_stats"],
    )


if __name__ == "__main__":
    main()
