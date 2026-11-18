"""`_cellpose_accel` replacements give bit-identical results to stock Cellpose.

Each patched function is run next to the stock Cellpose 4.2.1.1 function on
small deterministic inputs and the outputs are compared byte for byte (dtype,
shape and every bit). The MPS cases run only on a Mac with MPS; everything
that needs Cellpose is skipped where it is not installed (CI), while the
switch and version/source guards, checked with stand-in modules, need only
the standard library and always run.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import _cellpose_accel as accel  # noqa: E402

HAS_NUMPY = importlib.util.find_spec("numpy") is not None


def _cellpose_version():
    if importlib.util.find_spec("cellpose") is None:
        return None
    try:
        import cellpose
        return str(getattr(cellpose, "version", None))
    except Exception:  # noqa: BLE001
        return None


CELLPOSE = _cellpose_version()
NEEDS_CELLPOSE = unittest.skipUnless(
    CELLPOSE == accel.SUPPORTED_CELLPOSE,
    f"Cellpose {accel.SUPPORTED_CELLPOSE} not installed")


def _mps():
    try:
        import torch
        return bool(torch.backends.mps.is_available())
    except Exception:  # noqa: BLE001
        return False


@contextlib.contextmanager
def _quiet():
    with contextlib.redirect_stderr(io.StringIO()):
        yield


class SwitchTests(unittest.TestCase):
    """No Cellpose needed."""

    def tearDown(self):
        accel.restore()

    def test_environment_switch_keeps_stock(self):
        with patch.dict(os.environ, {accel.ENV_STOCK: "1"}), _quiet():
            status = accel.install()
        self.assertIn("off", status)
        self.assertEqual(accel.active_patches(), ())

    def test_install_is_idempotent_and_never_raises(self):
        with patch.dict(os.environ, {accel.ENV_STOCK: ""}), _quiet():
            first = accel.install()
            second = accel.install()
        self.assertEqual(first, second)
        if CELLPOSE != accel.SUPPORTED_CELLPOSE:
            self.assertIn("stock", first)
            self.assertEqual(accel.active_patches(), ())

    @unittest.skipUnless(HAS_NUMPY, "numpy not installed")
    def test_test_inputs_are_deterministic(self):
        import numpy as np
        a, b = accel.test_masks(), accel.test_masks()
        self.assertTrue(np.array_equal(a, b))
        self.assertGreaterEqual(int(a.max()), 6)
        touching = accel.test_touching_masks()
        labels = np.unique(touching)
        # Consecutive labels, as find_objects/get_centers require.
        self.assertEqual(labels.tolist(), list(range(int(touching.max()) + 1)))

    def test_flows_of_accepts_both_return_shapes(self):
        flows = object()
        self.assertIs(accel.flows_of((flows, ["slices"])), flows)   # 4.2
        self.assertIs(accel.flows_of(flows), flows)                 # 4.1


def _stand_in_cellpose(version):
    """Stand-in `cellpose` package whose functions are not the verified ones."""
    package = types.ModuleType("cellpose")
    package.version = version
    dynamics = types.ModuleType("cellpose.dynamics")
    plot = types.ModuleType("cellpose.plot")
    models = types.ModuleType("cellpose.models")

    def _extend_centers_gpu(*a, **k):
        raise AssertionError("must not run")

    def steps_interp(*a, **k):
        raise AssertionError("must not run")

    def masks_to_flows_gpu(*a, **k):
        raise AssertionError("must not run")

    def dx_to_circ(dP):
        raise AssertionError("must not run")

    dynamics._extend_centers_gpu = _extend_centers_gpu
    dynamics.steps_interp = steps_interp
    dynamics.masks_to_flows_gpu = masks_to_flows_gpu
    plot.dx_to_circ = dx_to_circ
    models.plot = plot
    package.dynamics, package.plot, package.models = dynamics, plot, models
    return {"cellpose": package, "cellpose.dynamics": dynamics,
            "cellpose.plot": plot, "cellpose.models": models}


class VersionGuardTests(unittest.TestCase):
    """Stand-in modules only; no numpy, torch or Cellpose needed."""

    def tearDown(self):
        accel.restore()

    def _install_with(self, modules):
        with patch.dict(sys.modules, modules), \
             patch.dict(os.environ, {accel.ENV_STOCK: ""}), _quiet():
            status = accel.install()
            return status, modules["cellpose.dynamics"], modules["cellpose.models"]

    def test_only_cellpose_4_2_1_1_is_targeted(self):
        self.assertEqual(accel.SUPPORTED_CELLPOSE, "4.2.1.1")
        self.assertEqual(set(accel._SOURCE_SHA256),
                         {"_extend_centers_gpu", "steps_interp", "dx_to_circ",
                          "masks_to_flows_gpu"})

    def test_cellpose_4_1_1_runs_stock(self):
        modules = _stand_in_cellpose("4.1.1")
        stock = modules["cellpose.dynamics"]._extend_centers_gpu
        status, dynamics, models = self._install_with(modules)
        self.assertIn("stock", status)
        self.assertIn("4.1.1 is not a verified version", status)
        self.assertEqual(accel.active_patches(), ())
        self.assertIs(dynamics._extend_centers_gpu, stock)
        self.assertIs(models.plot, modules["cellpose.plot"])

    def test_changed_source_runs_stock(self):
        modules = _stand_in_cellpose(accel.SUPPORTED_CELLPOSE)
        status, dynamics, _ = self._install_with(modules)
        self.assertIn("source differs", status)
        for name in ("_extend_centers_gpu", "steps_interp", "dx_to_circ", "masks_to_flows_gpu"):
            self.assertIn(name, status)
        self.assertEqual(accel.active_patches(), ())


def _diffusion_inputs(masks, device):
    """Exactly what Cellpose 4.2.1.1's masks_to_flows_gpu passes on."""
    import numpy as np
    import torch
    import torch.nn.functional as F
    from scipy.ndimage import find_objects
    from cellpose import dynamics as dyn
    masks_padded = F.pad(torch.from_numpy(masks.astype("int64")).to(device), (1, 1, 1, 1))
    y, x = torch.nonzero(masks_padded, as_tuple=True)
    y, x = y.int(), x.int()
    neighbors = torch.zeros((2, 9, y.shape[0]), dtype=torch.int, device=device)
    yxi = [[0, -1, 1, 0, 0, -1, -1, 1, 1], [0, 0, 0, -1, 1, -1, 1, -1, 1]]
    for i in range(9):
        neighbors[0, i] = y + yxi[0][i]
        neighbors[1, i] = x + yxi[1][i]
    isneighbor = torch.ones((9, y.shape[0]), dtype=torch.bool, device=device)
    m0 = masks_padded[neighbors[0, 0], neighbors[1, 0]]
    for i in range(1, 9):
        isneighbor[i] = masks_padded[neighbors[0, i], neighbors[1, i]] == m0
    centers, ext = dyn.get_centers(masks, find_objects(masks))
    meds = torch.from_numpy(np.asarray(centers)).to(device).long() + 1
    return neighbors, meds, isneighbor, masks_padded.shape, int(2 * ext.max())


def _bytes_equal(test, a, b):
    import numpy as np
    import torch
    if torch.is_tensor(a):
        test.assertTrue(torch.is_tensor(b))
        test.assertEqual(a.dtype, b.dtype)
        a, b = a.cpu().numpy(), b.cpu().numpy()
    a, b = np.asarray(a), np.asarray(b)
    test.assertEqual(a.dtype, b.dtype)
    test.assertEqual(a.shape, b.shape)
    test.assertEqual(a.tobytes(), b.tobytes())


@NEEDS_CELLPOSE
class Cellpose4Tests(unittest.TestCase):

    def setUp(self):
        import torch
        from cellpose import dynamics as dyn, plot
        self.torch = torch
        self.dyn = dyn
        self.stock_extend = dyn._extend_centers_gpu
        self.stock_steps = dyn.steps_interp
        self.stock_circ = plot.dx_to_circ

    def tearDown(self):
        accel.restore()

    def test_stock_sources_are_the_verified_ones(self):
        self.assertEqual(accel.source_sha256(self.stock_extend),
                         accel._SOURCE_SHA256["_extend_centers_gpu"])
        self.assertEqual(accel.source_sha256(self.stock_steps),
                         accel._SOURCE_SHA256["steps_interp"])
        self.assertEqual(accel.source_sha256(self.stock_circ),
                         accel._SOURCE_SHA256["dx_to_circ"])
        self.assertEqual(accel.source_sha256(self.dyn.masks_to_flows_gpu),
                         accel._SOURCE_SHA256["masks_to_flows_gpu"])

    def test_self_test_passes(self):
        fast_extend = accel.make_extend_centers(self.stock_extend)
        fast_steps = accel.make_steps_interp(self.stock_steps)
        self.assertIsNone(accel._self_test(self.dyn, fast_extend, fast_steps))
        self.assertIs(self.dyn._extend_centers_gpu, self.stock_extend)

    def _check_extend(self, device, masks):
        fast = accel.make_extend_centers(self.stock_extend)
        nb, meds, isn, shape, n_iter = _diffusion_inputs(masks, device)
        a = self.stock_extend(nb, meds, isn, shape, n_iter=n_iter, device=device)
        b = fast(nb, meds, isn, shape, n_iter=n_iter, device=device)
        _bytes_equal(self, a, b)

    def test_extend_centers_cpu_float64(self):
        self._check_extend(self.torch.device("cpu"), accel.test_masks())

    def test_extend_centers_cpu_touching_masks(self):
        import numpy as np
        m = accel.test_masks()
        m2 = m.copy()
        m2[:, 26:] = np.where(m[:, 26:] > 0, m[:, 26:], 0)
        m2[20:24, 5:47] = int(m.max()) + 1      # a bar touching several masks
        self._check_extend(self.torch.device("cpu"), m2)
        self._check_extend(self.torch.device("cpu"), accel.test_touching_masks())

    def test_extend_centers_falls_back_when_a_centre_is_outside(self):
        torch = self.torch
        cpu = torch.device("cpu")
        fast = accel.make_extend_centers(self.stock_extend)
        nb, meds, isn, shape, n_iter = _diffusion_inputs(accel.test_masks(), cpu)
        meds = meds.clone()
        meds[0] = torch.tensor([1, 1])           # a background pixel
        a = self.stock_extend(nb, meds, isn, shape, n_iter=40, device=cpu)
        b = fast(nb, meds, isn, shape, n_iter=40, device=cpu)
        _bytes_equal(self, a, b)

    def test_masks_to_flows_end_to_end_cpu(self):
        cpu = self.torch.device("cpu")
        for masks in (accel.test_masks(), accel.test_touching_masks()):
            a = self.dyn.masks_to_flows_gpu(masks, device=cpu)
            with patch.object(self.dyn, "_extend_centers_gpu",
                              accel.make_extend_centers(self.stock_extend)):
                b = self.dyn.masks_to_flows_gpu(masks, device=cpu)
            # Cellpose 4.2 returns (flows, slices).
            self.assertIsInstance(a, tuple)
            _bytes_equal(self, accel.flows_of(a), accel.flows_of(b))
            self.assertEqual(a[1], b[1])

    def test_flow_error_end_to_end_cpu(self):
        """The QC step that uses the diffusion: same errors and flows."""
        import numpy as np
        cpu = self.torch.device("cpu")
        masks = accel.test_touching_masks()
        dP, _ = accel.test_flows(masks)
        net_flows = (dP * 5.).astype(np.float32)
        a = self.dyn.flow_error(masks, net_flows, cpu)
        with patch.object(self.dyn, "_extend_centers_gpu",
                          accel.make_extend_centers(self.stock_extend)):
            b = self.dyn.flow_error(masks, net_flows, cpu)
        _bytes_equal(self, a[0], b[0])
        _bytes_equal(self, a[1], b[1])

    def _check_steps(self, device, niter):
        masks = accel.test_masks()
        dPm, inds = accel.test_flows(masks)
        a = self.stock_steps(dPm, inds, niter, device=device)
        b = accel.make_steps_interp(self.stock_steps)(dPm, inds, niter, device=device)
        _bytes_equal(self, a, b)

    def test_steps_interp_cpu(self):
        for niter in (1, 7, 120):
            self._check_steps(self.torch.device("cpu"), niter)

    @unittest.skipUnless(_mps(), "MPS not available")
    def test_extend_centers_mps_float32(self):
        self._check_extend(self.torch.device("mps"), accel.test_masks())

    @unittest.skipUnless(_mps(), "MPS not available")
    def test_steps_interp_mps(self):
        for niter in (1, 120):
            self._check_steps(self.torch.device("mps"), niter)

    def test_install_patches_and_restore(self):
        from cellpose import models, plot
        import numpy as np
        with patch.dict(os.environ, {accel.ENV_STOCK: ""}), _quiet():
            status = accel.install()
        self.assertIn("active", status)
        self.assertIsNot(self.dyn._extend_centers_gpu, self.stock_extend)
        self.assertIsNot(self.dyn.steps_interp, self.stock_steps)
        dP = np.ones((2, 5, 7), np.float32)
        circ = models.plot.dx_to_circ(dP)
        self.assertEqual((circ.shape, circ.dtype), ((5, 7, 3), np.dtype("uint8")))
        self.assertFalse(circ.any())
        self.assertIs(plot.dx_to_circ, self.stock_circ)   # cellpose.plot untouched
        accel.restore()
        self.assertIs(self.dyn._extend_centers_gpu, self.stock_extend)
        self.assertIs(self.dyn.steps_interp, self.stock_steps)
        self.assertIs(models.plot, plot)

    def test_three_d_goes_to_stock(self):
        calls = []

        def stock(*a, **k):
            calls.append(1)
            return "stock"
        import numpy as np
        steps = accel.make_steps_interp(stock)
        dP = np.zeros((3, 2, 2, 2), np.float32)
        self.assertEqual(steps(dP, np.nonzero(np.ones((2, 2, 2))), 3), "stock")
        self.assertEqual(calls, [1])


if __name__ == "__main__":
    unittest.main()
