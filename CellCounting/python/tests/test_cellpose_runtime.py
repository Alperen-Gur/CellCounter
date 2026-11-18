"""Cellpose-SAM sidecar: names the installed Cellpose does not know are
refused, and every result records what ran (``image_stats.runtime``).

Standard library and stand-in modules only, so this runs without numpy,
torch or Cellpose (CI).
"""

from __future__ import annotations

import contextlib
import hashlib
import importlib.machinery
import importlib.metadata
import importlib.util
import io
import json
import os
import platform
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import _cellpose_accel  # noqa: E402
import _cellpose_runtime as runtime  # noqa: E402
import cellpose4_detect  # noqa: E402

_real_find_spec = importlib.util.find_spec


def _without_dinov3(name, *args, **kwargs):
    return None if name == "dinov3" else _real_find_spec(name, *args, **kwargs)


def _with_dinov3(name, *args, **kwargs):
    if name == "dinov3":
        return importlib.machinery.ModuleSpec("dinov3", None)
    return _real_find_spec(name, *args, **kwargs)


def stand_in_models(names, default="cpsam", user=(), weights=None, evaluated=None):
    """Stand-in `cellpose.models` with the given MODEL_NAMES and default."""
    constructed = []

    class Net:
        device = "cpu"

        def parameters(self):
            return iter([types.SimpleNamespace(dtype="torch.bfloat16")])

    class CellposeModel:
        def __init__(self, gpu=False, pretrained_model=default, **kwargs):
            constructed.append(pretrained_model)
            if weights is None:
                raise AssertionError("the model must not be constructed")
            self.pretrained_model = weights
            self.device = "cpu"
            self.net = Net()

        def eval(self, image, **kwargs):
            if evaluated is not None:
                evaluated.append(kwargs)
            return ("masks", ["rgb", "dP", "cellprob"], "styles")

    module = types.ModuleType("cellpose.models")
    module.MODEL_NAMES = list(names)
    module.CellposeModel = CellposeModel
    module.get_user_models = lambda: list(user)
    module.constructed = constructed
    return module


def stand_in_cellpose(models, version):
    package = types.ModuleType("cellpose")
    package.version = version
    package.models = models
    utils = types.ModuleType("cellpose.utils")

    def download(*args, **kwargs):
        raise AssertionError("no download in this test")

    utils.download_url_to_file = download
    package.utils = utils
    torch = types.SimpleNamespace(
        __version__="2.12.0",
        backends=types.SimpleNamespace(mps=types.SimpleNamespace(is_available=lambda: False)),
        cuda=types.SimpleNamespace(is_available=lambda: False))
    return {"cellpose": package, "cellpose.models": models, "cellpose.utils": utils,
            "numpy": types.ModuleType("numpy"), "torch": torch}


class ModelNameTests(unittest.TestCase):

    def test_name_unknown_to_the_installed_cellpose_is_refused(self):
        refusal = cellpose4_detect.check_model_name(stand_in_models(["cpsam"]), "cpsam_v2", "4.1.1")
        self.assertIsNotNone(refusal)
        code, hint = refusal
        self.assertEqual(code, "model-not-in-cellpose")
        self.assertIn("4.1.1", hint)
        self.assertIn("cpsam_v2", hint)
        self.assertIn("update Cellpose-SAM", hint)

    def test_known_names_user_models_and_paths_are_accepted(self):
        models = stand_in_models(["cpsam_v2", "cpdino", "cpdino-vitb", "cpsam"], user=["my_model"])
        for name in ("cpsam", "cpsam_v2", "my_model"):
            self.assertIsNone(cellpose4_detect.check_model_name(models, name, "4.2.1.1"))
        with tempfile.NamedTemporaryFile() as checkpoint:
            self.assertIsNone(cellpose4_detect.check_model_name(stand_in_models([]), checkpoint.name, "4.2.1.1"))

    def test_dino_without_dinov3_is_refused(self):
        models = stand_in_models(["cpsam_v2", "cpdino", "cpdino-vitb", "cpsam"])
        with patch("importlib.util.find_spec", side_effect=_without_dinov3):
            for name in ("cpdino", "cpdino-vitb"):
                code, hint = cellpose4_detect.check_model_name(models, name, "4.2.1.1")
                self.assertEqual(code, "model-needs-dinov3")
                self.assertIn("dinov3", hint)
        with patch("importlib.util.find_spec", side_effect=_with_dinov3):
            self.assertIsNone(cellpose4_detect.check_model_name(models, "cpdino", "4.2.1.1"))

    def test_weight_recovery_uses_the_model_cellpose_falls_back_to(self):
        new = stand_in_models(["cpsam_v2", "cpdino", "cpdino-vitb", "cpsam"], default="cpsam_v2")
        old = stand_in_models(["cpsam"], default="cpsam")
        self.assertEqual(cellpose4_detect.cellpose_default_model(new), "cpsam_v2")
        self.assertEqual(cellpose4_detect.cellpose_default_model(old), "cpsam")
        self.assertEqual(cellpose4_detect.cellpose_default_model(types.SimpleNamespace()), "cpsam")


class SidecarTests(unittest.TestCase):

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        environment = patch.dict(os.environ, {
            "CELLPOSE_LOCAL_MODELS_PATH": str(self.folder / "models"),
            runtime.ENV_HASH_CACHE: str(self.folder / "weights-sha256.json"),
            _cellpose_accel.ENV_STOCK: "1",
        })
        environment.start()
        self.addCleanup(environment.stop)
        _cellpose_accel.restore()
        self.addCleanup(_cellpose_accel.restore)
        self.addCleanup(runtime._memo.clear)
        cellpose4_detect._MODEL_CACHE.clear()
        self.addCleanup(cellpose4_detect._MODEL_CACHE.clear)

    def run_sidecar(self, modules, model):
        output = io.StringIO()
        image = types.SimpleNamespace(shape=(10, 12), ndim=2)
        cc = cellpose4_detect.cc
        exit_code = 0
        with patch.dict(sys.modules, modules), \
             patch.object(cc, "open_image_for_detection", return_value=image) as opened, \
             patch.object(cc, "compute_qc_metrics", return_value={}), \
             patch.object(cc, "compute_colony_stats", return_value={}), \
             patch.object(cc, "measure_cells", return_value=[]), \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            try:
                cellpose4_detect.main(["--image", "fixture.png", "--pxPerUm", "1", "--model", model])
            except SystemExit as exc:
                exit_code = exc.code
        return exit_code, json.loads(output.getvalue()), opened.call_count

    def test_unknown_name_is_refused_before_the_image_or_model_loads(self):
        models = stand_in_models(["cpsam"])
        code, payload, opened = self.run_sidecar(stand_in_cellpose(models, "4.1.1"), "cpsam_v2")
        self.assertEqual(code, 4)
        self.assertEqual(payload["error"], "model-not-in-cellpose")
        self.assertIn("cpsam_v2", payload["hint"])
        self.assertEqual(opened, 0)
        self.assertEqual(models.constructed, [])

    def test_payload_records_the_runtime(self):
        # Outside the models folder, so no size pin can move the fixture aside.
        weights = self.folder / "checkpoint" / "cpsam_v2"
        weights.parent.mkdir(parents=True)
        weights.write_bytes(b"cpsam_v2 weights")
        evaluated = []
        models = stand_in_models(["cpsam_v2", "cpdino", "cpdino-vitb", "cpsam"], default="cpsam_v2",
                                 weights=str(weights), evaluated=evaluated)
        code, payload, _ = self.run_sidecar(stand_in_cellpose(models, "4.2.1.1"), "cpsam_v2")
        self.assertEqual(code, 0)
        self.assertEqual(models.constructed, ["cpsam_v2"])
        self.assertEqual(len(evaluated), 1)
        block = payload["image_stats"]["runtime"]
        self.assertEqual(block["schema"], 1)
        self.assertEqual(block["requested_model"], "cpsam_v2")
        self.assertEqual(block["weights_file"], "cpsam_v2")
        self.assertEqual(block["weights_size_bytes"], len(b"cpsam_v2 weights"))
        self.assertEqual(block["weights_sha256"], hashlib.sha256(b"cpsam_v2 weights").hexdigest())
        self.assertEqual(block["device"], "cpu")
        self.assertEqual(block["model_dtype"], "bfloat16")
        self.assertEqual(block["torch_version"], "2.12.0")
        self.assertIn("CELLCOUNTER_STOCK_CELLPOSE", block["accel"])
        self.assertEqual(block["accel_patches"], [])
        self.assertEqual(block["python_version"], platform.python_version())
        # No folder paths in what gets exported.
        self.assertNotIn(str(self.folder), json.dumps(block))


class RuntimeBlockTests(unittest.TestCase):

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        self.cache = self.folder / "caches" / "weights-sha256.json"
        environment = patch.dict(os.environ, {runtime.ENV_HASH_CACHE: str(self.cache)})
        environment.start()
        self.addCleanup(environment.stop)
        runtime._memo.clear()
        self.addCleanup(runtime._memo.clear)
        self.weights = self.folder / "cpsam"
        self.weights.write_bytes(b"weights" * 1000)

    def test_block_records_versions_and_accel_status(self):
        accel = types.SimpleNamespace(
            status=lambda: "cellpose accel: active (cellpose 4.2.1.1): extend_centers",
            active_patches=lambda: ("extend_centers",))
        versions = {"cellpose": "4.2.1.1", "torchvision": "0.27.0",
                    "opencv-python-headless": "4.13.0.92"}

        def version(name):
            if name in versions:
                return versions[name]
            raise importlib.metadata.PackageNotFoundError(name)

        model = types.SimpleNamespace(pretrained_model=str(self.weights))
        modules = {"torch": types.SimpleNamespace(__version__="2.12.0"),
                   "numpy": types.SimpleNamespace(__version__="2.4.6"),
                   "torchvision": None, "_cellpose_accel": accel}
        with patch.dict(sys.modules, modules), \
             patch("importlib.metadata.version", side_effect=version), \
             contextlib.redirect_stderr(io.StringIO()):
            block = runtime.runtime_block(model=model, requested_model="cpsam", device="mps")
        self.assertEqual(block["cellpose_version"], "4.2.1.1")
        self.assertEqual(block["torch_version"], "2.12.0")
        self.assertEqual(block["torchvision_version"], "0.27.0")
        self.assertEqual(block["numpy_version"], "2.4.6")
        self.assertEqual(block["opencv_version"], "4.13.0.92")
        self.assertEqual(block["opencv_distribution"], "opencv-python-headless")
        self.assertEqual(block["device"], "mps")
        self.assertEqual(block["weights_file"], "cpsam")
        self.assertTrue(block["weights_mtime"].endswith("Z"))
        self.assertEqual(block["accel"], "active (cellpose 4.2.1.1): extend_centers")
        self.assertEqual(block["accel_patches"], ["extend_centers"])
        json.dumps(block)

    def test_checksum_is_read_once_per_size_and_mtime(self):
        calls = []
        real_hash = runtime._hash_file

        def counting(path):
            calls.append(path)
            return real_hash(path)

        with patch.object(runtime, "_hash_file", side_effect=counting), \
             contextlib.redirect_stderr(io.StringIO()):
            first = runtime.weights_sha256(str(self.weights))
            runtime._memo.clear()          # a new worker: only the JSON cache remains
            second = runtime.weights_sha256(str(self.weights))
            self.assertEqual(len(calls), 1)
            self.assertTrue(self.cache.exists())
            self.weights.write_bytes(b"replaced")
            third = runtime.weights_sha256(str(self.weights))
        self.assertEqual(first, hashlib.sha256(b"weights" * 1000).hexdigest())
        self.assertEqual(second, first)
        self.assertEqual(third, hashlib.sha256(b"replaced").hexdigest())
        self.assertEqual(len(calls), 2)

    def test_damaged_cache_is_ignored(self):
        self.cache.parent.mkdir(parents=True)
        self.cache.write_text("{not json")
        with contextlib.redirect_stderr(io.StringIO()):
            digest = runtime.weights_sha256(str(self.weights))
        self.assertEqual(digest, hashlib.sha256(b"weights" * 1000).hexdigest())
        self.assertIn(digest, self.cache.read_text())

    def test_block_never_raises_and_omits_what_it_cannot_read(self):
        class Net:
            def parameters(self):
                raise RuntimeError("no parameters")

        broken = types.SimpleNamespace(net=Net(), pretrained_model=str(self.folder / "missing"))
        with patch("importlib.metadata.version", side_effect=RuntimeError("boom")), \
             patch.dict(sys.modules, {"_cellpose_accel": None}):
            block = runtime.runtime_block(model=broken)
        self.assertEqual(block["schema"], 1)
        self.assertNotIn("cellpose_version", block)
        self.assertNotIn("model_dtype", block)
        self.assertNotIn("weights_sha256", block)
        self.assertEqual(block["weights_file"], "missing")
        self.assertEqual(block["accel"], "not used")


if __name__ == "__main__":
    unittest.main()
