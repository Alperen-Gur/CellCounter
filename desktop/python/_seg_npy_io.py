#!/usr/bin/env python3
"""
_seg_npy_io.py — CellCounter <-> Cellpose GUI ``_seg.npy`` round-trip helper.

The Cellpose GUI stores its segmentation next to an image as ``<stem>_seg.npy``:
a pickled ``dict`` written with ``np.save(path, dict, allow_pickle=True)``. The
one field every Cellpose version writes is a HxW integer **label map** under the
key ``"masks"`` (0 = background, 1..N = cell ids); the GUI additionally persists
an ``"outlines"`` label map, ``"filename"``, ``"ismanual"``, ``"diameter"``,
``"chan_choose"``, ``"colors"``, and (for the *_seg.npy the GUI itself loads)
``"img"`` / ``"flows"``. See cellpose ``io.masks_flows_to_seg`` /
``io._save_seg`` for the canonical writer.

This helper bridges that format to CellCounter's cell vocabulary (the
``SidecarPayload`` schema documented in ``cellpose_detect.py``) so masks can move
losslessly in both directions — the train-from-GUI seam (ARCHITECTURE.md §3.5)
depends on this staying lossless.

Two subcommands, invoked by ``detection/seg_npy.rs`` from the same uv venv:

    python _seg_npy_io.py import --image <img> --npy <seg.npy> --pxPerUm <f> \
        [--small-threshold <f>] [--large-threshold <f>]
        -> stdout: {"width","height","cells":[…],"image_stats":{}}   (SidecarPayload)

    python _seg_npy_io.py export --cells <cells.json> --out <out_seg.npy> \
        [--image <img>]
        -> stdout: {"ok": true, "path": "<abs>", "n_cells": <int>}

On any failure both subcommands print a single structured JSON line to stdout
    {"error": "<code>", "hint": "<detail>"}
and exit non-zero (mirrors ``_cellpose_common.emit_error`` so the Rust host can
surface it as a ``sidecarFailed``).

**Import** reuses ``_cellpose_common.measure_cells`` verbatim — the SAME per-cell
measurement loop (area/diameter/contour/QC flags/size-class) the live detector
runs — so a mask imported from the GUI is measured identically to one Cellpose
produced in-app. We do NOT re-implement that kernel logic here.

**Export** rasterizes each cell back into an integer label map:
  * a cell with a ``contour_px`` polygon (>= 3 pts) is filled as that polygon;
  * a cell without a contour is filled as a filled circle of the recorded
    ``diameter_px`` centred on ``(cx, cy)``.
Later cells win overlaps (drawn in order, higher label = later), so the label
map stays 1..N contiguous and every kept cell is representable. ``outlines`` is
regenerated from the label map with cellpose's own ``masks_to_outlines`` when
available (a boundary-trace fallback keeps us self-contained otherwise), so the
written file opens cleanly in the Cellpose GUI.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

# Local helpers (_cellpose_common, _preprocessing, …) must be importable whether
# launched from the staged python dir or in-tree — same shim the detect scripts use.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


# ---------------------------------------------------------------------------
# stderr logging + structured error (stdout is reserved for the JSON result).
# Kept independent of _cellpose_common so an --export that never imports numpy
# still logs/errers consistently; import path re-uses cc.log once loaded.
# ---------------------------------------------------------------------------

def log(*args, **kwargs) -> None:
    print(*args, file=sys.stderr, **kwargs)


def emit_error(error: str, hint: str = "", exit_code: int = 2) -> None:
    payload: dict = {"error": error}
    if hint:
        payload["hint"] = hint
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()
    sys.exit(exit_code)


# ---------------------------------------------------------------------------
# Loading a Cellpose _seg.npy — tolerant of the several shapes it ships in.
# ---------------------------------------------------------------------------

def load_seg_masks(npy_path: str):
    """Return the HxW int label map from a Cellpose ``_seg.npy``.

    The file is normally a 0-d object array wrapping a ``dict`` (``masks`` key).
    We also accept: a bare 2-D int array saved as ``*_seg.npy``, and the rare
    case where ``np.load`` yields the dict directly. Never raises — calls
    ``emit_error`` and exits on anything unreadable.
    """
    import numpy as np

    if not os.path.exists(npy_path):
        emit_error("seg-npy-not-found", hint=npy_path, exit_code=3)

    try:
        raw = np.load(npy_path, allow_pickle=True)
    except Exception as exc:  # noqa: BLE001
        emit_error("seg-npy-unreadable", hint=f"{exc!r}", exit_code=3)
        return None  # unreachable; keeps type-checkers happy

    dat = raw
    # 0-d object array wrapping the dict → unwrap with .item().
    if isinstance(dat, np.ndarray) and dat.dtype == object and dat.shape == ():
        try:
            dat = dat.item()
        except Exception:  # noqa: BLE001
            pass

    masks = None
    if isinstance(dat, dict):
        masks = dat.get("masks")
        if masks is None:
            # Some exports nest under "outlines" only; reconstruct labels from it.
            outlines = dat.get("outlines")
            if outlines is not None:
                masks = _labels_from_outlines(np.asarray(outlines))
    elif isinstance(dat, np.ndarray) and dat.ndim == 2:
        # A bare label map saved directly as _seg.npy.
        masks = dat

    if masks is None:
        emit_error(
            "seg-npy-no-masks",
            hint="file has neither a 'masks' label map nor reconstructable 'outlines'",
            exit_code=4,
        )

    masks = np.asarray(masks)
    if masks.ndim != 2:
        # A stack (Z or channel) — collapse to the first plane; CellCounter is 2-D.
        log(f"[seg_npy_io] masks ndim={masks.ndim}; using first 2-D plane")
        masks = masks[tuple(0 for _ in range(masks.ndim - 2))]

    # Cellpose label maps are non-negative ints; coerce so regionprops is happy.
    if not np.issubdtype(masks.dtype, np.integer):
        masks = np.rint(masks).astype(np.int32)
    else:
        masks = masks.astype(np.int32, copy=False)
    masks[masks < 0] = 0
    return masks


def _labels_from_outlines(outlines):
    """Best-effort reconstruction of a label map from a Cellpose outline map.

    Cellpose ``outlines`` mark boundary pixels with the cell id (or 1). If the
    outline pixels already carry per-cell ids we fill each id's interior;
    otherwise we connected-component the closed contours. Never raises.
    """
    import numpy as np

    out = np.asarray(outlines)
    if out.ndim != 2:
        return None
    try:
        from scipy import ndimage as ndi

        ids = np.unique(out)
        ids = ids[ids != 0]
        # If the outline map has many distinct ids it is already per-cell labelled;
        # fill each id's convex-ish interior via binary_fill_holes on that id's ring.
        if ids.size > 1:
            labels = np.zeros(out.shape, dtype=np.int32)
            for i in ids:
                ring = out == i
                filled = ndi.binary_fill_holes(ring)
                labels[filled] = int(i)
            return labels
        # Single-id (all boundaries == same value): fill holes then label components.
        filled = ndi.binary_fill_holes(out > 0)
        labels, _ = ndi.label(filled)
        return labels.astype(np.int32)
    except Exception as exc:  # noqa: BLE001
        log(f"[seg_npy_io] could not reconstruct labels from outlines: {exc!r}")
        return None


# ---------------------------------------------------------------------------
# IMPORT: _seg.npy  ->  SidecarPayload (cells)
# ---------------------------------------------------------------------------

def cmd_import(args) -> None:
    import numpy as np  # noqa: F401  (used indirectly by cc + load)
    import _cellpose_common as cc

    masks = load_seg_masks(args.npy)
    height_px, width_px = int(masks.shape[0]), int(masks.shape[1])
    log(f"[seg_npy_io] imported label map {width_px}x{height_px} from {args.npy}")

    # Intensity measurements want the source image; if it's readable we load it
    # exactly as the detector would (grayscale by default). If not, we synthesise
    # a mid-gray plane so measure_cells still yields geometry (intensity fields
    # simply become uninformative, never wrong).
    img = None
    if args.image and os.path.exists(args.image):
        try:
            from PIL import Image

            pil = Image.open(args.image)
            pil.load()
            img = np.array(pil.convert("L"), dtype=np.uint8)
            if img.shape[:2] != masks.shape[:2]:
                log(
                    f"[seg_npy_io] image {img.shape[:2]} != masks {masks.shape[:2]}; "
                    "measuring geometry against the mask grid"
                )
                img = None
        except Exception as exc:  # noqa: BLE001
            log(f"[seg_npy_io] could not open source image: {exc!r}")
            img = None
    if img is None:
        img = np.full((height_px, width_px), 128, dtype=np.uint8)

    # Reuse the SAME measurement loop the live sidecar uses — no re-implementation.
    # measure_cells reads pxPerUm / small_threshold / large_threshold off args.
    cells = cc.measure_cells(masks, img, args, flows=None)

    # Masks imported from the GUI are human-authored segmentations: mark them
    # manual so the train seam can tell them apart from raw model output, and
    # give them full confidence (there is no cellprob map to derive one from).
    for c in cells:
        c["is_manual"] = True
        c["confidence"] = 1.0

    payload = {
        "width": width_px,
        "height": height_px,
        "cells": cells,
        "image_stats": {},
    }
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()
    log(f"[seg_npy_io] import emitted {len(cells)} cells")


# ---------------------------------------------------------------------------
# EXPORT: cells (JSON)  ->  _seg.npy  (label map + outlines, Cellpose-compatible)
# ---------------------------------------------------------------------------

def _fill_polygon(labels, contour, label_value: int) -> bool:
    """Rasterize a polygon (list of [x, y]) into ``labels`` with ``label_value``.

    Uses skimage.draw.polygon when available (exact, fast); falls back to a
    scanline fill so the helper is self-contained if skimage draw is missing.
    Returns True if any pixel was written.
    """
    import numpy as np

    H, W = labels.shape
    xs = [float(p[0]) for p in contour if len(p) >= 2]
    ys = [float(p[1]) for p in contour if len(p) >= 2]
    if len(xs) < 3:
        return False

    try:
        from skimage.draw import polygon as sk_polygon

        rr, cc_ = sk_polygon(np.asarray(ys), np.asarray(xs), shape=(H, W))
        if rr.size == 0:
            return False
        labels[rr, cc_] = label_value
        return True
    except Exception:  # noqa: BLE001
        pass

    # Scanline fallback (even-odd rule).
    wrote = False
    y_min = max(0, int(math.floor(min(ys))))
    y_max = min(H - 1, int(math.ceil(max(ys))))
    n = len(xs)
    for y in range(y_min, y_max + 1):
        yc = y + 0.5
        nodes = []
        j = n - 1
        for i in range(n):
            yi, yj = ys[i], ys[j]
            if (yi < yc <= yj) or (yj < yc <= yi):
                t = (yc - yi) / (yj - yi)
                nodes.append(xs[i] + t * (xs[j] - xs[i]))
            j = i
        nodes.sort()
        for k in range(0, len(nodes) - 1, 2):
            x0 = max(0, int(math.ceil(nodes[k] - 0.5)))
            x1 = min(W - 1, int(math.floor(nodes[k + 1] - 0.5)))
            if x1 >= x0:
                labels[y, x0:x1 + 1] = label_value
                wrote = True
    return wrote


def _fill_disc(labels, cx: float, cy: float, diameter_px: float, label_value: int) -> bool:
    """Rasterize a filled circle into ``labels``. Returns True if any pixel set."""
    import numpy as np

    H, W = labels.shape
    r = max(1.0, float(diameter_px) / 2.0)
    y0 = max(0, int(math.floor(cy - r)))
    y1 = min(H - 1, int(math.ceil(cy + r)))
    x0 = max(0, int(math.floor(cx - r)))
    x1 = min(W - 1, int(math.ceil(cx + r)))
    if y1 < y0 or x1 < x0:
        return False
    ys = np.arange(y0, y1 + 1).reshape(-1, 1)
    xs = np.arange(x0, x1 + 1).reshape(1, -1)
    disc = (xs - cx) ** 2 + (ys - cy) ** 2 <= r * r
    if not disc.any():
        # Sub-pixel cell: at least stamp the nearest pixel so the cell survives.
        iy = min(H - 1, max(0, int(round(cy))))
        ix = min(W - 1, max(0, int(round(cx))))
        labels[iy, ix] = label_value
        return True
    labels[y0:y1 + 1, x0:x1 + 1][disc] = label_value
    return True


def masks_to_outlines(masks):
    """HxW label map -> HxW outline map (boundary pixels carry the cell id).

    Prefers cellpose's own ``utils.masks_to_outlines`` so the written file is
    byte-compatible with what the GUI expects; falls back to an erosion-based
    boundary trace (same definition: a pixel whose 4-neighbourhood leaves its
    label) when cellpose isn't importable.
    """
    import numpy as np

    masks = np.asarray(masks)
    try:
        from cellpose.utils import masks_to_outlines as cp_m2o

        outl_bool = cp_m2o(masks)  # bool HxW, True on boundaries
        outlines = np.zeros_like(masks, dtype=np.int32)
        outlines[outl_bool] = masks[outl_bool].astype(np.int32)
        return outlines
    except Exception as exc:  # noqa: BLE001
        log(f"[seg_npy_io] cellpose masks_to_outlines unavailable ({exc!r}); "
            "using boundary-trace fallback")

    # Fallback: a labelled pixel is a boundary if any 4-neighbour differs.
    outlines = np.zeros_like(masks, dtype=np.int32)
    lab = masks
    diff = np.zeros(lab.shape, dtype=bool)
    diff[:-1, :] |= lab[:-1, :] != lab[1:, :]
    diff[1:, :] |= lab[1:, :] != lab[:-1, :]
    diff[:, :-1] |= lab[:, :-1] != lab[:, 1:]
    diff[:, 1:] |= lab[:, 1:] != lab[:, :-1]
    boundary = diff & (lab > 0)
    outlines[boundary] = lab[boundary]
    return outlines


def outlines_list(masks):
    """Per-cell outline coordinate list, as the Cellpose GUI stores in ``outlines``
    for some versions. Prefers ``cellpose.utils.outlines_list``; returns [] on
    failure (the scalar ``outlines`` label map above is the load-bearing field)."""
    try:
        from cellpose.utils import outlines_list as cp_ol

        return cp_ol(masks)
    except Exception:  # noqa: BLE001
        return []


def cmd_export(args) -> None:
    import numpy as np

    try:
        with open(args.cells, "r", encoding="utf-8") as fh:
            blob = json.load(fh)
    except Exception as exc:  # noqa: BLE001
        emit_error("cells-json-unreadable", hint=f"{exc!r}", exit_code=3)
        return

    cells = blob.get("cells") or []
    width = int(blob.get("width", 0) or 0)
    height = int(blob.get("height", 0) or 0)

    # Fall back to the source image for dimensions if the JSON omitted them.
    if (width <= 0 or height <= 0) and args.image and os.path.exists(args.image):
        try:
            from PIL import Image

            with Image.open(args.image) as pil:
                width, height = int(pil.width), int(pil.height)
        except Exception as exc:  # noqa: BLE001
            log(f"[seg_npy_io] could not read image dims: {exc!r}")

    if width <= 0 or height <= 0:
        emit_error(
            "export-bad-dimensions",
            hint="need width+height in cells JSON or a readable --image",
            exit_code=4,
        )
        return

    # Rasterize cells into a contiguous 1..N label map. Draw in list order so a
    # later cell wins an overlap; this keeps every cell representable and the ids
    # dense (== the number of kept cells) for a clean GUI load + train set.
    labels = np.zeros((height, width), dtype=np.int32)
    next_label = 1
    for cell in cells:
        try:
            contour = cell.get("contour_px")
            wrote = False
            if isinstance(contour, list) and len(contour) >= 3:
                wrote = _fill_polygon(labels, contour, next_label)
            if not wrote:
                cx = float(cell.get("cx", 0.0))
                cy = float(cell.get("cy", 0.0))
                dpx = float(cell.get("diameter_px", 0.0) or 0.0)
                if dpx <= 0.0:
                    # Derive px from µm if the caller only sent diameter_um.
                    d_um = float(cell.get("diameter_um", 0.0) or 0.0)
                    ppu = float(cell.get("_px_per_um", 0.0) or 0.0)
                    dpx = d_um * ppu if (d_um > 0 and ppu > 0) else 6.0
                wrote = _fill_disc(labels, cx, cy, dpx, next_label)
            if wrote:
                next_label += 1
        except Exception as exc:  # noqa: BLE001
            log(f"[seg_npy_io] skipped a cell during rasterize: {exc!r}")

    n_cells = int(next_label - 1)
    if n_cells == 0:
        log("[seg_npy_io] warning: export produced an empty label map (no cells)")

    outlines = masks_to_outlines(labels)

    # Build the Cellpose GUI dict. We populate every field a fresh GUI load reads;
    # the two load-bearing ones are 'masks' + 'outlines'. 'ismanual' marks each
    # cell hand-corrected (these came out of CellCounter's editor / import).
    seg: dict = {
        "masks": labels.astype(np.uint16 if n_cells < 65535 else np.int32),
        "outlines": outlines.astype(np.uint16 if n_cells < 65535 else np.int32),
        "outlines_list": outlines_list(labels),
        "filename": os.path.abspath(args.image) if args.image else "",
        "ismanual": np.ones(n_cells, dtype=bool),
        "manual_changes": [],
        "chan_choose": [0, 0],
        "colors": _random_colors(n_cells),
        "diameter": _median_diameter(labels, n_cells),
        "est_diam": _median_diameter(labels, n_cells),
    }

    # Optionally embed the source image + a zeroed flows placeholder so the file
    # is a fully self-contained GUI session (matches io._save_seg's shape).
    if args.image and os.path.exists(args.image):
        try:
            from PIL import Image

            pil = Image.open(args.image)
            pil.load()
            arr = np.array(pil.convert("RGB"), dtype=np.uint8)
            if arr.shape[:2] == (height, width):
                seg["img"] = arr
        except Exception as exc:  # noqa: BLE001
            log(f"[seg_npy_io] could not embed source image: {exc!r}")

    out_path = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    # Cellpose convention: the file is named "<image-stem>_seg.npy". We honour an
    # explicit --out but nudge toward the convention if the caller passed a dir.
    if os.path.isdir(out_path):
        stem = (
            os.path.splitext(os.path.basename(args.image))[0]
            if args.image else "cellcounter"
        )
        out_path = os.path.join(out_path, f"{stem}_seg.npy")

    try:
        np.save(out_path, seg, allow_pickle=True)
    except Exception as exc:  # noqa: BLE001
        emit_error("seg-npy-write-failed", hint=f"{exc!r}", exit_code=5)
        return

    sys.stdout.write(json.dumps({"ok": True, "path": out_path, "n_cells": n_cells}))
    sys.stdout.flush()
    log(f"[seg_npy_io] export wrote {n_cells} cells -> {out_path}")


def _median_diameter(labels, n_cells: int) -> float:
    """Median equivalent-circle diameter (px) over the label map — the GUI's
    'diameter' hint. Returns 0.0 for an empty map."""
    import numpy as np

    if n_cells <= 0:
        return 0.0
    ids, counts = np.unique(labels, return_counts=True)
    keep = ids != 0
    areas = counts[keep].astype(np.float64)
    if areas.size == 0:
        return 0.0
    diams = 2.0 * np.sqrt(areas / math.pi)
    return float(np.median(diams))


def _random_colors(n: int):
    """Deterministic per-cell RGB colour table (Nx3 uint8) the GUI expects.
    Deterministic (seeded) so re-exporting the same cells is byte-stable."""
    import numpy as np

    if n <= 0:
        return np.zeros((0, 3), dtype=np.uint8)
    rng = np.random.default_rng(0)
    return rng.integers(0, 256, size=(n, 3), dtype=np.uint8)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="CellCounter <-> Cellpose _seg.npy round-trip helper."
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    imp = sub.add_parser("import", help="Import a Cellpose _seg.npy into cells.")
    imp.add_argument("--image", default=None,
                     help="Source image path (for intensity measurements).")
    imp.add_argument("--npy", required=True, help="Path to the *_seg.npy file.")
    imp.add_argument("--pxPerUm", type=float, required=True,
                     help="Pixels per micrometer (converts px diameter to µm).")
    imp.add_argument("--small-threshold", dest="small_threshold", type=float,
                     default=20, help="Small-cell diameter threshold (µm).")
    imp.add_argument("--large-threshold", dest="large_threshold", type=float,
                     default=30, help="Large-cell diameter threshold (µm).")

    exp = sub.add_parser("export", help="Export cells to a Cellpose _seg.npy.")
    exp.add_argument("--cells", required=True,
                     help="Path to a JSON file: {width,height,cells:[…]}.")
    exp.add_argument("--out", required=True, help="Output *_seg.npy path (or dir).")
    exp.add_argument("--image", default=None,
                     help="Source image path (embedded + used for dimensions).")
    return p


def main() -> None:
    args = build_parser().parse_args()

    # numpy is required for both paths; fail with the same structured error the
    # detector uses so the Rust host maps it to sidecarFailed.
    try:
        import numpy  # noqa: F401
    except Exception as exc:  # noqa: BLE001
        emit_error("numpy-not-installed", hint=f"{exc!r}", exit_code=2)

    if args.cmd == "import":
        cmd_import(args)
    elif args.cmd == "export":
        cmd_export(args)
    else:  # argparse(required=True) already guards this.
        emit_error("unknown-subcommand", hint=str(args.cmd), exit_code=2)


if __name__ == "__main__":
    main()
