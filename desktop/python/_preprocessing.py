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

        # If multi-channel (H, W, C), run rolling ball per channel.
        if out.ndim == 3:
            for c in range(out.shape[2]):
                bg = restoration.rolling_ball(out[..., c], radius=radius)
                out[..., c] = out[..., c] - bg
        else:
            bg = restoration.rolling_ball(out, radius=radius)
            out = out - bg

        # Clip negative values introduced by subtraction, restore original dtype.
        out = np.clip(out, 0, None).astype(img.dtype)

    return out
