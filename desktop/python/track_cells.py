#!/usr/bin/env python3
"""
track_cells.py — CellCounter sidecar entry point for cell tracking / migration.

Thin CLI wrapper around `_tracking.track()`. Reads an ordered image series'
per-frame detections from a JSON file, prints ONE JSON object to stdout with
the tracking result. All progress/log output goes to stderr so stdout stays
parseable by a Swift host — the same convention every other sidecar in this
package uses (see `cellpose_detect.py` / `_cellpose_common.py`).

This script is intentionally self-contained: it does NOT import
`_cellpose_common`, which is scoped ("Shared helpers for the Cellpose 3.x
and 4.x sidecars") to the two detection sidecars. The whole point of
`_tracking.track()` is that it is a pure, dependency-light function callable
on its own with no cellpose-specific argparse baggage; this wrapper just
gives it a CLI/JSON front door for a future SidecarProcessRunner
integration, duplicating the ~10-line log/emit_error idiom locally instead.

Input JSON contract (--input path):
  {
    "frames": [
      [ {"cx": 12.3, "cy": 45.6, "id": "<any JSON scalar, optional>"}, … ],
      … one entry per ordered timepoint, in acquisition order …
    ]
  }
  An empty list `[]` for a given frame means "no cells detected that
  timepoint" — perfectly valid, it just can't extend a track through it.

Output JSON: see `_tracking.py`'s module docstring for the full schema
(`tracks`, `summary`, `params`, `message`).

Exit codes: 0 on success — INCLUDING the "degenerate input" branches (a
single-frame series, or a series with zero linkable cells), which are
reported through the `message` field, not a failure exit code: those are
normal, expected inputs, not errors. Exit 2 on a malformed --input file (bad
JSON / wrong shape) or missing required arguments.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _tracking  # noqa: E402


def log(*args, **kwargs) -> None:
    """Stderr logger — stdout is reserved for the final JSON result."""
    print(*args, file=sys.stderr, **kwargs)


def emit_error(error: str, hint: str = "", exit_code: int = 2) -> None:
    """Write a structured error JSON to stdout and exit (mirrors _cellpose_common.emit_error)."""
    payload: dict = {"error": error}
    if hint:
        payload["hint"] = hint
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()
    sys.exit(exit_code)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Cell tracking / migration sidecar for CellCounter.")
    p.add_argument("--input", required=True,
                   help='Path to a JSON file shaped {"frames": [...]} — see '
                        "module docstring.")
    p.add_argument("--px-per-um", dest="px_per_um", type=float, required=True,
                   help="Pixels per micrometer (same calibration used for "
                        "detection). Converts every centroid to µm.")
    p.add_argument("--frame-interval-min", dest="frame_interval_min",
                   type=float, required=True,
                   help="Minutes between consecutive frames. If your "
                        "acquisition interval is in seconds, pass seconds/60.")
    p.add_argument("--max-displacement-um", dest="max_displacement_um",
                   type=float, default=50.0,
                   help="Maximum centroid displacement (µm) allowed between "
                        "consecutive frames for two detections to be linked "
                        "into the same track. Default 50.0.")
    return p.parse_args()


def main() -> None:
    args = parse_args()

    # Every reported speed is (pixels / px_per_um) / frame_interval_min, so a
    # non-positive value for either silently rescales the whole result:
    # `_tracking._safe_float` substitutes 1.0, and a true 1.0 µm/min came back
    # as 10.0 with nothing in the JSON saying so. Both are required
    # calibrations, so refuse rather than substitute.
    for flag, value in (("--px-per-um", args.px_per_um),
                        ("--frame-interval-min", args.frame_interval_min)):
        if not (value > 0) or value != value:  # non-positive or NaN
            log(f"[track_cells] {flag}={value!r} is not a positive number")
            emit_error(
                "invalid-calibration",
                hint=(f"{flag} must be greater than zero (got {value!r}). "
                      f"Every speed is scaled by it, so a zero/negative value "
                      f"would be silently substituted with 1.0 and every "
                      f"µm/min figure would be wrong by that factor."),
                exit_code=2)
            return

    log(f"[track_cells] reading frames from {args.input}")
    try:
        with open(args.input, "r", encoding="utf-8") as fh:
            payload = json.load(fh)
    except Exception as exc:  # noqa: BLE001
        log(f"[track_cells] could not read --input: {exc!r}")
        emit_error("input-read-failed", hint=str(exc), exit_code=2)
        return

    frames = payload.get("frames") if isinstance(payload, dict) else None
    if frames is None:
        log('[track_cells] --input JSON missing a top-level "frames" list')
        emit_error("input-malformed", hint='expected {"frames": [...]}', exit_code=2)
        return

    log(f"[track_cells] {len(frames)} frame(s); px_per_um={args.px_per_um} "
        f"frame_interval_min={args.frame_interval_min} "
        f"max_displacement_um={args.max_displacement_um}")

    result = _tracking.track(
        frames,
        px_per_um=args.px_per_um,
        frame_interval_min=args.frame_interval_min,
        params={"max_displacement_um": args.max_displacement_um},
    )

    n_tracks = result.get("summary", {}).get("n_tracks", 0)
    note = f"; {result['message']}" if result.get("message") else ""
    log(f"[track_cells] done — {n_tracks} track(s){note}")

    sys.stdout.write(json.dumps(result))
    sys.stdout.flush()


if __name__ == "__main__":
    main()
