#!/usr/bin/env python3
"""
spatial_stats.py — CellCounter sidecar: cell-centroid spatial statistics.

Computes nearest-neighbour distance (per-cell and image-level), local
neighbour density, and the Clark-Evans clustering index (R) from cell
centroids — there's no pixel data to load here, so this script is much
thinner than the detection sidecars: read --cells-json, call
`_spatial.compute()`, print JSON. All the math lives in `_spatial.py` (pure
functions, no I/O).

Stdout contract (success): the dict documented at the top of `_spatial.py`,
plus "width"/"height" echoing the resolved image shape. On a known failure:
`{"error": ..., "hint": ...}`, non-zero exit — same convention as every
other CellCounter sidecar. `log`/`emit_error` are re-implemented locally
here rather than imported from `_cellpose_common.py` — see
`puncta_detect.py`'s module docstring for why (zero import-time coupling to
a file owned by a different, concurrently-in-flight pass).

--cells-json: a JSON array of {"label": <any>, "cx": <x_px>, "cy": <y_px>}
(aliases "id"/"x"/"y" also accepted). `label` is echoed back on each
per-cell row when present, else defaults to the entry's 0-based index.
"""

from __future__ import annotations

import argparse
import json
import os
import sys


def log(*args, **kwargs) -> None:
    """Stderr logger — stdout is reserved for the final JSON result."""
    print(*args, file=sys.stderr, **kwargs)


def emit_error(error: str, hint: str = "", exit_code: int = 2) -> None:
    """Write a structured error JSON to stdout and exit."""
    payload: dict = {"error": error}
    if hint:
        payload["hint"] = hint
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()
    sys.exit(exit_code)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="CellCounter spatial-statistics sidecar "
                    "(NND, local density, Clark-Evans R)")
    parser.add_argument("--cells-json", dest="cells_json", required=True,
                        help="Path to a JSON array of {label, cx, cy} cell centroids.")
    parser.add_argument("--pxPerUm", type=float, required=True,
                        help="Pixels per micrometer.")
    parser.add_argument("--width", type=int, default=None,
                        help="Image width in px. Inferred from the centroid bounding "
                             "box (padded) if omitted.")
    parser.add_argument("--height", type=int, default=None,
                        help="Image height in px. Same fallback as --width.")
    parser.add_argument("--radius-um", dest="radius_um", type=float, default=50.0,
                        help="Local-density neighbour search radius in µm.")
    parser.add_argument("--heatmap", action="store_true",
                        help="Also compute a density-heatmap grid.")
    parser.add_argument("--heatmap-bin-um", dest="heatmap_bin_um",
                        type=float, default=25.0)
    parser.add_argument("--heatmap-max-bins", dest="heatmap_max_bins",
                        type=int, default=64)
    return parser.parse_args()


def _load_centroids(path: str):
    """Read --cells-json into a list of {label, cx, cy} dicts.

    Never raises — logs and returns [] on a read/parse failure or when no
    entry has usable coordinates.
    """
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as exc:  # noqa: BLE001
        log(f"[spatial_stats] could not read --cells-json {path!r}: {exc!r}")
        return []

    if not isinstance(data, list):
        log(f"[spatial_stats] --cells-json must be a JSON array; got {type(data).__name__}")
        return []

    out = []
    for i, entry in enumerate(data):
        if not isinstance(entry, dict):
            continue
        label = entry.get("label", entry.get("id", i))
        cx = entry.get("cx", entry.get("x"))
        cy = entry.get("cy", entry.get("y"))
        if cx is None or cy is None:
            continue
        out.append({"label": label, "cx": cx, "cy": cy})
    return out


def main() -> None:
    args = parse_args()

    _here = os.path.dirname(os.path.abspath(__file__))
    if _here not in sys.path:
        sys.path.insert(0, _here)

    try:
        import _spatial
    except Exception as exc:  # noqa: BLE001
        log(f"[spatial_stats] _spatial import failed: {exc!r}")
        emit_error("spatial-module-not-available", hint=str(exc), exit_code=2)
        return

    centroids = _load_centroids(args.cells_json)
    if not centroids:
        emit_error("no-cells", hint="No usable {cx, cy} centroids in --cells-json.",
                   exit_code=3)
        return

    width_px = args.width
    height_px = args.height
    if not width_px or not height_px:
        xs = [float(c["cx"]) for c in centroids]
        ys = [float(c["cy"]) for c in centroids]
        pad = 10.0
        inferred_w = int(round(max(xs) - min(xs) + 2 * pad)) if xs else 0
        inferred_h = int(round(max(ys) - min(ys) + 2 * pad)) if ys else 0
        width_px = width_px or max(1, inferred_w)
        height_px = height_px or max(1, inferred_h)
        log(f"[spatial_stats] --width/--height not given; inferred {width_px}x{height_px} "
            "from the centroid bounding box (padded 10px) — Clark-Evans R depends on the "
            "image area and will be more accurate with the real image dimensions.")

    params = {
        "radius_um": args.radius_um,
        "heatmap": bool(args.heatmap),
        "heatmap_bin_um": args.heatmap_bin_um,
        "heatmap_max_bins": args.heatmap_max_bins,
    }

    result = _spatial.compute(centroids, args.pxPerUm, (height_px, width_px), params)
    result["width"] = width_px
    result["height"] = height_px

    # Wire contract: label/nn_label are always a string (or null) on the way
    # out — see puncta_detect.py's identical note. `_spatial.compute()` stays
    # label-type-agnostic internally.
    for row in result.get("per_cell", []):
        if row.get("label") is not None:
            row["label"] = str(row["label"])
        if row.get("nn_label") is not None:
            row["nn_label"] = str(row["nn_label"])

    log(f"[spatial_stats] n_cells={result.get('n_cells', 0)} "
        f"R={result.get('clark_evans_R')}")

    sys.stdout.write(json.dumps(result))
    sys.stdout.flush()


if __name__ == "__main__":
    main()
