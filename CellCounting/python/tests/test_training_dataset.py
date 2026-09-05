import hashlib
import importlib.util
import json
import logging
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
import numpy as np

PYTHON_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PYTHON_DIR))
from _training_dataset import validate_manifest, load_dataset, evaluate_masks, file_hash
import cellpose_train


class TrainingDatasetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        self.entries = []
        for index, partition in enumerate(("train", "validation", "test")):
            source = self.directory / f"source{index}.tif"
            source.write_bytes(f"source-{index}".encode())
            labels = self.directory / f"label{index}.u32"
            np.array([[1, 1], [0, 0]], dtype="<u4").tofile(labels)
            self.entries.append(dict(id=str(index), name=source.name, imagePath=str(source),
                                     labelsPath=str(labels), sourceHash=file_hash(source), labelsHash=file_hash(labels),
                                     width=2, height=2, group=f"specimen{index}", partition=partition,
                                     zProjection="mean", segmentChannel=1))
        self.path = self.directory / "dataset.json"
        self.save()

    def save(self):
        self.path.write_text(json.dumps(dict(version=1, split=dict(seed=42, trainPercent=70, validationPercent=20), samples=self.entries)))

    def test_manifest_preserves_all_three_disjoint_splits(self):
        manifest = validate_manifest(self.path)
        self.assertEqual([e["partition"] for e in manifest["samples"]], ["train", "validation", "test"])

    def test_specimen_group_leakage_is_rejected(self):
        self.entries[2]["group"] = self.entries[0]["group"]
        self.save()
        with self.assertRaisesRegex(ValueError, "leaks"):
            validate_manifest(self.path)

    def test_duplicate_source_bytes_are_rejected_even_with_distinct_names(self):
        Path(self.entries[2]["imagePath"]).write_bytes(Path(self.entries[0]["imagePath"]).read_bytes())
        self.entries[2]["sourceHash"] = self.entries[0]["sourceHash"]
        self.save()
        with self.assertRaisesRegex(ValueError, "Duplicate image content"):
            validate_manifest(self.path)

    def test_missing_test_split_is_not_replaced_by_validation(self):
        self.entries[2]["partition"] = "validation"
        self.save()
        with self.assertRaisesRegex(ValueError, "held-out test"):
            validate_manifest(self.path)

    def test_changed_source_or_labels_are_rejected(self):
        Path(self.entries[0]["imagePath"]).write_bytes(b"modified")
        with self.assertRaisesRegex(ValueError, "Source image changed"):
            validate_manifest(self.path)
        self.entries[0]["sourceHash"] = file_hash(self.entries[0]["imagePath"])
        self.save()
        Path(self.entries[0]["labelsPath"]).write_bytes(b"modified")
        with self.assertRaisesRegex(ValueError, "labels changed"):
            validate_manifest(self.path)

    def test_corrupt_labels_are_not_silently_dropped(self):
        labels = Path(self.entries[0]["labelsPath"])
        labels.write_bytes(b"bad")
        self.entries[0]["labelsHash"] = file_hash(labels)
        self.save()
        with self.assertRaisesRegex(ValueError, "byte count"):
            validate_manifest(self.path)

    def test_actual_corrected_labels_source_channel_and_projection_reach_training(self):
        calls = []
        def loader(path, **kwargs):
            calls.append(kwargs)
            return np.stack((np.ones((2, 2)), np.full((2, 2), 1742)), axis=-1), {}
        splits = load_dataset(validate_manifest(self.path), loader)
        np.testing.assert_array_equal(splits["train"][0][0], np.full((2, 2), 1742))
        np.testing.assert_array_equal(splits["train"][0][1], [[1, 1], [0, 0]])
        self.assertTrue(all(call == dict(z_project="mean", channel=None) for call in calls))

    def test_shape_and_missing_channels_fail_instead_of_clamping(self):
        with self.assertRaisesRegex(ValueError, "differ"):
            load_dataset(validate_manifest(self.path), lambda *_args, **_kwargs: (np.zeros((5, 5, 2)), {}))
        with self.assertRaisesRegex(ValueError, "channel is missing"):
            load_dataset(validate_manifest(self.path), lambda *_args, **_kwargs: (np.zeros((2, 2, 1)), {}))

    def test_metrics_known_matches_and_false_positives(self):
        truth = np.array([[1, 1, 0, 2, 2], [0, 0, 0, 0, 0]])
        pred = np.array([[5, 5, 0, 0, 0], [0, 0, 0, 7, 7]])
        metrics = evaluate_masks([pred], [truth])
        self.assertEqual(metrics["truePositives"], 1)
        self.assertEqual(metrics["falsePositives"], 1)
        self.assertEqual(metrics["falseNegatives"], 1)
        self.assertAlmostEqual(metrics["ap50"], 1 / 3)
        self.assertEqual(metrics["f1"], 0.5)
        self.assertEqual(metrics["meanDiamError"], 0)

    def test_failed_prediction_cannot_create_partial_or_zero_fallback_report(self):
        truth = np.array([[1, 1], [0, 0]])
        with self.assertRaisesRegex(ValueError, "Every held-out"):
            evaluate_masks([], [truth])
        with self.assertRaisesRegex(ValueError, "shape differs"):
            evaluate_masks([np.zeros((1, 1))], [truth])
        metrics = evaluate_masks([np.zeros((2, 2), dtype=int)], [truth])
        self.assertEqual(metrics["ap50"], 0)
        self.assertGreater(metrics["meanDiamError"], 0)

    def test_empty_dataset_cli_fails_without_creating_checkpoint(self):
        self.entries = []; self.save()
        output = self.directory / "model.ccmodel"
        result = subprocess.run([sys.executable, str(PYTHON_DIR / "cellpose_train.py"),
                                 "--manifest", str(self.path), "--output", str(output),
                                 "--epochs", "2", "--lr", "0.001", "--batch-size", "1",
                                 "--base-model", "cp-cyto3"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("DONE", result.stdout)
        self.assertFalse(output.exists())

    def test_real_training_contract_uses_one_optimizer_run_and_heldout_only_at_end(self):
        output = self.directory / "model.ccmodel"
        checkpoint = self.directory / "pretrained"
        checkpoint.write_bytes(b"w" * 2048)
        calls = []
        predictions = []
        class Model:
            def __init__(self, **kwargs):
                self.net = self
                self.loaded = kwargs["pretrained_model"]
            def save_model(self, filename):
                Path(filename).write_bytes(b"checkpoint" * 1024)
            def eval(self, image, **kwargs):
                predictions.append(float(image[0, 0]))
                return np.array([[1, 1], [0, 0]]), None, None
        def train_seg(net, **kwargs):
            calls.append(kwargs)
            logging.getLogger("cellpose.train").info("0, train_loss=1.23, test_loss=0.75, LR=0.001, time 1.0s")
            final = self.directory / "trained"
            net.save_model(final)
            return final, np.array([1.23]), np.array([0.75])
        torch = types.SimpleNamespace(manual_seed=lambda _: None,
                                      device=lambda name: types.SimpleNamespace(type=name),
                                      backends=types.SimpleNamespace(mps=types.SimpleNamespace(is_available=lambda: False)),
                                      cuda=types.SimpleNamespace(is_available=lambda: False))
        cp = types.ModuleType("cellpose")
        cp.models = types.SimpleNamespace(CellposeModel=Model)
        cp.train = types.SimpleNamespace(train_seg=train_seg)
        reader = types.ModuleType("_imageio")
        reader.load_planes = lambda path, **kwargs: (np.full((2, 2, 2), int(Path(path).stem[-1]) + 1), {})
        args = types.SimpleNamespace(manifest=str(self.path), epochs=6, lr=0.001, batch_size=1,
                                     augment=0, base_model="cp-cyto3", resume=str(checkpoint),
                                     output=str(output), early_stop=1)
        with patch.dict(sys.modules, {"torch": torch, "cellpose": cp, "_imageio": reader}), \
                patch("importlib.metadata.version", return_value="3.1.1.1"):
            cellpose_train.run(args)
        self.assertEqual(len(calls), 1)
        self.assertEqual(float(calls[0]["train_data"][0][0, 0]), 1)
        self.assertEqual(float(calls[0]["test_data"][0][0, 0]), 2)  # validation only
        self.assertEqual(predictions, [3])  # held-out only
        report = json.loads(output.with_suffix(".json").read_text())
        self.assertEqual(report["metrics"]["ap50"], 1)
        self.assertEqual(report["history"][0]["trainLoss"], 1.23)
        self.assertEqual(report["checkpointHash"], file_hash(output))
        self.assertTrue(report["checkpointValidated"])


if __name__ == "__main__":
    unittest.main()
