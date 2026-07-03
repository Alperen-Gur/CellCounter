"""
_preprocessing.py — CellCounter shared preprocessing module.

Exposes a single function, `apply(img, args)`, which takes a numpy array and an
argparse Namespace and returns a (potentially modified) numpy array of the same
dtype and shape.

Current preprocessing steps:
  - Rolling-ball background subtraction (scikit-image `restoration.rolling_ball`)
    gated by args.bg_subtract and args.rolling_ball_radius.
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

        # Compute the subtraction in a signed/float-wide dtype and clip BEFORE
        # casting back. Doing `out - bg` directly in a narrow unsigned dtype
        # (e.g. uint8) wraps around modularly wherever bg > pixel, turning
        # background-subtracted regions into bright noise; the later clip then
        # runs on already-corrupted data. Promote to a signed dtype wide enough
        # to hold the difference, clip to the original dtype's range, cast back.
        info = np.iinfo(img.dtype) if np.issubdtype(img.dtype, np.integer) else None
        hi = info.max if info is not None else None

        def _subtract(plane):
            bg = restoration.rolling_ball(plane, radius=radius)
            # int32 comfortably holds uint8/uint16 differences; float images use
            # their own dtype and just clip at 0.
            if info is not None:
                diff = plane.astype(np.int32) - bg.astype(np.int32)
                return np.clip(diff, 0, hi).astype(img.dtype)
            diff = plane.astype(np.float64) - bg.astype(np.float64)
            return np.clip(diff, 0.0, None).astype(img.dtype)

        # If multi-channel (H, W, C), run rolling ball per channel.
        if out.ndim == 3:
            for c in range(out.shape[2]):
                out[..., c] = _subtract(out[..., c])
        else:
            out = _subtract(out)

    return out
