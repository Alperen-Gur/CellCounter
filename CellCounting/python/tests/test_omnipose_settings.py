"""Regression source for settings/model identity; no weights or inference."""
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import omnipose_detect as omni


class OmniposeSettingsTests(unittest.TestCase):
    def args(self, *options):
        return omni.parse_args(["--image", "unused.tif", "--model", "omni-cyto2", "--pxPerUm", "1", *options])

    def test_requested_controls_are_distinct_from_confidence_and_size_bins(self):
        args = self.args("--mask-threshold", "-1", "--flow-threshold", "0.4",
                         "--cluster", "--conf", "0.9", "--small-threshold", "10",
                         "--large-threshold", "100")
        kwargs = omni.build_eval_kwargs(args, [1, 2])
        self.assertEqual(kwargs["mask_threshold"], -1)
        self.assertEqual(kwargs["flow_threshold"], 0.4)
        self.assertTrue(kwargs["cluster"])
        self.assertTrue(kwargs["omni"])
        self.assertEqual(kwargs["channels"], [1, 2])
        self.assertEqual(kwargs["diameter"], 0)

    def test_explicit_diameter_is_calibrated_without_silent_clamping(self):
        kwargs = omni.build_eval_kwargs(self.args("--diameter", "1", "--pxPerUm", "2"), [0, 0])
        self.assertEqual(kwargs["diameter"], 2)

    def test_invalid_thresholds_are_rejected_before_model_loading(self):
        for options in [("--mask-threshold", "nan"), ("--flow-threshold", "-1"),
                        ("--flow-threshold", "inf"), ("--diameter", "nan"),
                        ("--pxPerUm", "0")]:
            with self.subTest(options=options), self.assertRaises(ValueError):
                omni.build_eval_kwargs(self.args(*options), [0, 0])

    def test_model_identity_never_falls_back_to_bacteria_or_a_3d_checkpoint(self):
        self.assertEqual(omni.resolve_model_name("omni-cyto2"), "cyto2_omni")
        for unknown in ["typo", "omni-plant", "plant_omni"]:
            with self.subTest(model=unknown), self.assertRaises(ValueError):
                omni.resolve_model_name(unknown)

    def test_reuses_only_the_requested_cached_omnipose_checkpoint(self):
        with tempfile.TemporaryDirectory() as home:
            previous = os.path.join(home, ".cellpose", "models")
            os.makedirs(previous)
            with open(os.path.join(previous, "cyto2_omnitorch_0"), "wb") as handle:
                handle.write(b"cached-omnipose-checkpoint")
            with open(os.path.join(previous, "cyto2torch_0"), "wb") as handle:
                handle.write(b"different-model")
            with mock.patch.object(omni.os.path, "expanduser", return_value=home), mock.patch.dict(os.environ):
                omni.configure_model_cache("cyto2_omni")
                cache = os.environ["CELLPOSE_LOCAL_MODELS_PATH"]
                with open(os.path.join(cache, "cyto2_omnitorch_0"), "rb") as handle:
                    self.assertEqual(handle.read(), b"cached-omnipose-checkpoint")
                self.assertFalse(os.path.exists(os.path.join(cache, "cyto2torch_0")))
                self.assertTrue(os.path.exists(os.path.join(previous, "cyto2_omnitorch_0")))


if __name__ == "__main__":
    unittest.main()
