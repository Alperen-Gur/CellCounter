#!/usr/bin/env python3
"""
intensity_assays.py — CellCounter sidecar for the intensity-based assays.

Runs one or more assays from `_assays_intensity.py` over an **already
segmented** image. It does no segmentation of its own: you give it the cell
masks (as a label map, or as the contours from a previous detection run) plus
the multi-channel image, and it prints a single JSON object to stdout. All
progress/log output goes to stderr so stdout stays parseable by the Swift host.

Stdout contract — deliberately the same envelope shape that
`_cellpose_common.emit_payload` writes, plus one new `assays` block::

  {
    "width":  <int>,
    "height": <int>,
    "channel_names": ["DAPI", "GFP", …],
    "assays": { "<assay name>": { … full per-assay result, incl. per_cell … } },
    "image_stats": { "assay_marker_pct_positive": 37.0, … }   # flat {str: float}
  }

`image_stats` is the flat namespace the Swift host already decodes as
`[String: Double]` (`SidecarPayload.image_stats` → `DetectionRecord.imageStats`),
so assay scalars reach the UI with no schema change. The rich `assays` block is
for exports and for callers that want per-cell rows.

On a known failure this prints `{"error": "<slug>", "hint": "…"}` and exits
non-zero — same convention as the detection sidecars.

Cell masks — one of:
  --labels PATH          .npy int label map, or a single-channel PNG/TIF whose
                         pixel values ARE the labels (0 = background).
  --detection-json PATH  a sidecar payload from a previous run; cells are
                         rasterised from their `contour_px` polygons in order,
                         so label i+1 == cells[i].

Nuclear masks for the N:C assay — one of --nuclear-labels / --nuclear-channel
(the latter thresholds that channel with Otsu inside the cell masks).

Examples
--------
  python3 intensity_assays.py --image stack.tif --labels masks.npy \\
      --assay marker_positive --channel 1 --threshold-mode otsu

  python3 intensity_assays.py --image stack.nd2 --detection-json det.json \\
      --assay colocalization --channel-a 1 --channel-b 2

  python3 intensity_assays.py --image stack.tif --labels masks.npy \\
      --assay live_dead --live-channel 1 --dead-channel 2 \\
      --assay cell_cycle --dna-channel 0
"""

from __future__ import annotations

import argparse
import json
import os
import sys

# Ensure local helpers (_assays_intensity, _imageio, …) are importable both
# when launched from the staged python dir AND when launched in-tree.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

LOG_PREFIX = "[intensity_assays]"


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


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Intensity-based assay sidecar for CellCounter")
    p.add_argument("--image", required=True,
                   help="Path to the multi-channel image (tif/nd2/czi/lif/png…).")
    p.add_argument("--z-project", dest="z_project", default="max",
                   choices=["max", "sum", "mean", "none"],
                   help="Z projection passed to _imageio.load_planes "
                        "(default 'max'). Constrained here so an unrecognised "
                        "mode is rejected by argparse rather than reaching the "
                        "loader.")
    p.add_argument("--channel-names", dest="channel_names", default=None,
                   help="Comma-separated override for the channel names "
                        "reported by the loader.")

    src = p.add_argument_group("cell masks")
    src.add_argument("--labels", default=None,
                     help="Label map: .npy int array, or a single-channel "
                          "image whose pixel values are the labels.")
    src.add_argument("--detection-json", dest="detection_json", default=None,
                     help="A previous sidecar payload; cells are rasterised "
                          "from each cell's contour_px polygon.")

    p.add_argument("--assay", action="append", default=[],
                   help="Assay to run; repeatable. One of: marker_positive, "
                        "nuclear_cytoplasmic, colocalization, live_dead, "
                        "transfection_efficiency, cell_cycle.")

    g = p.add_argument_group("marker_positive / transfection_efficiency")
    g.add_argument("--channel", type=int, default=None,
                   help="Channel index to score.")
    g.add_argument("--metric", default="mean",
                   choices=["mean", "integrated", "median"],
                   help="Per-cell statistic to threshold (default mean).")
    g.add_argument("--threshold-mode", dest="threshold_mode", default="otsu",
                   choices=["manual", "otsu", "negative_sd"],
                   help="How the positivity threshold is chosen (default otsu).")
    g.add_argument("--threshold", type=float, default=None,
                   help="Threshold value for --threshold-mode manual.")
    g.add_argument("--k", type=float, default=3.0,
                   help="SD multiplier for --threshold-mode negative_sd "
                        "(default 3.0).")
    g.add_argument("--negative-values", dest="negative_values", default=None,
                   help="Per-cell values from a REAL negative control "
                        "(unstained / no-primary / untransfected), REQUIRED by "
                        "--threshold-mode negative_sd. Either a comma-separated "
                        "list, or a path to a .npy / .json / plain-text file — "
                        "including the JSON a previous run of this script wrote "
                        "with --per-cell for the control image. Without it the "
                        "negative population would have to be inferred from the "
                        "same image, which is circular, so negative_sd refuses.")
    g.add_argument("--marker-name", dest="marker_name", default=None,
                   help="Display name for the marker (Ki67, EdU, GFP…).")

    nc = p.add_argument_group("nuclear_cytoplasmic")
    nc.add_argument("--nuclear-labels", dest="nuclear_labels", default=None,
                    help="Nuclear label map / binary mask (same H×W).")
    nc.add_argument("--nuclear-channel", dest="nuclear_channel", type=int,
                    default=None,
                    help="Derive the nuclear mask by Otsu-thresholding this "
                         "channel inside the cell masks.")
    nc.add_argument("--nc-metric", dest="nc_metric", default="mean",
                    choices=["mean", "median"],
                    help="Per-compartment statistic (default mean).")

    co = p.add_argument_group("colocalization")
    co.add_argument("--channel-a", dest="channel_a", type=int, default=None)
    co.add_argument("--channel-b", dest="channel_b", type=int, default=None)
    co.add_argument("--coloc-threshold-mode", dest="coloc_threshold_mode",
                    default="otsu", choices=["otsu", "manual", "zero"],
                    help="Manders thresholding (default otsu).")
    co.add_argument("--threshold-a", dest="threshold_a", type=float, default=None)
    co.add_argument("--threshold-b", dest="threshold_b", type=float, default=None)
    co.add_argument("--coloc-threshold-scope", dest="coloc_threshold_scope",
                    default="image", choices=["image", "in_cells"],
                    help="Where the Manders thresholds are computed (default "
                         "image). 'in_cells' sees no background, so Otsu splits "
                         "signal from signal instead of signal from background "
                         "and M1/M2 come out deflated (measured 0.64 where the "
                         "truth was 1.0) — use it only on data whose background "
                         "is already subtracted to zero.")

    ld = p.add_argument_group("live_dead")
    ld.add_argument("--live-channel", dest="live_channel", type=int, default=None)
    ld.add_argument("--dead-channel", dest="dead_channel", type=int, default=None)
    ld.add_argument("--live-threshold", dest="live_threshold", type=float,
                    default=None)
    ld.add_argument("--dead-threshold", dest="dead_threshold", type=float,
                    default=None)

    cc = p.add_argument_group("cell_cycle")
    cc.add_argument("--dna-channel", dest="dna_channel", type=int, default=None)
    cc.add_argument("--bins", type=int, default=64,
                    help="DNA-content histogram bins (default 64).")
    cc.add_argument("--gate-width", dest="gate_width", type=float, default=0.15,
                    help="Half-width of the G1/G2 gates as a fraction of the "
                         "peak position (default 0.15).")

    p.add_argument("--per-cell", dest="per_cell", action="store_true",
                   help="Include the per-cell rows in the JSON (they are "
                        "dropped by default to keep stdout small).")
    return p


# ---------------------------------------------------------------------------
# Mask loading.
# ---------------------------------------------------------------------------

def load_label_map(path: str):
    """Load a label map from .npy or a single-channel image."""
    import numpy as np

    ext = os.path.splitext(path)[1].lower()
    if ext == ".npy":
        arr = np.load(path)
    else:
        from PIL import Image
        Image.MAX_IMAGE_PIXELS = 2_000_000_000
        with Image.open(path) as im:
            im.load()
            if im.mode not in ("I", "I;16", "I;16B", "L", "F"):
                im = im.convert("I")
            arr = np.array(im)
    if arr.ndim == 3:
        arr = arr[:, :, 0]
    return arr.astype(np.int32, copy=False)


def rasterize_polygon(poly_xy, out, label: int) -> None:
    """Even-odd scanline fill of one polygon into ``out`` (in place).

    Pure NumPy — no skimage.draw dependency. ``poly_xy`` is a sequence of
    ``[x, y]`` pairs in image-pixel coordinates; pixel centres (y + 0.5) decide
    membership, matching the convention used when the contour was traced.
    """
    import numpy as np

    pts = np.asarray(poly_xy, dtype=np.float64)
    if pts.ndim != 2 or pts.shape[0] < 3:
        return
    h, w = out.shape
    xs, ys = pts[:, 0], pts[:, 1]
    y0 = max(0, int(np.floor(ys.min())))
    y1 = min(h - 1, int(np.ceil(ys.max())))
    n = pts.shape[0]

    for y in range(y0, y1 + 1):
        yc = y + 0.5
        crossings: list[float] = []
        for i in range(n):
            j = (i + 1) % n
            y_i, y_j = ys[i], ys[j]
            if (y_i > yc) == (y_j > yc):
                continue
            t = (yc - y_i) / (y_j - y_i)
            crossings.append(float(xs[i] + t * (xs[j] - xs[i])))
        if len(crossings) < 2:
            continue
        crossings.sort()
        for a, b in zip(crossings[0::2], crossings[1::2]):
            xa = max(0, int(np.ceil(a - 0.5)))
            xb = min(w - 1, int(np.floor(b - 0.5)))
            if xb >= xa:
                out[y, xa:xb + 1] = label


def labels_from_detection_json(path: str, height: int, width: int):
    """Rasterise a previous sidecar payload's `contour_px` polygons.

    Label ``i + 1`` corresponds to ``payload["cells"][i]``, so per-cell assay
    rows line up with the original detection order. Cells without a contour are
    skipped (their label id is simply never painted) and reported in the log.
    """
    import numpy as np

    with open(path, "r", encoding="utf-8") as fh:
        payload = json.load(fh)
    cells = payload.get("cells") or []
    h = int(payload.get("height") or height)
    w = int(payload.get("width") or width)
    if h != height or w != width:
        log(f"{LOG_PREFIX} detection JSON is {w}x{h} but the image is "
            f"{width}x{height}; using the image size")
        h, w = height, width

    out = np.zeros((h, w), dtype=np.int32)
    painted = 0
    for i, cell in enumerate(cells):
        contour = cell.get("contour_px")
        if not contour:
            continue
        rasterize_polygon(contour, out, i + 1)
        painted += 1
    log(f"{LOG_PREFIX} rasterised {painted}/{len(cells)} cells from contours")
    if painted == 0:
        emit_error("no-contours",
                   hint="The detection JSON has no per-cell contour_px "
                        "polygons, so cell masks cannot be reconstructed. "
                        "Re-run detection, or pass --labels.",
                   exit_code=4)
    return out


def detected_calibration_stats(meta: dict) -> dict:
    """Surface the µm/pixel calibration `_imageio` read out of the image file.

    `_imageio` parses a real physical pixel size from CZI / ND2 / LIF / OIF /
    OME-TIFF / ImageJ metadata into ``meta["pixel_size_um"]``, and nothing used
    to read it. Reported only — no assay behaviour depends on it.

    MIND THE RECIPROCAL: ``pixel_size_um`` is µm per pixel; this app's
    convention is PIXELS per µm, so the emitted value is ``1 / pixel_size_um``.
    Returns ``{}`` when the file carried no calibration.
    """
    try:
        px_um = float((meta or {}).get("pixel_size_um"))
    except (TypeError, ValueError):
        return {}
    if not (px_um > 0) or px_um != px_um:
        return {}
    log(f"{LOG_PREFIX} calibration in file: {1.0 / px_um:.4f} px/µm "
        f"({px_um:.6g} µm/px)")
    return {"detected_px_per_um": 1.0 / px_um,
            "detected_pixel_size_um": px_um}


def load_negative_values(spec: str):
    """Per-cell values from a real negative control, for --threshold-mode negative_sd.

    Accepts, in order:

    * an inline comma-separated list of numbers — ``"101.2,98.7,…"``;
    * a ``.npy`` array (flattened);
    * a ``.json`` file holding either a bare list of numbers, ``{"values": […]}``,
      or a payload written by a previous ``intensity_assays.py --per-cell`` run
      (any ``assays.<name>.per_cell[].value`` is picked up) — so the normal
      workflow is "run the assay on the control image, feed that JSON back in";
    * any other text file: numbers separated by commas, whitespace or newlines.

    Raises ValueError with an actionable message; never returns an empty list.
    """
    import numpy as np

    values: list[float] = []
    if os.path.exists(spec):
        ext = os.path.splitext(spec)[1].lower()
        if ext == ".npy":
            values = [float(v) for v in np.asarray(np.load(spec)).ravel()]
        elif ext == ".json":
            with open(spec, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            values = _numbers_from_json(data)
        else:
            with open(spec, "r", encoding="utf-8") as fh:
                text = fh.read()
            values = [float(tok) for tok in text.replace(",", " ").split()]
    else:
        if "," not in spec and not _looks_numeric(spec):
            raise ValueError(
                f"{spec!r} is neither an existing file nor a comma-separated "
                f"list of numbers")
        values = [float(tok) for tok in spec.replace(",", " ").split()]

    values = [v for v in values if v == v and abs(v) != float("inf")]
    if len(values) < 2:
        raise ValueError(
            "a negative control needs at least two per-cell values (ideally "
            "tens); mean + k·SD is undefined otherwise")
    return values


def _looks_numeric(tok: str) -> bool:
    try:
        float(tok.strip())
        return True
    except ValueError:
        return False


def _numbers_from_json(data) -> list[float]:
    """Pull per-cell values out of the JSON shapes documented on load_negative_values."""
    if isinstance(data, list):
        return [float(v) for v in data if isinstance(v, (int, float))]
    if not isinstance(data, dict):
        return []
    if isinstance(data.get("values"), list):
        return [float(v) for v in data["values"] if isinstance(v, (int, float))]
    out: list[float] = []
    for res in (data.get("assays") or {}).values():
        if not isinstance(res, dict):
            continue
        for row in (res.get("per_cell") or []):
            if isinstance(row, dict) and isinstance(row.get("value"), (int, float)):
                out.append(float(row["value"]))
    return out


def nuclear_mask_from_channel(labels, planes, channel: int):
    """Otsu-threshold one channel *inside the cell masks* to get nuclei."""
    import numpy as np
    import _assays_intensity as ai

    arr = ai.as_hwc(planes)
    chan = arr[:, :, int(channel)]
    inside = chan[labels > 0]
    thr = ai.otsu_threshold(inside if inside.size else chan)
    if thr is None:
        return np.zeros(chan.shape, dtype=bool)
    log(f"{LOG_PREFIX} nuclear mask from channel {channel} at Otsu={thr:.4g}")
    return (chan > thr) & (labels > 0)


# ---------------------------------------------------------------------------
# Assay dispatch.
# ---------------------------------------------------------------------------

def run_assays(args, labels, planes, channel_names, negative_values=None) -> dict:
    import _assays_intensity as ai

    cells = ai.CellPixels(labels)
    log(f"{LOG_PREFIX} {len(cells)} labelled cells; "
        f"{ai.channel_count(planes)} channels")

    results: dict = {}
    for name in args.assay:
        key = name.strip().lower().replace("-", "_")
        log(f"{LOG_PREFIX} running assay: {key}")

        if key == "marker_positive":
            results[key] = ai.marker_positive(
                labels, planes, channel=args.channel or 0, metric=args.metric,
                threshold_mode=args.threshold_mode, threshold=args.threshold,
                k=args.k, negative_values=negative_values,
                channel_names=channel_names,
                marker_name=args.marker_name, cells=cells)

        elif key == "transfection_efficiency":
            results[key] = ai.transfection_efficiency(
                labels, planes, channel=args.channel or 0, metric=args.metric,
                threshold_mode=args.threshold_mode, threshold=args.threshold,
                k=args.k, negative_values=negative_values,
                channel_names=channel_names,
                reporter_name=args.marker_name, cells=cells)

        elif key == "nuclear_cytoplasmic":
            nuc = None
            if args.nuclear_labels:
                nuc = load_label_map(args.nuclear_labels)
            elif args.nuclear_channel is not None:
                nuc = nuclear_mask_from_channel(labels, planes,
                                                args.nuclear_channel)
            if nuc is None:
                results[key] = {
                    "assay": key, "ok": False, "error": "no-nuclear-mask",
                    "message": "This assay needs a nuclear mask. Pass "
                               "--nuclear-labels, or --nuclear-channel to "
                               "derive one by thresholding the DNA channel.",
                }
            else:
                results[key] = ai.nuclear_cytoplasmic(
                    labels, planes, channel=args.channel or 0, nuclear_mask=nuc,
                    metric=args.nc_metric, channel_names=channel_names,
                    cells=cells)

        elif key == "colocalization":
            results[key] = ai.colocalization(
                labels, planes,
                channel_a=args.channel_a if args.channel_a is not None else 0,
                channel_b=args.channel_b if args.channel_b is not None else 1,
                threshold_mode=args.coloc_threshold_mode,
                threshold_a=args.threshold_a, threshold_b=args.threshold_b,
                threshold_scope=args.coloc_threshold_scope,
                channel_names=channel_names, cells=cells)

        elif key == "live_dead":
            results[key] = ai.live_dead(
                labels, planes,
                live_channel=args.live_channel if args.live_channel is not None else 0,
                dead_channel=args.dead_channel if args.dead_channel is not None else 1,
                live_threshold_mode=("manual" if args.live_threshold is not None
                                     else args.threshold_mode),
                dead_threshold_mode=("manual" if args.dead_threshold is not None
                                     else args.threshold_mode),
                live_threshold=args.live_threshold,
                dead_threshold=args.dead_threshold,
                metric=args.metric, k=args.k,
                live_negative_values=negative_values,
                dead_negative_values=negative_values,
                channel_names=channel_names,
                cells=cells)

        elif key == "cell_cycle":
            results[key] = ai.cell_cycle(
                labels, planes,
                dna_channel=args.dna_channel if args.dna_channel is not None else 0,
                bins=args.bins, gate_width=args.gate_width,
                channel_names=channel_names, cells=cells)

        else:
            results[key] = {
                "assay": key, "ok": False, "error": "unknown-assay",
                "message": f"'{name}' is not a known assay. Known assays: "
                           + ", ".join(sorted(ai.ASSAYS)) + ".",
            }

        res = results[key]
        if res.get("ok"):
            log(f"{LOG_PREFIX}   ok")
        else:
            log(f"{LOG_PREFIX}   not run: {res.get('error')} — "
                f"{res.get('message')}")

    if not args.per_cell:
        for res in results.values():
            res.pop("per_cell", None)

    return results


def main() -> None:
    args = build_parser().parse_args()
    if not args.assay:
        emit_error("no-assay-selected",
                   hint="Pass at least one --assay (marker_positive, "
                        "nuclear_cytoplasmic, colocalization, live_dead, "
                        "transfection_efficiency, cell_cycle).",
                   exit_code=2)
        return

    try:
        import numpy  # noqa: F401
    except Exception as exc:  # noqa: BLE001
        log(f"{LOG_PREFIX} import failed: {exc!r}")
        emit_error("numpy-not-installed",
                   hint="Run scripts/install_python.sh", exit_code=2)
        return

    try:
        import _assays_intensity as ai
    except Exception as exc:  # noqa: BLE001
        log(f"{LOG_PREFIX} could not import _assays_intensity: {exc!r}")
        emit_error("assay-module-missing", hint=str(exc), exit_code=2)
        return

    # Multi-channel load goes through the shared loader.
    try:
        import _imageio
    except Exception as exc:  # noqa: BLE001
        log(f"{LOG_PREFIX} could not import _imageio: {exc!r}")
        emit_error("imageio-module-missing",
                   hint="_imageio.py is required to read multi-channel images. "
                        f"({exc})",
                   exit_code=2)
        return

    log(f"{LOG_PREFIX} loading planes: {args.image} (z_project={args.z_project})")
    try:
        planes, meta = _imageio.load_planes(args.image, z_project=args.z_project)
    except Exception as exc:  # noqa: BLE001
        log(f"{LOG_PREFIX} image load failed: {exc!r}")
        emit_error("image-open-failed", hint=str(exc), exit_code=3)
        return

    meta = meta or {}
    channel_names = meta.get("channel_names")
    if args.channel_names:
        channel_names = [s.strip() for s in args.channel_names.split(",")]

    height, width = int(planes.shape[0]), int(planes.shape[1])
    n_ch = ai.channel_count(planes)
    log(f"{LOG_PREFIX} image is {width}x{height} with {n_ch} channel(s); "
        f"names={channel_names}")

    # Cell masks.
    if args.labels:
        try:
            labels = load_label_map(args.labels)
        except Exception as exc:  # noqa: BLE001
            log(f"{LOG_PREFIX} label load failed: {exc!r}")
            emit_error("labels-open-failed", hint=str(exc), exit_code=4)
            return
    elif args.detection_json:
        try:
            labels = labels_from_detection_json(args.detection_json, height, width)
        except SystemExit:
            raise
        except Exception as exc:  # noqa: BLE001
            log(f"{LOG_PREFIX} detection JSON load failed: {exc!r}")
            emit_error("detection-json-failed", hint=str(exc), exit_code=4)
            return
    else:
        emit_error("no-masks",
                   hint="Pass --labels (a label map) or --detection-json "
                        "(a previous sidecar payload with contour_px).",
                   exit_code=2)
        return

    if labels.shape[0] != height or labels.shape[1] != width:
        emit_error("shape-mismatch",
                   hint=f"The masks are {labels.shape[1]}x{labels.shape[0]} but "
                        f"the image is {width}x{height}.",
                   exit_code=4)
        return

    negative_values = None
    if args.negative_values:
        try:
            negative_values = load_negative_values(args.negative_values)
        except Exception as exc:  # noqa: BLE001
            log(f"{LOG_PREFIX} --negative-values could not be read: {exc}")
            emit_error("negative-values-unreadable", hint=str(exc), exit_code=2)
            return
        log(f"{LOG_PREFIX} negative control: {len(negative_values)} value(s)")

    results = run_assays(args, labels, planes, channel_names,
                         negative_values=negative_values)
    image_stats = ai.flatten_for_image_stats(results.values())
    image_stats.update(detected_calibration_stats(meta))

    payload = {
        "width": width,
        "height": height,
        "channel_names": channel_names,
        "assays": results,
        "image_stats": image_stats,
    }
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()
    ran = sum(1 for r in results.values() if r.get("ok"))
    log(f"{LOG_PREFIX} emitted {ran}/{len(results)} assay result(s), "
        f"{len(image_stats)} image_stats key(s)")


if __name__ == "__main__":
    main()
