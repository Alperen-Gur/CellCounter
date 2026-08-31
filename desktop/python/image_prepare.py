#!/usr/bin/env python3
"""Prepare microscope containers for CellCounter's native macOS UI.

The detection sidecars can read vendor formats through ``_imageio``, while
ImageIO/AppKit cannot.  This helper keeps the original file untouched and
writes a lossless, projected PNG for display/export plus a small JPEG
thumbnail.  Stdout is one compact JSON object so the Swift importer can also
persist dimensions and physical pixel size before detection starts.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any


def _log(*args: Any) -> None:
    print("[image_prepare]", *args, file=sys.stderr)


def _display_array(stack, meta, imageio_module):
    """Return a uint8 L/RGB array suitable for AppKit display.

    Ordinary RGB images retain their original color relationship.  Each
    fluorescence channel is contrast-normalized independently so a dim marker
    is not hidden by a much brighter channel.  The raw stack is never changed;
    detection and quantitative intensity work continue to use the source file.
    """
    import numpy as np

    channels = int(stack.shape[2])
    if channels <= 1:
        return imageio_module.to_uint8(stack[..., 0], meta)

    if bool(meta.get("is_rgb", False)) and channels >= 3:
        return imageio_module.to_uint8(stack[..., :3], meta)

    height, width = int(stack.shape[0]), int(stack.shape[1])
    rgb = np.zeros((height, width, 3), dtype=np.uint8)
    for index in range(min(3, channels)):
        rgb[..., index] = imageio_module.to_uint8(stack[..., index], meta)
    return rgb


def _write_analysis_tiff(stack, meta, analysis_output: str) -> None:
    """Persist raw detector values as a lossless, portable multi-channel TIFF."""
    import numpy as np
    import tifffile

    channels = int(stack.shape[2])
    if channels == 1:
        data = np.ascontiguousarray(stack[..., 0])
        axes = "YX"
        photometric = "minisblack"
    elif bool(meta.get("is_rgb", False)) and channels in (3, 4):
        data = np.ascontiguousarray(stack)
        axes = "YXS"
        photometric = "rgb"
    else:
        data = np.ascontiguousarray(np.moveaxis(stack, -1, 0))
        axes = "CYX"
        photometric = "minisblack"
    metadata = {"axes": axes}
    pixel_size_um = meta.get("pixel_size_um")
    if pixel_size_um is not None:
        metadata["PhysicalSizeX"] = float(pixel_size_um)
        metadata["PhysicalSizeXUnit"] = "µm"
        metadata["PhysicalSizeY"] = float(pixel_size_um)
        metadata["PhysicalSizeYUnit"] = "µm"
    os.makedirs(os.path.dirname(os.path.abspath(analysis_output)), exist_ok=True)
    tifffile.imwrite(
        analysis_output,
        data,
        bigtiff=int(data.nbytes) >= 3_500_000_000,
        photometric=photometric,
        metadata=metadata,
    )


def prepare_image(image_path: str, display_output: str, thumbnail_output: str,
                  analysis_output: str,
                  z_project: str = "max", imageio_module=None) -> dict:
    """Decode one source and write its native-display derivatives."""
    if imageio_module is None:
        import _imageio as imageio_module  # noqa: PLC0415

    from PIL import Image

    stack, meta = imageio_module.load_planes(
        image_path, z_project=z_project, channel=None)
    display = _display_array(stack, meta, imageio_module)
    _write_analysis_tiff(stack, meta, analysis_output)
    image = Image.fromarray(display)

    os.makedirs(os.path.dirname(os.path.abspath(display_output)), exist_ok=True)
    os.makedirs(os.path.dirname(os.path.abspath(thumbnail_output)), exist_ok=True)
    image.save(display_output, format="PNG", optimize=True)

    thumb = image.copy()
    thumb.thumbnail((256, 256), Image.Resampling.LANCZOS)
    if thumb.mode != "RGB":
        thumb = thumb.convert("RGB")
    thumb.save(thumbnail_output, format="JPEG", quality=78, optimize=True)

    pixel_size_um = meta.get("pixel_size_um")
    try:
        pixel_size_um = float(pixel_size_um) if pixel_size_um is not None else None
    except (TypeError, ValueError):
        pixel_size_um = None
    if pixel_size_um is not None and not (pixel_size_um > 0):
        pixel_size_um = None

    payload = {
        "width": int(stack.shape[1]),
        "height": int(stack.shape[0]),
        "pixel_size_um": pixel_size_um,
        "source_format": str(meta.get("source_format") or "vendor"),
        "channel_names": list(meta.get("all_channel_names")
                              or meta.get("channel_names") or []),
        "z_count": int(meta.get("z_count") or 1),
        "t_count": int(meta.get("t_count") or 1),
    }
    return payload


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Prepare a microscope image for CellCounter's native UI")
    parser.add_argument("--image", required=True)
    parser.add_argument("--display-output", required=True)
    parser.add_argument("--thumbnail-output", required=True)
    parser.add_argument("--analysis-output", required=True)
    parser.add_argument("--z-project", default="max",
                        choices=("max", "sum", "mean", "none"))
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    try:
        payload = prepare_image(
            args.image, args.display_output, args.thumbnail_output,
            args.analysis_output,
            z_project=args.z_project)
    except Exception as exc:  # noqa: BLE001 - return an actionable wire error.
        code = getattr(exc, "code", "image-prepare-failed")
        hint = getattr(exc, "hint", "") or str(exc)
        _log(code, hint)
        sys.stdout.write(json.dumps({"error": str(code), "hint": str(hint)}))
        sys.stdout.flush()
        raise SystemExit(3)

    sys.stdout.write(json.dumps(payload, separators=(",", ":")))
    sys.stdout.flush()


if __name__ == "__main__":
    main()
