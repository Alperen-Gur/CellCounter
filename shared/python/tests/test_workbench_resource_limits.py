"""CellCounter's Model resource use in Workbench model runs.

Standard library only: a stand-in torch, no model, and the background state
is never applied to the test process.
"""
from __future__ import annotations

import contextlib
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import _workbench_resource_limits as limits  # noqa: E402
import _workbench_environment as environments  # noqa: E402

LIGHT_ENVIRONMENT = {
    "OMP_NUM_THREADS": "2", "MKL_NUM_THREADS": "2", "OPENBLAS_NUM_THREADS": "2",
    "VECLIB_MAXIMUM_THREADS": "2", "NUMEXPR_NUM_THREADS": "2", "TF_NUM_INTRAOP_THREADS": "2",
    "TF_NUM_INTEROP_THREADS": "2", "OPENCV_FOR_THREADS_NUM": "2", "CC_CPU_THREADS": "2",
    "PYTORCH_MPS_HIGH_WATERMARK_RATIO": "0.6250", "PYTORCH_MPS_LOW_WATERMARK_RATIO": "0.5000",
    "CC_MEMORY_LIMIT_GB": "5",
}


class FakeTorch(types.ModuleType):
    def __init__(self, default_threads=8):
        super().__init__("torch")
        self.threads, self.fractions, self.default_threads = [], [], default_threads
        self.mps = types.SimpleNamespace(set_per_process_memory_fraction=self.fractions.append)
        self.backends = types.SimpleNamespace(mps=types.SimpleNamespace(is_available=lambda: True))

    def set_num_threads(self, n):
        self.threads.append(n)

    def get_num_threads(self):
        return self.threads[-1] if self.threads else self.default_threads


def reset_state():
    limits._state.update(active=False, threads=None, default_threads=None, fraction=None, background=None)


class WorkbenchResourceLimitTests(unittest.TestCase):
    def setUp(self):
        reset_state()
        self.addCleanup(reset_state)
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = os.path.join(directory.name, "limits.json")

    def write(self, **values):
        state = {"version": 1, "preset": "light", "cpu_threads": 2, "default_cpu_threads": 8,
                 "memory_fraction": 0.625, "memory_limit_gb": 5, "background": True,
                 "environment": dict(LIGHT_ENVIRONMENT)}
        state.update(values)
        with open(self.path, "w") as handle:
            json.dump(state, handle)

    @contextlib.contextmanager
    def environment(self, **values):
        with patch.dict(os.environ, {}, clear=False):
            for key in limits.KEYS:
                os.environ.pop(key, None)
            os.environ.update(values)
            yield

    # -- launch environment -------------------------------------------------

    def test_model_runs_start_with_the_apps_limits_and_the_file_path(self):
        self.write()
        allowlisted = {"PATH": "/usr/bin", "HOME": "/Users/someone"}
        env = limits.environment(allowlisted, source={"CC_LIMITS_FILE": self.path})
        self.assertEqual(env, {**allowlisted, **LIGHT_ENVIRONMENT, "CC_LIMITS_FILE": self.path})

    def test_existing_values_are_kept_and_an_mps_override_keeps_both_ratios_out(self):
        self.write()
        env = limits.environment({"OMP_NUM_THREADS": "8"},
                                 source={"CC_LIMITS_FILE": self.path, "PYTORCH_MPS_LOW_WATERMARK_RATIO": "0.0"})
        self.assertEqual(env["OMP_NUM_THREADS"], "8")
        self.assertEqual(env["PYTORCH_MPS_LOW_WATERMARK_RATIO"], "0.0")   # passed through unchanged
        self.assertNotIn("PYTORCH_MPS_HIGH_WATERMARK_RATIO", env)
        self.assertNotIn("CC_MEMORY_LIMIT_GB", env)
        self.assertEqual(env["CC_CPU_THREADS"], "2")

    def test_only_known_string_variables_are_taken_from_the_file(self):
        self.write(environment={"OMP_NUM_THREADS": "2", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib",
                                "PYTHONPATH": "/tmp", "CC_CPU_THREADS": 2})
        env = limits.environment({}, source={"CC_LIMITS_FILE": self.path})
        self.assertEqual(env, {"OMP_NUM_THREADS": "2", "CC_LIMITS_FILE": self.path})

    def test_without_the_apps_file_nothing_is_added(self):
        env = limits.environment({"PATH": "/usr/bin"}, source={"CC_LIMITS_FILE": self.path + ".missing"})
        self.assertEqual(env, {"PATH": "/usr/bin", "CC_LIMITS_FILE": self.path + ".missing"})
        self.assertEqual(limits.environment({"PATH": "/usr/bin"}, source={"TMPDIR": "/nonexistent"}),
                         {"PATH": "/usr/bin"})

    def test_the_default_path_is_the_apps_fixed_per_user_file(self):
        with self.environment():
            self.assertEqual(limits.limits_file(),
                             os.path.join(tempfile.gettempdir(), "cellcounter-model-limits.json"))
            os.environ["CC_LIMITS_FILE"] = self.path
            self.assertEqual(limits.limits_file(), self.path)

    def test_the_recorded_environment_never_depends_on_the_limits(self):
        with self.environment():
            plain = environments.capture()
        self.write()
        with self.environment(**LIGHT_ENVIRONMENT, CC_LIMITS_FILE=self.path):
            limited = environments.capture()
        self.assertEqual(plain["hash"], limited["hash"])
        self.assertEqual(plain, limited)
        self.assertNotIn("OMP_NUM_THREADS", json.dumps(limited))

    # -- live changes ---------------------------------------------------------

    def test_threads_follow_the_file_and_return_to_the_default(self):
        torch = FakeTorch()
        with self.environment(CC_LIMITS_FILE=self.path, CC_CPU_THREADS="2",
                              PYTORCH_MPS_HIGH_WATERMARK_RATIO="0.6250", CC_MEMORY_LIMIT_GB="5"):
            self.write(cpu_threads=2)
            self.assertTrue(limits.apply(torch))
            self.write(cpu_threads=4)
            limits.apply(torch)
            self.write(cpu_threads=None)
            limits.apply(torch)
        self.assertEqual(torch.threads, [4, 8])

    def test_a_cap_is_raised_at_once_but_never_lowered_during_a_run(self):
        torch = FakeTorch()
        with self.environment(CC_LIMITS_FILE=self.path, CC_CPU_THREADS="2",
                              PYTORCH_MPS_HIGH_WATERMARK_RATIO="0.6250", CC_MEMORY_LIMIT_GB="5"):
            self.write(memory_fraction=None, memory_limit_gb=None)   # Balanced or Maximum
            limits.apply(torch)
            self.write(memory_fraction=0.5, memory_limit_gb=4)       # lower: next run
            limits.apply(torch)
        self.assertEqual(torch.fractions, [1.7])

    def test_a_developers_own_cap_is_left_alone(self):
        torch = FakeTorch()
        with self.environment(CC_LIMITS_FILE=self.path, PYTORCH_MPS_HIGH_WATERMARK_RATIO="0.9"):
            self.write(memory_fraction=1.2)
            limits.apply(torch)
        self.assertEqual(torch.fractions, [])

    @unittest.skipUnless(hasattr(signal, "SIGINFO"), "this platform has no SIGINFO")
    def test_a_running_worker_follows_a_change_without_restarting(self):
        torch = FakeTorch()
        background = []
        previous = signal.getsignal(signal.SIGINFO)
        self.addCleanup(signal.signal, signal.SIGINFO, previous)
        limits._stop.clear()
        self.addCleanup(limits._stop.set)
        self.write(cpu_threads=2, background=True)
        with self.environment(CC_LIMITS_FILE=self.path, CC_CPU_THREADS="2"), \
                patch.dict(sys.modules, {"torch": torch}), \
                patch.object(limits, "set_background", background.append):
            self.assertTrue(limits.activate(interval=0.02))
            self.assertFalse(limits.activate(interval=0.02))         # once per worker
            self.assertEqual(background, [True])
            time.sleep(0.05)
            self.write(cpu_threads=6, background=False)              # Light -> Custom
            deadline = time.monotonic() + 5
            while torch.threads != [6] and time.monotonic() < deadline:
                time.sleep(0.01)                                      # the handler runs here
        self.assertEqual(torch.threads, [6])
        self.assertEqual(background[-1], False)

    def test_activate_needs_the_apps_file_and_the_main_thread(self):
        with self.environment():
            self.assertFalse(limits.activate())
        results = []
        with self.environment(CC_LIMITS_FILE=self.path):
            worker = threading.Thread(target=lambda: results.append(limits.activate()))
            worker.start()
            worker.join()
        self.assertEqual(results, [False])


if __name__ == "__main__":
    unittest.main()
