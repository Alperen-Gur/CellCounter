"""Workbench Cellpose inference hands Cellpose 4 a writable copy of the plane.

The plane is loaded as a read-only memory map. Cellpose 4.2 keeps a 2-D
float32 plane as a view and normalizes it in place, which fails on that map
("output array is read-only"); Cellpose 4.1 always copied first. A stand-in
model does what 4.2 does to its input, so no Cellpose or torch is needed.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import _workbench_cellpose_worker as worker  # noqa: E402

HAS_NUMPY = importlib.util.find_spec("numpy") is not None


@unittest.skipUnless(HAS_NUMPY, "numpy not installed")
class CellposeInputTests(unittest.TestCase):

    def infer(self, backend, modifies_input):
        import numpy as np
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        root = Path(folder.name)
        plane = (np.arange(48, dtype=np.float64).reshape(6, 8) / 7).astype(np.float32)
        np.save(root / "raw.npy", plane, allow_pickle=False)
        seen = []

        class Model:
            def eval(self, image, **controls):
                seen.append({"writeable": bool(image.flags.writeable), "dtype": image.dtype,
                             "values": np.array(image, copy=True),
                             "memmap": isinstance(image, np.memmap)})
                if modifies_input:
                    # Cellpose 4.2 normalize99(copy=False): `X -= x01`.
                    image -= image.min()
                return np.zeros(image.shape, dtype=np.int32), None, None

        loaded = ("4.2.1.1", np, None, None, Model(), types.SimpleNamespace(type="cpu"))
        request = {"rawPath": str(root / "raw.npy"), "backend": backend,
                   "checkpointHash": "0" * 64,
                   "parameters": {"rescaleDiameterPx": None, "diameterPx": 30.0,
                                  "flowThreshold": 0.4, "cellprobThreshold": 0.0,
                                  "minSize": 15}}
        with patch.object(worker, "_model", return_value=loaded):
            result = worker._infer(request, root)
        return plane, seen, np.load(root / "raw.npy"), result

    def test_cellpose4_gets_a_writable_copy_with_the_same_values(self):
        import numpy as np
        plane, seen, on_disk, result = self.infer("cellpose4", modifies_input=True)
        self.assertEqual(len(seen), 1)
        self.assertTrue(seen[0]["writeable"])
        self.assertFalse(seen[0]["memmap"])
        self.assertEqual(seen[0]["dtype"], np.float32)
        self.assertEqual(seen[0]["values"].tobytes(), plane.tobytes())
        # The source plane on disk is never written.
        self.assertEqual(on_disk.tobytes(), plane.tobytes())
        self.assertEqual(result["backend"], "cellpose4")

    def test_cellpose3_input_is_passed_unchanged(self):
        # Cellpose 3 converts to a new float32 array itself; no extra copy.
        plane, seen, _, _ = self.infer("cellpose3", modifies_input=False)
        self.assertFalse(seen[0]["writeable"])
        self.assertEqual(seen[0]["values"].tobytes(), plane.tobytes())


if __name__ == "__main__":
    unittest.main()
