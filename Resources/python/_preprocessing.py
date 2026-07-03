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

    return out
