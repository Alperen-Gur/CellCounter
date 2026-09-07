#!/usr/bin/env python3
"""Strict one-shot StarDist fluorescence sidecar for the Windows port.

Stdout is reserved for one CellCounter result/error JSON object. Library
chatter and progress are redirected to stderr. The host passes the exact
pretrained name mapped from app id ``sd-fluo``; no other model is accepted.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import math
import os
import sys
import uuid
from typing import Optional


MODEL_NAME = "2D_versatile_fluo"


def log(message: str) -> None:
    print(f"[stardist_detect] {message}", file=sys.stderr, flush=True)


def fail(error: str, hint: str, code: int = 2) -> None:
    print(json.dumps({"error": error, "hint": hint}), end="", flush=True)
    raise SystemExit(code)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="CellCounter StarDist detector")
    parser.add_argument("--image", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--pxPerUm", type=float, required=True)
    parser.add_argument("--conf", type=float, default=0.5)
    parser.add_argument("--z-project", default="max", choices=("max", "sum", "mean", "none"))
    parser.add_argument("--segment-channel", type=int, default=None)
    parser.add_argument("--bg-subtract", action="store_true")
    parser.add_argument("--rolling-ball-radius", type=int, default=50)
    parser.add_argument("--watershed", action="store_true")
    parser.add_argument("--watershed-min-distance", type=int, default=8)
    parser.add_argument("--small-threshold", type=float, default=20.0)
    parser.add_argument("--large-threshold", type=float, default=30.0)
    return parser.parse_args()


def load_image(path: str, z_project="max", segment_channel=None):
    import numpy as np
    import _imageio

    stack, meta = _imageio.load_planes(path, z_project=z_project, channel=None)
    channels = int(stack.shape[2])
    if segment_channel is not None:
        if segment_channel < 0 or segment_channel >= channels:
            raise ValueError(f"Source channel {segment_channel} is unavailable; this image has {channels} channels")
        image = stack[..., segment_channel]
    elif bool(meta.get("is_rgb")) and channels >= 3:
        image = stack[..., :3].mean(axis=2)
    else:
        image = stack[..., 0]
    image = np.asarray(image, dtype=np.float32)
    if image.size == 0:
        raise ValueError("image has no pixels")
    return image, (int(image.shape[1]), int(image.shape[0]))


def qc_stats(image) -> dict[str, float]:
    import numpy as np
    from scipy.ndimage import laplace

    gray = image.astype(np.float64, copy=False)
    focus = min(1.0, max(0.0, float(laplace(gray).var()) / 10000.0))
    h, w = gray.shape
    ys = np.linspace(0, h - 1, min(128, h)).round().astype(int)
    xs = np.linspace(0, w - 1, min(128, w)).round().astype(int)
    yy, xx = np.meshgrid(ys, xs, indexing="ij")
    values = gray[yy, xx].ravel()
    design = np.column_stack([
        xx.ravel() ** 2,
        yy.ravel() ** 2,
        xx.ravel() * yy.ravel(),
        xx.ravel(),
        yy.ravel(),
        np.ones(values.size),
    ])
    coeffs, *_ = np.linalg.lstsq(design, values, rcond=None)
    mean = float(values.mean())
    residual = float((values - design @ coeffs).std()) / mean if mean > 1e-6 else 0.0
    return {"focus_score": focus, "illumination_residual": residual}


def contour_for(mask) -> Optional[list[list[float]]]:
    from skimage.measure import find_contours

    contours = find_contours(mask.astype(float), 0.5)
    if not contours:
        return None
    longest = max(contours, key=len)
    # Keep IPC bounded while retaining a smooth source-pixel outline.
    step = max(1, math.ceil(len(longest) / 256))
    return [[float(point[1]), float(point[0])] for point in longest[::step]]


def cells_from_labels(labels, intensity, probabilities, px_per_um: float,
                      small: float, large: float) -> list[dict]:
    import numpy as np
    from skimage.measure import perimeter, regionprops

    cells: list[dict] = []
    props = regionprops(labels, intensity_image=intensity)
    for index, prop in enumerate(props):
        if prop.area < 4:
            continue
        cy, cx = prop.centroid
        diameter_px = float(prop.equivalent_diameter_area)
        diameter_um = diameter_px / px_per_um
        perimeter_um = float(perimeter(prop.image, neighborhood=8)) / px_per_um
        confidence = 0.85
        if probabilities is not None and index < len(probabilities):
            confidence = max(0.0, min(1.0, float(probabilities[index])))
        cell_mask = labels == prop.label
        mean_intensity = float(prop.mean_intensity)
        size_class = (
            "small" if diameter_um < small
            else "intermediate" if diameter_um < large
            else "large"
        )
        result = {
            "id": str(uuid.uuid4()),
            "cx": float(cx),
            "cy": float(cy),
            "diameter_um": diameter_um,
            "diameter_px": diameter_px,
            "confidence": confidence,
            "area_um2": float(prop.area) / (px_per_um * px_per_um),
            "perimeter_um": perimeter_um,
            "circularity": (
                min(1.0, max(0.0, 4.0 * math.pi * float(prop.area) /
                    max(1e-9, float(perimeter(prop.image, neighborhood=8)) ** 2)))
            ),
            "eccentricity": float(prop.eccentricity),
            "mean_intensity": mean_intensity,
            "integrated_density": mean_intensity * float(prop.area),
            "centroid_um_x": float(cx) / px_per_um,
            "centroid_um_y": float(cy) / px_per_um,
            "aspect_ratio": float(prop.major_axis_length) / max(1e-9, float(prop.minor_axis_length)),
            "solidity": float(prop.solidity),
            "edge_touching": bool(
                prop.bbox[0] == 0 or prop.bbox[1] == 0
                or prop.bbox[2] == labels.shape[0]
                or prop.bbox[3] == labels.shape[1]
            ),
            "likely_clump": diameter_um > 80.0,
            "likely_debris": bool(prop.solidity < 0.7 and diameter_um < 8.0),
            "size_class": size_class,
            "is_manual": False,
        }
        contour = contour_for(cell_mask)
        if contour:
            result["contour_px"] = contour
        cells.append(result)
    return cells


def main() -> None:
    args = parse_args()
    if args.model != MODEL_NAME:
        fail(
            "unsupported-model",
            f"StarDist sidecar accepts only {MODEL_NAME}; got {args.model!r}.",
        )
    if not math.isfinite(args.pxPerUm) or args.pxPerUm <= 0:
        fail("invalid-calibration", "pxPerUm must be a positive finite number.", 3)

    try:
        import numpy as np
        # StarDist/csbdeep use plain print() during import/model discovery on
        # some versions. Keep stdout exclusively JSON for the Rust decoder.
        with contextlib.redirect_stdout(sys.stderr):
            from csbdeep.utils import normalize
            from stardist.models import StarDist2D
    except Exception as exc:
        fail("stardist-not-installed", repr(exc))

    try:
        image, (width, height) = load_image(args.image, args.z_project, args.segment_channel)
    except Exception as exc:
        fail("image-open-failed", str(exc), 3)

    stats = qc_stats(image)
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    if args.bg_subtract:
        try:
            import _preprocessing
            image = _preprocessing.apply(image, args)
        except Exception as exc:
            fail("preprocessing-failed", str(exc), 3)

    log(f"loading {MODEL_NAME}")
    try:
        with contextlib.redirect_stdout(sys.stderr):
            model = StarDist2D.from_pretrained(MODEL_NAME)
            labels, details = model.predict_instances(
                normalize(image, 1, 99.8),
                # Keep detector probability fixed; `--conf` is an analysis
                # visibility threshold applied by the host and must never
                # destructively remove cells from the saved result.
                prob_thresh=0.5,
            )
    except Exception as exc:
        fail("eval-failed", str(exc), 5)

    probabilities = details.get("prob") if isinstance(details, dict) else None
    if args.watershed:
        try:
            import _watershed
            distance_px = max(1, round(args.watershed_min_distance * args.pxPerUm))
            labels = _watershed.split(labels, min_distance_px=distance_px)
            probabilities = None
        except Exception as exc:
            fail("watershed-failed", str(exc), 5)

    try:
        import _colony
        stats.update(_colony.compute(labels, args.pxPerUm, (height, width)))
    except Exception as exc:
        log(f"colony statistics unavailable: {exc!r}")

    cells = cells_from_labels(
        labels,
        image.astype(np.float64, copy=False),
        probabilities,
        float(args.pxPerUm),
        float(args.small_threshold),
        float(args.large_threshold),
    )
    print(json.dumps({
        "width": int(width),
        "height": int(height),
        "cells": cells,
        "image_stats": stats,
    }), end="", flush=True)
    log(f"emitted {len(cells)} cells")


if __name__ == "__main__":
    main()
