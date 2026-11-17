"""`sam_detect.py --serve` answers exactly like one `sam_detect.py` run per request.

SAM detection and point/box refinement both run `sam_detect.py`. A `--serve`
worker keeps the SAM predictor loaded between requests and, for prompts, the
decoded image and its embedding for the last two images, so a second click
on an image runs only the prompt decoder. These tests run the same requests
both ways and compare the exact payloads, and they count model loads and
image-encoder runs.

micro_sam is not installed in CI, so the tests use stand-ins written to disk:

* A tiny deterministic "SAM" (`micro_sam.util`, `micro_sam.automatic_segmentation`).
  Its encoder averages 4x4 blocks and its decoder grows the region around the
  prompt. It records every model load, encoder run, cache read and decoder
  run. Its embedding cache on disk is a folder with `features.npy` and
  `attrs.json`, read back when present, as micro_sam reads its zarr cache.
* When `segment_anything` and PyTorch are importable (not in CI), the same
  micro_sam calls are also backed by segment_anything's real ViT-B predictor
  built with random weights (`checkpoint=None`, nothing is downloaded). The
  masks mean nothing, but the real encoder, prompt decoder and mask
  post-processing run, including the round trip of an embedding through the
  cache on disk.

Cell ids are random UUIDs. In-process tests number them 1, 2, 3, ... per
request; subprocess tests blank them out before comparing.
"""

from __future__ import annotations

import contextlib
import importlib
import importlib.util
import io
import itertools
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
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
import sam_detect  # noqa: E402

UUID_PATTERN = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
MICRO_SAM_MODULES = ("micro_sam", "micro_sam.util", "micro_sam.automatic_segmentation")
HAS_SEGMENT_ANYTHING = all(importlib.util.find_spec(name) is not None
                           for name in ("torch", "segment_anything"))


# ---------------------------------------------------------------------------
# micro_sam stand-ins.
# ---------------------------------------------------------------------------

_INIT = '__version__ = "0+fake"\n'

_AUTOMATIC = '''
"""micro_sam.automatic_segmentation stand-in, for the call sam_detect makes first."""
import numpy as np
from scipy import ndimage as ndi

from micro_sam import util


def automatic_instance_segmentation(predictor=None, image=None, ndim=None, **kwargs):
    if predictor is None or image is None:
        raise TypeError("automatic_instance_segmentation() needs predictor and image")
    util.precompute_image_embeddings(predictor, image, ndim=ndim)
    util.note("automatic", predictor.model_type)
    values = np.asarray(image, dtype=np.float64)
    if values.ndim == 3:
        values = values.mean(axis=2)
    labels, _ = ndi.label(values > values.mean() + 0.5 * values.std())
    return labels.astype(np.int32)
'''

# Shared by both micro_sam.util stand-ins: the embedding cache on disk.
_CACHE_HELPERS = '''
import json
import os
import sys

import numpy as np

CALLS = []


def note(*event):
    CALLS.append(event)
    print("[fake-sam] " + " ".join(str(part) for part in event), file=sys.stderr)


def _read_cache(save_path):
    if save_path is None or not os.path.exists(os.path.join(save_path, "attrs.json")):
        return None
    note("load_embeddings", os.path.basename(save_path))
    with open(os.path.join(save_path, "attrs.json")) as handle:
        attrs = json.load(handle)
    # Read back from disk as lists, as zarr attributes come back.
    return {"features": np.load(os.path.join(save_path, "features.npy")),
            "input_size": attrs["input_size"], "original_size": attrs["original_size"]}


def _write_cache(save_path, features, input_size, original_size):
    if save_path is None:
        return
    os.makedirs(save_path, exist_ok=True)
    np.save(os.path.join(save_path, "features.npy"), features)
    with open(os.path.join(save_path, "attrs.json"), "w") as handle:
        json.dump({"input_size": [int(v) for v in input_size],
                   "original_size": [int(v) for v in original_size]}, handle)
'''

_TINY_UTIL = _CACHE_HELPERS + '''
from scipy import ndimage as ndi

BLOCK = 4


class Predictor:
    """A deterministic stand-in for micro_sam's SamPredictor."""

    def __init__(self, model_type, device):
        self.model_type = model_type
        self.device = device or "default"
        self.reset_image()

    def reset_image(self):
        self.features = None
        self.original_size = None
        self.input_size = None
        self.is_image_set = False

    def predict(self, point_coords=None, point_labels=None, box=None,
                multimask_output=True, **kwargs):
        if not self.is_image_set:
            raise RuntimeError("An image must be set before predicting")
        note("decode")
        height, width = (int(v) for v in self.original_size)
        coarse = np.asarray(self.features, dtype=np.float32)[0, 0]
        dense = np.kron(coarse, np.ones((BLOCK, BLOCK), dtype=np.float32))[:height, :width]
        if point_coords is not None:
            x, y = (float(v) for v in np.asarray(point_coords)[0])
        else:
            x0, y0, x1, y1 = (float(v) for v in box)
            x, y = (x0 + x1) / 2.0, (y0 + y1) / 2.0
        col = min(width - 1, max(0, int(round(x))))
        row = min(height - 1, max(0, int(round(y))))
        seed = float(dense[row, col])
        spread = float(dense.max() - dense.min()) + 1.0
        masks, scores = [], []
        for tolerance in (0.1, 0.25, 0.4):
            inside = np.abs(dense - seed) <= tolerance * spread
            if box is not None:
                x0, y0, x1, y1 = (int(round(float(v))) for v in box)
                window = np.zeros_like(inside)
                window[max(0, y0):max(0, y1) + 1, max(0, x0):max(0, x1) + 1] = True
                inside &= window
            labels, _ = ndi.label(inside)
            mask = labels == labels[row, col] if labels[row, col] else np.zeros_like(inside)
            masks.append(mask)
            area = float(mask.sum())
            scores.append(area / (area + 50.0) - tolerance / 2.0)
        return np.stack(masks), np.asarray(scores, dtype=np.float32), None


def get_sam_model(model_type="vit_b_lm", device=None, **kwargs):
    note("load_model", model_type, device)
    return Predictor(model_type, device)


def _encode(image):
    values = np.asarray(image, dtype=np.float32)
    if values.ndim == 3:
        values = values.mean(axis=2)
    height, width = values.shape
    rows, cols = -(-height // BLOCK), -(-width // BLOCK)
    padded = np.zeros((rows * BLOCK, cols * BLOCK), dtype=np.float32)
    padded[:height, :width] = values
    coarse = padded.reshape(rows, BLOCK, cols, BLOCK).mean(axis=(1, 3))
    return coarse[None, None].astype(np.float32)


def precompute_image_embeddings(predictor, input_, save_path=None, lazy_loading=False,
                                ndim=None, **kwargs):
    cached = _read_cache(save_path)
    if cached is not None:
        return cached
    note("encode", tuple(np.asarray(input_).shape))
    predictor.reset_image()
    features = _encode(input_)
    size = tuple(int(v) for v in np.asarray(input_).shape[:2])
    _write_cache(save_path, features, size, size)
    return {"features": features, "input_size": size, "original_size": size}


def set_precomputed(predictor, image_embeddings, i=None, tile_id=None):
    predictor.features = np.asarray(image_embeddings["features"][:])
    predictor.original_size = image_embeddings["original_size"]
    predictor.input_size = image_embeddings["input_size"]
    predictor.is_image_set = True
    return predictor
'''

# The micro_sam calls sam_detect makes, around segment_anything's real
# predictor. `get_sam_model` seeds PyTorch before building the network, so
# every process builds the same random weights.
_SEGMENT_ANYTHING_UTIL = _CACHE_HELPERS + '''
import torch
from segment_anything import SamPredictor, sam_model_registry


def get_sam_model(model_type="vit_b", device=None, **kwargs):
    note("load_model", model_type, device)
    torch.manual_seed(0)
    sam = sam_model_registry["vit_b"](checkpoint=None)  # random weights; nothing is downloaded
    sam.to("cpu")
    sam.eval()
    return SamPredictor(sam)


def _to_image(input_):
    values = np.asarray(input_)
    return np.stack([values] * 3, axis=-1) if values.ndim == 2 else values


def precompute_image_embeddings(predictor, input_, save_path=None, lazy_loading=False,
                                ndim=None, **kwargs):
    cached = _read_cache(save_path)
    if cached is not None:
        return cached
    note("encode", tuple(np.asarray(input_).shape))
    predictor.reset_image()
    predictor.set_image(_to_image(input_))
    features = predictor.get_image_embedding().cpu().numpy()
    _write_cache(save_path, features, predictor.input_size, predictor.original_size)
    return {"features": features, "input_size": predictor.input_size,
            "original_size": predictor.original_size}


def set_precomputed(predictor, image_embeddings, i=None, tile_id=None):
    # What micro_sam.util.set_precomputed does for a 2-D image.
    features = image_embeddings["features"]
    predictor.features = torch.from_numpy(np.asarray(features[:])).to(predictor.device)
    predictor.original_size = image_embeddings["original_size"]
    predictor.input_size = image_embeddings["input_size"]
    predictor.is_image_set = True
    return predictor
'''


def write_micro_sam(root: Path, util_source: str) -> None:
    package = root / "micro_sam"
    package.mkdir(parents=True, exist_ok=True)
    (package / "__init__.py").write_text(_INIT)
    (package / "util.py").write_text(util_source.lstrip("\n"))
    (package / "automatic_segmentation.py").write_text(_AUTOMATIC.lstrip("\n"))


def load_micro_sam(root: Path) -> dict:
    """Import a stand-in without leaving it visible to other tests."""
    hidden = {name: sys.modules.pop(name) for name in MICRO_SAM_MODULES if name in sys.modules}
    sys.path.insert(0, str(root))
    try:
        return {name: importlib.import_module(name) for name in MICRO_SAM_MODULES}
    finally:
        sys.path.remove(str(root))
        for name in MICRO_SAM_MODULES:
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


@contextlib.contextmanager
def micro_sam_missing():
    """Make `import micro_sam` fail, whatever is installed."""
    saved = {name: sys.modules.get(name) for name in MICRO_SAM_MODULES}
    for name in MICRO_SAM_MODULES:
        sys.modules[name] = None  # an ImportError on import
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

def _disc_image(shape, discs, background=18.0, seed=0):
    rng = np.random.default_rng(seed)
    height, width = shape
    rows, cols = np.mgrid[0:height, 0:width]
    image = background + rng.normal(0.0, 4.0, shape)
    for row, col, radius, level in discs:
        image[(rows - row) ** 2 + (cols - col) ** 2 <= radius ** 2] = level
    return np.clip(image, 0, 255).astype(np.uint8)


def write_images(root: Path) -> dict:
    images = {
        "a": _disc_image((80, 96), [(20, 20, 8, 210), (22, 50, 7, 190), (55, 30, 6, 230),
                                    (50, 70, 9, 200)], seed=1),
        "b": _disc_image((72, 64), [(15, 15, 6, 160), (40, 22, 8, 210), (40, 45, 7, 205)], seed=2),
        "c": _disc_image((64, 64), [(30, 30, 10, 220)], seed=3),
    }
    green = _disc_image((70, 70), [(18, 20, 7, 200), (45, 45, 9, 230)], seed=4)
    images["rgb"] = np.stack([np.full_like(green, 12), green, np.full_like(green, 30)], axis=-1)
    paths = {}
    for name, pixels in images.items():
        path = root / f"{name}.png"
        Image.fromarray(pixels).save(path)
        paths[name] = str(path)
    return paths


# ---------------------------------------------------------------------------
# Running both ways in-process.
# ---------------------------------------------------------------------------

class _NumberedIds:
    """uuid4 stand-in numbering ids 1, 2, 3, ...; restarted for each request."""

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


def forget_everything():
    """The state a new process starts with."""
    sam_detect._MODEL_CACHE.clear()
    sam_detect._PROMPT_IMAGES.clear()
    sam_detect._PROMPT_EMBEDDINGS.clear()


def one_shot(argv):
    """Run `sam_detect.py argv...` as a new process would. Returns (code, stdout, stderr)."""
    forget_everything()
    ids = _NumberedIds()
    output, logs = io.StringIO(), io.StringIO()
    code = 0
    with patch("uuid.uuid4", ids), patch.object(sys, "argv", ["sam_detect.py", *argv]), \
            contextlib.redirect_stdout(output), contextlib.redirect_stderr(logs):
        try:
            sam_detect.main()
        except SystemExit as exc:
            code = cc._exit_status(exc.code)
    forget_everything()
    return code, output.getvalue(), logs.getvalue()


def serve(requests):
    """Feed `requests` (argument lists) to one new worker. Returns (responses, stderr)."""
    forget_everything()
    ids = _NumberedIds()
    lines = [json.dumps({"request_id": f"r{index}", "args": argv}) + "\n"
             for index, argv in enumerate(requests)]
    output, logs = io.StringIO(), io.StringIO()
    with patch("uuid.uuid4", ids), patch.object(sys, "stdin", _Requests(lines, ids)), \
            contextlib.redirect_stdout(output), contextlib.redirect_stderr(logs):
        sam_detect.serve()
    responses = [json.loads(line) for line in output.getvalue().splitlines()]
    return responses, logs.getvalue()


def point(image, x, y, cache, model="vit_b_lm", extra=()):
    return ["--image", image, "--model", model, "--pxPerUm", "1.0", "--prompts", "interactive",
            "--embedding-cache", cache, "--prompt-point", str(x), str(y), *extra]


def box(image, x0, y0, x1, y1, cache, model="vit_b_lm", extra=()):
    return ["--image", image, "--model", model, "--pxPerUm", "1.0", "--prompts", "interactive",
            "--embedding-cache", cache, "--prompt-box", str(x0), str(y0), str(x1), str(y1), *extra]


class SamTestCase(unittest.TestCase):
    util_source = _TINY_UTIL

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.mkdtemp(prefix="cc-sam-serve-test-")
        root = Path(cls._tmp)
        cls.images = write_images(root)
        cls.fakes_root = root / "fakes"
        write_micro_sam(cls.fakes_root, cls.util_source)
        cls.fakes = load_micro_sam(cls.fakes_root)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls._tmp, ignore_errors=True)

    def setUp(self):
        forget_everything()
        self.calls.clear()
        self.run_dir = Path(tempfile.mkdtemp(prefix="run-", dir=self._tmp))

    @property
    def calls(self):
        return self.fakes["micro_sam.util"].CALLS

    def events(self, kind):
        return [call for call in self.calls if call[0] == kind]

    def caches(self, name):
        """Two separate embedding folders: one for the worker, one for one-shot runs."""
        return (str(self.run_dir / "served" / f"{name}.zarr"),
                str(self.run_dir / "once" / f"{name}.zarr"))

    def assert_same_payloads(self, served_requests, one_shot_requests, expect_success=True):
        """Each served response equals the one-shot run of the matching request.

        The one-shot runs happen in order after the worker has finished, each
        as a new process: the first click on an image computes and writes its
        embedding, later ones read it back from disk.
        """
        with installed(self.fakes):
            responses, _ = serve(served_requests)
            self.assertEqual(len(responses), len(served_requests))
            for index, (argv, response) in enumerate(zip(one_shot_requests, responses)):
                code, stdout, stderr = one_shot(argv)
                with self.subTest(request=index, args=argv):
                    self.assertEqual(response["request_id"], f"r{index}")
                    self.assertEqual(response["exit_code"], code, stderr[-2000:])
                    self.assertEqual(response["stdout"], stdout)
                    if expect_success:
                        self.assertEqual(code, 0, stderr[-2000:])
                        self.assertIn('"cells"', stdout)
        return responses


# ---------------------------------------------------------------------------
# Point/box refinement.
# ---------------------------------------------------------------------------

class PromptServeTests(SamTestCase):
    def clicks(self, cache_a, cache_b):
        a, b = self.images["a"], self.images["b"]
        return [
            point(a, 20, 20, cache_a),
            point(a, 50, 22, cache_a),
            box(a, 60, 40, 80, 60, cache_a),
            point(b, 22, 40, cache_b),
            point(a, 30, 55, cache_a),          # back to the first image
            box(b, 5, 5, 25, 25, cache_b, extra=("--watershed", "--watershed-min-distance", "3")),
            point(a, 20, 20, cache_a, extra=("--bg-subtract", "--rolling-ball-radius", "15")),
        ]

    def test_served_clicks_match_one_shot_clicks(self):
        served_a, once_a = self.caches("a")
        served_b, once_b = self.caches("b")
        responses = self.assert_same_payloads(self.clicks(served_a, served_b),
                                              self.clicks(once_a, once_b))
        for response in responses:
            payload = json.loads(response["stdout"])
            self.assertEqual(len(payload["cells"]), 1, response["stdout"][:400])
            # A prompt refines one cell: no per-image statistics.
            self.assertEqual(payload["image_stats"], {})
        # Both ways leave the same embedding files behind.
        for served, once in ((served_a, once_a), (served_b, once_b)):
            self.assertEqual(Path(served, "features.npy").read_bytes(),
                             Path(once, "features.npy").read_bytes())

    def test_worker_loads_the_model_once_and_encodes_each_image_once(self):
        cache_a, _ = self.caches("a")
        cache_b, _ = self.caches("b")
        a, b = self.images["a"], self.images["b"]
        requests = [point(a, 20, 20, cache_a), point(a, 50, 22, cache_a), box(a, 60, 40, 80, 60, cache_a),
                    point(b, 22, 40, cache_b), point(b, 45, 40, cache_b), point(a, 30, 55, cache_a)]
        with installed(self.fakes):
            responses, logs = serve(requests)
        self.assertEqual([r["exit_code"] for r in responses], [0] * len(requests))
        self.assertEqual(self.events("load_model"), [("load_model", "vit_b_lm", None)])
        self.assertEqual(len(self.events("encode")), 2)          # one per image
        self.assertEqual(self.events("load_embeddings"), [])     # never re-read from disk
        self.assertEqual(len(self.events("decode")), len(requests))
        self.assertEqual(logs.count("reusing interactive image embedding from memory"), 4)
        self.assertEqual(logs.count("reusing decoded image"), 4)

    def test_one_shot_runs_reuse_the_embedding_on_disk(self):
        # Unchanged one-shot behaviour: a model load per click, the encoder
        # only for the first click on an image.
        cache_a, _ = self.caches("a")
        a = self.images["a"]
        with installed(self.fakes):
            for argv in (point(a, 20, 20, cache_a), point(a, 50, 22, cache_a)):
                code, _, stderr = one_shot(argv)
                self.assertEqual(code, 0, stderr[-2000:])
        self.assertEqual(len(self.events("load_model")), 2)
        self.assertEqual(len(self.events("encode")), 1)
        self.assertEqual(len(self.events("load_embeddings")), 1)

    def test_only_the_two_most_recent_images_stay_in_memory(self):
        caches = {name: self.caches(name)[0] for name in ("a", "b", "c")}
        image = self.images
        requests = [point(image["a"], 20, 20, caches["a"]),
                    point(image["b"], 22, 40, caches["b"]),
                    point(image["c"], 30, 30, caches["c"]),     # evicts a
                    point(image["a"], 50, 22, caches["a"]),     # a again: read from disk
                    point(image["c"], 31, 31, caches["c"])]     # c is still in memory
        with installed(self.fakes):
            responses, _ = serve(requests)
            self.assertEqual([r["exit_code"] for r in responses], [0] * len(requests))
            self.assertEqual(len(self.events("encode")), 3)
            self.assertEqual(self.events("load_embeddings"), [("load_embeddings", "a.zarr")])
            self.assertEqual(len(sam_detect._PROMPT_IMAGES), 2)
            self.assertEqual(len(sam_detect._PROMPT_EMBEDDINGS), 2)
            self.assertEqual([stamp[0] for stamp in sam_detect._PROMPT_IMAGES],
                             [os.path.realpath(image["a"]), os.path.realpath(image["c"])])
            self.assertEqual([key[1][0] for key in sam_detect._PROMPT_EMBEDDINGS],
                             [os.path.realpath(image["a"]), os.path.realpath(image["c"])])

    def test_cached_decoded_image_is_read_only(self):
        cache_a, _ = self.caches("a")
        with installed(self.fakes):
            serve([point(self.images["a"], 20, 20, cache_a)])
            (cached,) = sam_detect._PROMPT_IMAGES.values()
        self.assertFalse(cached.flags.writeable)

    def test_a_rewritten_image_is_decoded_again(self):
        path = self.run_dir / "changing.png"
        Image.open(self.images["a"]).save(path)
        cache, _ = self.caches("changing")
        first, second = point(str(path), 20, 20, cache), point(str(path), 22, 50, cache)
        ids = _NumberedIds()

        def requests():
            yield json.dumps({"request_id": "r0", "args": first}) + "\n"
            # The file changes between two clicks of one worker.
            pixels = np.array(Image.open(path))
            Image.fromarray(np.ascontiguousarray(pixels[:, ::-1])).save(path)
            stat = path.stat()
            os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns + 1_000_000_000))
            ids.restart()
            yield json.dumps({"request_id": "r1", "args": second}) + "\n"

        output, logs = io.StringIO(), io.StringIO()
        with installed(self.fakes):
            forget_everything()
            with patch("uuid.uuid4", ids), patch.object(sys, "stdin", requests()), \
                    contextlib.redirect_stdout(output), contextlib.redirect_stderr(logs):
                sam_detect.serve()
            responses = [json.loads(line) for line in output.getvalue().splitlines()]
            # A new process for the second click reads the same embedding
            # from disk (micro_sam's cache, now stale), so it answers the same.
            code, stdout, _ = one_shot(second)
        self.assertEqual([r["exit_code"] for r in responses], [0, 0])
        self.assertNotIn("reusing decoded image", logs.getvalue())
        self.assertNotIn("reusing interactive image embedding from memory", logs.getvalue())
        self.assertEqual(code, 0)
        self.assertEqual(responses[1]["stdout"], stdout)
        self.assertEqual(self.events("load_embeddings"), [("load_embeddings", "changing.zarr")] * 2)

    def test_a_removed_embedding_cache_is_computed_and_written_again(self):
        cache_a, _ = self.caches("a")
        a = self.images["a"]

        def requests():
            yield json.dumps({"request_id": "r0", "args": point(a, 20, 20, cache_a)}) + "\n"
            shutil.rmtree(cache_a)  # e.g. the image was deleted and the cache cleaned up
            yield json.dumps({"request_id": "r1", "args": point(a, 50, 22, cache_a)}) + "\n"

        with installed(self.fakes):
            forget_everything()
            with patch.object(sys, "stdin", requests()), contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(io.StringIO()):
                sam_detect.serve()
        self.assertEqual(len(self.events("encode")), 2)
        self.assertTrue(Path(cache_a, "features.npy").exists())

    def test_no_gpu_prompts_use_a_cpu_predictor(self):
        cache_a, _ = self.caches("a")
        a = self.images["a"]
        with installed(self.fakes):
            serve([point(a, 20, 20, cache_a, extra=("--no-gpu",)),
                   point(a, 50, 22, cache_a, extra=("--no-gpu",)),
                   point(a, 50, 22, cache_a)])
        self.assertEqual(self.events("load_model"),
                         [("load_model", "vit_b_lm", "cpu"), ("load_model", "vit_b_lm", None)])
        # Changing the predictor drops the embeddings made with the old one.
        self.assertEqual(len(self.events("encode")), 1)
        self.assertEqual(len(self.events("load_embeddings")), 1)

    def test_a_different_model_replaces_the_loaded_one(self):
        cache_lm, _ = self.caches("a-lm")
        cache_t, _ = self.caches("a-t")
        a = self.images["a"]
        with installed(self.fakes):
            serve([point(a, 20, 20, cache_lm), point(a, 20, 20, cache_t, model="vit_t"),
                   point(a, 22, 20, cache_t, model="vit_t")])
            self.assertEqual(list(sam_detect._MODEL_CACHE), [("vit_t", None)])
            self.assertEqual(len(sam_detect._PROMPT_EMBEDDINGS), 1)
        self.assertEqual([call[1] for call in self.events("load_model")], ["vit_b_lm", "vit_t"])

    def test_failures_answer_the_same_way(self):
        cache_a, once_a = self.caches("a")
        missing = str(self.run_dir / "missing.png")
        no_prompt = ["--image", self.images["a"], "--model", "vit_b_lm", "--pxPerUm", "1",
                     "--prompts", "interactive"]
        served = [point(missing, 1, 1, cache_a), no_prompt + ["--embedding-cache", cache_a]]
        once = [point(missing, 1, 1, once_a), no_prompt + ["--embedding-cache", once_a]]
        responses = self.assert_same_payloads(served, once, expect_success=False)
        self.assertEqual([r["exit_code"] for r in responses], [3, 5])
        self.assertEqual(json.loads(responses[0]["stdout"])["error"], "image-open-failed")
        self.assertEqual(json.loads(responses[1]["stdout"])["error"], "segmentation-failed")

    def test_without_micro_sam_every_request_reports_it(self):
        cache_a, _ = self.caches("a")
        argv = point(self.images["a"], 20, 20, cache_a)
        with micro_sam_missing():
            responses, _ = serve([argv, argv])
            code, stdout, _ = one_shot(argv)
        self.assertEqual(code, 2)
        self.assertEqual([r["exit_code"] for r in responses], [2, 2])
        self.assertEqual([r["stdout"] for r in responses], [stdout, stdout])
        self.assertEqual(json.loads(stdout)["error"], "micro_sam-not-installed")


# ---------------------------------------------------------------------------
# Whole-image SAM detection.
# ---------------------------------------------------------------------------

class DetectionServeTests(SamTestCase):
    def requests(self):
        common = ["--model", "vit_b_lm", "--pxPerUm", "1.0", "--conf", "0.5", "--prompts", "auto",
                  "--small-threshold", "8", "--large-threshold", "14"]
        image = self.images
        return [
            ["--image", image["a"], *common],
            ["--image", image["b"], *common, "--watershed", "--watershed-min-distance", "3"],
            ["--image", image["a"], *common, "--bg-subtract", "--rolling-ball-radius", "15"],
            ["--image", image["rgb"], *common, "--no-gpu"],
            ["--image", image["a"], *common],
        ]

    def test_served_payloads_match_one_shot_payloads(self):
        responses = self.assert_same_payloads(self.requests(), self.requests())
        for response in responses:
            payload = json.loads(response["stdout"])
            self.assertGreater(len(payload["cells"]), 0)
            self.assertIn("focus_score", payload["image_stats"])

    def test_worker_loads_the_model_once(self):
        with installed(self.fakes):
            responses, logs = serve(self.requests())
        self.assertEqual([r["exit_code"] for r in responses], [0] * 5)
        # Automatic mode has always ignored --no-gpu, so one predictor serves all.
        self.assertEqual(self.events("load_model"), [("load_model", "vit_b_lm", None)])
        self.assertEqual(len(self.events("encode")), 5)  # every image is encoded
        self.assertEqual(logs.count("reusing initialized predictor"), 4)
        # Detection never fills the prompt caches.
        self.assertEqual(len(sam_detect._PROMPT_IMAGES), 0)

    def test_a_missing_image_fails_the_same_way(self):
        argv = ["--image", str(self.run_dir / "missing.png"), "--model", "vit_b_lm", "--pxPerUm", "1"]
        responses = self.assert_same_payloads([argv], [argv], expect_success=False)
        self.assertEqual(responses[0]["exit_code"], 3)


# ---------------------------------------------------------------------------
# The real `--serve` entry point, in subprocesses.
# ---------------------------------------------------------------------------

class SubprocessServeTests(SamTestCase):
    """`sam_detect.py --serve` answers like `sam_detect.py args...` run once per request."""

    def environment(self):
        env = dict(os.environ)
        paths = [str(self.fakes_root)]
        if SHARED_DIR.is_dir():
            paths.append(str(SHARED_DIR))
        env["PYTHONPATH"] = os.pathsep.join(paths)
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        return env

    def run_script(self, argv, stdin=None):
        return subprocess.run(
            [sys.executable, "-B", str(PYTHON_DIR / "sam_detect.py"), *argv],
            input=stdin, capture_output=True, text=True, timeout=300,
            env=self.environment(), cwd=self._tmp)

    def check(self, served_requests, one_shot_requests, loads_per_worker):
        lines = "".join(json.dumps({"request_id": f"r{i}", "args": argv}) + "\n"
                        for i, argv in enumerate(served_requests))
        served = self.run_script(["--serve"], stdin=lines)
        self.assertEqual(served.returncode, 0, served.stderr[-2000:])
        responses = [json.loads(line) for line in served.stdout.splitlines()]
        self.assertEqual([r["request_id"] for r in responses],
                         [f"r{i}" for i in range(len(served_requests))])
        for argv, response in zip(one_shot_requests, responses):
            once = self.run_script(argv)
            with self.subTest(args=argv):
                self.assertEqual(response["exit_code"], once.returncode, once.stderr[-2000:])
                self.assertEqual(response["exit_code"], 0, response["stdout"])
                self.assertEqual(UUID_PATTERN.sub("<id>", response["stdout"]),
                                 UUID_PATTERN.sub("<id>", once.stdout))
        self.assertEqual(served.stderr.count("[fake-sam] load_model"), loads_per_worker,
                         served.stderr[-2000:])
        return served

    def test_detection(self):
        common = ["--model", "vit_b_lm", "--pxPerUm", "1.0"]
        requests = [["--image", self.images["a"], *common], ["--image", self.images["b"], *common]]
        self.check(requests, requests, loads_per_worker=1)

    def test_prompts(self):
        served_a, once_a = self.caches("a")
        a = self.images["a"]

        def clicks(cache):
            return [point(a, 20, 20, cache), point(a, 50, 22, cache), box(a, 60, 40, 80, 60, cache)]

        served = self.check(clicks(served_a), clicks(once_a), loads_per_worker=1)
        self.assertEqual(served.stderr.count("[fake-sam] encode"), 1)


# ---------------------------------------------------------------------------
# segment_anything's real predictor behind the micro_sam calls (not in CI).
# ---------------------------------------------------------------------------

@unittest.skipUnless(HAS_SEGMENT_ANYTHING, "segment_anything and torch are not installed")
class SegmentAnythingPromptTests(SamTestCase):
    util_source = _SEGMENT_ANYTHING_UTIL

    def test_served_clicks_match_one_shot_clicks(self):
        served_a, once_a = self.caches("a")
        a = self.images["a"]

        def clicks(cache):
            return [point(a, 20, 20, cache), point(a, 50, 22, cache), box(a, 60, 40, 80, 60, cache)]

        self.assert_same_payloads(clicks(served_a), clicks(once_a))
        # One model build for the worker plus one per one-shot run; one
        # encoder run for the worker and one for the first one-shot click.
        self.assertEqual(len(self.events("load_model")), 4)
        self.assertEqual(len(self.events("encode")), 2)
        self.assertEqual(len(self.events("load_embeddings")), 2)


if __name__ == "__main__":
    unittest.main()
