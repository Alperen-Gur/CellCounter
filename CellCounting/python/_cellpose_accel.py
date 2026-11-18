"""
_cellpose_accel.py — bit-identical replacements for two loops in Cellpose
4.2.1.1's mask post-processing, and a skip of an unused flow picture.

Nothing here changes a result. Each replacement does the same floating-point
operations on the same values, in the same tensor layout, as the function it
replaces, so masks, flows and CellCounter payloads stay bit-for-bit the same
as with stock Cellpose 4.2.1.1. Only how the work is issued changes. The
speed gain has not been measured on 4.2.1.1.

Usage (Cellpose 4 sidecar, right after ``from cellpose import models``):

    import _cellpose_accel; _cellpose_accel.install()

``install`` is idempotent. It patches only when the installed Cellpose is
exactly 4.2.1.1 (the version whose source was checked), each replaced
function's source text (and that of ``masks_to_flows_gpu``, which builds the
diffusion inputs) has the expected hash, and a small CPU self-test gives
bitwise equal results to the stock functions. Otherwise Cellpose stays
completely stock; every other version, 4.1.1 included, runs stock.
``CELLCOUNTER_STOCK_CELLPOSE=1`` turns everything off.

Replaced (2D only; 3D always runs stock):

* ``dynamics._extend_centers_gpu`` — the flow-QC diffusion. Stock 4.2.1.1
  diffuses over the whole padded image ``T_flat`` with flat indices:
  ``T_flat[flat_center] = (T_flat[flat_neighbors] * isneighbor).sum(0) / 9``.
  The replacement keeps one slot per mask pixel (in ``flat_center`` order)
  plus one slot that always holds +0.0. A neighbour that is not a valid
  neighbour (``isneighbor`` False) reads that slot, which is exactly what
  stock's multiply by False produces, because every value of T is finite and
  >= 0. The gathered (9, N) tensor therefore holds the same bits as stock's
  ``Tneigh * isneighbor``, and it goes through the same ``.sum(dim=0)`` and
  the same ``/ 9`` (the same dtype rule: float32 on MPS or above 4e7 pixels,
  else float64), so the same rounding. The final gradients read the same
  4-neighbours without the mask, as stock does (a pixel of another mask has
  its own slot; background reads +0.0, as stock's untouched zeros). Per step
  this drops the (9, N) bool multiply and the scatter into the padded image.
* ``dynamics.steps_interp`` — the Euler integration. Stock's per-component
  ``pt[..., k] += dPt[:, k]; torch.clamp_(pt[..., k], -1., 1.)`` becomes one
  in-place ``add_(...).clamp_(...)`` over both components; each element gets
  the same float32 add and the same clamp, and both components still use the
  dPt sampled before either update. The set-up and the return are verbatim.
* ``models.plot.dx_to_circ`` — the HSV flow picture returned in ``flows[0]``
  is never read by CellCounter (it reads ``flows[2]``). ``CellposeModel.eval``
  now gets an all-zero uint8 array of the same shape instead (allocated
  lazily, so it costs nothing). ``cellpose.plot`` itself is untouched; stock
  ``dx_to_circ`` reads ``dP`` without modifying it, so skipping it changes
  nothing else.
"""

from __future__ import annotations

import hashlib
import inspect
import os
import sys

ENV_STOCK = "CELLCOUNTER_STOCK_CELLPOSE"

SUPPORTED_CELLPOSE = "4.2.1.1"

# sha256 of inspect.getsource() of the stock functions in Cellpose 4.2.1.1.
# `masks_to_flows_gpu` is not replaced; it builds the inputs the diffusion
# replacement relies on ((2, 9, N) int32 neighbours, (9, N) bool mask,
# centres inside their masks), so a change there also keeps Cellpose stock.
_SOURCE_SHA256 = {
    "_extend_centers_gpu": "8510b83166f900c669958de5e7b1b2ead73a0980e25ea90a475db6b21942ede6",
    "steps_interp": "3eed83688a55a28aa924c908c4d5a6bc5ca21ea72fca79cc9eca001f91001919",
    "dx_to_circ": "fbae7828018940bfb4185696538651b660df5b530977a4a250af79ee94884752",
    "masks_to_flows_gpu": "920f8ea9b5dea498bb3d7bd4041f7d137006690406920f44f5efc381d39d6fa7",
}

_STATUS = None      # the line logged by the first install()
_ACTIVE = ()        # names of the active patches
_APPLIED = []       # (owner, attribute, stock value), for restore()


def _log(msg: str) -> None:
    print(f"[cellpose_detect] {msg}", file=sys.stderr, flush=True)


def _stock_requested() -> bool:
    return os.environ.get(ENV_STOCK, "").strip() not in ("", "0")


def source_sha256(fn) -> str:
    try:
        src = inspect.getsource(inspect.unwrap(fn))
    except (OSError, TypeError):
        return "unavailable"
    return hashlib.sha256(src.encode("utf-8")).hexdigest()


def status() -> str:
    return _STATUS or "not installed"


def active_patches() -> tuple:
    return _ACTIVE


# ---------------------------------------------------------------------------
# Replacements. Each takes the stock function so it can hand 3D (or any case
# it does not cover) back to it unchanged.
# ---------------------------------------------------------------------------

def make_extend_centers(stock):
    import numpy as np
    import torch

    def _extend_centers_gpu(neighbors, meds, isneighbor, shape, n_iter=200,
                            device=torch.device("cpu")):
        if (len(shape) != 2 or neighbors.ndim != 3 or neighbors.shape[0] != 2
                or tuple(isneighbor.shape) != tuple(neighbors.shape[1:])):
            return stock(neighbors, meds, isneighbor, shape, n_iter=n_iter, device=device)
        # Same dtype rule as stock 4.2.1.1.
        dtype = (torch.float32 if torch.prod(torch.tensor(shape)) > 4e7 or device.type == "mps"
                 else torch.float64)
        Ly, Lx = shape
        # Same flat indices as stock: (9, N) neighbours, row 0 is the pixel.
        flat_neighbors = (neighbors[0] * Lx + neighbors[1]).long()
        flat_meds = (meds[:, 0] * Lx + meds[:, 1]).long()
        nneigh = flat_neighbors.shape[0]
        npix = int(flat_neighbors.shape[1])
        # Slot j holds T at flat_center[j]; every other pixel maps to slot
        # npix. Stock writes T only at mask pixels and centres, so when every
        # centre is a mask pixel (checked) all other pixels of T stay +0.0.
        cmap = torch.full((int(Ly) * int(Lx),), npix, dtype=torch.int64, device=device)
        cmap[flat_neighbors[0]] = torch.arange(npix, dtype=torch.int64, device=device)
        medc = cmap[flat_meds]
        if npix == 0 or bool((medc == npix).any()):
            return stock(neighbors, meds, isneighbor, shape, n_iter=n_iter, device=device)
        # stock: T[neighbour] * False -> +0.0 (T is finite and >= 0).
        nb = cmap[flat_neighbors].masked_fill_(~isneighbor, npix)
        # Stock reads T at the 4-neighbours without the isneighbor mask.
        grad_slots = cmap[flat_neighbors[[2, 1, 4, 3]]]
        del cmap, flat_neighbors, flat_meds
        V = torch.zeros(npix + 1, dtype=dtype, device=device)
        Vn = V[:npix]
        for i in range(n_iter):
            V[medc] += 1
            # Same (9, N) values and layout as stock's (Tneigh * isneighbor),
            # same .sum(dim=0) and the same division.
            Vn.copy_(V[nb].sum(dim=0) / nneigh)
        del nb, medc
        grads = V[grad_slots]
        dy = grads[0] - grads[1]
        dx = grads[2] - grads[3]
        del grads
        return np.stack((dy.cpu().numpy(), dx.cpu().numpy()), axis=0)

    _extend_centers_gpu.__cellcounter_stock__ = stock
    return _extend_centers_gpu


def make_steps_interp(stock):
    import numpy as np
    import torch

    def steps_interp(dP, inds, niter, device=torch.device("cpu")):
        shape = dP.shape[1:]
        ndim = len(shape)
        if ndim != 2:
            return stock(dP, inds, niter, device=device)
        # Set-up verbatim from Cellpose 4.2.1.1 (2D branch).
        pt = torch.zeros((*[1]*ndim, len(inds[0]), ndim), dtype=torch.float32, device=device)
        im = torch.zeros((1, ndim, *shape), dtype=torch.float32, device=device)
        for n in range(ndim):
            pt[0, 0, :, ndim - n - 1] = torch.from_numpy(inds[n]).to(device, dtype=torch.float32)
            im[0, ndim - n - 1] = torch.from_numpy(dP[n]).to(device, dtype=torch.float32)
        shape = np.array(shape)[::-1].astype("float") - 1
        for k in range(ndim):
            im[:, k] *= 2. / shape[k]
            pt[..., k] /= shape[k]
        pt *= 2
        pt -= 1
        grid_sample = torch.nn.functional.grid_sample
        for t in range(niter):
            dPt = grid_sample(im, pt, align_corners=False)
            # Stock: for each k, pt[..., k] += dPt[:, k]; clamp_(pt[..., k]).
            pt.add_(dPt.permute(0, 2, 3, 1)).clamp_(-1., 1.)
        # Return verbatim from Cellpose 4.2.1.1 (2D branch).
        pt += 1
        pt *= 0.5
        for k in range(ndim):
            pt[..., k] *= shape[k]
        pt = pt[..., [1, 0]].squeeze()
        pt = pt.unsqueeze(0) if pt.ndim == 1 else pt
        return pt.T

    steps_interp.__cellcounter_stock__ = stock
    return steps_interp


def make_plot_proxy(plot_module):
    """A copy of ``cellpose.plot``'s namespace whose ``dx_to_circ`` returns
    an all-zero picture; installed as ``cellpose.models.plot`` only."""
    import types
    import numpy as np

    def dx_to_circ(dP):
        return np.zeros((*dP.shape[1:], 3), "uint8")

    proxy = types.ModuleType(plot_module.__name__)
    proxy.__dict__.update(plot_module.__dict__)
    proxy.dx_to_circ = dx_to_circ
    proxy.__cellcounter_stock__ = plot_module
    return proxy


# ---------------------------------------------------------------------------
# Self-test: tiny deterministic CPU case, patched vs stock, bitwise.
# ---------------------------------------------------------------------------

def test_masks(H=44, W=52):
    """Small label image: discs, a ring and a C shape (centroid outside the
    mask), an ellipse, a tiny object and one touching the border."""
    import numpy as np
    m = np.zeros((H, W), np.int32)
    yy, xx = np.mgrid[:H, :W]
    lab = 0
    for cy, cx, r, kind in [(12, 13, 9, 0), (30, 36, 11, 1), (14, 40, 8, 2),
                            (33, 12, 7, 3), (22, 25, 3, 0), (40, 47, 4, 3)]:
        d2 = (yy - cy) ** 2 + (xx - cx) ** 2
        if kind == 0:
            sel = d2 <= r * r
        elif kind == 1:
            sel = (d2 <= r * r) & (d2 >= (r // 2) ** 2)
        elif kind == 2:
            sel = (d2 <= r * r) & (d2 >= (r // 2) ** 2) & ~((xx > cx) & (abs(yy - cy) < r // 3))
        else:
            sel = ((yy - cy) / max(1, r // 2)) ** 2 + ((xx - cx) / r) ** 2 <= 1
        sel &= m == 0
        if sel.sum() >= 3:
            lab += 1
            m[sel] = lab
    m[0:3, 0:4] = lab + 1
    return m


def test_touching_masks():
    """`test_masks` with a bar across several masks, so masks touch masks
    of other labels; labels renumbered 1..n."""
    import numpy as np
    m = test_masks()
    m[20:24, 5:47] = int(m.max()) + 1
    _, dense = np.unique(m, return_inverse=True)
    return dense.reshape(m.shape).astype(np.int32)


def test_flows(masks):
    import numpy as np
    rng = np.random.default_rng(7)
    H, W = masks.shape
    gy, gx = np.mgrid[:H, :W].astype(np.float32)
    dP = np.stack([np.sin(gy / 5.0) * 3 + rng.standard_normal((H, W)) * 0.3,
                   np.cos(gx / 7.0) * 3 + rng.standard_normal((H, W)) * 0.3]).astype(np.float32)
    cp = masks > 0
    return dP * cp / 5., np.nonzero(cp)


def flows_of(result):
    """The flow array of `masks_to_flows_gpu` (4.2 returns ``(mu0, slices)``)."""
    return result[0] if isinstance(result, tuple) else result


def _self_test(dyn, extend_centers, steps_interp):
    import numpy as np
    import torch
    cpu = torch.device("cpu")
    masks = test_masks()
    # Flow-QC end to end (masks_to_flows_gpu builds the diffusion inputs),
    # with separate and with touching masks. Cellpose 4.2 returns
    # (flows, slices); only the flows are compared.
    for case in (masks, test_touching_masks()):
        stock = flows_of(dyn.masks_to_flows_gpu(case, device=cpu))
        saved = dyn._extend_centers_gpu
        dyn._extend_centers_gpu = extend_centers
        try:
            fast = flows_of(dyn.masks_to_flows_gpu(case, device=cpu))
        finally:
            dyn._extend_centers_gpu = saved
        if (not isinstance(stock, np.ndarray) or not isinstance(fast, np.ndarray)
                or stock.dtype != fast.dtype or stock.shape != fast.shape
                or stock.tobytes() != fast.tobytes()):
            return "extend_centers"
    dPm, inds = test_flows(masks)
    a = dyn.steps_interp(dPm, inds, 60, device=cpu)
    b = steps_interp(dPm, inds, 60, device=cpu)
    if a.dtype != b.dtype or a.shape != b.shape or not torch.equal(a, b):
        return "steps_interp"
    return None


# ---------------------------------------------------------------------------
# Install / restore
# ---------------------------------------------------------------------------

def install() -> str:
    """Patch Cellpose once per process; returns (and logs once) the status."""
    global _STATUS
    if _STATUS is not None:
        return _STATUS
    if _stock_requested():
        _STATUS = f"cellpose accel: off ({ENV_STOCK} set), stock Cellpose"
    else:
        try:
            _STATUS = _install()
        except Exception as exc:  # noqa: BLE001
            restore()
            _STATUS = f"cellpose accel: stock Cellpose (install error {exc!r})"
    _log(_STATUS)
    return _STATUS


def _install() -> str:
    global _ACTIVE
    import cellpose
    from cellpose import dynamics as dyn, models, plot

    version = str(getattr(cellpose, "version", "unknown"))
    if version != SUPPORTED_CELLPOSE:
        return f"cellpose accel: stock Cellpose ({version} is not a verified version)"
    stock = {"_extend_centers_gpu": dyn._extend_centers_gpu,
             "steps_interp": dyn.steps_interp,
             "dx_to_circ": plot.dx_to_circ,
             "masks_to_flows_gpu": dyn.masks_to_flows_gpu}
    bad = [name for name, fn in stock.items()
           if _SOURCE_SHA256[name] and source_sha256(fn) != _SOURCE_SHA256[name]]
    if bad:
        return f"cellpose accel: stock Cellpose (source differs: {', '.join(bad)})"
    extend_centers = make_extend_centers(dyn._extend_centers_gpu)
    steps_interp = make_steps_interp(dyn.steps_interp)
    failed = _self_test(dyn, extend_centers, steps_interp)
    if failed:
        return f"cellpose accel: stock Cellpose (self-test mismatch in {failed})"
    _patch(dyn, "_extend_centers_gpu", extend_centers)
    _patch(dyn, "steps_interp", steps_interp)
    _patch(models, "plot", make_plot_proxy(plot))
    _ACTIVE = ("extend_centers", "steps_interp", "no_flow_rgb")
    return f"cellpose accel: active (cellpose {version}): {', '.join(_ACTIVE)}"


def _patch(owner, name, value):
    _APPLIED.append((owner, name, getattr(owner, name)))
    setattr(owner, name, value)


def restore() -> None:
    """Undo every patch (used by tests)."""
    global _ACTIVE, _STATUS
    while _APPLIED:
        owner, name, value = _APPLIED.pop()
        setattr(owner, name, value)
    _ACTIVE = ()
    _STATUS = None
