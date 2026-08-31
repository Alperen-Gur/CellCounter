#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import pathlib
import tempfile
import unittest

import numpy as np
from PIL import Image


HERE = pathlib.Path(__file__).resolve().parent
MODULE_PATH = HERE.parent / "image_prepare.py"
SPEC = importlib.util.spec_from_file_location("image_prepare", MODULE_PATH)
IMAGE_PREPARE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(IMAGE_PREPARE)


class FakeImageIO:
    def __init__(self, stack, meta):
        self.stack = stack
        self.meta = meta
        self.calls = []

    def load_planes(self, path, *, z_project, channel):
        self.calls.append((path, z_project, channel))
        return self.stack, self.meta

    @staticmethod
    def to_uint8(array, meta=None):
        values = np.asarray(array, dtype=np.float32)
        lo = float(values.min()) if values.size else 0.0
        hi = float(values.max()) if values.size else 0.0
        if hi > lo:
            values = (values - lo) / (hi - lo) * 255.0
        else:
            values = np.zeros_like(values)
        return np.clip(values, 0, 255).astype(np.uint8)


class ImagePrepareTests(unittest.TestCase):
    def test_writes_display_thumbnail_dimensions_and_calibration(self):
        stack = np.zeros((40, 60, 3), dtype=np.float32)
        stack[..., 0] = np.linspace(0, 10, 60)[None, :]
        stack[..., 1] = np.linspace(100, 200, 40)[:, None]
        stack[..., 2] = 5
        fake = FakeImageIO(stack, {
            "pixel_size_um": 0.25,
            "source_format": "nd2",
            "all_channel_names": ["DsRed", "EGFP", "405"],
            "z_count": 4,
            "t_count": 2,
            "is_rgb": False,
            "dtype": "uint16",
        })

        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            display = root / "display.png"
            thumb = root / "thumb.jpg"
            payload = IMAGE_PREPARE.prepare_image(
                "sample.nd2", str(display), str(thumb), "mean", fake)

            self.assertEqual(fake.calls, [("sample.nd2", "mean", None)])
            self.assertEqual(payload["width"], 60)
            self.assertEqual(payload["height"], 40)
            self.assertEqual(payload["pixel_size_um"], 0.25)
            self.assertEqual(payload["source_format"], "nd2")
            self.assertEqual(payload["channel_names"], ["DsRed", "EGFP", "405"])
            self.assertEqual(payload["z_count"], 4)
            self.assertTrue(display.is_file())
            self.assertTrue(thumb.is_file())
            self.assertEqual(Image.open(display).size, (60, 40))
            tw, th = Image.open(thumb).size
            self.assertLessEqual(max(tw, th), 256)

    def test_every_advertised_vendor_extension_is_registered(self):
        imageio_path = HERE.parent / "_imageio.py"
        spec = importlib.util.spec_from_file_location("cellcounter_imageio", imageio_path)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        self.assertEqual(
            set(module.VENDOR_PACKAGES),
            {".nd2", ".czi", ".lif", ".oif", ".oib", ".oir"},
        )


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ImagePrepareTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result.wasSuccessful():
        print("vendor image preparation verified")
    raise SystemExit(0 if result.wasSuccessful() else 1)
