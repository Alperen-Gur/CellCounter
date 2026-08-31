"""Allocation-free safety tests for the shared microscopy reader."""

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import _imageio


class ImageBudgetTests(unittest.TestCase):
    def test_typical_multichannel_stack_is_allowed(self):
        _imageio._enforce_shape_budget((8, 3, 2048, 2048), "ZCYX", 2)

    def test_huge_vendor_stack_is_rejected_without_allocating_it(self):
        with self.assertRaises(_imageio.ImageTooLargeError) as raised:
            _imageio._enforce_shape_budget((100, 8, 20000, 20000), "ZCYX", 2)
        self.assertEqual(raised.exception.code, "image-too-large")
        self.assertIn("OME-TIFF", raised.exception.hint)

    def test_projected_float_budget_covers_tiff_and_vendor_readers(self):
        with self.assertRaises(_imageio.ImageTooLargeError):
            _imageio._enforce_shape_budget((16, 12000, 12000), "CYX", 1)


if __name__ == "__main__":
    unittest.main()
