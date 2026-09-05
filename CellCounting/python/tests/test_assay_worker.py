"""Exercise the real assay protocol and prepared data without model weights."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time
import unittest

import numpy as np
from PIL import Image

PYTHON_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PYTHON_DIR))
import _assay_worker as worker


class AssayCacheTests(unittest.TestCase):
    def setUp(self):
        worker.CACHE = worker.PreparedDataCache()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "mask.png"

    def test_raw_planes_and_masks_keep_high_bit_depth_and_private_copies(self):
        pixels = np.array([[0, 60000], [4096, 65535]], dtype=np.uint16)
        Image.fromarray(pixels).save(self.path)
        planes, metadata = worker.load_raw_planes(str(self.path))
        np.testing.assert_array_equal(planes[:, :, 0], pixels)
        planes[:] = 2
        again, metadata_again = worker.load_raw_planes(str(self.path))
        np.testing.assert_array_equal(again[:, :, 0], pixels)
        self.assertEqual(metadata, metadata_again)
        self.assertEqual(worker.CACHE.hits, 1)
        worker.load_raw_planes(str(self.path), z_project="mean")
        self.assertEqual(worker.CACHE.misses, 2, "projection is part of preparation identity")
        from neurite_outgrowth import _load_mask_image
        mask = _load_mask_image(str(self.path))
        np.testing.assert_array_equal(mask, pixels)
        mask[:] = 0
        np.testing.assert_array_equal(_load_mask_image(str(self.path)), pixels)

    def test_file_edits_replacement_and_deletion_cannot_return_stale_pixels(self):
        self.path.write_bytes(b"first")
        def read(): return self.path.read_bytes()
        self.assertEqual(worker.cached_file_load("test", self.path, read), b"first")
        self.assertEqual(worker.cached_file_load("test", self.path, read), b"first")
        self.assertEqual(worker.CACHE.hits, 1)
        original = self.path.stat()
        self.path.write_bytes(b"other")
        os.utime(self.path, ns=(original.st_atime_ns, original.st_mtime_ns))
        self.assertEqual(worker.cached_file_load("test", self.path, read), b"other")
        replacement = self.path.with_suffix(".new")
        replacement.write_bytes(b"third")
        os.utime(replacement, ns=(original.st_atime_ns, original.st_mtime_ns))
        replacement.replace(self.path)
        self.assertEqual(worker.cached_file_load("test", self.path, read), b"third")
        self.path.unlink()
        with self.assertRaises(FileNotFoundError):
            worker.cached_file_load("test", self.path, read)

    def test_input_changed_during_decode_is_rejected(self):
        self.path.write_bytes(b"start")
        def unstable():
            self.path.write_bytes(b"changed")
            return b"start"
        with self.assertRaisesRegex(OSError, "changed"):
            worker.cached_file_load("test", self.path, unstable)
        self.assertEqual(len(worker.CACHE.entries), 0)

    def test_cache_limits_lru_oversized_entries_and_result_isolation(self):
        cache = worker.PreparedDataCache(max_bytes=2400, max_entries=2)
        loads = []
        def load(value):
            loads.append(value)
            return np.full((100,), value, dtype=np.uint8)
        cache.get_or_load("a", lambda: load(1))
        cache.get_or_load("b", lambda: load(2))
        cache.get_or_load("a", lambda: load(9))[:] = 0
        cache.get_or_load("c", lambda: load(3))
        self.assertNotIn("b", cache.entries)
        np.testing.assert_array_equal(cache.get_or_load("a", lambda: load(9)), np.ones(100))
        for number in range(20):
            cache.get_or_load(str(number), lambda: np.ones(500, dtype=np.uint8))
            self.assertLessEqual(cache.bytes, cache.max_bytes)
            self.assertLessEqual(len(cache.entries), cache.max_entries)
        cache.get_or_load("huge", lambda: np.ones(10000))
        self.assertNotIn("huge", cache.entries)
        self.assertEqual(loads, [1, 2, 3])
        cache.clear()
        self.assertEqual(cache.bytes, 0)

    def test_prepared_mask_keys_include_every_coordinate_label_order_and_shape(self):
        calls = []
        base = [{"label": "a", "polygon": [[0, 0], [0, 4], [4, 4]]},
                {"label": "b", "polygon": [[8, 0], [8, 4], [9, 4]]}]
        def prepare(descriptor):
            return worker.cached_value("polygons", descriptor,
                                       lambda: calls.append(descriptor) or np.ones((4, 4)))
        descriptor = [base, [20, 20]]
        prepare(descriptor)[:] = 0
        self.assertTrue(prepare(descriptor).all())
        edited = json.loads(json.dumps(base))
        edited[0]["polygon"][0][0] = 1
        prepare([edited, [20, 20]])
        edited[0]["label"] = "changed"
        prepare([edited, [20, 20]])
        prepare([list(reversed(base)), [20, 20]])
        prepare([base, [21, 20]])
        self.assertEqual(len(calls), 5)
        self.assertEqual(worker.CACHE.hits, 1)


class AssayProtocolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "mask.png"
        Image.fromarray(np.array([[0, 200], [200, 200]], dtype=np.uint8)).save(self.path)
        self.proc = self.start()

    def start(self):
        process = subprocess.Popen([sys.executable, str(PYTHON_DIR / "_assay_worker.py"), "--serve"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, bufsize=1)
        def stop():
            if process.poll() is None:
                process.terminate()
            try: process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.communicate(timeout=5)
        self.addCleanup(stop)
        return process

    def request(self, args, request_id="test", process=None):
        process = process or self.proc
        process.stdin.write(json.dumps({"request_id": request_id, "args": args}) + "\n")
        process.stdin.flush()
        self.assertTrue(select.select([process.stdout], [], [], 20)[0], "worker response timed out")
        line = process.stdout.readline()
        self.assertTrue(line, "worker exited unexpectedly")
        result = json.loads(line)
        self.assertEqual(result["request_id"], request_id)
        return result

    def mask_args(self, scale="1"):
        return ["area_assays_detect.py", "--mode", "confluence", "--mask", str(self.path),
                "--pxPerUm", scale]

    def test_actual_assay_reuses_process_and_pixels_but_recomputes_parameters(self):
        first = self.request(self.mask_args(), "one")
        second = self.request(self.mask_args("2"), "two")
        self.assertEqual(first["exit_code"], 0)
        self.assertEqual(first["worker_pid"], second["worker_pid"])
        self.assertEqual(first["worker_pid"], self.proc.pid)
        self.assertEqual(json.loads(first["stdout"])["result"]["covered_area_um2"], 3)
        self.assertEqual(json.loads(second["stdout"])["result"]["covered_area_um2"], 0.75)
        self.assertEqual(second["cache"]["hits"], first["cache"]["hits"] + 1)
        # Repeat CLI computation independently to detect changes in warm behavior.
        cold = subprocess.run([sys.executable, str(PYTHON_DIR / "area_assays_detect.py")]
                              + self.mask_args("2")[1:], check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(second["stdout"]), json.loads(cold.stdout))

    def test_pixel_edit_and_threshold_change_are_observed(self):
        args = ["area_assays_detect.py", "--mode", "confluence", "--image", str(self.path),
                "--pxPerUm", "1", "--smooth-sigma-px", "0", "--threshold-method", "fixed",
                "--fixed-threshold", "128"]
        first = self.request(args)
        changed = self.request(args[:-1] + ["220"])
        self.assertEqual(json.loads(first["stdout"])["result"]["coverage_pct"], 75)
        self.assertEqual(json.loads(changed["stdout"])["result"]["coverage_pct"], 0)
        self.assertGreater(changed["cache"]["hits"], first["cache"]["hits"])
        Image.fromarray(np.zeros((2, 2), dtype=np.uint8)).save(self.path)
        edited = self.request(args)
        self.assertEqual(json.loads(edited["stdout"])["result"]["coverage_pct"], 0)
        self.assertGreater(edited["cache"]["misses"], changed["cache"]["misses"])

    def test_puncta_reuses_prepared_masks_and_invalidates_content_edits(self):
        Image.fromarray(np.zeros((20, 20), dtype=np.uint8)).save(self.path)
        cells = Path(self.temp.name) / "cells.json"
        polygons = [{"label": "a", "contour_px": [[1, 1], [8, 1], [8, 8], [1, 8]]}]
        cells.write_text(json.dumps(polygons))
        args = ["puncta_detect.py", "--image", str(self.path), "--pxPerUm", "1",
                "--cells-json", str(cells)]
        first = self.request(args)
        second = self.request(args)
        self.assertEqual(first["exit_code"], 0)
        self.assertEqual(second["exit_code"], 0)
        self.assertEqual(second["cache"]["hits"] - first["cache"]["hits"], 2)
        self.assertEqual(json.loads(first["stdout"]), json.loads(second["stdout"]))
        # Native runners export a new temporary JSON path per request.
        fresh_cells = Path(self.temp.name) / "fresh-cells.json"
        fresh_cells.write_text(json.dumps(polygons))
        args[-1] = str(fresh_cells)
        fresh = self.request(args)
        self.assertEqual(fresh["cache"]["hits"] - second["cache"]["hits"], 2)
        # Same mask path and vertex count, different geometry must rerasterize.
        polygons[0]["contour_px"][1][0] = 9
        fresh_cells.write_text(json.dumps(polygons))
        edited = self.request(args)
        self.assertEqual(edited["exit_code"], 0)
        self.assertEqual(edited["cache"]["misses"] - fresh["cache"]["misses"], 1)
        self.assertEqual(edited["cache"]["hits"] - fresh["cache"]["hits"], 1)

    def test_neurite_mask_warm_output_matches_cold_analysis(self):
        pixels = np.zeros((16, 16), dtype=np.uint16)
        pixels[8, 2:13] = 60000
        Image.fromarray(pixels).save(self.path)
        args = ["neurite_outgrowth.py", "--neurite-mask", str(self.path), "--px-per-um", "1"]
        first = self.request(args)
        second = self.request(args)
        self.assertEqual(first["exit_code"], 0)
        self.assertEqual(second["cache"]["hits"] - first["cache"]["hits"], 1)
        cold = subprocess.run([sys.executable, str(PYTHON_DIR / args[0])] + args[1:],
                              check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(second["stdout"]), json.loads(cold.stdout))

    def test_invalid_request_and_missing_input_preserve_structured_errors_and_recover(self):
        invalid = self.request(["anything.py"])
        self.assertNotEqual(invalid["exit_code"], 0)
        good = self.request(self.mask_args())
        self.path.unlink()
        missing = self.request(self.mask_args())
        self.assertEqual(missing["exit_code"], 3)
        self.assertEqual(json.loads(missing["stdout"])["error"], "image-open-failed")
        self.assertEqual(invalid["worker_pid"], good["worker_pid"])
        self.assertEqual(good["worker_pid"], missing["worker_pid"])

    def test_sigterm_cancels_active_decode_and_restart_has_fresh_cache(self):
        fifo = Path(self.temp.name) / "waiting.png"
        os.mkfifo(fifo)
        args = self.mask_args()
        args[4] = str(fifo)
        self.proc.stdin.write(json.dumps({"request_id": "blocked", "args": args}) + "\n")
        self.proc.stdin.flush()
        self.assertTrue(select.select([self.proc.stderr], [], [], 20)[0])
        self.assertIn("confluence", self.proc.stderr.readline())
        start = time.monotonic()
        self.proc.terminate()
        self.proc.wait(timeout=5)
        self.assertLess(time.monotonic() - start, 5)
        self.assertEqual(self.proc.returncode, -15)
        replacement = self.start()
        result = self.request(self.mask_args(), process=replacement)
        self.assertNotEqual(result["worker_pid"], self.proc.pid)
        self.assertEqual(result["cache"]["hits"], 0)
        self.assertEqual(result["exit_code"], 0)


if __name__ == "__main__":
    unittest.main()
