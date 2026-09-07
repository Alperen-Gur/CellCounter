import argparse
import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import numpy as np
from PIL import Image
import tifffile

import _cellpose_common as cc
import _imageio
import stardist_detect


class SourcePlaneTests(unittest.TestCase):
    def test_auto_rgb_preserves_luminance_and_explicit_zero_selects_red(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "rgb.png"
            rgb = np.arange(180, dtype=np.uint8).reshape(6, 10, 3)
            Image.fromarray(rgb).save(path)
            args = argparse.Namespace(z_project="max", segment_channel=None)
            np.testing.assert_array_equal(cc.open_image_for_detection(str(path), [0, 0], args),
                                          np.asarray(Image.fromarray(rgb).convert("L")))
            args.segment_channel = 0
            np.testing.assert_array_equal(cc.open_image_for_detection(str(path), [0, 0], args), rgb[..., 0])
            args.segment_channel = 8
            with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit):
                cc.open_image_for_detection(str(path), [0, 0], args)

    def test_each_projection_and_source_channel_uses_original_tiff_planes(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "stack.tiff"
            stack = np.arange(3 * 4 * 6 * 8, dtype=np.uint16).reshape(3, 4, 6, 8)
            tifffile.imwrite(path, stack, photometric="minisblack", metadata={"axes": "ZCYX"})
            operations = dict(max=lambda x: x.max(axis=0), mean=lambda x: x.mean(axis=0),
                              sum=lambda x: x.sum(axis=0), none=lambda x: x[1])
            for projection, operation in operations.items():
                expected = np.moveaxis(operation(stack), 0, -1).astype(np.float32)
                args = argparse.Namespace(z_project=projection, segment_channel=3)
                cc.open_image_for_detection(str(path), [0, 0], args)
                np.testing.assert_array_equal(args._cc_channel_stack, expected)
                image, size = stardist_detect.load_image(str(path), projection, 3)
                np.testing.assert_array_equal(image, expected[..., 3])
                self.assertEqual(size, (8, 6))

    def test_analysis_only_projection_preserves_raw_channels_without_display_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source.tiff"
            output = Path(tmp) / "selected.tiff"
            stack = np.arange(3 * 2 * 6 * 8, dtype=np.uint16).reshape(3, 2, 6, 8)
            tifffile.imwrite(source, stack, photometric="minisblack", metadata={"axes": "ZCYX"})
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("image_prepare.py")),
                "--image", str(source), "--analysis-output", str(output),
                "--analysis-only", "--z-project", "sum"], capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            actual, _ = _imageio.load_planes(str(output))
            np.testing.assert_array_equal(actual, np.moveaxis(stack.sum(axis=0), 0, -1))
            self.assertEqual(sorted(p.name for p in Path(tmp).iterdir()), ["selected.tiff", "source.tiff"])


if __name__ == "__main__":
    unittest.main()
