"""
_preprocessing.py — CellCounter shared preprocessing module.

Exposes a single function, `apply(img, args)`, which takes a numpy array and an
argparse Namespace and returns a (potentially modified) numpy array of the same
dtype and shape.

Current preprocessing steps:
  - Rolling-ball background subtraction.
  - Perona-Malik anisotropic diffusion (edge-preserving denoise).
  - CLAHE local-contrast enhancement.

Diffusion uses CuPy when requested and available, and falls back to the same
vectorized NumPy implementation. The original source image is never written.
"""

from __future__ import annotations


def apply(img, args):
    """Apply preprocessing to *img* according to *args* flags.

    Parameters
    ----------
    img : numpy.ndarray
        Input image array (2-D grayscale or 3-D RGB/multi-channel).
    args : argparse.Namespace
        Parsed CLI arguments.  Reads two optional attributes:
          - bg_subtract (bool, default False) — enable rolling-ball subtraction.
          - rolling_ball_radius (int, default 50) — radius for the rolling ball.

    Returns
    -------
    numpy.ndarray
        Preprocessed image, same dtype and shape as *img*.
    """
    out = img.copy()

    if getattr(args, "bg_subtract", False):
        from skimage import restoration
        import numpy as np

        radius = max(5, int(getattr(args, "rolling_ball_radius", 50)))

        # Subtraction must happen in a signed/float dtype: an unsigned `pixel - bg`
        # wraps modularly (e.g. uint8 0 - 5 == 251) BEFORE any clip can run, turning
        # background regions into bright noise. Compute the difference wide, clip to
        # the original dtype's valid range, then cast back.
        info = np.iinfo(img.dtype) if np.issubdtype(img.dtype, np.integer) else None
        hi = None if info is None else info.max

        def _subtract(plane):
            diff = plane.astype(np.float32) - bg.astype(np.float32)
            return np.clip(diff, 0, hi).astype(img.dtype)

        # If multi-channel (H, W, C), run rolling ball per channel.
        if out.ndim == 3:
            for c in range(out.shape[2]):
                bg = restoration.rolling_ball(out[..., c], radius=radius)
                out[..., c] = _subtract(out[..., c])
        else:
            bg = restoration.rolling_ball(out, radius=radius)
            out = _subtract(out)

    if getattr(args, "anisotropic_diffusion", False):
        out = _apply_per_channel(out, lambda plane: _anisotropic_diffusion(
            plane, use_gpu=bool(getattr(args, "gpu_preprocess", False))))

    if getattr(args, "clahe", False):
        out = _apply_per_channel(out, _clahe)

    return out


def _apply_per_channel(img, operation):
    """Apply a 2-D operation plane-by-plane without changing shape/dtype."""
    if img.ndim == 3:
        out = img.copy()
        for channel in range(out.shape[2]):
            out[..., channel] = operation(out[..., channel])
        return out
    return operation(img)


def _normalize(plane):
    import numpy as np
    arr = plane.astype(np.float32)
    if np.issubdtype(plane.dtype, np.integer):
        scale = float(np.iinfo(plane.dtype).max)
        return arr / max(scale, 1.0), scale
    lo, hi = float(arr.min()), float(arr.max())
    return ((arr - lo) / (hi - lo) if hi > lo else arr * 0), (lo, hi)


def _restore(normalized, dtype, scale):
    import numpy as np
    normalized = np.clip(normalized, 0.0, 1.0)
    if np.issubdtype(dtype, np.integer):
        return np.rint(normalized * float(scale)).astype(dtype)
    lo, hi = scale
    return (normalized * (hi - lo) + lo).astype(dtype)


def _clahe(plane):
    from skimage import exposure
    normalized, scale = _normalize(plane)
    # A conservative clip limit improves dim fields without turning sensor
    # noise into dominant texture.
    enhanced = exposure.equalize_adapthist(normalized, clip_limit=0.02)
    return _restore(enhanced, plane.dtype, scale)


def _anisotropic_diffusion(plane, use_gpu=False, iterations=10,
                           kappa=0.10, gamma=0.16):
    import numpy as np
    normalized, scale = _normalize(plane)
    xp = np
    gpu = False
    if use_gpu:
        try:
            import cupy as cp
            xp = cp
            normalized = cp.asarray(normalized)
            gpu = True
        except Exception:
            xp = np

    out = normalized.astype(xp.float32, copy=True)
    for _ in range(max(1, int(iterations))):
        north = xp.zeros_like(out); south = xp.zeros_like(out)
        east = xp.zeros_like(out); west = xp.zeros_like(out)
        north[1:, :] = out[:-1, :] - out[1:, :]
        south[:-1, :] = out[1:, :] - out[:-1, :]
        west[:, 1:] = out[:, :-1] - out[:, 1:]
        east[:, :-1] = out[:, 1:] - out[:, :-1]
        update = sum(g * xp.exp(-((g / kappa) ** 2))
                     for g in (north, south, east, west))
        out = out + gamma * update

    if gpu:
        out = xp.asnumpy(out)
    return _restore(out, plane.dtype, scale)
