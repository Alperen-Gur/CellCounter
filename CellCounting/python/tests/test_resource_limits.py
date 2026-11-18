"""Model resource limits on the Python side (Settings → General → Model resource use).

The host passes the limits in the environment. These tests use a stand-in
torch module and never import numpy or torch.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import _cellpose_common as cc  # noqa: E402

MPS_OOM = ("MPS backend out of memory (MPS allocated: 4.20 GB, other allocations: 1.10 GB, "
           "max allowed: 5.00 GB). Tried to allocate 256.00 MB on private pool. Use "
           "PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0 to disable upper limit for memory "
           "allocations (may cause system failure).")


class FakeTorch(types.ModuleType):
    def __init__(self, refuse_interop=False):
        super().__init__("torch")
        self.threads = []
        self.interop = []
        self.refuse_interop = refuse_interop

    def set_num_threads(self, n):
        self.threads.append(n)

    def set_num_interop_threads(self, n):
        if self.refuse_interop:
            raise RuntimeError("Error: cannot set number of interop threads after parallel work has started")
        self.interop.append(n)


def reset_live_state():
    cc._live.clear()
    cc._live.update(cc._fresh_live_state())
    cc._cpu_threads_applied = False


class CPUThreadLimitTests(unittest.TestCase):
    def setUp(self):
        reset_live_state()
        self.addCleanup(reset_live_state)

    def apply(self, env, torch_mod):
        with patch.dict(os.environ, env, clear=False), contextlib.redirect_stderr(io.StringIO()):
            if "CC_CPU_THREADS" not in env:
                os.environ.pop("CC_CPU_THREADS", None)
            cc.apply_cpu_thread_limit(torch_mod)

    def test_threads_are_applied_once_per_process(self):
        torch = FakeTorch()
        self.apply({"CC_CPU_THREADS": "4"}, torch)
        self.apply({"CC_CPU_THREADS": "4"}, torch)
        self.assertEqual(torch.threads, [4])
        self.assertEqual(torch.interop, [2])

    def test_one_thread_keeps_one_interop_thread(self):
        torch = FakeTorch()
        self.apply({"CC_CPU_THREADS": "1"}, torch)
        self.assertEqual((torch.threads, torch.interop), ([1], [1]))

    def test_no_or_invalid_value_changes_nothing(self):
        for env in ({}, {"CC_CPU_THREADS": ""}, {"CC_CPU_THREADS": "many"}, {"CC_CPU_THREADS": "0"}):
            with self.subTest(env=env):
                torch = FakeTorch()
                self.apply(env, torch)
                self.assertEqual((torch.threads, torch.interop), ([], []))

    def test_a_refused_interop_size_is_not_fatal(self):
        torch = FakeTorch(refuse_interop=True)
        self.apply({"CC_CPU_THREADS": "2"}, torch)
        self.assertEqual(torch.threads, [2])


class MemoryLimitErrorTests(unittest.TestCase):
    def setUp(self):
        reset_live_state()
        self.addCleanup(reset_live_state)

    def test_mps_out_of_memory_is_recognised(self):
        self.assertTrue(cc.is_memory_limit_error(RuntimeError(MPS_OOM)))
        self.assertTrue(cc.is_memory_limit_error(MPS_OOM))
        for text in ("CUDA out of memory. Tried to allocate 2.00 GiB",
                     "out of memory while reading timestamps",
                     "Invalid buffer size: 12.50 GB", "", "eval failed"):
            with self.subTest(text=text):
                self.assertFalse(cc.is_memory_limit_error(text))

    def test_hint_names_the_limit_when_the_host_set_one(self):
        with patch.dict(os.environ, {"CC_MEMORY_LIMIT_GB": "6"}):
            hint = cc.memory_limit_hint()
        self.assertIn("6 GB limit", hint)
        self.assertIn("Settings → General → Model resource use", hint)
        self.assertIn("Maximum", hint)
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("CC_MEMORY_LIMIT_GB", None)
            self.assertNotIn("Settings", cc.memory_limit_hint())

    def test_emit_error_reports_memory_limit_with_the_callers_exit_code(self):
        out, err = io.StringIO(), io.StringIO()
        with patch.dict(os.environ, {"CC_MEMORY_LIMIT_GB": "5"}), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            with self.assertRaises(SystemExit) as stopped:
                cc.emit_error("eval-failed", hint=MPS_OOM, exit_code=5)
        self.assertEqual(stopped.exception.code, 5)
        payload = json.loads(out.getvalue())
        self.assertEqual(payload["error"], cc.MEMORY_LIMIT_ERROR)
        self.assertIn("5 GB limit", payload["hint"])
        self.assertIn("MPS backend out of memory", err.getvalue())

    def test_other_errors_are_unchanged(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit):
            cc.emit_error("eval-failed", hint="shape mismatch", exit_code=5)
        self.assertEqual(json.loads(out.getvalue()), {"error": "eval-failed", "hint": "shape mismatch"})

    def test_an_uncaught_out_of_memory_in_a_served_request_is_reported_too(self):
        def run_once(argv):
            raise RuntimeError(MPS_OOM)

        request = json.dumps({"request_id": "r1", "args": ["--image", "x.tif"]}) + "\n"
        out = io.StringIO()
        with patch.object(sys, "stdin", io.StringIO(request)), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            cc.serve_ndjson(run_once)
        response = json.loads(out.getvalue().splitlines()[0])
        self.assertEqual(response["request_id"], "r1")
        self.assertEqual(response["exit_code"], 70)
        self.assertEqual(json.loads(response["stdout"])["error"], cc.MEMORY_LIMIT_ERROR)


class FakeMPSTorch(FakeTorch):
    """A stand-in with PyTorch's thread and MPS memory-fraction entry points."""

    def __init__(self, default_threads=8, mps_available=True):
        super().__init__()
        self.default_threads = default_threads
        self.fractions = []
        self.mps = types.SimpleNamespace(set_per_process_memory_fraction=self.fractions.append)
        self.backends = types.SimpleNamespace(mps=types.SimpleNamespace(is_available=lambda: mps_available))

    def get_num_threads(self):
        return self.threads[-1] if self.threads else self.default_threads


class LiveLimitsTests(unittest.TestCase):
    """Settings changed while a model runs (`CC_LIMITS_FILE` + SIGINFO)."""

    LIMIT_KEYS = ("CC_LIMITS_FILE", "CC_CPU_THREADS", "CC_MEMORY_LIMIT_GB",
                  "PYTORCH_MPS_HIGH_WATERMARK_RATIO", "PYTORCH_MPS_LOW_WATERMARK_RATIO")

    def setUp(self):
        reset_live_state()
        self.addCleanup(reset_live_state)
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = os.path.join(directory.name, "limits.json")
        if cc.LIMITS_SIGNAL is not None:
            previous = signal.getsignal(cc.LIMITS_SIGNAL)
            self.addCleanup(signal.signal, cc.LIMITS_SIGNAL, previous)

    def write(self, **values):
        state = {"version": 1, "preset": "custom", "default_cpu_threads": 8, "background": False}
        state.update(values)
        with open(self.path, "w") as handle:
            json.dump(state, handle)

    @contextlib.contextmanager
    def environment(self, **values):
        """Only `CC_LIMITS_FILE` and the given launch values are set."""
        with patch.dict(os.environ, {}, clear=False):
            for key in self.LIMIT_KEYS:
                os.environ.pop(key, None)
            os.environ["CC_LIMITS_FILE"] = self.path
            os.environ.update(values)
            yield

    def test_only_a_version_1_file_is_read(self):
        with self.environment():
            self.assertIsNone(cc.read_live_limits())          # no file yet
            with open(self.path, "w") as handle:
                handle.write("{not json")
            self.assertIsNone(cc.read_live_limits())
            self.write(version=2)
            self.assertIsNone(cc.read_live_limits())
            self.write(cpu_threads=4)
            self.assertEqual(cc.read_live_limits()["cpu_threads"], 4)
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("CC_LIMITS_FILE", None)
            self.assertIsNone(cc.read_live_limits())

    def test_threads_change_live_and_return_to_the_default_on_maximum(self):
        torch = FakeMPSTorch()
        self.write(cpu_threads=2, memory_fraction=0.625, memory_limit_gb=5)
        with self.environment(CC_CPU_THREADS="2", PYTORCH_MPS_HIGH_WATERMARK_RATIO="0.6250",
                              CC_MEMORY_LIMIT_GB="5"), contextlib.redirect_stderr(io.StringIO()):
            cc.apply_cpu_thread_limit(torch)                  # started on Light
            self.assertEqual(torch.threads, [2])
            self.write(cpu_threads=4, memory_fraction=0.625, memory_limit_gb=5)
            cc.apply_live_limits(torch)
            self.write(cpu_threads=None, memory_fraction=0.625, memory_limit_gb=5)
            cc.apply_live_limits(torch)                       # Maximum
        self.assertEqual(torch.threads, [2, 4, 8])
        self.assertEqual(torch.fractions, [])                 # the cap never changed

    def test_a_process_started_without_a_limit_runs_as_it_started_on_maximum(self):
        torch = FakeMPSTorch(default_threads=8)
        self.write(cpu_threads=None, default_cpu_threads=6)
        with self.environment(), contextlib.redirect_stderr(io.StringIO()):
            cc.apply_cpu_thread_limit(torch)
            self.assertEqual((torch.threads, torch.fractions), ([], []))
            self.write(cpu_threads=2, default_cpu_threads=6)
            cc.apply_live_limits(torch)
            self.write(cpu_threads=None, default_cpu_threads=6)
            cc.apply_live_limits(torch)
        # Back to the default this process actually started with.
        self.assertEqual(torch.threads, [2, 8])

    def test_a_higher_cap_applies_now_and_a_lower_one_after_the_request(self):
        torch = FakeMPSTorch()
        with self.environment(CC_CPU_THREADS="2", PYTORCH_MPS_HIGH_WATERMARK_RATIO="0.6250",
                              CC_MEMORY_LIMIT_GB="5"):
            cc._live["in_request"] = True
            self.write(cpu_threads=4)                         # Balanced: no hard cap
            cc.apply_live_limits(torch)
            self.assertEqual(torch.fractions, [1.7])
            self.assertNotIn("GB limit", cc.memory_limit_hint())
            self.write(cpu_threads=4, memory_fraction=0.5, memory_limit_gb=4)
            cc.apply_live_limits(torch)
            self.assertEqual(torch.fractions, [1.7])          # the running image keeps 1.7
            self.assertEqual(cc._live["pending"], (0.5, 4))
            cc._live["in_request"] = False
            cc.apply_deferred_live_limits(torch)
            self.assertEqual(torch.fractions, [1.7, 0.5])
            self.assertIn("4 GB limit", cc.memory_limit_hint())

    def test_a_lower_cap_applies_at_once_before_any_model_loads(self):
        torch = FakeMPSTorch()
        self.write(cpu_threads=4, memory_fraction=0.5, memory_limit_gb=4)
        with self.environment(CC_CPU_THREADS="4", PYTORCH_MPS_HIGH_WATERMARK_RATIO="1.0000",
                              CC_MEMORY_LIMIT_GB="8"), contextlib.redirect_stderr(io.StringIO()):
            cc.apply_cpu_thread_limit(torch)
        self.assertEqual(torch.fractions, [0.5])

    def test_a_developers_own_cap_is_never_changed(self):
        torch = FakeMPSTorch()
        self.write(cpu_threads=2, memory_fraction=0.5, memory_limit_gb=4)
        with self.environment(PYTORCH_MPS_HIGH_WATERMARK_RATIO="0.9"):
            cc._live["in_request"] = False
            cc.apply_live_limits(torch)
        self.assertEqual(torch.fractions, [])
        self.assertEqual(torch.threads, [2])

    def test_nothing_happens_without_torch_or_mps(self):
        self.write(cpu_threads=2, memory_fraction=0.5, memory_limit_gb=4)
        with self.environment(), patch.dict(sys.modules, {}, clear=False):
            sys.modules.pop("torch", None)
            self.assertFalse(cc.apply_live_limits())
        torch = FakeMPSTorch(mps_available=False)
        with self.environment():
            cc._live["in_request"] = False
            cc.apply_live_limits(torch)
        self.assertEqual((torch.threads, torch.fractions), ([2], []))

    @unittest.skipIf(cc.LIMITS_SIGNAL is None, "this platform has no SIGINFO")
    def test_the_signal_applies_the_file_without_writing_anything(self):
        torch = FakeMPSTorch()
        self.write(cpu_threads=3)
        err = io.StringIO()
        with self.environment(), patch.dict(sys.modules, {"torch": torch}), contextlib.redirect_stderr(err):
            self.assertTrue(cc.install_limits_control())
            signal.raise_signal(cc.LIMITS_SIGNAL)
            self.assertEqual(torch.threads, [3])
            self.assertEqual(err.getvalue(), "")               # notes wait for a safe point
            cc.flush_live_notes()
        self.assertIn("CPU threads now 3", err.getvalue())

    @unittest.skipIf(cc.LIMITS_SIGNAL is None, "this platform has no SIGINFO")
    def test_someone_elses_handler_is_left_in_place(self):
        def theirs(signum, frame):
            pass
        signal.signal(cc.LIMITS_SIGNAL, theirs)
        with self.environment():
            self.assertFalse(cc.install_limits_control())
        self.assertIs(signal.getsignal(cc.LIMITS_SIGNAL), theirs)

    def test_a_served_worker_lowers_the_cap_after_the_response(self):
        torch = FakeMPSTorch()
        self.write(cpu_threads=2, memory_fraction=0.625, memory_limit_gb=5)
        seen_during_request = []

        def run_once(argv):
            # Settings lower the cap while this image is analysed.
            self.write(cpu_threads=2, memory_fraction=0.5, memory_limit_gb=4)
            cc.apply_live_limits()
            seen_during_request.extend(torch.fractions)

        request = json.dumps({"request_id": "r1", "args": []}) + "\n"
        out = io.StringIO()
        with self.environment(CC_CPU_THREADS="2", PYTORCH_MPS_HIGH_WATERMARK_RATIO="0.6250",
                              CC_MEMORY_LIMIT_GB="5"), \
                patch.dict(sys.modules, {"torch": torch}), \
                patch.object(sys, "stdin", io.StringIO(request)), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            cc.serve_ndjson(run_once)
        self.assertEqual(json.loads(out.getvalue().splitlines()[0])["exit_code"], 0)
        self.assertEqual(seen_during_request, [])
        self.assertEqual(torch.fractions, [0.5])


if __name__ == "__main__":
    unittest.main()
