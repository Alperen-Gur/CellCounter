"""CellCounter's Model resource use setting for Workbench model runs.

The app writes its current choice (Settings -> General -> Model resource use)
to a small JSON control file: PyTorch's thread count, the GPU memory cap,
Light's background priority, and the environment variables a new model
process starts with. Workbench model runs are started by request processes
and detached job workers the app does not track, so they read that file
themselves. Standard library only; outside macOS only the environment
variables apply.

* `environment(env)` adds the launch variables (thread counts for PyTorch,
  Accelerate/OpenBLAS, NumExpr, TensorFlow and OpenCV; PyTorch's MPS memory
  limits) and the file's path to a model worker's allowlisted environment.
  A key already set is never changed, and if either MPS ratio is already
  set neither is added.
* `activate()`, inside a model worker before it runs a model, enters the
  background state for Light and follows later changes: a daemon thread
  watches the file and signals the main thread (SIGINFO), whose handler sets
  PyTorch's thread count and raises or removes the GPU memory cap. A lower
  cap applies from the next model run, so a running one is never stopped by
  the change.

None of these values reach a recorded environment inventory
(`_workbench_environment.capture` records installed distributions, never
environment variables), a request hash or a model result (the workers add
nothing to it), so recorded provenance and environment hashes are the same
whichever choice was in effect. `KEYS` lists every variable involved.
"""
from __future__ import annotations

import json
import os
import signal
import sys
import tempfile
import threading

FILE_ENV = "CC_LIMITS_FILE"
# The app's fixed per-user path, used when no path was passed down.
DEFAULT_FILE_NAME = "cellcounter-model-limits.json"
MPS_HIGH = "PYTORCH_MPS_HIGH_WATERMARK_RATIO"
MPS_LOW = "PYTORCH_MPS_LOW_WATERMARK_RATIO"
MEMORY_KEYS = frozenset({MPS_HIGH, MPS_LOW, "CC_MEMORY_LIMIT_GB"})
# Exactly the variables `ModelResourceLimits.environmentAdditions` may add.
LAUNCH_KEYS = frozenset({
    "OMP_NUM_THREADS", "MKL_NUM_THREADS", "OPENBLAS_NUM_THREADS", "VECLIB_MAXIMUM_THREADS",
    "NUMEXPR_NUM_THREADS", "TF_NUM_INTRAOP_THREADS", "TF_NUM_INTEROP_THREADS",
    "OPENCV_FOR_THREADS_NUM", "CC_CPU_THREADS",
}) | MEMORY_KEYS
# Never part of a recorded environment (see `_workbench_environment`).
KEYS = LAUNCH_KEYS | {FILE_ENV}

PYTORCH_DEFAULT_MPS_FRACTION = 1.7
_SIGNAL = getattr(signal, "SIGINFO", None)
_PRIO_DARWIN_PROCESS = 4      # sys/resource.h
_PRIO_DARWIN_BG = 0x1000

_state = {"active": False, "threads": None, "default_threads": None,
          "fraction": None, "background": None}
# Set only by tests; a model worker follows the file until it exits.
_stop = threading.Event()


def limits_file(source=None) -> str:
    """`CC_LIMITS_FILE`, else the app's fixed file in the per-user temporary folder."""
    source = os.environ if source is None else source
    if source.get(FILE_ENV):
        return source[FILE_ENV]
    directory = source.get("TMPDIR") or tempfile.gettempdir()
    return os.path.join(os.path.abspath(directory), DEFAULT_FILE_NAME)


def read(path=None):
    """The app's current limits, or None when absent or unreadable."""
    try:
        with open(path or limits_file(), "rb") as handle:
            state = json.loads(handle.read(65536))
    except (OSError, ValueError):
        return None
    return state if isinstance(state, dict) and state.get("version") == 1 else None


def environment(env, source=None) -> dict:
    """`env` (an allowlisted child environment) plus the current launch limits."""
    source = os.environ if source is None else source
    result = dict(env)
    # A developer's own values, or limits this process was started with.
    for key in KEYS:
        if key in source and key not in result:
            result[key] = source[key]
    path = limits_file(source)
    state = read(path)
    if state is None:
        return result
    additions = state.get("environment")
    if isinstance(additions, dict):
        mps_overridden = MPS_HIGH in result or MPS_LOW in result
        for key, value in additions.items():
            if key not in LAUNCH_KEYS or not isinstance(value, str):
                continue
            if mps_overridden and key in MEMORY_KEYS:
                continue
            result.setdefault(key, value)
    result.setdefault(FILE_ENV, path)
    return result


def activate(interval=2.0) -> bool:
    """Follow the app's limits for the rest of this model worker. Main thread; once."""
    if _state["active"] or not os.environ.get(FILE_ENV):
        return False
    if threading.current_thread() is not threading.main_thread():
        return False
    _state["active"] = True
    path = os.environ[FILE_ENV]
    current = read(path)
    if current is not None:
        set_background(bool(current.get("background")))
    signal_main = _install_handler()
    threading.Thread(target=_watch, args=(path, interval, signal_main),
                     name="cellcounter-resource-limits", daemon=True).start()
    return True


def _install_handler() -> bool:
    if _SIGNAL is None:
        return False
    try:
        if signal.getsignal(_SIGNAL) not in (signal.SIG_DFL, signal.SIG_IGN, None):
            return False
        signal.signal(_SIGNAL, _on_signal)
        # Interrupted system calls restart, so native code never sees EINTR.
        signal.siginterrupt(_SIGNAL, False)
    except (ValueError, OSError, AttributeError):
        return False
    return True


def _stamp(path):
    try:
        info = os.stat(path)
    except OSError:
        return None
    return info.st_ino, info.st_mtime_ns, info.st_size


def _watch(path, interval, signal_main) -> None:
    last, torch_loaded = _stamp(path), "torch" in sys.modules
    while not _stop.wait(interval):
        stamp, loaded = _stamp(path), "torch" in sys.modules
        if stamp == last and loaded == torch_loaded:
            continue
        last, torch_loaded = stamp, loaded
        current = read(path)
        if current is None:
            continue
        # Process-wide, so safe from this thread.
        set_background(bool(current.get("background")))
        if signal_main and loaded:
            # Thread count and allocator limit are set on the main thread.
            signal.pthread_kill(threading.main_thread().ident, _SIGNAL)


def _on_signal(signum, frame) -> None:
    # Runs in the main thread between bytecodes; writes nothing.
    try:
        apply()
    except Exception:  # noqa: BLE001
        pass


def set_background(background: bool) -> bool:
    """Enter or leave Darwin's background state (lowest CPU and I/O priority)."""
    if sys.platform != "darwin" or _state["background"] == background:
        return False
    try:
        import ctypes
        libc = ctypes.CDLL(None, use_errno=True)
        libc.setpriority.argtypes = (ctypes.c_int, ctypes.c_uint, ctypes.c_int)
        if libc.setpriority(_PRIO_DARWIN_PROCESS, 0, _PRIO_DARWIN_BG if background else 0) != 0:
            return False
    except (OSError, AttributeError):
        return False
    _state["background"] = background
    return True


def _positive_int(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else None


def _launch_int(key):
    try:
        value = int(os.environ.get(key, ""))
    except ValueError:
        return None
    return value if value > 0 else None


def apply(torch_mod=None) -> bool:
    """Apply the file's thread count and a higher or removed GPU memory cap."""
    torch_mod = torch_mod if torch_mod is not None else sys.modules.get("torch")
    current = read(limits_file())
    if torch_mod is None or current is None:
        return False
    _apply_threads(torch_mod, current)
    _apply_memory(torch_mod, current)
    return True


def _apply_threads(torch_mod, current) -> None:
    launched = _launch_int("CC_CPU_THREADS")
    now = _state["threads"] if _state["threads"] is not None else launched
    if now is None and _state["default_threads"] is None:
        try:
            _state["default_threads"] = int(torch_mod.get_num_threads())
        except Exception:  # noqa: BLE001
            pass
    target = _positive_int(current.get("cpu_threads"))
    if target is None:
        # Maximum: PyTorch's own default; a process never limited is left alone.
        if now is None:
            return
        target = _state["default_threads"] or _positive_int(current.get("default_cpu_threads"))
        if target is None:
            return
    if target == now:
        return
    try:
        torch_mod.set_num_threads(target)
    except Exception:  # noqa: BLE001
        return
    _state["threads"] = target


def _apply_memory(torch_mod, current) -> None:
    # A cap CellCounter did not set (it always names its own) is left alone.
    if os.environ.get(MPS_HIGH) and not os.environ.get("CC_MEMORY_LIMIT_GB"):
        return
    target = current.get("memory_fraction")
    if isinstance(target, bool) or not isinstance(target, (int, float)) or not 0 < target <= 2:
        target = PYTORCH_DEFAULT_MPS_FRACTION
    try:
        launched = float(os.environ.get(MPS_HIGH, ""))
    except ValueError:
        launched = PYTORCH_DEFAULT_MPS_FRACTION
    now = _state["fraction"] if _state["fraction"] is not None else launched
    if float(target) <= now:
        return      # equal, or lower: from the next model run
    mps = getattr(torch_mod, "mps", None)
    backend = getattr(getattr(torch_mod, "backends", None), "mps", None)
    setter = getattr(mps, "set_per_process_memory_fraction", None)
    try:
        if setter is None or backend is None or not backend.is_available():
            return
        setter(float(target))
    except Exception:  # noqa: BLE001
        return
    _state["fraction"] = float(target)
