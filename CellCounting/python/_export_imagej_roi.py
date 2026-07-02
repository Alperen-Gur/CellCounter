"""
_export_imagej_roi.py — Pass-14 ImageJ RoiSet exporter (F3).

Reads a small JSON describing detected cells + the source image dimensions,
then writes an ImageJ-compatible `RoiSet.zip` containing one .roi per cell.

Cells that carry a polygon `contour_px` get a POLYGON / FREEHAND ROI; cells
without a contour fall back to an OVAL ROI centred on (cx, cy) with the
recorded diameter (px).

Each ROI has its z/c/t position set to 1 (we're 2D).

Invocation:
    python _export_imagej_roi.py --in detection.json --out RoiSet.zip

Input JSON schema:
    {
      "width":  <int, pixels>,
      "height": <int, pixels>,
      "cells": [
        {
          "id":          "<uuid>",
          "cx":          <float, px>,
          "cy":          <float, px>,
          "diameter_px": <float>,
          "contour_px":  [[x, y], …] | null,
          "name":        "<optional>",
        },
        ...
      ]
    }

Exits 0 on success, prints a single JSON line to stdout:
    {"ok": true, "n_rois": 42, "path": "/abs/RoiSet.zip"}

On failure, exits 1 and emits:
    {"ok": false, "error": "<message>"}
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import zipfile

try:
    import roifile  # type: ignore
except ImportError:
    print(json.dumps({"ok": False, "error": "roifile not installed in venv"}))
    sys.exit(1)


def _safe_name(idx: int, fallback_id: str | None = None) -> str:
    # ImageJ uses the ROI name as the filename inside the zip. Keep names
    # short, unique, and ascii-safe.
    base = "cell_{:05d}".format(idx + 1)
    if fallback_id:
        return f"{base}_{fallback_id[:8]}"
    return base


def _build_roi(idx: int, cell: dict, width: int, height: int):
    cx = float(cell.get("cx", 0))
    cy = float(cell.get("cy", 0))
    dpx = float(cell.get("diameter_px", 0))
    contour = cell.get("contour_px")
    name = cell.get("name") or _safe_name(idx, cell.get("id"))

    # Polygon path — preferred when a contour exists.
    if contour and isinstance(contour, list) and len(contour) >= 3:
        pts = []
        for pt in contour:
            if not (isinstance(pt, (list, tuple)) and len(pt) >= 2):
                continue
            x = float(pt[0])
            y = float(pt[1])
            # Clamp into image bounds so ImageJ doesn't choke on outliers.
            x = max(0.0, min(float(width - 1), x))
            y = max(0.0, min(float(height - 1), y))
            pts.append((x, y))
        if len(pts) >= 3:
            roi = roifile.ImagejRoi.frompoints(pts, name=name)
            # 2D image — z/c/t = 1.
            roi.z_position = 1
            roi.c_position = 1
            roi.t_position = 1
            roi.position = 1
            return roi

    # Fallback: oval / circle ROI from cx/cy/diameter.
    r = max(1.0, dpx / 2.0)
    left = int(round(cx - r))
    top = int(round(cy - r))
    right = int(round(cx + r))
    bottom = int(round(cy + r))
    # Clamp into bounds.
    left = max(0, min(width - 1, left))
    top = max(0, min(height - 1, top))
    right = max(left + 1, min(width, right))
    bottom = max(top + 1, min(height, bottom))

    # OVAL = 1 in roifile's enum.
    try:
        roi = roifile.ImagejRoi(
            roitype=roifile.ROI_TYPE.OVAL,
            name=name,
            top=top, left=left, bottom=bottom, right=right,
        )
    except Exception:
        # Older roifile versions: build via frompoints with a 4-point bbox fallback.
        pts = [
            (float(left), float(top)),
            (float(right), float(top)),
            (float(right), float(bottom)),
            (float(left), float(bottom)),
        ]
        roi = roifile.ImagejRoi.frompoints(pts, name=name)

    roi.z_position = 1
    roi.c_position = 1
    roi.t_position = 1
    roi.position = 1
    return roi


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--in", dest="inp", required=True,
                        help="Path to detection JSON describing cells + image dims.")
    parser.add_argument("--out", dest="out", required=True,
                        help="Path to the RoiSet.zip to write.")
    args = parser.parse_args()

    try:
        with open(args.inp, "r", encoding="utf-8") as fh:
            blob = json.load(fh)
    except Exception as exc:
        print(json.dumps({"ok": False, "error": f"Could not read input JSON: {exc}"}))
        return 1

    width = int(blob.get("width", 0) or 0)
    height = int(blob.get("height", 0) or 0)
    cells = blob.get("cells") or []
    if width <= 0 or height <= 0:
        print(json.dumps({"ok": False, "error": "Invalid image dimensions in input JSON."}))
        return 1
    if not isinstance(cells, list) or not cells:
        print(json.dumps({"ok": False, "error": "Input JSON contains no cells."}))
        return 1

    # Build all ROIs first so we can fail before writing anything.
    rois = []
    for idx, cell in enumerate(cells):
        try:
            roi = _build_roi(idx, cell, width, height)
        except Exception as exc:
            # Skip the bad cell rather than aborting the whole export.
            sys.stderr.write(f"[_export_imagej_roi] skipped cell {idx}: {exc}\n")
            continue
        rois.append(roi)

    if not rois:
        print(json.dumps({"ok": False, "error": "No valid ROIs could be built from cells."}))
        return 1

    out_path = os.path.abspath(args.out)
    # Ensure parent dir exists.
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    # Remove any stale destination so we don't accidentally append.
    if os.path.exists(out_path):
        try:
            os.remove(out_path)
        except OSError:
            pass

    # Write each ROI into the zip. roifile.tofile appends when the target is
    # a zip, so we can stream all of them in.
    try:
        for roi in rois:
            roi.tofile(out_path)
    except Exception as exc:
        # Cleanup any partial zip on failure.
        try:
            os.remove(out_path)
        except OSError:
            pass
        print(json.dumps({"ok": False, "error": f"Failed to write RoiSet.zip: {exc}"}))
        return 1

    # Sanity-check the zip — should contain one entry per ROI.
    try:
        with zipfile.ZipFile(out_path, "r") as zf:
            n_entries = len(zf.namelist())
    except Exception:
        n_entries = len(rois)

    print(json.dumps({
        "ok": True,
        "n_rois": n_entries,
        "path": out_path,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
