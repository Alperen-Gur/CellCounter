"""
_tracking.py — CellCounter cell tracking / migration over time.

Exposes:

    track(frames, px_per_um, frame_interval_min, params=None) -> dict

Pure function, no file/network/subprocess I/O — matches the pattern of
`_colony.compute()` / `_watershed.split()` elsewhere in this package: given
in-memory inputs it returns a plain JSON-serialisable dict, and it NEVER
raises (see "Never raises" below). `track_cells.py` is the thin CLI/JSON
front door that calls this from a subprocess context.

Calibration convention: `px_per_um` is PIXELS PER MICROMETRE, matching
`args.pxPerUm` used by every Cellpose sidecar in this package (see
`cellpose_detect.py`'s `--pxPerUm` flag and `_cellpose_common.measure_cells`,
which both compute `um = px / px_per_um`). We deliberately use this name
(not "pixel_size_um", i.e. µm per pixel) so a value read straight out of the
app's existing calibration state can be passed through unchanged with no
risk of an inverted-units bug at the integration boundary.

`frames` is an ORDERED list, one entry per timepoint in the image series.
Each entry is one of:
  * a list of per-cell dicts, each with at least "cx" and "cy" (pixel
    coordinates — same convention as `DetectedCell.cx/cy` elsewhere in this
    codebase) and an optional "id" (any JSON scalar, carried through
    unchanged into the output "source_id" field) so a caller can cross-
    reference a track point back to the DetectedCell it came from;
  * a 2-D integer label mask (0 = background, 1..N = per-cell labels) — in
    which case per-cell centroids are computed the same way
    `_colony.compute` does (mean row/col of each label's pixels) before
    linking. This is the "masks" half of "centroids + optionally masks" in
    the feature spec: it lets a caller pass raw segmentation output straight
    through without measuring centroids itself first;
  * an empty list / None — a frame with no detections that timepoint. Valid;
    it just can't extend any track through it (no gap closing — see below).

Linking rule (consecutive frames only, no gap closing):
  For every pair of adjacent frames (t, t+1) we build a cost matrix of
  pairwise centroid distances (µm) and solve it with
  `scipy.optimize.linear_sum_assignment` — the Hungarian / linear sum
  assignment algorithm. This finds the assignment that minimises *total*
  displacement across every cell simultaneously, which is systematically
  better than a naive greedy nearest-neighbour loop: greedy can lock in an
  early convenient match that forces a much worse one later for a different
  cell; Hungarian can't, because it considers all pairings jointly.

  Candidate pairs whose distance exceeds `max_displacement_um` are set to a
  large sentinel cost before solving, so the solver avoids them whenever a
  legal alternative exists — and any pair that still comes back over
  threshold (cardinality can force a bad pairing, e.g. equal cell counts in
  both frames with every candidate over threshold) is discarded from the
  result regardless. A cell left unmatched going INTO frame t+1 starts a new
  track; a cell whose frame-t position has no continuation in t+1 simply
  stops accumulating — its track ends at frame t. This is exactly "Handle
  appearance/disappearance (unmatched cells start or end a track)" from the
  feature spec.

  We deliberately do NOT do gap closing (bridging a cell across a frame
  where it went briefly undetected). The spec calls for nearest-neighbour
  linking between CONSECUTIVE frames; gap closing needs its own tunable
  (how many frames to bridge) and its own cost model, which would expand
  scope well beyond what was asked for here.

Degenerate inputs never raise:
  * 0 or 1 frames -> returns an empty-tracks result with an explanatory
    `message` (motion is undefined for a single snapshot).
  * A frame with 0 cells is fine — see above.
  * Any unexpected exception during linking/summarisation is caught and
    reported via `message` with `tracks: []`, matching `_colony.compute`'s
    "never raises" contract elsewhere in this package.

Report shape (see `_summarize_track` / `track` for the authoritative
fields): per track — total path length (µm), net displacement (µm), mean
speed (µm/min), directionality ratio (net / path, in [0, 1]), and duration
(frames + minutes). Per series — number of tracks, mean speed, mean
directionality (see `summary`). Track paths themselves are returned in full
(`points`, one entry per frame the track was observed in, in both px and µm)
so a UI can draw them directly without re-deriving anything.

`mean_speed_um_per_min` / `mean_directionality_ratio` / `mean_track_duration_min`
in `summary` are averaged only over tracks with `duration_frames >= 1` (i.e.
tracks that were actually linked across at least one frame gap) —
a track that appeared in exactly one frame and was never linked has no
defined velocity, and folding its speed=0 into the mean would silently bias
the series-level average toward zero for reasons that have nothing to do
with how fast anything actually moved. `summary.n_tracks` still counts
every track, including these zero-duration ones, so nothing is hidden.
"""

from __future__ import annotations

import math
from typing import Any, Optional


_DEFAULT_MAX_DISPLACEMENT_UM = 50.0
# Sentinel cost for a candidate pair beyond max_displacement_um: large enough
# that the Hungarian solver only ever picks it when cardinality leaves no
# other option, small enough to stay well inside float64 range once summed
# across a whole cost matrix.
_FORBIDDEN_COST = 1.0e6


def _safe_float(value: Any, default: float) -> float:
    """`float(value)` if that yields a finite, positive number; else `default`.

    Centralises every calibration/timing cast in this module so a bad caller
    input (None, a string, 0, NaN, a negative number) degrades to a sane
    default instead of raising or silently propagating a NaN into every
    downstream µm/speed calculation.
    """
    try:
        v = float(value)
    except (TypeError, ValueError):
        return default
    if not math.isfinite(v) or v <= 0:
        return default
    return v


def _empty_result(n_frames: int, message: str, params: dict) -> dict:
    """The canonical degenerate/error result — mirrors `_colony.zero_stats()`."""
    return {
        "n_frames": n_frames,
        "tracks": [],
        "summary": {
            "n_tracks": 0,
            "n_tracks_with_motion": 0,
            "mean_speed_um_per_min": 0.0,
            "mean_directionality_ratio": 0.0,
            "mean_track_duration_min": 0.0,
        },
        "params": params,
        "message": message,
    }


def _frame_points(frame: Any) -> list[dict]:
    """Normalise one frame's detections into a list of {"cx","cy","id"} dicts.

    Accepts None/[] (empty frame), a list of cell dicts (cx/cy required, id
    optional and passed through as-is), or a 2-D integer label mask
    (centroids computed the same way `_colony.compute` does: mean row/col of
    each label's pixels — an unweighted centroid, consistent with
    `_cellpose_common.measure_cells`'s `cy = ys.mean(); cx = xs.mean()`).
    """
    if frame is None:
        return []

    # 2-D label mask: detected by duck-typing `.ndim` so this module doesn't
    # need numpy imported at module scope for callers that only ever pass
    # plain cell-dict lists. Checked BEFORE any bare `if frame`/`not frame`
    # truthiness test — numpy raises ValueError ("ambiguous truth value") on
    # exactly that for any array with more than one element.
    if hasattr(frame, "ndim") and getattr(frame, "ndim", None) == 2:
        import numpy as np

        arr = np.asarray(frame)
        label_ids = np.unique(arr)
        label_ids = label_ids[label_ids != 0]
        out: list[dict] = []
        for lab in label_ids.tolist():
            ys, xs = np.where(arr == lab)
            if ys.size == 0:
                continue
            out.append({"cx": float(xs.mean()), "cy": float(ys.mean()), "id": str(int(lab))})
        return out

    # List (or other sized sequence) of per-cell dicts. `len()` rather than a
    # bare truthiness test for the same reason as the `frame is None` check
    # above — stay safe even if a caller hands us a 1-D array-like here.
    try:
        n = len(frame)
    except TypeError:
        return []
    if n == 0:
        return []

    out = []
    for c in frame:
        try:
            cx = c.get("cx")
            cy = c.get("cy")
        except AttributeError:
            continue
        if cx is None or cy is None:
            continue
        try:
            out.append({"cx": float(cx), "cy": float(cy), "id": c.get("id")})
        except (TypeError, ValueError):
            continue
    return out


def _link_frames(prev_pts: list[dict], cur_pts: list[dict],
                  px_per_um: float, max_displacement_um: float
                  ) -> tuple[list[tuple[int, int]], list[int], list[int]]:
    """Match prev_pts[i] <-> cur_pts[j] via gated Hungarian assignment.

    Cost = centroid distance in µm. Pairs beyond `max_displacement_um` are
    biased away from (large sentinel cost) during solving and then always
    excluded from the result, even if cardinality forced the solver to use
    one anyway.

    Returns (matches, unmatched_prev_idx, unmatched_cur_idx); `matches` is a
    list of (i, j) index pairs into `prev_pts` / `cur_pts` respectively.
    """
    n, m = len(prev_pts), len(cur_pts)
    if n == 0 or m == 0:
        return [], list(range(n)), list(range(m))

    import numpy as np
    from scipy.optimize import linear_sum_assignment

    prev_xy = np.array([[p["cx"], p["cy"]] for p in prev_pts], dtype=np.float64)
    cur_xy = np.array([[p["cx"], p["cy"]] for p in cur_pts], dtype=np.float64)
    # Pairwise Euclidean distance in px, then µm. Both axes share one
    # px_per_um (isotropic calibration), matching every other µm conversion
    # in this codebase.
    diff = prev_xy[:, None, :] - cur_xy[None, :, :]
    dist_px = np.sqrt((diff ** 2).sum(axis=-1))
    dist_um = dist_px / px_per_um

    cost = np.where(dist_um > max_displacement_um, _FORBIDDEN_COST, dist_um)
    row_ind, col_ind = linear_sum_assignment(cost)

    matches: list[tuple[int, int]] = []
    matched_prev: set[int] = set()
    matched_cur: set[int] = set()
    for i, j in zip(row_ind.tolist(), col_ind.tolist()):
        if dist_um[i, j] <= max_displacement_um:
            matches.append((i, j))
            matched_prev.add(i)
            matched_cur.add(j)
        # else: cardinality forced a beyond-threshold pairing — leave both
        # ends unmatched (frame-t cell's track ends; frame-(t+1) cell starts
        # a new one) rather than accept a biologically implausible link.

    unmatched_prev = [i for i in range(n) if i not in matched_prev]
    unmatched_cur = [j for j in range(m) if j not in matched_cur]
    return matches, unmatched_prev, unmatched_cur


def _point_record(p: dict, frame_idx: int, px_per_um: float) -> dict:
    return {
        "frame": frame_idx,
        "x_px": p["cx"],
        "y_px": p["cy"],
        "x_um": p["cx"] / px_per_um,
        "y_um": p["cy"] / px_per_um,
        "source_id": p.get("id"),
    }


def _summarize_track(track_id: int, points: list[dict], frame_interval_min: float) -> dict:
    """Per-track metrics from its ordered list of `_point_record` dicts."""
    n = len(points)
    start_frame = points[0]["frame"]
    end_frame = points[-1]["frame"]
    duration_frames = end_frame - start_frame
    duration_min = duration_frames * frame_interval_min

    path_um = 0.0
    for k in range(1, n):
        dx = points[k]["x_um"] - points[k - 1]["x_um"]
        dy = points[k]["y_um"] - points[k - 1]["y_um"]
        path_um += math.hypot(dx, dy)

    net_um = math.hypot(points[-1]["x_um"] - points[0]["x_um"],
                         points[-1]["y_um"] - points[0]["y_um"])

    speed = (path_um / duration_min) if duration_min > 0 else 0.0
    directionality = (net_um / path_um) if path_um > 0 else 0.0
    # Clamp for float noise only (a perfectly straight track can round to
    # 1.0000000000000002 depending on summation order).
    directionality = min(1.0, max(0.0, directionality))

    return {
        "track_id": track_id,
        "start_frame": start_frame,
        "end_frame": end_frame,
        "duration_frames": duration_frames,
        "duration_min": duration_min,
        "total_path_length_um": path_um,
        "net_displacement_um": net_um,
        "mean_speed_um_per_min": speed,
        "directionality_ratio": directionality,
        "points": points,
    }


def track(frames: Any, px_per_um: float, frame_interval_min: float,
          params: dict | None = None) -> dict:
    """Link detections across an ordered image series. See module docstring.

    Parameters
    ----------
    frames : sequence
        Ordered per-frame detections — see module docstring for the accepted
        shapes (list-of-cell-dicts, a 2-D label mask, or an empty frame).
    px_per_um : float
        Pixels per micrometre (this app's calibration convention).
    frame_interval_min : float
        Minutes between consecutive frames. Pass `seconds / 60.0` if your
        acquisition interval is recorded in seconds.
    params : dict, optional
        "max_displacement_um" (float, default 50.0) — maximum centroid
        displacement allowed between consecutive frames for two detections
        to be linked into the same track. User-settable per the feature
        spec; exposed here rather than hardcoded so the UI can surface it as
        a slider/field.

    Returns
    -------
    dict — never raises. See module docstring for the full schema.
    """
    params = dict(params or {})
    pxu = _safe_float(px_per_um, 1.0)
    fi_min = _safe_float(frame_interval_min, 1.0)
    max_displacement_um = _safe_float(params.get("max_displacement_um"),
                                       _DEFAULT_MAX_DISPLACEMENT_UM)
    out_params = {
        "px_per_um": pxu,
        "frame_interval_min": fi_min,
        "max_displacement_um": max_displacement_um,
    }

    # `_safe_float` silently substitutes 1.0 for a non-positive/unparseable
    # calibration, and every speed in µm/min is scaled by BOTH of these — a
    # frame_interval_min of 0 turned a true 1.0 µm/min into a reported 10.0
    # with nothing in the output to say so. Record the substitution; the caller
    # decides whether to refuse (track_cells.py does, up front).
    substitutions: list[str] = []
    if _safe_float(px_per_um, -1.0) < 0:
        substitutions.append(
            f"px_per_um={px_per_um!r} is not a positive number, so 1.0 "
            f"pixel/µm was assumed — every distance and speed below is in "
            f"PIXELS per minute, not µm per minute")
    if _safe_float(frame_interval_min, -1.0) < 0:
        substitutions.append(
            f"frame_interval_min={frame_interval_min!r} is not a positive "
            f"number, so 1.0 minute per frame was assumed — every speed below "
            f"is per FRAME, not per minute")
    substitution_note = (
        "Calibration was substituted: " + "; ".join(substitutions) + "."
        if substitutions else None)
    out_params["calibration_substituted"] = bool(substitutions)

    def _message(text: Optional[str]) -> Optional[str]:
        """Merge the calibration note (if any) into a result message."""
        if substitution_note and text:
            return f"{substitution_note} {text}"
        return substitution_note or text

    try:
        # `is not None` rather than a bare truthiness test: `frames` could in
        # principle be a numpy array (e.g. a caller passing a raw (T,H,W)
        # mask stack instead of a python list), and numpy raises ValueError
        # ("ambiguous truth value") on `if frames` for anything with more
        # than one element.
        n_frames = len(frames) if frames is not None else 0
    except TypeError:
        return _empty_result(
            0, _message("`frames` is not a sequence — no tracks computed."),
            out_params)

    if n_frames == 0:
        return _empty_result(
            0, _message("No image series provided — nothing to track."),
            out_params)
    if n_frames == 1:
        return _empty_result(
            1,
            _message("Only one frame provided — cell tracking requires at least "
                     "two frames in the series to link any motion. No tracks "
                     "were computed."),
            out_params,
        )

    try:
        norm_frames = [_frame_points(f) for f in frames]

        tracks: dict[int, dict] = {}
        next_id = 0

        prev_pts = norm_frames[0]
        prev_track_ids: list[int] = []
        for p in prev_pts:
            tid = next_id
            next_id += 1
            tracks[tid] = {"points": [_point_record(p, 0, pxu)]}
            prev_track_ids.append(tid)

        for t in range(1, n_frames):
            cur_pts = norm_frames[t]
            matches, unmatched_prev, unmatched_cur = _link_frames(
                prev_pts, cur_pts, pxu, max_displacement_um)

            cur_track_ids: list[int | None] = [None] * len(cur_pts)
            for i, j in matches:
                tid = prev_track_ids[i]
                tracks[tid]["points"].append(_point_record(cur_pts[j], t, pxu))
                cur_track_ids[j] = tid
            for j in unmatched_cur:
                tid = next_id
                next_id += 1
                tracks[tid] = {"points": [_point_record(cur_pts[j], t, pxu)]}
                cur_track_ids[j] = tid
            # unmatched_prev entries simply stop accumulating — their track
            # already ended at frame t-1 in the output below.

            prev_pts = cur_pts
            prev_track_ids = cur_track_ids

        out_tracks = [_summarize_track(tid, tracks[tid]["points"], fi_min)
                      for tid in sorted(tracks.keys())]

        moving = [tr for tr in out_tracks if tr["duration_frames"] >= 1]
        n_tracks = len(out_tracks)
        n_moving = len(moving)
        mean_speed = (sum(tr["mean_speed_um_per_min"] for tr in moving) / n_moving) if n_moving else 0.0
        mean_dir = (sum(tr["directionality_ratio"] for tr in moving) / n_moving) if n_moving else 0.0
        mean_dur = (sum(tr["duration_min"] for tr in moving) / n_moving) if n_moving else 0.0

        return {
            "n_frames": n_frames,
            "tracks": out_tracks,
            "summary": {
                "n_tracks": n_tracks,
                "n_tracks_with_motion": n_moving,
                "mean_speed_um_per_min": mean_speed,
                "mean_directionality_ratio": mean_dir,
                "mean_track_duration_min": mean_dur,
            },
            "params": out_params,
            "message": _message(None),
        }
    except Exception as exc:  # noqa: BLE001 — pure function must never raise.
        return _empty_result(n_frames,
                             _message(f"Tracking failed (non-fatal): {exc!r}"),
                             out_params)
