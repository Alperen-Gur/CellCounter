"""
_cellpose_common.py — Shared helpers for the Cellpose 3.x and 4.x sidecars.

Pass-18 (K4): Both `cellpose_detect.py` (3.x) and `cellpose4_detect.py` (4.x /
CPSAM) used to carry verbatim copies of: stderr logging, error emission,
argument parsing, image-array loading, QC metrics, watershed + colony
post-processing dispatch, the per-cell measurement loop, and JSON emission.
This module factors those into reusable functions so the two detect scripts
keep only the version-specific bits:

  * Cellpose 3.x: `restore_type` model construction, channels-aware eval,
    half-resolution retry on size-predictor IndexError.
  * Cellpose 4.x: tqdm progress bridge for the lazy CPSAM weights download,
    `pretrained_model=` constructor, eval without channels.

The Swift host (`Detection/SidecarSchema.swift`) decodes the JSON contract
documented at the top of `cellpose_detect.py` — this module emits identical
keys, in identical types.

Public API (callers in cellpose_detect.py / cellpose4_detect.py):

    log(*args, **kwargs) -> None
    emit_error(error: str, hint: str = "", exit_code: int = 2) -> NoReturn
        A PyTorch MPS out-of-memory hint is reported as `memory-limit`.

    apply_cpu_thread_limit(torch_mod=None) -> None
        Applies the host's `CC_CPU_THREADS` to PyTorch once per process,
        then the live control file. Call after importing torch, before
        loading a model.

    install_limits_control() -> bool / apply_live_limits(...) -> bool
        Live limits: on SIGINFO, re-read `CC_LIMITS_FILE` and apply PyTorch's
        thread count and GPU memory cap without reloading the model.
        `run_sidecar` and `serve_ndjson` install the handler.

    is_memory_limit_error(error) -> bool / memory_limit_hint() -> str

    build_arg_parser(description: str, default_model: str) -> argparse.ArgumentParser
        Adds every CLI flag both scripts share. Caller adds version-specific
        flags (e.g. --restore) before parse_args() in the script.

    parse_channels(channels_str: str) -> list[int]

    load_image_array(pil_image) -> np.ndarray
        PIL → numpy, uint8, HxW or HxWx3 depending on mode. Retained for
        backward compatibility; new code should go through `_imageio`.

    open_image_for_detection(path: str, channels: list[int], args) -> np.ndarray
        Opens file, picks grayscale vs RGB based on channel selection,
        applies _preprocessing.apply with args. Caller passes args separately
        because it owns the argparse.Namespace.

        Since the vendor-format pass this routes through
        `_imageio.load_planes()`, so Zeiss .czi / Nikon .nd2 / Leica .lif /
        Olympus .oif|.oib|.oir, Z-stacks and N-channel fluorescence all work
        here — but the RETURN VALUE is unchanged: a uint8 HxW (grayscale
        mode) or HxWx3 (cellpose channel mode) array. The full float32
        (H, W, C) stack is stashed on `args` as `_cc_channel_stack` (names in
        `_cc_channel_names`, metadata in `_cc_image_meta`) so `measure_cells`
        can emit per-cell per-channel intensities without any caller change.

    compute_qc_metrics(img: np.ndarray) -> dict
        Returns {"focus_score", "illumination_residual"} (or {} on failure).

    resolve_device(args, torch_mod) -> (override_device | None, use_gpu_kw: bool)

    measure_cells(masks, img, args, flows=None, channel_stack=None,
                  channel_names=None) -> list[dict]
        Runs the full per-cell measurement loop. Returns cell dicts matching
        the SidecarPayload schema. When the source had more than one channel
        each cell additionally carries a "channel_intensities" list — see the
        function docstring for the exact JSON.

    label_crops(masks, label_ids) -> iterator of (label, crop, row0, col0)
        Each label's mask cropped to its bounding box (plus a 1-pixel
        margin inside the image). Used by measure_cells and by the StarDist
        and SAM sidecars so per-cell work scales with cell size, not image
        size.

    apply_watershed_if_requested(masks, args) -> masks
    compute_colony_stats(masks, args, height_px, width_px) -> dict
    emit_payload(width_px, height_px, cells, image_stats) -> None

    model_loading_progress(package="cellpose") -> context manager
        Routes Cellpose's lazy weight downloads through `_model_downloads`
        (verified TLS, resumable `.cellcounter-part`, size checks) and cleans the models
        folder first. Yields the models folder.

    build_with_weight_recovery(build, managed_names, models_directory)
        Constructs a model; a truncated/corrupt checkpoint that CellCounter
        downloaded is moved aside, downloaded once more, and loaded again.

    run_sidecar(entry)
        Entry-point wrapper: SIGTERM unwinds the stack (finally blocks run,
        partial downloads stay resumable), then the process ends by SIGTERM.

The logger prefix is "[cellpose_detect]" in both scripts. We keep that exact
spelling so the existing UI parser (ccDetectionStage) doesn't have to learn
two prefixes.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import math
import os
import signal
import stat
import sys
import threading
import uuid
from typing import Any

try:
    import _model_downloads as downloads
except ImportError:  # imported from outside the sidecar folder
    sys.path.append(os.path.dirname(os.path.abspath(__file__)))
    import _model_downloads as downloads


# ---------------------------------------------------------------------------
# stderr logging — stdout is reserved for the final JSON result.
# ---------------------------------------------------------------------------

def log(*args, **kwargs) -> None:
    """Stderr logger. Used by both detect scripts via this module."""
    print(*args, file=sys.stderr, **kwargs)


def emit_error(error: str, hint: str = "", exit_code: int = 2) -> None:
    """Write a structured error JSON to stdout and exit.

    Whatever stage raised it, a PyTorch GPU out-of-memory failure is reported
    as `memory-limit` with a plain hint (see `memory_limit_failure`).
    """
    error, hint = memory_limit_failure(error, hint)
    payload: dict = {"error": error}
    if hint:
        payload["hint"] = hint
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()
    sys.exit(exit_code)


# ---------------------------------------------------------------------------
# Resource limits (Settings → General → Model resource use). The host passes
# them in the environment: thread counts for every numeric library,
# `CC_CPU_THREADS` for PyTorch (applied below), PyTorch's own
# PYTORCH_MPS_HIGH/LOW_WATERMARK_RATIO, and `CC_MEMORY_LIMIT_GB` to name the
# limit in an error. They change speed and memory use, not processing steps.
# ---------------------------------------------------------------------------

MEMORY_LIMIT_ERROR = "memory-limit"

_cpu_threads_applied = False


def cpu_thread_limit():
    """The thread count the host chose (`CC_CPU_THREADS`), or None for no limit."""
    raw = os.environ.get("CC_CPU_THREADS", "").strip()
    if not raw:
        return None
    try:
        threads = int(raw)
    except ValueError:
        log(f"[cellpose_detect] ignoring CC_CPU_THREADS={raw!r}")
        return None
    return threads if threads > 0 else None


def apply_cpu_thread_limit(torch_mod=None) -> None:
    """Limit PyTorch's CPU threads to `CC_CPU_THREADS`, once per process.

    Call after importing torch and before loading a model. ``torch_mod``
    defaults to an already imported torch; this never imports it. The
    inter-op pool can only be sized before any parallel work has started,
    so a refusal there is logged and ignored. Then applies the live control
    file, in case Settings changed after this process started.
    """
    global _cpu_threads_applied
    torch_mod = torch_mod if torch_mod is not None else sys.modules.get("torch")
    if _cpu_threads_applied or torch_mod is None:
        return
    _cpu_threads_applied = True
    threads = cpu_thread_limit()
    if threads is None:
        # Started without a limit: this is PyTorch's own default, which
        # Maximum returns to after a live change.
        try:
            _live["default_threads"] = int(torch_mod.get_num_threads())
        except Exception:  # noqa: BLE001
            pass
    else:
        try:
            torch_mod.set_num_threads(threads)
        except Exception as exc:  # noqa: BLE001
            log(f"[cellpose_detect] could not limit CPU threads: {exc!r}")
        else:
            try:
                # Matches TF_NUM_INTEROP_THREADS on the host side.
                torch_mod.set_num_interop_threads(max(1, min(2, threads)))
            except Exception as exc:  # noqa: BLE001
                log(f"[cellpose_detect] inter-op threads left unchanged: {exc!r}")
            log(f"[cellpose_detect] CPU threads limited to {threads}")
    apply_live_limits(torch_mod, initial=True)
    flush_live_notes()


def is_memory_limit_error(error) -> bool:
    """Whether `error` (an exception or its text) is PyTorch running out of MPS memory.

    PyTorch raises ``MPS backend out of memory (MPS allocated: …, max allowed:
    …)`` both when the limit set in Settings is reached and when the Mac
    itself has no memory left.
    """
    text = str(error).lower()
    return "out of memory" in text and ("mps backend" in text or "mps allocated" in text)


def memory_limit_hint() -> str:
    """Plain advice for a `memory-limit` error.

    Names the limit in force: the one set live from Settings, if any,
    otherwise the one this process started with.
    """
    if _live["limit_set_live"]:
        limit = str(_live["limit_gb"] or "")
    else:
        limit = os.environ.get("CC_MEMORY_LIMIT_GB", "").strip()
    if limit:
        return (f"The model needed more memory than the {limit} GB limit set in "
                "Settings → General → Model resource use. Raise the limit or "
                "choose Maximum, then run it again.")
    return ("The model ran out of GPU memory. Close apps that use a lot of "
            "memory or try a smaller image, then run it again.")


def memory_limit_failure(error: str, hint: str):
    """(error, hint) to report: a PyTorch out-of-memory failure becomes `memory-limit`."""
    if error == MEMORY_LIMIT_ERROR or not is_memory_limit_error(hint):
        return error, hint
    log(f"[cellpose_detect] {error} was PyTorch running out of GPU memory: {hint}")
    return MEMORY_LIMIT_ERROR, memory_limit_hint()


# ---------------------------------------------------------------------------
# Live limits. When the choice changes in Settings, the host rewrites the JSON
# file named in `CC_LIMITS_FILE` and sends SIGINFO; the handler applies
# PyTorch's thread count and GPU memory cap without reloading the model.
# Priority (Darwin background state) is set by the host itself.
#
# SIGINFO, not SIGUSR1: its default action is to ignore the signal, so a
# process that is still starting, or a helper that never installs the
# handler, is not stopped by it.
#
# A Python signal handler runs in the main thread between bytecodes, never
# inside a torch call, so setting the thread count or the allocator limit
# there is safe. It writes nothing (an interrupted write to stderr could be
# re-entered); notes are logged later at a safe point.
# ---------------------------------------------------------------------------

LIMITS_FILE_ENV = "CC_LIMITS_FILE"
LIMITS_SIGNAL = getattr(signal, "SIGINFO", None)
# PyTorch's default MPS high watermark: "no cap set by CellCounter".
PYTORCH_DEFAULT_MPS_FRACTION = 1.7


def _fresh_live_state() -> dict:
    return {
        # Between requests in a serve loop; a one-shot run is one request.
        "in_request": True,
        # Threads this process set live, and PyTorch's default when the
        # process started without a limit.
        "threads": None,
        "default_threads": None,
        # MPS cap this process set live; a lower one waiting for the request.
        "fraction": None,
        "pending": None,
        # The hard cap's size for the error hint, once set live.
        "limit_gb": None,
        "limit_set_live": False,
        "handler_installed": False,
        "notes": [],
    }


_live = _fresh_live_state()


def _note(message: str) -> None:
    notes = _live["notes"]
    notes.append(message)
    del notes[:-10]


def flush_live_notes() -> None:
    """Log what the live handler did. Call only outside the handler."""
    notes, _live["notes"] = _live["notes"], []
    for message in notes:
        log(f"[cellpose_detect] {message}")


def _positive_int(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else None


def _mps_fraction(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    value = float(value)
    return value if 0 < value <= 2 else None


def read_live_limits(path=None):
    """The host's live limits (`CC_LIMITS_FILE`), or None if absent or unreadable."""
    path = path or os.environ.get(LIMITS_FILE_ENV, "")
    if not path:
        return None
    try:
        with open(path, "rb") as handle:
            state = json.loads(handle.read(65536))
    except (OSError, ValueError):
        return None
    if not isinstance(state, dict) or state.get("version") != 1:
        return None
    return state


def install_limits_control() -> bool:
    """Apply new limits when the host sends SIGINFO. Main thread only; idempotent.

    Leaves a handler some other code installed alone. Interrupted system
    calls restart, so native code never sees EINTR because of it.
    """
    if _live["handler_installed"]:
        return True
    if LIMITS_SIGNAL is None or not os.environ.get(LIMITS_FILE_ENV):
        return False
    if threading.current_thread() is not threading.main_thread():
        return False
    try:
        if signal.getsignal(LIMITS_SIGNAL) not in (signal.SIG_DFL, signal.SIG_IGN, None):
            return False
        signal.signal(LIMITS_SIGNAL, _on_limits_signal)
        signal.siginterrupt(LIMITS_SIGNAL, False)
    except (ValueError, OSError, AttributeError):
        return False
    _live["handler_installed"] = True
    return True


def _on_limits_signal(signum, frame) -> None:
    try:
        apply_live_limits()
    except Exception as exc:  # noqa: BLE001
        _note(f"could not apply new limits: {exc!r}")


def apply_live_limits(torch_mod=None, *, initial=False) -> bool:
    """Apply the live control file to this process.

    Sets PyTorch's thread count, and its GPU memory cap: a higher or removed
    cap at once; a lower one at once only between requests (or when
    ``initial``, before any model is loaded), otherwise after the current
    request (`apply_deferred_live_limits`), so a running image never fails
    because of the change. Does nothing before torch is imported; never
    imports it. Returns whether a state was read.
    """
    torch_mod = torch_mod if torch_mod is not None else sys.modules.get("torch")
    if torch_mod is None:
        return False
    state = read_live_limits()
    if state is None:
        return False
    _apply_live_threads(torch_mod, state)
    _apply_live_memory(torch_mod, state, allow_lower=initial or not _live["in_request"])
    return True


def _apply_live_threads(torch_mod, state) -> None:
    target = _positive_int(state.get("cpu_threads"))
    launched = cpu_thread_limit()
    current = _live["threads"] if _live["threads"] is not None else launched
    if target is None:
        # Maximum: PyTorch's own default. A process that never had a limit
        # keeps running exactly as it started.
        if current is None:
            return
        target = _live["default_threads"] or _positive_int(state.get("default_cpu_threads"))
        if target is None:
            return
    if target == current:
        return
    try:
        torch_mod.set_num_threads(target)
    except Exception as exc:  # noqa: BLE001
        _note(f"could not change CPU threads: {exc!r}")
        return
    _live["threads"] = target
    _note(f"CPU threads now {target} (Settings changed)")


def _launch_mps_fraction() -> float:
    try:
        return float(os.environ.get("PYTORCH_MPS_HIGH_WATERMARK_RATIO", ""))
    except ValueError:
        return PYTORCH_DEFAULT_MPS_FRACTION


def _developer_memory_cap() -> bool:
    """A cap CellCounter did not set; it always names its own in CC_MEMORY_LIMIT_GB."""
    return (bool(os.environ.get("PYTORCH_MPS_HIGH_WATERMARK_RATIO"))
            and not os.environ.get("CC_MEMORY_LIMIT_GB"))


def _apply_live_memory(torch_mod, state, allow_lower) -> None:
    if _developer_memory_cap():
        return
    target = _mps_fraction(state.get("memory_fraction"))
    limit_gb = _positive_int(state.get("memory_limit_gb")) if target is not None else None
    if target is None:
        target = PYTORCH_DEFAULT_MPS_FRACTION
    current = _live["fraction"] if _live["fraction"] is not None else _launch_mps_fraction()
    if abs(target - current) < 1e-9:
        _live["pending"] = None
        return
    if target < current and not allow_lower:
        _live["pending"] = (target, limit_gb)
        _note(f"GPU memory cap lowers after the current image (fraction {target:.4f})")
        return
    _set_mps_fraction(torch_mod, target, limit_gb)


def _set_mps_fraction(torch_mod, fraction, limit_gb) -> bool:
    mps = getattr(torch_mod, "mps", None)
    backend = getattr(getattr(torch_mod, "backends", None), "mps", None)
    setter = getattr(mps, "set_per_process_memory_fraction", None)
    try:
        if setter is None or backend is None or not backend.is_available():
            return False
        setter(float(fraction))
    except Exception as exc:  # noqa: BLE001
        _note(f"could not change the GPU memory cap: {exc!r}")
        return False
    _live.update(fraction=float(fraction), pending=None, limit_gb=limit_gb, limit_set_live=True)
    _note(f"GPU memory cap now fraction {fraction:.4f} (Settings changed)")
    return True


def apply_deferred_live_limits(torch_mod=None) -> None:
    """Apply a lower GPU memory cap that waited for the request to finish."""
    pending = _live["pending"]
    torch_mod = torch_mod if torch_mod is not None else sys.modules.get("torch")
    if pending is None or torch_mod is None:
        return
    _set_mps_fraction(torch_mod, *pending)


# ---------------------------------------------------------------------------
# Termination. The host stops workers with SIGTERM (Cancel, idle retirement,
# quit) and SIGKILLs stragglers. Python's default SIGTERM action ends the
# process without running `finally` blocks.
# ---------------------------------------------------------------------------

class WorkerTerminated(SystemExit):
    """Raised in the main thread when SIGTERM arrives.

    A SystemExit, so `except Exception` handlers let it through and `finally`
    blocks (closing a partial download, restoring hooks) run on the way out.
    `serve_ndjson` never turns it into a response.
    """


# How long unwinding may take before the process ends regardless, in case a
# library swallowed the exception. Started by the handler itself.
TERMINATION_GRACE_SECONDS = 3.0


def _end_by_sigterm() -> None:
    """End the process by SIGTERM, so the host sees the same status as before."""
    try:
        sys.stderr.flush()
    except Exception:  # noqa: BLE001
        pass
    try:
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
    except ValueError:  # not the main thread; SIG_DFL is already in place
        pass
    # Aimed at this thread, the signal is delivered before the call returns
    # (os.kill could be taken by another thread after os._exit had run).
    signal.pthread_kill(threading.get_ident(), signal.SIGTERM)
    os._exit(128 + signal.SIGTERM)  # only if the signal was blocked


def install_termination_handler() -> bool:
    """Make SIGTERM raise `WorkerTerminated` in the main thread.

    A second SIGTERM while unwinding ends the process at once, as SIGTERM
    always did. Returns False when called off the main thread (no-op).
    """
    if threading.current_thread() is not threading.main_thread():
        return False

    def handle(signum, frame):
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        timer = threading.Timer(TERMINATION_GRACE_SECONDS, _end_by_sigterm)
        timer.daemon = True
        timer.start()
        raise WorkerTerminated(128 + signum)

    signal.signal(signal.SIGTERM, handle)
    return True


def run_sidecar(entry):
    """Run a sidecar's entry point with clean SIGTERM handling.

    SIGTERM unwinds `entry` (a weight download keeps its resumable `.cellcounter-part`;
    nothing is half-moved), then the process ends by SIGTERM exactly as it
    did without the handler. Ordinary `sys.exit` codes pass through. Live
    limit changes (SIGINFO) are applied while `entry` runs.
    """
    install_termination_handler()
    install_limits_control()
    try:
        return entry()
    except WorkerTerminated:
        _end_by_sigterm()


def _exit_status(code) -> int:
    """The process exit status `sys.exit(code)` would give a one-shot run."""
    if code is None:
        return 0
    if isinstance(code, int):
        return int(code)
    return 1


def serve_ndjson(run_once, after_response=None) -> None:
    """Serve serialized detection requests over newline-delimited JSON.

    The process keeps imported modules and the caller's model cache alive
    between requests. Each input line is ``{"request_id": ..., "args": [...]}``
    and each output line is an envelope containing the unchanged one-shot
    stdout payload plus its logical exit code. Logs continue to use stderr, so
    the host can stream progress exactly as it does for a one-shot process.

    ``run_once(argv)`` must be the function a one-shot run calls with the same
    arguments, so a served payload matches the one-shot payload exactly.

    ``after_response``, when given, is called with no arguments after each
    response has been written and flushed, so work that does not affect the
    result (such as `release_request_memory`) never delays it. Anything it
    prints goes to stderr, and an exception it raises is logged and does not
    stop the worker.

    Requests are deliberately executed one at a time: Cellpose model objects
    are not documented as thread-safe, and serialization prevents concurrent
    eval calls from multiplying peak model/GPU memory.

    Live limits from Settings (SIGINFO) apply during a request; each request
    also starts from the current control file, and a lower GPU memory cap
    that arrived during a request applies after its response.
    """
    install_limits_control()
    _live["in_request"] = False
    for raw_line in sys.stdin:
        # Settings may have changed while this worker waited.
        try:
            apply_live_limits()
        except Exception as exc:  # noqa: BLE001
            _note(f"could not apply new limits: {exc!r}")
        _live["in_request"] = True
        request_id = None
        output = io.StringIO()
        exit_code = 0
        try:
            request = json.loads(raw_line)
            request_id = request.get("request_id")
            argv = request.get("args")
            if not isinstance(request_id, str) or not isinstance(argv, list):
                raise ValueError("request_id must be a string and args must be an array")
            if not all(isinstance(value, str) for value in argv):
                raise ValueError("every args value must be a string")
            with contextlib.redirect_stdout(output):
                try:
                    run_once(argv)
                except WorkerTerminated:
                    # The host stopped this worker: no response, no next request.
                    raise
                except SystemExit as exc:
                    exit_code = _exit_status(exc.code)
                    if exc.code is not None and not isinstance(exc.code, int):
                        # A one-shot interpreter prints a non-integer exit
                        # message to stderr; keep that diagnostic.
                        log(exc.code)
        except Exception as exc:  # noqa: BLE001
            exit_code = 70
            log(f"[cellpose_detect] worker request failed: {exc!r}")
            error, hint = memory_limit_failure("worker-request-failed", str(exc))
            output = io.StringIO()
            output.write(json.dumps({
                "error": error,
                "hint": hint,
            }, separators=(",", ":")))

        response = {
            "request_id": request_id,
            "exit_code": exit_code,
            "stdout": output.getvalue(),
        }
        sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
        sys.stdout.flush()
        _live["in_request"] = False

        if after_response is not None:
            # Drop this request's input and payload first, so the hook can
            # reclaim them. The model cache lives in the caller's module.
            raw_line = request = argv = output = response = None
            _run_after_response(after_response)
        # A lower GPU memory cap that arrived during the request, now that
        # its memory has been handed back.
        apply_deferred_live_limits()
        flush_live_notes()


def _run_after_response(hook) -> None:
    try:
        with contextlib.redirect_stdout(sys.stderr):
            hook()
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] post-response cleanup failed: {exc!r}")


def release_request_memory() -> None:
    """Hand back memory a finished request no longer needs.

    For use as `serve_ndjson`'s ``after_response`` hook. A cached model stays
    loaded. This collects unreachable Python objects (including reference
    cycles left by the request) and, only when the worker has already
    imported PyTorch, returns its cached, now unused accelerator blocks to
    the system. It never imports PyTorch itself, so the TensorFlow and
    scikit-image workers pay for the collection only. It writes nothing to
    stdout.
    """
    import gc

    with contextlib.redirect_stdout(sys.stderr):
        gc.collect()
        torch = sys.modules.get("torch")
        if torch is None:
            return
        try:
            mps_backend = getattr(getattr(torch, "backends", None), "mps", None)
            mps = getattr(torch, "mps", None)
            if (mps_backend is not None and mps_backend.is_available()
                    and hasattr(mps, "empty_cache")):
                mps.empty_cache()
        except Exception as exc:  # noqa: BLE001
            log(f"[cellpose_detect] could not release the MPS cache: {exc!r}")
        try:
            cuda = getattr(torch, "cuda", None)
            if (cuda is not None and cuda.is_available()
                    and cuda.is_initialized()):
                cuda.empty_cache()
        except Exception as exc:  # noqa: BLE001
            log(f"[cellpose_detect] could not release the CUDA cache: {exc!r}")


# ---------------------------------------------------------------------------
# First-use model loading — visible, bounded network operations.
# ---------------------------------------------------------------------------

# The weights are unavailable; image loading/inference is not the failure.
# Defined in `_model_downloads`, so its subclasses are caught here too.
ModelDownloadError = downloads.ModelDownloadError


class WeightsUnusableError(ModelDownloadError):
    """Downloaded weights still cannot be loaded after one fresh download."""


def install_tqdm_progress_bridge() -> None:
    """Translate byte bars into newline stages the native UI does not filter.

    Patch the class once per worker so model reuse cannot stack wrappers. A
    partial bar closing on cancellation or error must never announce success.
    """
    try:
        import tqdm
    except ImportError:
        return
    bar_type = tqdm.tqdm
    if getattr(bar_type, "_cc_download_bridge", False):
        return
    original_init = bar_type.__init__
    original_update = bar_type.update
    original_close = bar_type.close

    def is_bytes(bar):
        return getattr(bar, "unit", "") == "B" and bool(getattr(bar, "unit_scale", False))

    def progress(bar, final=False):
        import time
        total = float(getattr(bar, "total", 0) or 0)
        done = float(getattr(bar, "n", 0) or 0)
        now = time.monotonic()
        previous = getattr(bar, "_cc_last_bytes", 0)
        bucket = int(done * 20 / total) if total > 0 else 0
        changed = bucket > getattr(bar, "_cc_last_bucket", -1) if total > 0 else done - previous >= 1024 * 1024
        if not final and not changed and now - getattr(bar, "_cc_last_time", now) < 2:
            return
        if final and getattr(bar, "_cc_closed", False):
            return
        if final:
            bar._cc_closed = True
        bar._cc_last_time = now
        bar._cc_last_bytes = done
        bar._cc_last_bucket = bucket
        amount = f"{done / (1024 * 1024):.1f} MB"
        if total > 0:
            amount = f"{done / (1024 * 1024):.1f} / {total / (1024 * 1024):.1f} MB ({min(100, int(done * 100 / total))}%)"
        # Only a complete known-size bar is independently evidence of success.
        # The download wrapper below confirms unknown-size downloads on return.
        status = "downloaded weights" if final and total > 0 and done >= total else "downloading weights"
        log(f"[cellpose_detect] {status}: {amount}", flush=True)

    def patched_init(bar, *args, **kwargs):
        original_init(bar, *args, **kwargs)
        if is_bytes(bar):
            bar._cc_last_bucket = -1
            bar._cc_last_time = 0
            bar._cc_closed = False
            progress(bar)

    def patched_update(bar, n=1):
        result = original_update(bar, n)
        if is_bytes(bar):
            progress(bar)
        return result

    def patched_close(bar):
        if is_bytes(bar):
            progress(bar, final=True)
        return original_close(bar)

    bar_type.__init__ = patched_init
    bar_type.update = patched_update
    bar_type.close = patched_close
    bar_type._cc_download_bridge = True


@contextlib.contextmanager
def model_loading_progress(package: str = "cellpose"):
    """Route Cellpose's lazy weight downloads through `_model_downloads`.

    While the block runs, ``<package>.utils.download_url_to_file`` is
    CellCounter's downloader: verified TLS, a resumable ``<file>.cellcounter-part``, and
    a size check before the file is moved into place. Before that, abandoned
    downloads are removed from the models folder and pinned weights of the
    wrong size are moved aside (so Cellpose downloads them again). Yields the
    models folder.

    This worker processes one request at a time. The library hooks are
    restored on exit so cached-model evaluations and subsequent requests
    retain its API. No download happens here unless Cellpose itself requests
    missing weights. ``package`` is ``"cellpose_omni"`` for Omnipose.
    """
    try:
        root = __import__(package, fromlist=["utils"])
    except ImportError:
        root = None
    utils = getattr(root, "utils", None) or sys.modules.get(package + ".utils")
    models_module = getattr(root, "models", None) or sys.modules.get(package + ".models")
    directory = downloads.models_dir(models_module)
    downloads.restore_default_https_context()
    downloads.cleanup_stale_files(directory)
    downloads.quarantine_mismatched_pinned_weights(directory)

    original_download = getattr(utils, "download_url_to_file", None) if utils is not None else None
    if original_download is None:
        yield directory
        return

    def download(url, destination, progress=True, *args, **kwargs):
        name = os.path.basename(os.fspath(destination))
        log(f"[cellpose_detect] downloading weights for {name} — one-time model setup", flush=True)
        try:
            downloads.download_url_to_file(url, destination, progress=progress)
        except ModelDownloadError as exc:
            message = f"Could not download the {name} model weights. {exc}"
            log(f"[cellpose_detect] {message}", flush=True)
            raise type(exc)(message) from exc
        except Exception as exc:  # noqa: BLE001
            message = (f"Could not download the {name} model weights. "
                       f"Check your internet connection and retry. {exc}")
            log(f"[cellpose_detect] {message}", flush=True)
            raise ModelDownloadError(message) from exc
        log(f"[cellpose_detect] weights ready: {name}", flush=True)

    # `cellpose.models` calls `utils.download_url_to_file`; a fork that
    # imported the function by name is covered too.
    patched = [utils]
    if models_module is not None and getattr(models_module, "download_url_to_file", None) is original_download:
        patched.append(models_module)
    for module in patched:
        module.download_url_to_file = download
    try:
        yield directory
    finally:
        for module in patched:
            module.download_url_to_file = original_download
        downloads.restore_default_https_context()


def managed_cellpose_weights(models_module, requested: str, *, default: str,
                             torch_suffixed=(), extra=()) -> list:
    """Weight files Cellpose downloads into its models folder for `requested`.

    Empty for a user's own model (an existing path, or a name the Cellpose GUI
    registered in gui_models.txt): those are never moved aside. A name
    Cellpose does not know falls back to its `default` model, as Cellpose
    does. Cellpose 3 stores cyto/cyto2/nuclei as `<name>torch_0`.
    """
    directory = downloads.models_dir(models_module)
    if os.path.exists(requested) or requested in downloads.user_registered_models(directory):
        return []
    known = set(getattr(models_module, "MODEL_NAMES", None) or ())
    name = requested if requested in known else default
    return [f"{name}torch_0" if name in torch_suffixed else name, *extra]


def _managed_weight_paths(directory, names) -> list:
    user_models = downloads.user_registered_models(directory)
    paths = []
    for name in names:
        if name in user_models or downloads.is_download_artifact(name):
            continue
        path = os.path.join(os.fspath(directory), name)
        try:
            info = os.lstat(path)
        except OSError:
            continue
        if stat.S_ISREG(info.st_mode):  # a symlink is the user's own arrangement
            paths.append(path)
    return paths


def build_with_weight_recovery(build, managed_names, models_directory):
    """Return `build()`, recovering once from damaged downloaded weights.

    When construction fails the way a truncated or corrupt checkpoint does
    (torch zip/PytorchStreamReader errors, UnpicklingError, EOFError, ...),
    the files in `managed_names` — files Cellpose downloads, never a user's
    own model — are moved aside to `<name>.corrupt-<timestamp>` and `build()`
    runs once more, which downloads them again (call this inside
    `model_loading_progress`). If that fails too, or the same file was
    already replaced within the last hour, a `WeightsUnusableError` says so.
    """
    try:
        return build()
    except ModelDownloadError:
        raise
    except Exception as first:  # noqa: BLE001
        if not downloads.is_corrupt_checkpoint_error(first):
            raise
        candidates = _managed_weight_paths(models_directory, managed_names)
        if not candidates:
            raise
        names = ", ".join(os.path.basename(path) for path in candidates)
        recent = [found for found in map(downloads.recently_quarantined, candidates) if found]
        if recent:
            raise WeightsUnusableError(
                f"The {names} model weights cannot be loaded ({first}). They were already "
                f"downloaded again less than an hour ago (the damaged copy is {recent[0]} in "
                f"{models_directory}). Check the disk and network, then retry later.") from first
        log(f"[cellpose_detect] the cached {names} weights could not be loaded ({first!r}); "
            "downloading them again", flush=True)
        moved = []
        for path in candidates:
            try:
                moved.append(downloads.quarantine(path, f"loading failed with {type(first).__name__}"))
            except OSError as exc:
                raise WeightsUnusableError(
                    f"The {names} model weights cannot be loaded ({first}), and the damaged "
                    f"file could not be moved aside ({exc}).") from first
    try:
        return build()
    except ModelDownloadError:
        raise
    except Exception as second:  # noqa: BLE001
        if not downloads.is_corrupt_checkpoint_error(second):
            raise
        kept = ", ".join(os.path.basename(path) for path in moved)
        raise WeightsUnusableError(
            f"CellCounter downloaded the {names} model weights again, but Cellpose still "
            f"cannot load them ({second}). The damaged copies are kept as {kept} in "
            f"{models_directory}.") from second


# ---------------------------------------------------------------------------
# Argument parser — the shared shape.
# ---------------------------------------------------------------------------

def build_arg_parser(description: str, default_model: str) -> argparse.ArgumentParser:
    """Build the common CLI for both cellpose detect scripts.

    Caller adds version-specific flags (e.g. ``--restore`` for the 3.x
    script) on the returned parser before calling ``parse_args()``.
    """
    p = argparse.ArgumentParser(description=description)
    p.add_argument("--image", required=True,
                   help="Path to input image. Common formats (jpg/png/tif/bmp) "
                        "plus the vendor microscope formats handled by "
                        "_imageio: .czi, .nd2, .lif, .oif, .oib, .oir.")
    p.add_argument("--model", default=default_model,
                   help="Cellpose model name or path to a checkpoint.")
    p.add_argument("--pxPerUm", type=float, required=True,
                   help="Pixels per micrometer; converts pixel diameter to µm.")
    p.add_argument("--conf", type=float, default=0.5,
                   help="Confidence threshold in [0,1]. Reported per-cell so "
                        "the host can filter.")
    p.add_argument("--channels", default="0,0",
                   help="Two comma-separated ints: cyto channel, nuclei channel. "
                        "0=grayscale/none, 1=red, 2=green, 3=blue. Default 0,0.")
    p.add_argument("--z-project", dest="z_project", default="max",
                   choices=["max", "sum", "mean", "none"],
                   help="How to collapse a Z-stack into one plane. 'none' "
                        "applies no projection and uses the central Z plane. "
                        "Default max.")
    p.add_argument("--segment-channel", dest="segment_channel", type=int,
                   default=0,
                   help="Zero-based index of the channel the segmenter runs "
                        "on for multi-channel images. In grayscale mode "
                        "(--channels 0,0) that channel IS the input; with a "
                        "cellpose channel pair it is mapped onto cellpose "
                        "channel 1 (red) and the rest follow in order. Per-cell "
                        "intensities are still measured in EVERY channel. "
                        "Default 0.")
    p.add_argument("--bg-subtract", dest="bg_subtract", action="store_true",
                   help="Apply rolling-ball background subtraction before detection.")
    p.add_argument("--rolling-ball-radius", dest="rolling_ball_radius", type=int,
                   default=50,
                   help="Radius for rolling-ball background subtraction (default 50).")
    p.add_argument("--clahe", action="store_true",
                   help="Apply contrast-limited adaptive histogram equalization before detection.")
    p.add_argument("--anisotropic-diffusion", dest="anisotropic_diffusion", action="store_true",
                   help="Apply edge-preserving Perona-Malik diffusion before detection.")
    p.add_argument("--gpu-preprocess", dest="gpu_preprocess", action="store_true",
                   help="Use a compatible array GPU for diffusion when available; otherwise CPU.")
    p.add_argument("--watershed", action="store_true",
                   help="Run distance-transform watershed to split touching cells.")
    p.add_argument("--watershed-min-distance", dest="watershed_min_distance",
                   type=int, default=8,
                   help="Watershed seed peak min distance in µm (default 8).")
    p.add_argument("--small-threshold", dest="small_threshold", type=float,
                   default=20,
                   help="Diameter (µm) below which cells are 'small'. Default 20.")
    p.add_argument("--large-threshold", dest="large_threshold", type=float,
                   default=30,
                   help="Diameter (µm) at/above which cells are 'large'. Default 30.")
    p.add_argument("--no-gpu", dest="no_gpu", action="store_true",
                   help="Force CPU inference (no MPS/CUDA).")
    p.add_argument("--device", default=None,
                   help="Optional explicit torch device override (mps, cpu, cuda).")
    return p


# ---------------------------------------------------------------------------
# Channel + image loading.
# ---------------------------------------------------------------------------

def parse_channels(channels_str: str) -> list[int]:
    """Parse '--channels c0,c1' into [c0, c1], clamping to [0,3]."""
    try:
        parts = [int(x.strip()) for x in channels_str.split(",")]
        if len(parts) != 2:
            raise ValueError("expected exactly 2 values")
        return [max(0, min(3, parts[0])), max(0, min(3, parts[1]))]
    except Exception as exc:
        log(f"[cellpose_detect] invalid --channels '{channels_str}': {exc!r}; "
            "falling back to [0,0]")
        return [0, 0]


def load_image_array(pil_image):
    """PIL → numpy in a Cellpose-friendly form (uint8, HxW or HxWx3)."""
    import numpy as np

    mode = pil_image.mode
    if mode == "L":
        return np.array(pil_image, dtype=np.uint8)
    if mode in ("I", "F"):
        arr = np.array(pil_image, dtype=np.float32)
        arr_min, arr_max = arr.min(), arr.max()
        if arr_max > arr_min:
            arr = (arr - arr_min) / (arr_max - arr_min) * 255.0
        return arr.astype(np.uint8)
    # RGB / RGBA / P → coerce to RGB so cellpose can pick channels.
    rgb = pil_image.convert("RGB")
    return np.array(rgb, dtype=np.uint8)


def _ensure_sidecar_path() -> None:
    """Make sibling sidecar modules (_imageio, _preprocessing, …) importable."""
    _here = os.path.dirname(os.path.abspath(__file__))
    if _here not in sys.path:
        sys.path.insert(0, _here)


def open_image_for_detection(path: str, channels: list[int], args):
    """Open the image file, pick gray vs RGB based on channels, apply preprocessing.

    Returns the numpy array (uint8) — HxW in grayscale mode, HxWx3 when the
    caller asked for a cellpose channel pair. That return contract is
    UNCHANGED; what changed underneath is that loading now goes through
    `_imageio.load_planes()`, which understands vendor microscope formats,
    Z-stacks and N-channel fluorescence.

    Side effect (deliberate, so callers need no signature change): the full
    float32 (H, W, C) stack in RAW source units is attached to ``args`` as
    ``_cc_channel_stack``, its names as ``_cc_channel_names`` and the loader
    metadata as ``_cc_image_meta``. ``measure_cells`` picks those up to emit
    per-cell per-channel intensities.

    On failure, calls emit_error() and exits.
    """
    import numpy as np

    _ensure_sidecar_path()
    import _imageio  # noqa: E402

    z_project = str(getattr(args, "z_project", "max") or "max")
    log(f"[cellpose_detect] loading image: {path} (z_project={z_project})")

    try:
        stack, meta = _imageio.load_planes(path, z_project=z_project,
                                           channel=None)
    except _imageio.ImageIOError as exc:
        log(f"[cellpose_detect] could not open image: {exc.message} "
            f"({exc.hint})")
        emit_error(exc.code, hint=exc.hint or exc.message, exit_code=3)
        return None
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] could not open image: {exc!r}")
        emit_error("image-open-failed", hint=str(exc), exit_code=3)
        return None

    channel_count = int(stack.shape[2])
    channel_names = list(meta.get("channel_names") or [])
    is_rgb = bool(meta.get("is_rgb", False))

    # Stash the full stack for the per-channel measurement pass.
    setattr(args, "_cc_channel_stack", stack)
    setattr(args, "_cc_channel_names", channel_names)
    setattr(args, "_cc_image_meta", meta)

    seg_channel = int(getattr(args, "segment_channel", 0) or 0)
    is_grayscale_mode = (channels[0] == 0 and channels[1] == 0)

    if is_grayscale_mode:
        if channel_count == 1:
            plane = stack[..., 0]
        elif is_rgb and seg_channel <= 0 and channel_count >= 3:
            # Preserve the legacy `PIL.Image.convert("L")` result bit-for-bit
            # for ordinary RGB photographs.
            plane = _imageio.rgb_luminance(stack)
        else:
            idx = max(0, min(channel_count - 1, seg_channel))
            name = channel_names[idx] if idx < len(channel_names) else f"Ch{idx}"
            log(f"[cellpose_detect] segmenting on channel {idx} ({name}) "
                f"of {channel_count}")
            plane = stack[..., idx]
        img = _imageio.to_uint8(plane, meta)
    else:
        # Cellpose's channels=[cyto, nuclei] index 1=R, 2=G, 3=B into an
        # HxWx3 array. Map source channel k onto RGB slot k so an ordinary RGB
        # photo is an identity and a 2-channel fluorescence stack lands as
        # (ch0 -> "red", ch1 -> "green") — which is what channels=[1,2] means.
        #
        # `--segment-channel` used to be honoured ONLY in grayscale mode and
        # ignored here, so for every caller that sends both flags (all five
        # services do) the channel picker silently did nothing. It now selects
        # which source channel lands in RGB slot 0 — i.e. cellpose channel 1,
        # "red" — with the remaining channels following in their original order.
        # seg_channel 0 is the identity mapping, so the default path is
        # bit-for-bit unchanged.
        height, width = int(stack.shape[0]), int(stack.shape[1])
        rgb = np.zeros((height, width, 3), dtype=np.float32)
        take = min(3, channel_count)
        order = list(range(channel_count))
        seg_idx = max(0, min(channel_count - 1, seg_channel))
        if seg_idx != 0:
            order = [seg_idx] + [c for c in order if c != seg_idx]
            seg_name = (channel_names[seg_idx] if seg_idx < len(channel_names)
                        else f"Ch{seg_idx}")
            log(f"[cellpose_detect] --segment-channel {seg_idx} ({seg_name}) "
                f"mapped onto cellpose channel 1 (red); channel order is now "
                f"{order[:take]}")
        for slot in range(take):
            rgb[..., slot] = stack[..., order[slot]]
        if channel_count > 3:
            log(f"[cellpose_detect] {channel_count} channels present; cellpose "
                "channel mode uses the first 3 (intensities are still measured "
                "in all of them)")
        img = _imageio.to_uint8(rgb, meta)

    import _preprocessing  # noqa: E402
    img = _preprocessing.apply(img, args)
    return img


# ---------------------------------------------------------------------------
# QC metrics — focus score (Laplacian variance) + illumination residual.
# ---------------------------------------------------------------------------

def detected_calibration_stats(args) -> dict:
    """The µm/pixel calibration READ FROM THE IMAGE, as pixels per micrometre.

    `_imageio` already parses a real physical pixel size out of CZI / ND2 / LIF
    / OIF / OME-TIFF / ImageJ metadata into ``meta["pixel_size_um"]``, and
    until now nothing in the app looked at it — researchers kept typing
    ``--pxPerUm`` by hand while the correct number sat unused in the file.

    This only EXPOSES it; it changes no calibration behaviour. Every
    measurement still uses the ``--pxPerUm`` the caller passed, so the host can
    compare the two and offer "use the calibration detected in this file"
    without anything silently switching underneath a saved result.

    MIND THE RECIPROCAL: ``pixel_size_um`` is µm per pixel, this app's
    convention is PIXELS per µm, so the reported value is ``1 / pixel_size_um``.

    Returns ``{}`` when the file carried no calibration.
    """
    meta = getattr(args, "_cc_image_meta", None) or {}
    px_um = meta.get("pixel_size_um")
    try:
        px_um = float(px_um)
    except (TypeError, ValueError):
        return {}
    if not (px_um > 0) or px_um != px_um or px_um in (float("inf"),):
        return {}
    detected = 1.0 / px_um
    out = {
        "detected_px_per_um": detected,
        "detected_pixel_size_um": px_um,
    }
    requested = getattr(args, "pxPerUm", None)
    try:
        requested = float(requested)
    except (TypeError, ValueError):
        requested = None
    if requested is not None and requested > 0:
        out["pxPerUm_used"] = requested
        log(f"[cellpose_detect] calibration in file: {detected:.4f} px/µm "
            f"({px_um:.6g} µm/px); --pxPerUm in use: {requested:.4f} px/µm")
    else:
        log(f"[cellpose_detect] calibration in file: {detected:.4f} px/µm "
            f"({px_um:.6g} µm/px)")
    return out


def compute_qc_metrics(img) -> dict:
    """Compute focus_score and illumination_residual on the raw image array.

    Never raises — returns whatever fields succeed.
    """
    import numpy as np

    stats: dict = {}
    try:
        gray = (img.astype(np.float64) if img.ndim == 2
                else img.mean(axis=2).astype(np.float64))

        # Focus: Laplacian variance, normalised to [0, 1] (cap at lap_var=10000).
        try:
            import cv2 as _cv2
            lap_var = float(_cv2.Laplacian(gray, _cv2.CV_64F).var())
        except ImportError:
            from scipy.ndimage import laplace as _sp_laplace
            lap_var = float(_sp_laplace(gray).var())
        focus_score = min(1.0, max(0.0, lap_var / 10000.0))
        stats["focus_score"] = focus_score
        log(f"[cellpose_detect] QC focus_score={focus_score:.4f} (lap_var={lap_var:.1f})")

        # Illumination: residual std / mean after fitting a quadratic surface on a
        # grid capped to the image size. Sampling more points than there are rows
        # (or columns) just round-trips onto the same integer pixels, over-weighting
        # duplicated samples in the lstsq fit — so cap each axis at its extent.
        H, W = gray.shape
        DS = 128
        ny = min(DS, H)
        nx = min(DS, W)
        ys = np.linspace(0, H - 1, ny, dtype=np.float64)
        xs = np.linspace(0, W - 1, nx, dtype=np.float64)
        xv, yv = np.meshgrid(xs, ys)
        xv_f = xv.ravel()
        yv_f = yv.ravel()
        yi = np.clip(np.round(yv_f).astype(int), 0, H - 1)
        xi = np.clip(np.round(xv_f).astype(int), 0, W - 1)
        z = gray[yi, xi]
        A = np.column_stack([
            xv_f ** 2, yv_f ** 2, xv_f * yv_f,
            xv_f, yv_f, np.ones(len(xv_f))
        ])
        coeffs, _, _, _ = np.linalg.lstsq(A, z, rcond=None)
        fitted = A @ coeffs
        residual_std = float((z - fitted).std())
        lum_mean = float(z.mean())
        illumination_residual = (residual_std / lum_mean) if lum_mean > 1e-6 else 0.0
        stats["illumination_residual"] = illumination_residual
        log(f"[cellpose_detect] QC illumination_residual={illumination_residual:.4f}")
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] QC metrics failed (non-fatal): {exc!r}")
    return stats


# ---------------------------------------------------------------------------
# Device resolution — surfaces use_gpu kwarg + optional explicit override.
# ---------------------------------------------------------------------------

def resolve_device(args, torch_mod):
    """Return (override_device | None, use_gpu_kw: bool).

    * ``use_gpu_kw`` reflects ``--no-gpu`` (the kw is True when GPU allowed).
    * ``override_device`` is a torch.device when either ``--device`` is set
      OR GPU is allowed AND MPS/CUDA is available — passed to model
      construction or applied manually after.
    """
    use_gpu_kw = not getattr(args, "no_gpu", False)
    if not use_gpu_kw:
        log("[cellpose_detect] --no-gpu set; forcing CPU inference")

    mps_avail = bool(getattr(torch_mod.backends, "mps", None)
                     and torch_mod.backends.mps.is_available())
    cuda_avail = bool(torch_mod.cuda.is_available())
    log(f"[cellpose_detect] torch={torch_mod.__version__} "
        f"mps_available={mps_avail} cuda_available={cuda_avail}")

    override = None
    arg_device = getattr(args, "device", None)
    if arg_device:
        try:
            override = torch_mod.device(arg_device)
            log(f"[cellpose_detect] --device override -> {override}")
        except Exception as exc:  # noqa: BLE001
            log(f"[cellpose_detect] invalid --device {arg_device!r}: {exc!r}; ignoring")
            override = None
    elif use_gpu_kw and mps_avail:
        override = torch_mod.device("mps")
    elif use_gpu_kw and cuda_avail:
        override = torch_mod.device("cuda")
    return override, use_gpu_kw


# ---------------------------------------------------------------------------
# Watershed + colony post-process — thin wrappers that never raise.
# ---------------------------------------------------------------------------

def apply_watershed_if_requested(masks, args):
    """Optional distance-transform watershed split. Never raises."""
    if not getattr(args, "watershed", False):
        return masks
    try:
        _here = os.path.dirname(os.path.abspath(__file__))
        if _here not in sys.path:
            sys.path.insert(0, _here)
        import _watershed  # noqa: E402
        min_d_px = max(1, int(round(args.watershed_min_distance * args.pxPerUm)))
        log(f"[cellpose_detect] watershed split with min_distance_px={min_d_px}")
        return _watershed.split(masks, min_distance_px=min_d_px)
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] watershed split failed: {exc!r}; using original masks")
        return masks


def compute_colony_stats(masks, args, height_px: int, width_px: int) -> dict:
    """Per-image colony + spatial statistics. Falls back to zero_stats on error."""
    try:
        _here = os.path.dirname(os.path.abspath(__file__))
        if _here not in sys.path:
            sys.path.insert(0, _here)
        import _colony  # noqa: E402
        out = _colony.compute(masks, args.pxPerUm, (height_px, width_px))
        log(f"[cellpose_detect] colony: n_colonies={out.get('n_colonies', 0)} "
            f"confluency={out.get('confluency_pct', 0):.1f}%")
        return out
    except Exception as exc:  # noqa: BLE001
        log(f"[cellpose_detect] colony stats failed (non-fatal): {exc!r}")
        try:
            import _colony  # noqa: E402
            return _colony.zero_stats()
        except Exception:  # noqa: BLE001
            return {}


# ---------------------------------------------------------------------------
# Per-cell measurement loop.
# ---------------------------------------------------------------------------

# Above this many possible label values per present label, the bounding boxes
# are not looked up (scipy's find_objects allocates one slot per value up to
# the largest label). Such labels fall back to the whole image.
_SPARSE_LABEL_FACTOR = 4
_SPARSE_LABEL_FLOOR = 1 << 16


def label_crops(masks, label_ids):
    """Yield ``(label, crop, row0, col0)`` for every label in ``label_ids``.

    ``crop`` is ``masks == label`` restricted to that label's bounding box
    grown by one pixel on each side, but never past the image border.
    ``(row0, col0)`` is the crop's top-left corner in full-image pixels.

    Measuring a cell on this crop gives exactly what the same code gives on
    the full-image ``masks == label``:

    * ``np.nonzero(crop)`` shifted by ``(row0, col0)`` lists the same pixels
      in the same row-major order as ``np.where(masks == label)``, so means,
      medians and fancy-indexed values come out identical.
    * ``skimage.measure.perimeter`` only gives weight to the cell's border
      pixels, whose 3x3 neighbourhoods lie inside the grown box. Outside the
      image both its erosion and its convolution read zeros, as they do for
      the full image.
    * ``skimage.measure.find_contours(..., 0.5)`` visits the squares that
      touch the cell in the same order, so it returns the same contours
      shifted by ``(row0, col0)``. Shift a contour back BEFORE any further
      float processing (``approximate_polygon`` is not translation-exact).
      The box is not grown past the image border because a full-image
      contour stays open there.

    Labels with no usable bounding box (non-integer label maps, labels below
    1, very sparse label values, or scipy unavailable) get the whole image as
    their crop, which is the plain whole-image computation.
    """
    import numpy as np

    height, width = int(masks.shape[0]), int(masks.shape[1])
    objects = None
    if len(label_ids) and np.issubdtype(masks.dtype, np.integer):
        max_label = int(np.max(label_ids))
        limit = max(_SPARSE_LABEL_FLOOR, _SPARSE_LABEL_FACTOR * len(label_ids))
        if 1 <= max_label <= limit:
            try:
                from scipy.ndimage import find_objects
                objects = find_objects(masks)
            except Exception:  # noqa: BLE001
                objects = None

    for label in label_ids:
        box = None
        if objects is not None:
            index = int(label) - 1
            if 0 <= index < len(objects):
                box = objects[index]
        if box is None:
            row0, row1, col0, col1 = 0, height, 0, width
        else:
            row0 = max(box[0].start - 1, 0)
            row1 = min(box[0].stop + 1, height)
            col0 = max(box[1].start - 1, 0)
            col1 = min(box[1].stop + 1, width)
        yield label, masks[row0:row1, col0:col1] == label, row0, col0


def simplify_chains(chains, tolerance):
    """``skimage.measure.approximate_polygon(chain, tolerance)`` for many
    chains at once, with the same result bit for bit.

    Douglas–Peucker splits each segment independently, so every segment of
    every chain can be handled in one vectorised pass per split level. Each
    distance uses the same float64 operations in the same order as
    scikit-image, and ties pick the first point, like ``np.argmax``.
    """
    import numpy as np

    if not chains:
        return []
    if tolerance <= 0:
        return list(chains)
    lens = np.array([len(c) for c in chains], dtype=np.int64)
    offs = np.zeros(len(chains), dtype=np.int64)
    np.cumsum(lens[:-1], out=offs[1:])
    points = np.concatenate(chains)
    rows = np.ascontiguousarray(points[:, 0])
    cols = np.ascontiguousarray(points[:, 1])
    keep = np.zeros(len(points), dtype=bool)
    keep[offs] = True
    keep[offs + lens - 1] = True
    starts, ends = offs.copy(), offs + lens - 1
    while True:
        inner = ends - starts >= 2
        starts, ends = starts[inner], ends[inner]
        if starts.size == 0:
            break
        r0, c0, r1, c1 = rows[starts], cols[starts], rows[ends], cols[ends]
        dr = r1 - r0
        dc = c1 - c0
        angle = -np.arctan2(dr, dc)
        sin_a = np.sin(angle)
        cos_a = np.cos(angle)
        dist = c0 * sin_a + r0 * cos_a
        counts = ends - starts - 1
        first = np.zeros(counts.size, dtype=np.int64)
        np.cumsum(counts[:-1], out=first[1:])
        seg = np.repeat(np.arange(counts.size), counts)
        idx = np.arange(int(counts.sum())) - first[seg] + starts[seg] + 1
        pr, pc = rows[idx], cols[idx]
        dr0 = pr - r0[seg]
        dc0 = pc - c0[seg]
        dr1 = pr - r1[seg]
        dc1 = pc - c1[seg]
        seg_dr, seg_dc = dr[seg], dc[seg]
        perp = np.logical_and(dr0 * seg_dr + dc0 * seg_dc > 0,
                              -dr1 * seg_dr - dc1 * seg_dc > 0)
        d = np.where(perp,
                     np.abs(pr * cos_a[seg] + pc * sin_a[seg] - dist[seg]),
                     np.minimum(np.sqrt(dc0 ** 2 + dr0 ** 2),
                                np.sqrt(dc1 ** 2 + dr1 ** 2)))
        peak = np.maximum.reduceat(d, first)
        split = peak > tolerance
        at_peak = np.where(d == peak[seg], np.arange(d.size), d.size)
        new = (starts + np.minimum.reduceat(at_peak, first) - first + 1)[split]
        keep[new] = True
        starts = np.concatenate([new, starts[split]])
        ends = np.concatenate([ends[split], new])
    return [points[o:o + n][keep[o:o + n]] for o, n in zip(offs, lens)]


def measure_cells(masks, img, args, flows=None, channel_stack=None,
                  channel_names=None) -> list[dict]:
    """Build the list of per-cell dicts matching SidecarPayload's schema.

    * masks: HxW int label map (0 = background).
    * img:   HxW or HxWx3 uint8 array used for the legacy single-plane
             intensity measurements (``mean_intensity``/``integrated_density``).
    * args:  argparse.Namespace — must have pxPerUm, small_threshold,
             large_threshold.
    * flows: optional eval flows tuple. flows[2] (when present and
             shape-matched) is read as the cellprob/confidence map.
    * channel_stack:  optional (H, W, C) float32 array in RAW source units.
             Defaults to ``args._cc_channel_stack``, which
             ``open_image_for_detection`` sets for every load.
    * channel_names:  optional list[str], one per channel. Defaults to
             ``args._cc_channel_names``; missing entries become "Ch<i>".

    MULTI-CHANNEL CONTRACT — when the stack has C > 1 every cell dict also
    carries, in exactly this shape:

        "channel_intensities": [
            {"channel": 0, "name": "DAPI", "mean": 123.4,
             "integrated": 45678.0, "median": 120.0},
            {"channel": 1, "name": "GFP", "mean": 55.1,
             "integrated": 20100.0, "median": 51.0}
        ]

    one entry per channel, ordered by channel index, measured over the cell's
    own mask. ``integrated`` is ``mean * area_px``, matching the definition of
    the existing ``integrated_density`` field. Values are in the source file's
    RAW units (NOT rescaled to 0–255) so cross-channel and cross-image
    comparisons stay meaningful.

    The key is OMITTED ENTIRELY when C == 1. The existing single-channel
    ``mean_intensity`` / ``integrated_density`` fields are unchanged.
    """
    import numpy as np

    # Cellprob map for per-cell confidence — same index for v3.x and v4.x.
    cellprob_map = None
    if flows is not None:
        try:
            candidate = flows[2]
            if hasattr(candidate, "shape") and candidate.shape == masks.shape:
                cellprob_map = candidate
        except Exception:  # noqa: BLE001
            cellprob_map = None

    px_per_um = float(args.pxPerUm) if args.pxPerUm > 0 else 1.0

    # skimage helpers (optional — perimeter/eccentricity/contours omitted otherwise).
    try:
        from skimage.measure import (perimeter as sk_perimeter,
                                     regionprops,
                                     find_contours as sk_find_contours,
                                     approximate_polygon as sk_approx_polygon)
        _skimage_ok = True
    except ImportError:
        _skimage_ok = False
        sk_perimeter = None  # type: ignore
        regionprops = None  # type: ignore
        sk_find_contours = None  # type: ignore
        sk_approx_polygon = None  # type: ignore
        log("[cellpose_detect] skimage not available — perimeter/eccentricity/"
            "contours will be omitted")

    if img.ndim == 2:
        img_gray = img.astype(np.float64)
    else:
        img_gray = img.mean(axis=2).astype(np.float64)

    height_px, width_px = int(img.shape[0]), int(img.shape[1])

    # --- Per-channel planes for the "channel_intensities" contract ----------
    # Only engaged when the source really had >1 channel AND the stack lines up
    # with the mask grid (a half-resolution retry, a crop, or a caller that
    # never went through open_image_for_detection all land here as "no stack",
    # which just means the key is omitted — never a crash).
    if channel_stack is None:
        channel_stack = getattr(args, "_cc_channel_stack", None)
    if channel_names is None:
        channel_names = getattr(args, "_cc_channel_names", None)

    channel_planes: list = []
    resolved_names: list[str] = []
    if channel_stack is not None:
        try:
            stack_arr = np.asarray(channel_stack)
            if (stack_arr.ndim == 3 and stack_arr.shape[2] > 1
                    and stack_arr.shape[:2] == masks.shape):
                n_ch = int(stack_arr.shape[2])
                raw_names = list(channel_names or [])
                for c in range(n_ch):
                    name = (str(raw_names[c]).strip()
                            if c < len(raw_names) and raw_names[c] is not None
                            else "")
                    resolved_names.append(name if name else f"Ch{c}")
                    channel_planes.append(
                        np.ascontiguousarray(stack_arr[..., c],
                                             dtype=np.float64))
                log(f"[cellpose_detect] measuring per-cell intensities in "
                    f"{n_ch} channels: {resolved_names}")
            elif stack_arr.ndim == 3 and stack_arr.shape[2] > 1:
                log("[cellpose_detect] channel stack "
                    f"{stack_arr.shape[:2]} does not match masks "
                    f"{masks.shape}; omitting channel_intensities")
        except Exception as exc:  # noqa: BLE001
            log(f"[cellpose_detect] per-channel setup failed (non-fatal): "
                f"{exc!r}")
            channel_planes = []
            resolved_names = []

    if _skimage_ok:
        try:
            props_by_label = {p.label: p for p in regionprops(masks)}
        except Exception:  # noqa: BLE001
            props_by_label = {}
    else:
        props_by_label = {}

    label_ids = np.unique(masks)
    label_ids = label_ids[label_ids != 0]
    n_total = len(label_ids)
    log(f"[cellpose_detect] found {n_total} masks; measuring per-cell properties…")

    progress_every = max(50, n_total // 10) if n_total else 1
    cells: list[dict] = []
    pending_outlines: list = []

    small_t = float(getattr(args, "small_threshold", 20))
    large_t = float(getattr(args, "large_threshold", 30))
    EDGE_MARGIN_PX = 16

    # Each cell is measured on a small crop around its bounding box rather
    # than on a full-image mask: `mask` is that crop and (row0, col0) its
    # top-left corner. `ys`/`xs` are full-image coordinates. See
    # `label_crops` for why the numbers are unchanged.
    for cell_idx, (label, mask, row0, col0) in enumerate(
            label_crops(masks, label_ids)):
        if cell_idx > 0 and cell_idx % progress_every == 0:
            log(f"[cellpose_detect] measured {cell_idx}/{n_total} cells…")
        crop_ys, crop_xs = np.nonzero(mask)
        area_px = int(crop_ys.size)
        if area_px < 4:
            continue
        ys = crop_ys + row0
        xs = crop_xs + col0
        cy = float(ys.mean())
        cx = float(xs.mean())
        diameter_px = 2.0 * math.sqrt(area_px / math.pi)
        diameter_um = diameter_px / px_per_um

        if cellprob_map is not None:
            try:
                raw = float(cellprob_map[ys, xs].mean())
                conf = 1.0 / (1.0 + math.exp(-raw))
            except Exception:  # noqa: BLE001
                conf = 0.85
        else:
            conf = 0.85

        area_um2 = area_px / (px_per_um ** 2)

        perimeter_um = None
        circularity = None
        if _skimage_ok:
            try:
                # scikit-image renamed `neighbourhood` → `neighborhood` in 0.26.
                # Try the new spelling, fall back to the old one.
                try:
                    perim_px = sk_perimeter(mask, neighborhood=8)
                except TypeError:
                    perim_px = sk_perimeter(mask, neighbourhood=8)
                if perim_px > 0:
                    perimeter_um = perim_px / px_per_um
                    circularity = min(1.0, max(0.0,
                        4 * math.pi * area_um2 / (perimeter_um ** 2)))
            except Exception:  # noqa: BLE001
                pass

        eccentricity = None
        if _skimage_ok and int(label) in props_by_label:
            try:
                eccentricity = float(props_by_label[int(label)].eccentricity)
            except Exception:  # noqa: BLE001
                pass

        mean_intensity = float(img_gray[ys, xs].mean()) if area_px else None
        integrated_density = ((area_px * mean_intensity)
                              if mean_intensity is not None else None)

        centroid_um_x = cx / px_per_um
        centroid_um_y = cy / px_per_um

        aspect_ratio = 1.0
        if _skimage_ok and int(label) in props_by_label:
            try:
                prop = props_by_label[int(label)]
                minor = float(prop.minor_axis_length)
                if minor > 0:
                    aspect_ratio = float(prop.major_axis_length) / minor
            except Exception:  # noqa: BLE001
                pass

        solidity = None
        if _skimage_ok and int(label) in props_by_label:
            try:
                solidity = float(props_by_label[int(label)].solidity)
            except Exception:  # noqa: BLE001
                pass

        edge_touching = (
            cx < EDGE_MARGIN_PX or cy < EDGE_MARGIN_PX
            or cx > (width_px - EDGE_MARGIN_PX)
            or cy > (height_px - EDGE_MARGIN_PX)
        )

        likely_clump = diameter_um > 80.0
        likely_debris = (
            solidity is not None and solidity < 0.7
            and diameter_um < 8.0
            and mean_intensity is not None and mean_intensity > 220.0
        )

        if diameter_um < small_t:
            size_class = "small"
        elif diameter_um < large_t:
            size_class = "intermediate"
        else:
            size_class = "large"

        cell_dict: dict = {
            "id": str(uuid.uuid4()),
            "cx": cx,
            "cy": cy,
            "diameter_um": diameter_um,
            "diameter_px": diameter_px,
            "confidence": conf,
            "area_um2": area_um2,
            "centroid_um_x": centroid_um_x,
            "centroid_um_y": centroid_um_y,
            "aspect_ratio": aspect_ratio,
            "edge_touching": edge_touching,
            "likely_clump": likely_clump,
            "likely_debris": likely_debris,
            "size_class": size_class,
            "is_manual": False,
        }
        if solidity is not None:
            cell_dict["solidity"] = solidity
        if perimeter_um is not None:
            cell_dict["perimeter_um"] = perimeter_um
        if circularity is not None:
            cell_dict["circularity"] = circularity
        if eccentricity is not None:
            cell_dict["eccentricity"] = eccentricity
        if mean_intensity is not None:
            cell_dict["mean_intensity"] = mean_intensity
        if integrated_density is not None:
            cell_dict["integrated_density"] = integrated_density

        # Per-cell, per-channel intensities. Key omitted entirely when the
        # source was single-channel (channel_planes stays empty).
        if channel_planes:
            try:
                per_channel: list[dict] = []
                for c, plane in enumerate(channel_planes):
                    values = plane[ys, xs]
                    ch_mean = float(values.mean())
                    per_channel.append({
                        "channel": c,
                        "name": resolved_names[c],
                        "mean": ch_mean,
                        "integrated": ch_mean * area_px,
                        "median": float(np.median(values)),
                    })
                cell_dict["channel_intensities"] = per_channel
            except Exception as exc:  # noqa: BLE001
                log("[cellpose_detect] channel intensities failed for label "
                    f"{int(label)} (non-fatal): {exc!r}")

        # Per-cell polygon contour for filled overlay rendering.
        # find_contours returns (row, col) pairs at 0.5 iso-level, shifted
        # here to full-image pixels. Contours longer than 4 points are
        # simplified with Ramer–Douglas–Peucker after the loop, all at once.
        if _skimage_ok and sk_find_contours is not None:
            try:
                contours = sk_find_contours(mask.astype(np.uint8), 0.5)
                if contours:
                    best = max(contours, key=len) + np.array(
                        [row0, col0], dtype=np.float64)
                    if sk_approx_polygon is not None and len(best) > 4:
                        pending_outlines.append((cell_dict, best))
                    else:
                        _set_contour(cell_dict, best)
            except Exception:  # noqa: BLE001
                pass

        cells.append(cell_dict)

    if pending_outlines:
        chains = [chain for _, chain in pending_outlines]
        try:
            simplified = simplify_chains(chains, 0.5)
        except Exception as exc:  # noqa: BLE001
            log(f"[cellpose_detect] batched outline simplification failed "
                f"({exc!r}); simplifying one by one")
            simplified = []
            for chain in chains:
                try:
                    simplified.append(sk_approx_polygon(chain, tolerance=0.5))
                except Exception:  # noqa: BLE001
                    simplified.append(None)
        for (cell_dict, _), approx in zip(pending_outlines, simplified):
            if approx is not None:
                _set_contour(cell_dict, approx)

    log(f"[cellpose_detect] measured {len(cells)}/{n_total} cells; serializing JSON…")
    return cells


def _set_contour(cell_dict, approx):
    """Store a (row, col) outline as ≤200 (x, y) points."""
    import math
    if len(approx) > 200:
        stride = int(math.ceil(len(approx) / 200.0))
        approx = approx[::stride]
    cell_dict["contour_px"] = [[float(pt[1]), float(pt[0])] for pt in approx]


# ---------------------------------------------------------------------------
# Final payload writer.
# ---------------------------------------------------------------------------

def emit_payload(width_px: int, height_px: int, cells: list[dict],
                 image_stats: dict) -> None:
    """Write the final JSON payload to stdout and flush."""
    payload = {
        "width": width_px,
        "height": height_px,
        "cells": cells,
        "image_stats": image_stats,
    }
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()
    log(f"[cellpose_detect] emitted {len(cells)} cells")
