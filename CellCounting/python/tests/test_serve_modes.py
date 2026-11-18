"""A served detection request gives exactly the one-shot payload.

Every detector script runs in two ways: one image per process (one-shot), or
many images in one `--serve` worker that keeps its model loaded between
images. Both call the same `main`, so for the same arguments the stdout
payload must be identical. These tests run both ways on small generated
images and compare the exact bytes.

* The classical detector runs its real pipeline (NumPy, SciPy,
  scikit-image).
* StarDist, Omnipose and Cellpose (built-in and custom) run their real
  sidecar code around small stand-ins for the frameworks, which CI does not
  install. The stand-ins segment by thresholding and record every model
  they build, so the tests can also check that a worker builds its model
  once.

Cell ids are random UUIDs. In-process tests number them 1, 2, 3, ... for each
image; subprocess tests blank them out before comparing.
"""

from __future__ import annotations

import contextlib
import importlib
import io
import itertools
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve()
PYTHON_DIR = HERE.parents[1]
SHARED_DIR = HERE.parents[3] / "shared" / "python"
for _path in (SHARED_DIR, PYTHON_DIR):
    if _path.is_dir() and str(_path) not in sys.path:
        sys.path.insert(0, str(_path))

import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402

import _cellpose_common as cc  # noqa: E402
import cellpose4_detect  # noqa: E402
import cellpose_detect  # noqa: E402
import classical_detect  # noqa: E402
import custom_detect  # noqa: E402
import omnipose_detect  # noqa: E402
import stardist_detect  # noqa: E402

UUID_PATTERN = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


# ---------------------------------------------------------------------------
# Framework stand-ins. Written to disk so subprocesses can import them too.
# ---------------------------------------------------------------------------

FAKE_FILES = {
    "_cc_fake_segment.py": '''
"""Deterministic segmentation shared by the framework stand-ins."""
import sys

import numpy as np
from scipy import ndimage as ndi

BUILDS = []


def record_build(framework, name):
    BUILDS.append((framework, name))
    print(f"[fake] built {framework} model {name}", file=sys.stderr)


def gray(image):
    values = np.asarray(image, dtype=np.float64)
    return values if values.ndim == 2 else values.mean(axis=2)


def segment(image, offset=0.0):
    values = gray(image)
    threshold = float(values.mean() + 0.5 * values.std()) + float(offset)
    labels, _ = ndi.label(values > threshold)
    scale = max(1e-6, float(values.max()) - threshold)
    cellprob = np.clip((values - threshold) / scale * 4.0, -20.0, 20.0)
    return labels.astype(np.int32), cellprob
''',
    "torch/__init__.py": '''
"""PyTorch stand-in: CPU only."""
__version__ = "0+fake"


class _NoAccelerator:
    @staticmethod
    def is_available():
        return False


class backends:
    mps = _NoAccelerator


class cuda:
    @staticmethod
    def is_available():
        return False

    @staticmethod
    def is_initialized():
        return False


def device(name):
    return str(name)
''',
    "cellpose/__init__.py": 'version = "fake"\n',
    "cellpose/models.py": '''
import _cc_fake_segment as seg


class CellposeModel:
    def __init__(self, gpu=False, pretrained_model=None, model_type=None, device=None, **kwargs):
        seg.record_build("cellpose", pretrained_model or model_type)
        self.device = "cpu"
        self.net = None

    def eval(self, image, diameter=None, channels=None, **kwargs):
        masks, cellprob = seg.segment(image)
        return masks, [None, None, cellprob], None
''',
    "cellpose/utils.py": '''
def urlopen(*args, **kwargs):
    raise OSError("no network in tests")


def download_url_to_file(url, destination, progress=True):
    raise OSError("no network in tests")
''',
    "cellpose_omni/__init__.py": "",
    "cellpose_omni/models.py": '''
import _cc_fake_segment as seg

MODEL_NAMES = ["bact_phase_omni", "bact_fluor_omni", "cyto2_omni", "worm_omni"]


class CellposeModel:
    def __init__(self, gpu=False, model_type=None, omni=False, nchan=2, nclasses=3, dim=2, **kwargs):
        print(f"cellpose_omni loading {model_type}")  # the fork prints to stdout
        seg.record_build("omnipose", model_type)
        self.device = "cpu"
        self.net = None

    def eval(self, image, mask_threshold=0.0, **kwargs):
        masks, cellprob = seg.segment(image, offset=mask_threshold)
        return masks, [None, None, cellprob], None
''',
    "stardist/__init__.py": "",
    "stardist/models.py": '''
import numpy as np
from scipy import ndimage as ndi

import _cc_fake_segment as seg


class _Config:
    n_channel_in = 1


class StarDist2D:
    def __init__(self, config=None, name=None, basedir=None):
        print(f"Loading network weights from {name!r}.")  # csbdeep prints to stdout
        seg.record_build("stardist", name)
        self.config = _Config()

    @classmethod
    def from_pretrained(cls, name):
        print(f"Found model {name!r} for 'StarDist2D'.")
        return cls(None, name=name)

    def predict_instances(self, image, prob_thresh=0.5, nms_thresh=0.4):
        values = seg.gray(image)
        labels, count = ndi.label(values > prob_thresh)
        ids = list(range(1, count + 1))
        points = np.asarray(ndi.center_of_mass(np.ones_like(values), labels, ids)).reshape(-1, 2)
        probs = np.clip(np.asarray(ndi.mean(values, labels, ids), dtype=np.float64).reshape(-1), 0, 1)
        return labels.astype(np.int32), {"points": points, "prob": probs}
''',
    "csbdeep/__init__.py": "",
    "csbdeep/utils.py": '''
import numpy as np


def normalize(x, pmin=3, pmax=99.8, axis=None, eps=1e-20, dtype=np.float32):
    values = np.asarray(x, dtype=np.float32)
    low = np.percentile(values, pmin, axis=axis, keepdims=True)
    high = np.percentile(values, pmax, axis=axis, keepdims=True)
    return ((values - low) / (high - low + eps)).astype(dtype)
''',
}

FAKE_MODULES = ("_cc_fake_segment", "torch", "cellpose", "cellpose.models", "cellpose.utils",
                "cellpose_omni", "cellpose_omni.models", "stardist", "stardist.models",
                "csbdeep", "csbdeep.utils")


def write_fakes(root: Path) -> None:
    for relative, source in FAKE_FILES.items():
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(source.lstrip("\n"))


def load_fakes(root: Path) -> dict:
    """Import the stand-ins without leaving them visible to other tests."""
    hidden = {name: sys.modules.pop(name) for name in FAKE_MODULES if name in sys.modules}
    sys.path.insert(0, str(root))
    try:
        return {name: importlib.import_module(name) for name in FAKE_MODULES}
    finally:
        sys.path.remove(str(root))
        for name in FAKE_MODULES:
            sys.modules.pop(name, None)
        sys.modules.update(hidden)


@contextlib.contextmanager
def installed(modules: dict):
    """Expose `modules` in sys.modules, touching no other entry."""
    saved = {name: sys.modules.get(name) for name in modules}
    sys.modules.update(modules)
    try:
        yield
    finally:
        for name, module in saved.items():
            if module is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = module


# ---------------------------------------------------------------------------
# Generated images.
# ---------------------------------------------------------------------------

def _disc_image(shape, discs, background=18.0, gradient=0.0, seed=0):
    rng = np.random.default_rng(seed)
    height, width = shape
    rows, cols = np.mgrid[0:height, 0:width]
    image = background + gradient * cols / max(1, width - 1) + rng.normal(0.0, 4.0, shape)
    for row, col, radius, level in discs:
        image[(rows - row) ** 2 + (cols - col) ** 2 <= radius ** 2] = level
    return np.clip(image, 0, 255).astype(np.uint8)


def write_images(root: Path) -> dict:
    gray_a = _disc_image((80, 96), [(20, 20, 8, 210), (20, 35, 7, 190), (55, 30, 6, 230),
                                    (50, 70, 9, 200), (25, 75, 5, 170), (65, 60, 6, 220)], seed=1)
    gray_b = _disc_image((72, 64), [(15, 15, 6, 160), (40, 22, 8, 210), (40, 37, 7, 205),
                                    (60, 50, 5, 180)], gradient=30.0, seed=2)
    green = _disc_image((70, 70), [(18, 20, 7, 200), (45, 45, 9, 230), (20, 52, 6, 180)], seed=3)
    rgb = np.stack([np.full_like(green, 12), green, np.full_like(green, 30)], axis=-1)
    blank = np.zeros((40, 40), dtype=np.uint8)
    paths = {}
    for name, pixels in (("a", gray_a), ("b", gray_b), ("rgb", rgb), ("blank", blank)):
        path = root / f"{name}.png"
        Image.fromarray(pixels).save(path)
        paths[name] = str(path)
    return paths


# ---------------------------------------------------------------------------
# Running both ways in-process.
# ---------------------------------------------------------------------------

class _NumberedIds:
    """uuid4 stand-in numbering ids 1, 2, 3, ...; restarted for each image."""

    def __init__(self):
        self.restart()

    def restart(self):
        self._counter = itertools.count(1)

    def __call__(self):
        return uuid.UUID(int=next(self._counter))


class _Requests:
    """stdin stand-in that restarts the id numbering at each request."""

    def __init__(self, lines, ids):
        self._lines = lines
        self._ids = ids

    def __iter__(self):
        for line in self._lines:
            self._ids.restart()
            yield line


def one_shot_in_process(entry, script_name, argv):
    """Run `entry()` the way `python script argv...` would. Returns (code, stdout)."""
    ids = _NumberedIds()
    output = io.StringIO()
    code = 0
    with patch("uuid.uuid4", ids), patch.object(sys, "argv", [script_name, *argv]), \
            contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
        try:
            entry()
        except SystemExit as exc:
            code = cc._exit_status(exc.code)
    return code, output.getvalue()


def serve_in_process(serve_entry, requests):
    """Feed `requests` (argument lists) to a serve loop. Returns (responses, stderr)."""
    ids = _NumberedIds()
    lines = [json.dumps({"request_id": f"r{index}", "args": argv}) + "\n"
             for index, argv in enumerate(requests)]
    output = io.StringIO()
    logs = io.StringIO()
    with patch("uuid.uuid4", ids), patch.object(sys, "stdin", _Requests(lines, ids)), \
            contextlib.redirect_stdout(output), contextlib.redirect_stderr(logs):
        serve_entry()
    responses = [json.loads(line) for line in output.getvalue().splitlines()]
    return responses, logs.getvalue()


class ServeTestCase(unittest.TestCase):
    """Shared fixtures: generated images and framework stand-ins."""

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.mkdtemp(prefix="cc-serve-test-")
        root = Path(cls._tmp)
        # Model loading cleans the Cellpose models folder. Point it (and the
        # subprocesses, which inherit the environment) away from ~/.cellpose.
        # HOME too: omnipose_detect.configure_model_cache resets the folder to
        # ~/.cellpose_omni/models. Stopping the patch restores both.
        (root / "home").mkdir()
        cls._models_env = patch.dict(os.environ, {"CELLPOSE_LOCAL_MODELS_PATH": str(root / "cellpose-models"),
                                                  "HOME": str(root / "home")})
        cls._models_env.start()
        cls.images = write_images(root)
        (root / "fakes").mkdir()
        write_fakes(root / "fakes")
        cls.fakes_root = root / "fakes"
        cls.fakes = load_fakes(cls.fakes_root)

        cls.checkpoint = root / "custom_cellpose_checkpoint"
        cls.checkpoint.write_bytes(b"\x01" * 2048)
        cls.stardist_dir = root / "custom_stardist_model"
        cls.stardist_dir.mkdir()
        (cls.stardist_dir / "config.json").write_text("{}")
        (cls.stardist_dir / "weights_best.h5").write_bytes(b"\x02" * 64)

    @classmethod
    def tearDownClass(cls):
        cls._models_env.stop()
        shutil.rmtree(cls._tmp, ignore_errors=True)

    def setUp(self):
        for module in (stardist_detect, omnipose_detect, custom_detect,
                       cellpose_detect, cellpose4_detect):
            module._MODEL_CACHE.clear()
        self.fakes["_cc_fake_segment"].BUILDS.clear()

    @property
    def builds(self):
        return list(self.fakes["_cc_fake_segment"].BUILDS)

    def assert_served_matches_one_shot(self, script_name, one_shot_entry, serve_entry,
                                       requests, clear_cache=None, expect_success=True):
        """Every served payload equals the one-shot payload byte for byte."""
        responses, _ = serve_in_process(serve_entry, requests)
        self.assertEqual(len(responses), len(requests))
        for index, (argv, response) in enumerate(zip(requests, responses)):
            if clear_cache is not None:
                clear_cache()  # a one-shot process starts with no model loaded
            code, stdout = one_shot_in_process(one_shot_entry, script_name, argv)
            with self.subTest(request=index, args=argv):
                self.assertEqual(response["request_id"], f"r{index}")
                self.assertEqual(response["exit_code"], code)
                self.assertEqual(response["stdout"], stdout)
                if expect_success:
                    self.assertEqual(code, 0, stdout)
                    self.assertIn('"cells"', stdout)
        return responses


# ---------------------------------------------------------------------------
# Classical detector: the real pipeline.
# ---------------------------------------------------------------------------

class ClassicalServeTests(ServeTestCase):
    def requests(self):
        common = ["--pxPerUm", "1.0", "--conf", "0.5", "--watershed-min-distance", "4",
                  "--small-threshold", "8", "--large-threshold", "14", "--no-gpu"]
        image = self.images
        return [
            ["--image", image["a"], "--model", "cw-otsu", "--threshold-method", "otsu", *common],
            ["--image", image["b"], "--model", "cw-triangle", "--threshold-method", "triangle", *common],
            ["--image", image["a"], "--model", "cw-adaptive", "--threshold-method", "adaptive",
             "--bg-subtract", "--rolling-ball-radius", "15", *common],
            ["--image", image["rgb"], "--model", "cw-manual", "--threshold-method", "manual",
             "--threshold-value", "120", *common],
            ["--image", image["b"], "--model", "cw-li", "--threshold-method", "li",
             "--diameter", "12", *common],
            ["--image", image["blank"], "--model", "cw-otsu", "--threshold-method", "otsu", *common],
            ["--image", image["a"], "--model", "cw-yen", "--threshold-method", "yen",
             "--watershed", *common],
        ]

    def test_served_payloads_match_one_shot_payloads(self):
        import _workbench_classical_legacy as kernel
        responses = self.assert_served_matches_one_shot(
            "classical_detect.py", kernel.main, classical_detect.serve, self.requests())
        counts = [len(json.loads(r["stdout"])["cells"]) for r in responses]
        self.assertGreater(counts[0], 0)
        self.assertEqual(counts[5], 0)  # the blank image

    def test_argument_errors_keep_their_exit_status(self):
        import _workbench_classical_legacy as kernel
        missing_scale = ["--image", self.images["a"], "--model", "cw-otsu"]
        bad_method = ["--image", self.images["a"], "--pxPerUm", "1", "--threshold-method", "nope"]
        responses = self.assert_served_matches_one_shot(
            "classical_detect.py", kernel.main, classical_detect.serve,
            [missing_scale, bad_method], expect_success=False)
        self.assertEqual([r["exit_code"] for r in responses], [2, 2])

    def test_a_request_does_not_leave_its_arguments_behind(self):
        before = list(sys.argv)
        serve_in_process(classical_detect.serve, self.requests()[:1])
        self.assertEqual(sys.argv, before)


# ---------------------------------------------------------------------------
# Model-backed detectors around framework stand-ins.
# ---------------------------------------------------------------------------

class StarDistServeTests(ServeTestCase):
    def test_served_payloads_match_one_shot_payloads(self):
        common = ["--pxPerUm", "1.0", "--conf", "0.5", "--small-threshold", "8",
                  "--large-threshold", "14"]
        requests = [
            ["--image", self.images["a"], "--model", "2D_versatile_fluo", *common],
            ["--image", self.images["b"], "--model", "2D_versatile_fluo", "--prob-thresh", "0.4", *common],
            ["--image", self.images["a"], "--model", "2D_versatile_fluo", "--watershed",
             "--watershed-min-distance", "4", "--bg-subtract", "--rolling-ball-radius", "15", *common],
            ["--image", self.images["rgb"], "--model", "2D_versatile_he", *common],
            ["--image", self.images["b"], "--model", "2D_versatile_fluo", *common],
        ]
        with installed(self.fakes):
            self.assert_served_matches_one_shot(
                "stardist_detect.py", stardist_detect.main, stardist_detect.serve, requests,
                clear_cache=stardist_detect._MODEL_CACHE.clear)

    def test_worker_loads_its_model_once(self):
        argv = ["--image", self.images["a"], "--model", "2D_versatile_fluo", "--pxPerUm", "1"]
        with installed(self.fakes):
            responses, logs = serve_in_process(stardist_detect.serve, [argv, argv, argv])
        self.assertEqual([r["exit_code"] for r in responses], [0, 0, 0])
        self.assertEqual(self.builds, [("stardist", "2D_versatile_fluo")])
        self.assertEqual(logs.count("reusing initialized model"), 2)
        # The library's own stdout chatter never reaches the payload.
        for response in responses:
            json.loads(response["stdout"])

    def test_a_different_model_replaces_the_loaded_one(self):
        fluo = ["--image", self.images["a"], "--model", "2D_versatile_fluo", "--pxPerUm", "1"]
        he = ["--image", self.images["rgb"], "--model", "2D_versatile_he", "--pxPerUm", "1"]
        with installed(self.fakes):
            serve_in_process(stardist_detect.serve, [fluo, he, he])
        self.assertEqual(self.builds, [("stardist", "2D_versatile_fluo"), ("stardist", "2D_versatile_he")])
        self.assertEqual(list(stardist_detect._MODEL_CACHE), ["2D_versatile_he"])

    def test_an_unknown_pretrained_name_is_not_cached(self):
        class Missing:
            @classmethod
            def from_pretrained(cls, name):
                return None

        with contextlib.redirect_stderr(io.StringIO()):
            self.assertIsNone(stardist_detect.load_pretrained_model(Missing, "2D_versatile_fluo"))
        self.assertEqual(stardist_detect._MODEL_CACHE, {})


class OmniposeServeTests(ServeTestCase):
    def setUp(self):
        super().setUp()
        # Model-cache configuration touches the home folder; it is not part of
        # what is compared here.
        patcher = patch.object(omnipose_detect, "configure_model_cache", lambda name: None)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_served_payloads_match_one_shot_payloads(self):
        common = ["--model", "omni-bact-phase", "--pxPerUm", "1.0", "--conf", "0.5",
                  "--small-threshold", "8", "--large-threshold", "14"]
        requests = [
            ["--image", self.images["a"], *common],
            ["--image", self.images["b"], *common, "--mask-threshold", "-0.5", "--flow-threshold", "0.4"],
            ["--image", self.images["a"], *common, "--cluster", "--diameter", "10"],
            ["--image", self.images["rgb"], *common, "--channels", "2,0", "--watershed"],
            ["--image", self.images["b"], *common, "--no-gpu"],
        ]
        with installed(self.fakes):
            self.assert_served_matches_one_shot(
                "omnipose_detect.py", omnipose_detect.main, omnipose_detect.serve, requests,
                clear_cache=omnipose_detect._MODEL_CACHE.clear)

    def test_worker_builds_one_model_per_name_and_device(self):
        base = ["--image", self.images["a"], "--model", "omni-bact-phase", "--pxPerUm", "1"]
        with installed(self.fakes):
            responses, logs = serve_in_process(
                omnipose_detect.serve,
                [base, base + ["--mask-threshold", "-1"], base + ["--no-gpu"], base + ["--no-gpu"]])
        self.assertEqual([r["exit_code"] for r in responses], [0, 0, 0, 0])
        # Thresholds are per image; the GPU flag is part of the model.
        self.assertEqual(self.builds, [("omnipose", "bact_phase_omni"), ("omnipose", "bact_phase_omni")])
        self.assertEqual(logs.count("reusing initialized model"), 2)
        self.assertNotEqual(json.loads(responses[0]["stdout"]), json.loads(responses[1]["stdout"]))

    def test_invalid_settings_fail_the_same_way(self):
        argv = ["--image", self.images["a"], "--model", "omni-bact-phase", "--pxPerUm", "1",
                "--flow-threshold", "-1"]
        with installed(self.fakes):
            responses = self.assert_served_matches_one_shot(
                "omnipose_detect.py", omnipose_detect.main, omnipose_detect.serve, [argv],
                expect_success=False)
        self.assertEqual(responses[0]["exit_code"], 2)
        self.assertEqual(json.loads(responses[0]["stdout"])["error"], "invalid-model-settings")


class CustomModelServeTests(ServeTestCase):
    def cellpose_requests(self):
        common = ["--model", str(self.checkpoint), "--custom-kind", "cellpose", "--pxPerUm", "1.0",
                  "--conf", "0.5", "--small-threshold", "8", "--large-threshold", "14"]
        return [
            ["--image", self.images["a"], *common],
            ["--image", self.images["b"], *common, "--diameter", "11"],
            ["--image", self.images["rgb"], *common, "--channels", "2,0", "--watershed"],
        ]

    def stardist_requests(self):
        common = ["--model", str(self.stardist_dir), "--custom-kind", "stardist", "--pxPerUm", "1.0",
                  "--small-threshold", "8", "--large-threshold", "14"]
        return [
            ["--image", self.images["a"], *common],
            ["--image", self.images["b"], *common, "--prob-thresh", "0.4"],
            ["--image", self.images["rgb"], *common, "--no-gpu"],
        ]

    def test_served_cellpose_checkpoint_payloads_match_one_shot_payloads(self):
        with installed(self.fakes):
            self.assert_served_matches_one_shot(
                "custom_detect.py", custom_detect.main, custom_detect.serve, self.cellpose_requests(),
                clear_cache=custom_detect._MODEL_CACHE.clear)

    def test_served_stardist_folder_payloads_match_one_shot_payloads(self):
        with installed(self.fakes):
            self.assert_served_matches_one_shot(
                "custom_detect.py", custom_detect.main, custom_detect.serve, self.stardist_requests(),
                clear_cache=custom_detect._MODEL_CACHE.clear)

    def test_worker_loads_each_model_once(self):
        with installed(self.fakes):
            serve_in_process(custom_detect.serve, self.cellpose_requests())
            self.assertEqual(self.builds, [("cellpose", str(self.checkpoint))])
            self.fakes["_cc_fake_segment"].BUILDS.clear()
            serve_in_process(custom_detect.serve, self.stardist_requests())
        self.assertEqual(self.builds, [("stardist", self.stardist_dir.name)])

    def test_a_rewritten_model_file_is_loaded_again(self):
        requests = self.cellpose_requests()[:1]
        original = self.checkpoint.read_bytes()
        self.addCleanup(self.checkpoint.write_bytes, original)
        with installed(self.fakes):
            serve_in_process(custom_detect.serve, requests)
            serve_in_process(custom_detect.serve, requests)  # unchanged: reused
            self.checkpoint.write_bytes(b"\x03" * 4096)
            serve_in_process(custom_detect.serve, requests)  # retrained in place
        self.assertEqual(len(self.builds), 2)

    def test_a_retrained_stardist_folder_is_loaded_again(self):
        requests = self.stardist_requests()[:1]
        weights = self.stardist_dir / "weights_best.h5"
        original = weights.read_bytes()
        self.addCleanup(weights.write_bytes, original)
        with installed(self.fakes):
            serve_in_process(custom_detect.serve, requests)
            weights.write_bytes(b"\x04" * 128)
            serve_in_process(custom_detect.serve, requests)
        self.assertEqual(len(self.builds), 2)

    def test_a_missing_model_fails_the_same_way(self):
        argv = ["--image", self.images["a"], "--model", str(self.checkpoint) + ".missing",
                "--custom-kind", "cellpose", "--pxPerUm", "1"]
        with installed(self.fakes):
            responses = self.assert_served_matches_one_shot(
                "custom_detect.py", custom_detect.main, custom_detect.serve, [argv],
                expect_success=False)
        self.assertEqual(responses[0]["exit_code"], 6)


class CellposeServeTests(ServeTestCase):
    """The Cellpose 3 and 4 workers, now releasing memory after each response."""

    def requests(self, model):
        common = ["--model", model, "--pxPerUm", "1.0", "--conf", "0.5",
                  "--small-threshold", "8", "--large-threshold", "14"]
        return [
            ["--image", self.images["a"], *common],
            ["--image", self.images["b"], *common, "--diameter", "11", "--watershed"],
            ["--image", self.images["rgb"], *common, "--channels", "2,0"],
        ]

    @staticmethod
    def served(module):
        # Exactly what each script's `--serve` branch runs.
        return lambda: cc.serve_ndjson(module.main, after_response=cc.release_request_memory)

    def test_cellpose3_served_payloads_match_one_shot_payloads(self):
        with installed(self.fakes):
            self.assert_served_matches_one_shot(
                "cellpose_detect.py", cellpose_detect.main, self.served(cellpose_detect),
                self.requests("cyto3"), clear_cache=cellpose_detect._MODEL_CACHE.clear)
            # A new worker: no model loaded yet.
            cellpose_detect._MODEL_CACHE.clear()
            self.fakes["_cc_fake_segment"].BUILDS.clear()
            serve_in_process(self.served(cellpose_detect), self.requests("cyto3"))
        self.assertEqual(self.builds, [("cellpose", "cyto3")])

    def test_cellpose4_served_payloads_match_one_shot_payloads(self):
        with installed(self.fakes):
            self.assert_served_matches_one_shot(
                "cellpose4_detect.py", cellpose4_detect.main, self.served(cellpose4_detect),
                self.requests("cpsam"), clear_cache=cellpose4_detect._MODEL_CACHE.clear)
            # A new worker: no model loaded yet.
            cellpose4_detect._MODEL_CACHE.clear()
            self.fakes["_cc_fake_segment"].BUILDS.clear()
            serve_in_process(self.served(cellpose4_detect), self.requests("cpsam"))
        self.assertEqual(self.builds, [("cellpose", "cpsam")])


# ---------------------------------------------------------------------------
# The after-response hook and the serve loop itself.
# ---------------------------------------------------------------------------

class AfterResponseHookTests(unittest.TestCase):
    def serve(self, run_once, count, after_response=None):
        lines = [json.dumps({"request_id": str(i), "args": [str(i)]}) + "\n" for i in range(count)]
        output = io.StringIO()
        logs = io.StringIO()
        with patch.object(sys, "stdin", io.StringIO("".join(lines))), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(logs):
            cc.serve_ndjson(run_once, after_response=after_response)
        return output, logs

    def test_hook_runs_after_each_response_is_written(self):
        output_holder = {}
        seen = []

        def hook():
            seen.append(output_holder["output"].getvalue().count("\n"))

        def run_once(argv):
            sys.stdout.write(json.dumps({"echo": argv[0]}))

        output = io.StringIO()
        output_holder["output"] = output
        lines = "".join(json.dumps({"request_id": str(i), "args": [str(i)]}) + "\n" for i in range(3))
        with patch.object(sys, "stdin", io.StringIO(lines)), contextlib.redirect_stdout(output), \
                contextlib.redirect_stderr(io.StringIO()):
            cc.serve_ndjson(run_once, after_response=hook)
        self.assertEqual(seen, [1, 2, 3])

    def test_hook_runs_after_failed_requests_too(self):
        calls = []

        def run_once(argv):
            if argv[0] == "1":
                raise RuntimeError("boom")
            cc.emit_error("structured", exit_code=4)

        output, _ = self.serve(run_once, 3, after_response=lambda: calls.append(1))
        codes = [json.loads(line)["exit_code"] for line in output.getvalue().splitlines()]
        self.assertEqual(codes, [4, 70, 4])
        self.assertEqual(len(calls), 3)

    def test_hook_failure_is_logged_and_serving_continues(self):
        def hook():
            raise RuntimeError("cleanup broke")

        output, logs = self.serve(lambda argv: print("{}", end=""), 2, after_response=hook)
        self.assertEqual(len(output.getvalue().splitlines()), 2)
        self.assertEqual(logs.getvalue().count("post-response cleanup failed"), 2)

    def test_hook_output_cannot_reach_the_response_channel(self):
        output, logs = self.serve(lambda argv: print("{}", end=""), 2,
                                  after_response=lambda: print("hook chatter"))
        for line in output.getvalue().splitlines():
            json.loads(line)
        self.assertNotIn("hook chatter", output.getvalue())
        self.assertEqual(logs.getvalue().count("hook chatter"), 2)

    def test_without_a_hook_the_loop_is_unchanged(self):
        output, _ = self.serve(lambda argv: print(json.dumps({"n": argv[0]}), end=""), 2)
        responses = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([r["stdout"] for r in responses], ['{"n": "0"}', '{"n": "1"}'])

    def test_exit_status_matches_a_one_shot_interpreter(self):
        def run_once(argv):
            raise SystemExit({"0": None, "1": "bad input", "2": 3}[argv[0]])

        output, logs = self.serve(run_once, 3)
        codes = [json.loads(line)["exit_code"] for line in output.getvalue().splitlines()]
        self.assertEqual(codes, [0, 1, 3])
        self.assertIn("bad input", logs.getvalue())


class ReleaseRequestMemoryTests(unittest.TestCase):
    def test_never_imports_torch_for_cleanup(self):
        saved = sys.modules.pop("torch", None)
        try:
            with patch("gc.collect") as collect:
                cc.release_request_memory()
            self.assertNotIn("torch", sys.modules)
            collect.assert_called_once()
        finally:
            if saved is not None:
                sys.modules["torch"] = saved

    def test_empties_only_accelerator_caches_that_exist(self):
        emptied = []

        def fake_torch(mps_available, cuda_available, cuda_initialized):
            torch = types.ModuleType("torch")
            torch.backends = types.SimpleNamespace(
                mps=types.SimpleNamespace(is_available=lambda: mps_available))
            torch.mps = types.SimpleNamespace(empty_cache=lambda: emptied.append("mps"))
            torch.cuda = types.SimpleNamespace(
                is_available=lambda: cuda_available,
                is_initialized=lambda: cuda_initialized,
                empty_cache=lambda: emptied.append("cuda"))
            return torch

        for flags, expected in (((True, False, False), ["mps"]),
                                ((False, True, True), ["cuda"]),
                                ((False, True, False), []),
                                ((False, False, False), [])):
            emptied.clear()
            with installed({"torch": fake_torch(*flags)}):
                cc.release_request_memory()
            self.assertEqual(emptied, expected, flags)

    def test_a_failing_cache_release_is_logged_not_raised(self):
        torch = types.ModuleType("torch")

        def broken():
            raise RuntimeError("driver")

        torch.backends = types.SimpleNamespace(mps=types.SimpleNamespace(is_available=lambda: True))
        torch.mps = types.SimpleNamespace(empty_cache=broken)
        torch.cuda = types.SimpleNamespace(is_available=lambda: False)
        logs = io.StringIO()
        with installed({"torch": torch}), contextlib.redirect_stderr(logs):
            cc.release_request_memory()
        self.assertIn("could not release the MPS cache", logs.getvalue())


# ---------------------------------------------------------------------------
# End to end: the scripts' real `--serve` entry points, in subprocesses.
# ---------------------------------------------------------------------------

class SubprocessServeTests(ServeTestCase):
    """`script --serve` answers like `script args...` run once per image.

    This covers each script's `__main__` branch. The interpreter is the one
    running the tests; the framework stand-ins come first on its path.
    """

    def environment(self):
        env = dict(os.environ)
        paths = [str(self.fakes_root)]
        if SHARED_DIR.is_dir():
            paths.append(str(SHARED_DIR))
        env["PYTHONPATH"] = os.pathsep.join(paths)
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        return env

    def run_script(self, script, argv, stdin=None):
        return subprocess.run(
            [sys.executable, "-B", str(PYTHON_DIR / script), *argv],
            input=stdin, capture_output=True, text=True, timeout=300,
            env=self.environment(), cwd=self._tmp)

    def check(self, script, requests, builds_per_worker=None):
        lines = "".join(json.dumps({"request_id": f"r{i}", "args": argv}) + "\n"
                        for i, argv in enumerate(requests))
        served = self.run_script(script, ["--serve"], stdin=lines)
        self.assertEqual(served.returncode, 0, served.stderr[-2000:])
        responses = [json.loads(line) for line in served.stdout.splitlines()]
        self.assertEqual([r["request_id"] for r in responses], [f"r{i}" for i in range(len(requests))])
        for argv, response in zip(requests, responses):
            once = self.run_script(script, argv)
            with self.subTest(script=script, args=argv):
                self.assertEqual(response["exit_code"], once.returncode, once.stderr[-2000:])
                self.assertEqual(response["exit_code"], 0, response["stdout"])
                self.assertEqual(UUID_PATTERN.sub("<id>", response["stdout"]),
                                 UUID_PATTERN.sub("<id>", once.stdout))
        if builds_per_worker is not None:
            self.assertEqual(served.stderr.count("[fake] built"), builds_per_worker, served.stderr[-2000:])

    def test_classical(self):
        common = ["--pxPerUm", "1.0", "--watershed-min-distance", "4", "--no-gpu"]
        self.check("classical_detect.py", [
            ["--image", self.images["a"], "--model", "cw-otsu", "--threshold-method", "otsu", *common],
            ["--image", self.images["b"], "--model", "cw-adaptive", "--threshold-method", "adaptive", *common],
        ])

    def test_stardist(self):
        common = ["--model", "2D_versatile_fluo", "--pxPerUm", "1.0"]
        self.check("stardist_detect.py", [["--image", self.images["a"], *common],
                                          ["--image", self.images["b"], *common]],
                   builds_per_worker=1)

    def test_omnipose(self):
        # A fresh home keeps the model-cache setup away from the real one.
        home = Path(self._tmp) / "home"
        home.mkdir(exist_ok=True)
        common = ["--model", "omni-cyto2", "--pxPerUm", "1.0"]
        with patch.dict(os.environ, {"HOME": str(home)}):
            self.check("omnipose_detect.py", [["--image", self.images["a"], *common],
                                              ["--image", self.images["b"], *common, "--cluster"]],
                       builds_per_worker=1)

    def test_custom_models(self):
        cellpose = ["--model", str(self.checkpoint), "--custom-kind", "cellpose", "--pxPerUm", "1.0"]
        stardist = ["--model", str(self.stardist_dir), "--custom-kind", "stardist", "--pxPerUm", "1.0"]
        self.check("custom_detect.py", [["--image", self.images["a"], *cellpose],
                                        ["--image", self.images["b"], *cellpose]],
                   builds_per_worker=1)
        self.check("custom_detect.py", [["--image", self.images["a"], *stardist],
                                        ["--image", self.images["b"], *stardist]],
                   builds_per_worker=1)

    def test_cellpose(self):
        self.check("cellpose_detect.py", [["--image", self.images["a"], "--model", "cyto3", "--pxPerUm", "1"],
                                          ["--image", self.images["b"], "--model", "cyto3", "--pxPerUm", "1"]],
                   builds_per_worker=1)
        self.check("cellpose4_detect.py", [["--image", self.images["a"], "--model", "cpsam", "--pxPerUm", "1"],
                                           ["--image", self.images["b"], "--model", "cpsam", "--pxPerUm", "1"]],
                   builds_per_worker=1)


if __name__ == "__main__":
    unittest.main()
