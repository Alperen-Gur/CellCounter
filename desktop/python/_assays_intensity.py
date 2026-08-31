"""
_assays_intensity.py — intensity-based assays over already-segmented cells.

These are **post-processing** functions, not segmentation. Every public entry
point takes a label map (0 = background, 1..N = cell labels) plus a
multi-channel image array and returns a plain dict. Nothing here opens files,
imports a detector, or touches argparse — so each assay is directly unit
testable with a synthetic array (see the docstring examples).

Six assays, all derived from per-cell channel intensity:

    1. marker_positive(...)          % Ki67+ / EdU+ / BrdU+ / cCasp3+ …
    2. nuclear_cytoplasmic(...)      per-cell N:C intensity ratio
    3. colocalization(...)           Pearson r + Manders M1/M2 (per-cell + image)
    4. live_dead(...)                two-channel viability, % viable
    5. transfection_efficiency(...)  thin, named preset over (1)
    6. cell_cycle(...)               G1/S/G2-M estimate from DNA content

Channel array contract (matches `_imageio.load_planes`):

    planes: np.ndarray, shape (H, W, C), float32
    meta:   {"channel_names", "pixel_size_um", "z_count", "t_count",
             "source_format"}

`channel_names` is optional everywhere — pass it through and the result dicts
carry human-readable names; omit it and they carry ``None``.

Result-shape conventions
------------------------
Every assay returns a dict with at least::

    {"assay": "<name>", "ok": True|False, ...}

On a precondition failure (not enough channels, channel index out of range,
no cells) the dict is ``{"assay": …, "ok": False, "error": "<slug>",
"message": "<human sentence>"}`` — **nothing raises**. Callers can render the
message directly.

`flatten_for_image_stats(results)` collapses one or more assay dicts into the
flat ``{str: float}`` namespace that `_cellpose_common.emit_payload` already
uses for ``image_stats`` (focus_score, confluency_pct, …), so assay scalars
ride the existing Swift decode path with no schema change. Every key is
prefixed ``assay_``.

Honesty notes
-------------
* The cell-cycle assay is a **peak-and-gate estimate**, not a Watson /
  Dean-Jett-Fox deconvolution. It reports `is_estimate: True` and a caveat
  string; do not present it as a fitted cell-cycle model.
* Manders coefficients are threshold-dependent. The threshold actually used
  is always echoed back in the result under ``thresholds`` — report it.
* **Automatic positivity thresholds are gated.** Otsu returns a split for any
  non-constant input, so on a 100%-negative population it reports ~50%
  positive with no hint that anything is wrong. `marker_positive`,
  `transfection_efficiency` and `live_dead` therefore require evidence of two
  populations (`bimodality_gate`) before an automatic threshold is accepted;
  when that evidence is missing they return `ok=False` and NO percentage, so
  nothing reaches `image_stats`. `threshold_mode="manual"` is never gated.
* **`negative_sd` requires a real negative control.** It will not infer the
  negative population from the same image — that is circular and lands the
  threshold ~1.1 σ into the distribution it is supposed to sit above.
"""

from __future__ import annotations

import math as _math
from typing import Any, Iterable, Optional, Sequence

try:  # numpy is required; degrade to a clean error dict rather than crashing.
    import numpy as np
    _HAVE_NUMPY = True
except Exception:  # noqa: BLE001  — pragma: no cover
    np = None  # type: ignore
    _HAVE_NUMPY = False


# ---------------------------------------------------------------------------
# Failure envelopes — every assay funnels its refusals through these.
# ---------------------------------------------------------------------------

def _fail(assay: str, error: str, message: str, **extra: Any) -> dict:
    out = {"assay": assay, "ok": False, "error": error, "message": message}
    out.update(extra)
    return out


def _no_numpy(assay: str) -> dict:
    return _fail(assay, "numpy-unavailable",
                 "NumPy is not importable in this Python environment, so "
                 "intensity assays cannot run.")


# ---------------------------------------------------------------------------
# Array plumbing.
# ---------------------------------------------------------------------------

def as_hwc(planes: Any):
    """Coerce a plane array to (H, W, C) float64. Accepts HxW or HxWxC."""
    arr = np.asarray(planes)
    if arr.ndim == 2:
        arr = arr[:, :, None]
    elif arr.ndim != 3:
        raise ValueError(f"expected a 2-D or 3-D plane array, got ndim={arr.ndim}")
    return arr.astype(np.float64, copy=False)


def channel_count(planes: Any) -> int:
    """Number of channels in a plane array (HxW counts as 1)."""
    if not _HAVE_NUMPY:
        return 0
    try:
        arr = np.asarray(planes)
    except Exception:  # noqa: BLE001
        return 0
    if arr.ndim == 2:
        return 1
    if arr.ndim == 3:
        return int(arr.shape[2])
    return 0


def channel_name(channel_names: Optional[Sequence[str]], index: int) -> Optional[str]:
    """Safe lookup into an optional channel-name list."""
    if not channel_names:
        return None
    try:
        name = channel_names[index]
    except Exception:  # noqa: BLE001
        return None
    return str(name) if name is not None else None


def _check_inputs(assay: str, labels: Any, planes: Any,
                  needed_channels: int,
                  channel_indices: Iterable[int]) -> Optional[dict]:
    """Shared precondition gate. Returns a failure dict, or None when OK."""
    if not _HAVE_NUMPY:
        return _no_numpy(assay)
    try:
        lab = np.asarray(labels)
    except Exception:  # noqa: BLE001
        return _fail(assay, "bad-labels", "The label map could not be read as an array.")
    if lab.ndim != 2 or lab.size == 0:
        return _fail(assay, "bad-labels",
                     "The label map must be a non-empty 2-D integer array "
                     "(0 = background).")
    n_ch = channel_count(planes)
    if n_ch < needed_channels:
        return _fail(assay, f"requires-{needed_channels}-channels",
                     f"This assay requires at least {needed_channels} channel"
                     f"{'s' if needed_channels > 1 else ''}; this image has "
                     f"{n_ch}. Load a multi-channel image (or pick a different "
                     f"channel split) and try again.",
                     n_channels=int(n_ch))
    for idx in channel_indices:
        if idx is None:
            continue
        if not (0 <= int(idx) < n_ch):
            return _fail(assay, "channel-out-of-range",
                         f"Channel {idx} does not exist — this image has "
                         f"{n_ch} channel{'s' if n_ch != 1 else ''} "
                         f"(0–{n_ch - 1}).",
                         n_channels=int(n_ch))
    try:
        arr = as_hwc(planes)
    except Exception as exc:  # noqa: BLE001
        return _fail(assay, "bad-planes", f"The image array is unusable: {exc}")
    if arr.shape[0] != lab.shape[0] or arr.shape[1] != lab.shape[1]:
        return _fail(assay, "shape-mismatch",
                     f"The label map is {lab.shape[0]}×{lab.shape[1]} but the "
                     f"image is {arr.shape[0]}×{arr.shape[1]}. They must match.")
    return None


# ---------------------------------------------------------------------------
# Per-cell pixel index table — computed once, reused by every assay.
# ---------------------------------------------------------------------------

class CellPixels:
    """Flat pixel indices grouped by label.

    Built with a single argsort over the label map (O(P log P)) instead of an
    ``N × (labels == lab)`` scan, which matters on 2k×2k images with 5000
    cells.

    Attributes
    ----------
    labels_present : np.ndarray of int64, the non-zero labels, ascending.
    index_of : dict[int, np.ndarray] — flat pixel indices for each label.
    shape : (H, W)
    """

    __slots__ = ("labels_present", "index_of", "shape")

    def __init__(self, labels: Any):
        lab = np.asarray(labels)
        self.shape = (int(lab.shape[0]), int(lab.shape[1]))
        flat = lab.ravel()
        order = np.argsort(flat, kind="stable")
        sorted_vals = flat[order]
        uniq, starts = np.unique(sorted_vals, return_index=True)
        bounds = list(starts) + [sorted_vals.size]
        index_of: dict[int, Any] = {}
        present: list[int] = []
        for i, value in enumerate(uniq):
            v = int(value)
            if v == 0:
                continue
            idx = order[bounds[i]:bounds[i + 1]]
            index_of[v] = idx
            present.append(v)
        self.index_of = index_of
        self.labels_present = np.asarray(present, dtype=np.int64)

    def __len__(self) -> int:
        return int(self.labels_present.size)


def per_cell_channel_stats(labels: Any, planes: Any,
                           channel_names: Optional[Sequence[str]] = None,
                           cells: Optional[CellPixels] = None) -> list[dict]:
    """Per-cell mean / integrated / median for every channel.

    Returns a list of ``{"label": int, "area_px": int, "channel_intensities":
    [{"channel", "name", "mean", "integrated", "median"}, …]}``.

    The inner list matches the ``channel_intensities`` entry that the detection
    sidecars emit per cell, so a caller can splice it straight into a cell dict.
    """
    if not _HAVE_NUMPY:
        return []
    arr = as_hwc(planes)
    h, w, n_ch = arr.shape
    flat = arr.reshape(h * w, n_ch)
    cp = cells if cells is not None else CellPixels(labels)

    out: list[dict] = []
    for lab in cp.labels_present:
        idx = cp.index_of[int(lab)]
        area_px = int(idx.size)
        entries = []
        for c in range(n_ch):
            vals = flat[idx, c]
            mean = float(vals.mean()) if area_px else 0.0
            entries.append({
                "channel": int(c),
                "name": channel_name(channel_names, c),
                "mean": mean,
                "integrated": float(vals.sum()),
                "median": float(np.median(vals)) if area_px else 0.0,
            })
        out.append({
            "label": int(lab),
            "area_px": area_px,
            "channel_intensities": entries,
        })
    return out


def _metric_values(labels: Any, planes: Any, channel: int, metric: str,
                   cells: Optional[CellPixels] = None):
    """Per-cell scalar for one channel. Returns (labels_array, values_array)."""
    arr = as_hwc(planes)
    h, w, _ = arr.shape
    chan = arr[:, :, int(channel)].reshape(h * w)
    cp = cells if cells is not None else CellPixels(labels)
    m = (metric or "mean").lower()
    vals = []
    for lab in cp.labels_present:
        idx = cp.index_of[int(lab)]
        v = chan[idx]
        if v.size == 0:
            vals.append(0.0)
        elif m == "integrated":
            vals.append(float(v.sum()))
        elif m == "median":
            vals.append(float(np.median(v)))
        else:
            vals.append(float(v.mean()))
    return cp.labels_present, np.asarray(vals, dtype=np.float64)


# ---------------------------------------------------------------------------
# Thresholding.
# ---------------------------------------------------------------------------

def otsu_threshold(values: Any, nbins: int = 256) -> Optional[float]:
    """Otsu's threshold by maximising between-class variance.

    Pure NumPy so it works without scikit-image. Histograms the values into
    ``nbins`` and picks the bin boundary that maximises σ²_between, exactly as
    ``skimage.filters.threshold_otsu`` does. Classification is ``value > threshold``.

    One deliberate refinement over the textbook version: once the optimal bin
    boundary is found, the returned threshold is the **midpoint between the
    largest low-class value and the smallest high-class value**, not the bin
    centre. This matters for per-cell data, where N is small (tens to
    thousands) and the between-class variance plateaus across every empty bin
    in the gap — ``argmax`` then picks the *first* plateau index, whose bin
    centre can fall inside the low cluster and misclassify its top members. On
    dense pixel data the two conventions agree to within one bin width.

    Returns None when the input is empty or constant.
    """
    if not _HAVE_NUMPY:
        return None
    v = np.asarray(values, dtype=np.float64).ravel()
    v = v[np.isfinite(v)]
    if v.size == 0:
        return None
    vmin, vmax = float(v.min()), float(v.max())
    if not (vmax > vmin):
        return None

    nbins = max(2, int(nbins))
    counts, edges = np.histogram(v, bins=nbins, range=(vmin, vmax))
    counts = counts.astype(np.float64)
    centers = (edges[:-1] + edges[1:]) / 2.0

    weight1 = np.cumsum(counts)
    weight2 = np.cumsum(counts[::-1])[::-1]
    with np.errstate(invalid="ignore", divide="ignore"):
        mean1 = np.cumsum(counts * centers) / weight1
        mean2 = (np.cumsum((counts * centers)[::-1]) / weight2[::-1])[::-1]
    variance12 = weight1[:-1] * weight2[1:] * (mean1[:-1] - mean2[1:]) ** 2
    variance12 = np.nan_to_num(variance12, nan=-1.0, posinf=-1.0, neginf=-1.0)
    if variance12.size == 0 or float(variance12.max()) <= 0:
        return None
    idx = int(np.argmax(variance12))

    # Refine onto the actual gap between the two classes (see docstring).
    boundary = float(edges[idx + 1])
    low = v[v <= boundary]
    high = v[v > boundary]
    if low.size and high.size:
        return float(0.5 * (float(low.max()) + float(high.min())))
    return float(centers[idx])


def between_class_variance_ratio(values: Any,
                                 threshold: Optional[float]) -> Optional[float]:
    """η² = σ²_between / σ²_total for the two classes split at ``threshold``.

    This is the scale- and offset-invariant "are there really two populations
    here?" statistic. With class weights ``w₁``/``w₂`` and class means
    ``m₁``/``m₂``::

        σ²_between = w₁ · w₂ · (m₁ − m₂)²
        η²         = σ²_between / σ²_total          ∈ [0, 1]

    η² → 1 for two well-separated clusters and settles near 0.64 for ANY
    single Gaussian population, because Otsu bisects it at the mean and the
    two half-normals sit a fixed distance apart no matter how the data are
    scaled or offset. That fixed floor is what makes it usable as a gate —
    see :data:`MIN_BIMODALITY_RATIO`.

    Returns None when the split is degenerate (empty class, constant input).
    """
    if not _HAVE_NUMPY or threshold is None:
        return None
    v = np.asarray(values, dtype=np.float64).ravel()
    v = v[np.isfinite(v)]
    if v.size < 2:
        return None
    total_var = float(v.var())
    if not (total_var > 0):
        return None
    hi = v > float(threshold)
    n_hi = int(hi.sum())
    if n_hi == 0 or n_hi == v.size:
        return None
    w2 = n_hi / float(v.size)
    w1 = 1.0 - w2
    m1 = float(v[~hi].mean())
    m2 = float(v[hi].mean())
    between = w1 * w2 * (m1 - m2) ** 2
    ratio = between / total_var
    if not _math.isfinite(ratio):
        return None
    return float(max(0.0, min(1.0, ratio)))


#: η² below which an AUTOMATIC threshold is refused as "one population, not two".
#:
#: Calibrated on this module (40 draws of n=100 per distribution, median η²):
#:
#:     UNIMODAL  N(100,8) 0.646 · N(5000,400) 0.640 · lognormal 0.641–0.670 ·
#:               exponential 0.670 · uniform 0.757
#:     BIMODAL   100/400 0.983 · 90:10 100/400 0.983 · 100/160 0.917 ·
#:               pedestal 520/700 0.988 · pedestal 5200/5900 0.965 ·
#:               lognormal pair 0.825
#:
#: 0.80 sits in the gap: it refuses every unimodal shape tested (worst 0.757)
#: and accepts every realistically separated pair (worst 0.825). Two Gaussians
#: closer than ~3 SD apart (η² ≈ 0.74) are also refused — deliberately, since
#: at that overlap a % positive is not a measurement.
MIN_BIMODALITY_RATIO = 0.80

#: Fewest cells for which η² means anything. Small samples inflate it badly
#: (measured on unimodal N(100,8): P(η² ≥ 0.80) = 0.88 at n=3, 0.60 at n=5,
#: 0.14 at n=12, 0.038 at n=20, 0.006 at n=30, 0.000 at n≥50). Below this the
#: gate cannot do its job, so an automatic threshold is refused outright rather
#: than rubber-stamped by a statistic that is noise at that sample size.
MIN_CELLS_FOR_AUTO_THRESHOLD = 20


def negative_population_threshold(values: Any, k: float = 3.0,
                                  negative_values: Optional[Any] = None
                                  ) -> tuple[Optional[float], dict]:
    """``mean + k × SD`` of the negative population.

    The negative population MUST be supplied explicitly (``negative_values``
    — per-cell values measured on a real no-primary / untransfected /
    unstained control). There is no inference fallback, and that is the whole
    point of this function.

    Bootstrapping the negative population out of ``values`` itself (split at
    Otsu, call the lower class "negative") is circular and quietly wrong: on a
    single population the lower class is a LEFT-TRUNCATED sample whose SD is
    only ~0.6–0.7× the true SD, so ``mean + 3 SD`` lands around +1.1 σ of the
    full distribution instead of +3 σ — and ~14% of a 100%-negative population
    is reported positive. That is exactly the plausible-but-wrong number this
    module exists to refuse, so with no control supplied it refuses.

    Returns ``(threshold | None, detail_dict)``. The detail dict records how
    the negative population was chosen so the result is reproducible.
    """
    if not _HAVE_NUMPY:
        return None, {"source": "unavailable"}

    if negative_values is None:
        return None, {
            "source": "none-supplied",
            "error": "no-negative-control",
            "message": (
                "The 'negative_sd' threshold mode needs a real negative "
                "control: per-cell values from an unstained / no-primary / "
                "untransfected sample. Inferring the negative population from "
                "this same image would be circular — the inferred population "
                "is left-truncated, its SD is ~0.65× the true SD, and "
                "mean + k·SD then falls inside the population it is supposed "
                "to sit above. Supply --negative-values, or switch to a "
                "manual threshold."),
        }

    neg = np.asarray(negative_values, dtype=np.float64).ravel()
    neg = neg[np.isfinite(neg)]
    source = "supplied"
    split: Optional[float] = None

    if neg.size == 0:
        return None, {
            "source": source, "n_negative": 0, "split": split,
            "error": "empty-negative-control",
            "message": ("The supplied negative control contains no finite "
                        "values, so mean + k·SD cannot be computed."),
        }
    if neg.size < 2:
        return None, {
            "source": source, "n_negative": int(neg.size), "split": split,
            "error": "negative-control-too-small",
            "message": ("The supplied negative control has only one value, so "
                        "its SD is undefined. Supply the per-cell values from "
                        "a control image (tens of cells or more)."),
        }
    mu = float(neg.mean())
    sd = float(neg.std(ddof=1))
    thr = mu + float(k) * sd
    return thr, {
        "source": source,
        "split": split,
        "n_negative": int(neg.size),
        "negative_mean": mu,
        "negative_sd": sd,
        "k": float(k),
    }


def resolve_threshold(values: Any, mode: str = "otsu",
                      manual: Optional[float] = None,
                      k: float = 3.0,
                      negative_values: Optional[Any] = None
                      ) -> tuple[Optional[float], dict]:
    """Resolve one of the three supported threshold modes.

    mode
        ``"manual"``      — use ``manual`` verbatim.
        ``"otsu"``        — Otsu over ``values``.
        ``"negative_sd"`` — mean + k×SD of the negative population.

    Returns ``(threshold | None, detail)``. ``detail["mode"]`` echoes the mode
    that was actually applied (it can differ from the request when a mode
    degrades — e.g. Otsu on a constant input falls back to manual/None).
    """
    m = (mode or "otsu").lower().replace("-", "_")
    if m in ("manual", "value", "fixed"):
        if manual is None:
            return None, {
                "mode": "manual",
                "error": "manual-threshold-missing",
                "message": ("The manual threshold mode was selected but no "
                            "threshold value was supplied."),
            }
        return float(manual), {"mode": "manual"}
    if m in ("negative_sd", "negative", "mean_plus_ksd", "ksd"):
        thr, detail = negative_population_threshold(values, k=k,
                                                    negative_values=negative_values)
        detail["mode"] = "negative_sd"
        if thr is None and manual is not None:
            return float(manual), {"mode": "manual", "degraded_from": "negative_sd"}
        return thr, detail
    thr = otsu_threshold(values)
    if thr is None and manual is not None:
        return float(manual), {"mode": "manual", "degraded_from": "otsu"}
    if thr is None:
        return None, {
            "mode": "otsu",
            "error": "threshold-unresolved",
            "message": ("Otsu could not split these per-cell intensities — "
                        "they are empty or constant."),
        }
    return thr, {"mode": "otsu"}


def _is_automatic(detail: dict) -> bool:
    """True when the threshold actually applied was derived from the data."""
    return str((detail or {}).get("mode", "")).lower() not in ("manual", "")


def bimodality_gate(values: Any, threshold: Optional[float], detail: dict, *,
                    min_bimodality_ratio: float = MIN_BIMODALITY_RATIO,
                    min_cells: int = MIN_CELLS_FOR_AUTO_THRESHOLD) -> dict:
    """Decide whether an AUTOMATIC threshold has two populations to sit between.

    Otsu (and any mean+k·SD derived from the same data) always returns *some*
    split, even across a single uniform population — so an automatic positivity
    threshold has to be checked against the data it came from before its
    ``% positive`` is allowed out. This mirrors the bimodality gate
    ``_assays_area.scratch_wound`` already applies to its texture map.

    Returns a dict that is always merged into the assay result::

        {"applied": bool,          # was the gate evaluated at all (auto mode)?
         "passed": bool,
         "bimodality_ratio": float | None,     # η², see between_class_variance_ratio
         "separation_ratio": float | None,     # mean_positive / mean_negative
         "n_cells": int,
         "min_bimodality_ratio": float,
         "min_cells": int,
         "error": str | None, "message": str | None}

    ``separation_ratio`` is REPORTED but deliberately not the decision
    variable: measured across this module it fails in both directions — a
    unimodal log-normal (very common for fluorescence) reaches 2.3–4.4, while a
    genuinely bimodal population riding a 16-bit camera pedestal sits at 1.14.
    η² separates those cases cleanly; the ratio is kept because it is the
    number a reviewer will ask for.
    """
    n_cells = 0
    sep: Optional[float] = None
    eta2: Optional[float] = None
    if _HAVE_NUMPY:
        v = np.asarray(values, dtype=np.float64).ravel()
        v = v[np.isfinite(v)]
        n_cells = int(v.size)
        if threshold is not None and n_cells:
            hi = v > float(threshold)
            if hi.any() and not hi.all():
                mean_pos = float(v[hi].mean())
                mean_neg = float(v[~hi].mean())
                if mean_neg > 0:
                    sep = mean_pos / mean_neg
            eta2 = between_class_variance_ratio(v, threshold)

    out = {
        "applied": False,
        "passed": True,
        "bimodality_ratio": eta2,
        "separation_ratio": sep,
        "n_cells": n_cells,
        "min_bimodality_ratio": float(min_bimodality_ratio),
        "min_cells": int(min_cells),
        "error": None,
        "message": None,
    }
    if not _is_automatic(detail):
        return out                      # manual mode is never gated.

    out["applied"] = True
    if n_cells < int(min_cells):
        out["passed"] = False
        out["error"] = "too-few-cells-for-auto-threshold"
        out["message"] = (
            f"Only {n_cells} cell(s) were segmented. An automatic threshold "
            f"cannot be shown to separate two populations at that sample size "
            f"(the bimodality statistic is dominated by noise below "
            f"{int(min_cells)} cells), so no % positive is reported. Supply a "
            f"manual threshold, or a negative control, or segment more cells.")
        return out
    if eta2 is None:
        out["passed"] = False
        out["error"] = "no-bimodality"
        out["message"] = (
            "The automatic threshold produced a degenerate split (one side is "
            "empty, or the per-cell intensities are constant), so there is no "
            "evidence of a positive and a negative population. Supply a manual "
            "threshold or a negative control.")
        return out
    if eta2 < float(min_bimodality_ratio):
        out["passed"] = False
        out["error"] = "no-bimodality"
        ratio_txt = f"{sep:.2f}" if sep is not None else "n/a"
        out["message"] = (
            f"These per-cell intensities look like ONE population, not a "
            f"positive and a negative one: the between-class variance ratio at "
            f"the automatic threshold is {eta2:.2f}, below the {float(min_bimodality_ratio):.2f} "
            f"required (a single population sits near 0.65; two separated ones "
            f"reach 0.9+). Mean positive / mean negative is {ratio_txt}. Otsu "
            f"always finds some split, so it would have reported a % positive "
            f"anyway — that number is withheld. Supply a manual threshold "
            f"(--threshold-mode manual --threshold …) or a negative control "
            f"(--negative-values …).")
    return out


# ---------------------------------------------------------------------------
# Assay 1 — % marker-positive (Ki67, EdU, BrdU, cleaved caspase-3, …).
# ---------------------------------------------------------------------------

def marker_positive(labels: Any, planes: Any, *,
                    channel: int,
                    metric: str = "mean",
                    threshold_mode: str = "otsu",
                    threshold: Optional[float] = None,
                    k: float = 3.0,
                    negative_values: Optional[Any] = None,
                    channel_names: Optional[Sequence[str]] = None,
                    marker_name: Optional[str] = None,
                    assay_name: str = "marker_positive",
                    min_bimodality_ratio: float = MIN_BIMODALITY_RATIO,
                    min_cells_for_auto_threshold: int = MIN_CELLS_FOR_AUTO_THRESHOLD,
                    cells: Optional[CellPixels] = None) -> dict:
    """Score each cell positive / negative in one channel.

    Parameters
    ----------
    channel : int              index into the channel axis.
    metric : str               per-cell statistic to threshold —
                               "mean" (default) | "integrated" | "median".
    threshold_mode : str       "manual" | "otsu" | "negative_sd".
    threshold : float | None   the value for manual mode (also the fallback
                               if an automatic mode can't resolve).
    k : float                  multiplier for "negative_sd" (default 3.0).
    negative_values : seq|None negative-control per-cell values. REQUIRED by
                               "negative_sd" — see
                               :func:`negative_population_threshold`.
    marker_name : str | None   label for the readout ("Ki67", "EdU", …).
    min_bimodality_ratio, min_cells_for_auto_threshold
                               tuning for the automatic-threshold gate below;
                               see :func:`bimodality_gate`.

    Bimodality gate (automatic threshold modes only)
    ------------------------------------------------
    Otsu returns a split for ANY non-constant input, so on a 100%-negative
    population it happily reports ~50% positive. Before an automatic threshold
    is accepted here, the split has to show two populations
    (:func:`bimodality_gate`); when it does not, this returns
    ``ok=False, error="no-bimodality"`` and NO percentage — deliberately, so
    that nothing lands in the flat ``image_stats`` namespace the UI reads.
    ``threshold_mode="manual"`` is never gated.

    Result
    ------
    ``{"assay", "ok", "channel", "channel_name", "marker", "metric",
       "threshold", "threshold_mode", "threshold_detail",
       "n_cells", "n_positive", "n_negative", "pct_positive",
       "mean_positive", "mean_negative",
       "separation_ratio", "bimodality_ratio", "bimodality_gate",
       "per_cell": [{"label", "value", "positive"}, …]}``
    """
    bad = _check_inputs(assay_name, labels, planes, 1, [channel])
    if bad is not None:
        return bad

    cp = cells if cells is not None else CellPixels(labels)
    if len(cp) == 0:
        return _fail(assay_name, "no-cells",
                     "No segmented cells in this image, so there is nothing "
                     "to score.")

    lab_ids, values = _metric_values(labels, planes, channel, metric, cells=cp)
    thr, detail = resolve_threshold(values, mode=threshold_mode,
                                    manual=threshold, k=k,
                                    negative_values=negative_values)
    if thr is None:
        return _fail(assay_name,
                     detail.get("error") or "threshold-unresolved",
                     detail.get("message") or
                     ("Could not determine a threshold: the per-cell intensities "
                      "are constant and no manual value was supplied. Switch to "
                      "the manual threshold mode."),
                     channel=int(channel),
                     channel_name=channel_name(channel_names, int(channel)),
                     threshold_mode=detail.get("mode", threshold_mode),
                     threshold_detail=detail,
                     n_cells=len(cp))

    # An automatic threshold has to prove there were two populations to sit
    # between before its % positive is allowed out of this function. A failure
    # here returns ok=False, which keeps every `assay_*_pct_positive` key out of
    # `flatten_for_image_stats` — a wrong number in the flat namespace is what
    # reaches the UI, so it must never be produced.
    gate = bimodality_gate(values, thr, detail,
                           min_bimodality_ratio=min_bimodality_ratio,
                           min_cells=min_cells_for_auto_threshold)
    if not gate["passed"]:
        return _fail(assay_name, gate["error"], gate["message"],
                     channel=int(channel),
                     channel_name=channel_name(channel_names, int(channel)),
                     marker=marker_name,
                     metric=(metric or "mean").lower(),
                     threshold=float(thr),
                     threshold_mode=detail.get("mode", threshold_mode),
                     threshold_detail=detail,
                     n_cells=int(values.size),
                     separation_ratio=gate["separation_ratio"],
                     bimodality_ratio=gate["bimodality_ratio"],
                     bimodality_gate=gate)

    positive = values > float(thr)
    n_pos = int(positive.sum())
    n_cells = int(values.size)
    pos_vals = values[positive]
    neg_vals = values[~positive]

    return {
        "assay": assay_name,
        "ok": True,
        "channel": int(channel),
        "channel_name": channel_name(channel_names, int(channel)),
        "marker": marker_name,
        "metric": (metric or "mean").lower(),
        "threshold": float(thr),
        "threshold_mode": detail.get("mode", threshold_mode),
        "threshold_detail": detail,
        "n_cells": n_cells,
        "n_positive": n_pos,
        "n_negative": n_cells - n_pos,
        "pct_positive": (100.0 * n_pos / n_cells) if n_cells else 0.0,
        "mean_positive": float(pos_vals.mean()) if pos_vals.size else None,
        "mean_negative": float(neg_vals.mean()) if neg_vals.size else None,
        "separation_ratio": gate["separation_ratio"],
        "bimodality_ratio": gate["bimodality_ratio"],
        "bimodality_gate": gate,
        "per_cell": [
            {"label": int(lab_ids[i]), "value": float(values[i]),
             "positive": bool(positive[i])}
            for i in range(n_cells)
        ],
    }


# ---------------------------------------------------------------------------
# Assay 5 — transfection efficiency (named preset over assay 1).
# ---------------------------------------------------------------------------

def transfection_efficiency(labels: Any, planes: Any, *,
                            channel: int,
                            metric: str = "mean",
                            threshold_mode: str = "otsu",
                            threshold: Optional[float] = None,
                            k: float = 3.0,
                            negative_values: Optional[Any] = None,
                            channel_names: Optional[Sequence[str]] = None,
                            reporter_name: Optional[str] = None,
                            min_bimodality_ratio: float = MIN_BIMODALITY_RATIO,
                            min_cells_for_auto_threshold: int = MIN_CELLS_FOR_AUTO_THRESHOLD,
                            cells: Optional[CellPixels] = None) -> dict:
    """% of cells positive in the reporter channel (GFP / mCherry / …).

    Deliberately a thin preset over :func:`marker_positive` — same maths, same
    parameters — but surfaced under the name researchers actually search for.
    Adds ``pct_transfected`` / ``n_transfected`` aliases on top of the standard
    positivity keys.
    """
    res = marker_positive(labels, planes, channel=channel, metric=metric,
                          threshold_mode=threshold_mode, threshold=threshold,
                          k=k, negative_values=negative_values,
                          channel_names=channel_names,
                          marker_name=reporter_name,
                          assay_name="transfection_efficiency",
                          min_bimodality_ratio=min_bimodality_ratio,
                          min_cells_for_auto_threshold=min_cells_for_auto_threshold,
                          cells=cells)
    if res.get("ok"):
        res["reporter"] = reporter_name
        res["n_transfected"] = res["n_positive"]
        res["pct_transfected"] = res["pct_positive"]
    return res


# ---------------------------------------------------------------------------
# Assay 2 — nuclear : cytoplasmic intensity ratio.
# ---------------------------------------------------------------------------

def nuclear_cytoplasmic(labels: Any, planes: Any, *,
                        channel: int,
                        nuclear_mask: Any,
                        metric: str = "mean",
                        min_nuclear_px: int = 4,
                        min_cyto_px: int = 4,
                        channel_names: Optional[Sequence[str]] = None,
                        cells: Optional[CellPixels] = None) -> dict:
    """Per-cell nuclear : cytoplasmic intensity ratio.

    ``labels`` is the **cell** label map. ``nuclear_mask`` is either a boolean
    mask or a nuclear label map (anything non-zero counts as nuclear); it must
    have the same H×W as the cell label map.

    For each cell:

        nucleus   = cell mask ∧ nuclear mask
        cytoplasm = cell mask ∧ ¬nuclear mask          (the "cell minus nucleus" ring)
        N:C       = <intensity>_nucleus / <intensity>_cytoplasm

    ``metric`` selects the per-compartment statistic ("mean" | "median"). Mean
    is the default: an integrated ratio would mostly report the area ratio of
    the two compartments, not a concentration difference.

    Cells with fewer than ``min_nuclear_px`` nuclear or ``min_cyto_px``
    cytoplasmic pixels, or a non-positive cytoplasmic intensity, are skipped and
    counted in ``n_skipped`` — they'd otherwise produce infinities.
    """
    assay = "nuclear_cytoplasmic"
    bad = _check_inputs(assay, labels, planes, 1, [channel])
    if bad is not None:
        return bad

    lab = np.asarray(labels)
    try:
        nuc = np.asarray(nuclear_mask)
    except Exception:  # noqa: BLE001
        return _fail(assay, "bad-nuclear-mask",
                     "The nuclear mask could not be read as an array.")
    if nuc.shape[:2] != lab.shape[:2]:
        return _fail(assay, "shape-mismatch",
                     f"The nuclear mask is {nuc.shape[0]}×{nuc.shape[1]} but the "
                     f"cell label map is {lab.shape[0]}×{lab.shape[1]}.")
    nuc_flat = (nuc != 0).ravel()
    if not bool(nuc_flat.any()):
        return _fail(assay, "empty-nuclear-mask",
                     "The nuclear mask is empty, so no nucleus/cytoplasm split "
                     "is possible. Segment nuclei (e.g. on the DNA channel) "
                     "first.")

    cp = cells if cells is not None else CellPixels(labels)
    if len(cp) == 0:
        return _fail(assay, "no-cells", "No segmented cells in this image.")

    arr = as_hwc(planes)
    h, w, _ = arr.shape
    chan = arr[:, :, int(channel)].reshape(h * w)
    use_median = (metric or "mean").lower() == "median"

    per_cell: list[dict] = []
    ratios: list[float] = []
    n_skipped = 0
    for lab_id in cp.labels_present:
        idx = cp.index_of[int(lab_id)]
        is_nuc = nuc_flat[idx]
        nuc_idx = idx[is_nuc]
        cyt_idx = idx[~is_nuc]
        if nuc_idx.size < int(min_nuclear_px) or cyt_idx.size < int(min_cyto_px):
            n_skipped += 1
            continue
        nv = chan[nuc_idx]
        cv = chan[cyt_idx]
        n_stat = float(np.median(nv)) if use_median else float(nv.mean())
        c_stat = float(np.median(cv)) if use_median else float(cv.mean())
        if not (c_stat > 0) or not np.isfinite(c_stat):
            n_skipped += 1
            continue
        ratio = n_stat / c_stat
        ratios.append(ratio)
        per_cell.append({
            "label": int(lab_id),
            "nuclear": n_stat,
            "cytoplasmic": c_stat,
            "nc_ratio": float(ratio),
            "nuclear_px": int(nuc_idx.size),
            "cytoplasmic_px": int(cyt_idx.size),
            "nuclear_area_fraction": float(nuc_idx.size) / float(idx.size),
        })

    if not ratios:
        return _fail(assay, "no-measurable-cells",
                     "No cell had both a nucleus and a cytoplasmic ring large "
                     "enough to measure (check that the nuclear mask is "
                     "aligned with the cell masks).",
                     n_skipped=int(n_skipped))

    r = np.asarray(ratios, dtype=np.float64)
    return {
        "assay": assay,
        "ok": True,
        "channel": int(channel),
        "channel_name": channel_name(channel_names, int(channel)),
        "metric": "median" if use_median else "mean",
        "n_cells": int(r.size),
        "n_skipped": int(n_skipped),
        "mean_nc_ratio": float(r.mean()),
        "median_nc_ratio": float(np.median(r)),
        "sd_nc_ratio": float(r.std(ddof=1)) if r.size > 1 else 0.0,
        "min_nc_ratio": float(r.min()),
        "max_nc_ratio": float(r.max()),
        "per_cell": per_cell,
        "definition": "cytoplasm = cell mask minus nuclear mask; ratio = "
                      f"{'median' if use_median else 'mean'} nuclear intensity / "
                      f"{'median' if use_median else 'mean'} cytoplasmic intensity",
    }


# ---------------------------------------------------------------------------
# Assay 3 — colocalization: Pearson r, Manders M1 / M2.
# ---------------------------------------------------------------------------

def _pearson(a: Any, b: Any) -> Optional[float]:
    """Pearson correlation coefficient over paired pixel values."""
    if a.size < 2:
        return None
    am = a - a.mean()
    bm = b - b.mean()
    denom = float(np.sqrt(float((am * am).sum()) * float((bm * bm).sum())))
    if not (denom > 0) or not np.isfinite(denom):
        return None
    return float(float((am * bm).sum()) / denom)


def _manders(a: Any, b: Any, thr_a: float, thr_b: float
             ) -> tuple[Optional[float], Optional[float]]:
    """Manders M1 / M2 with explicit intensity thresholds.

    M1 = Σ a_i over pixels where b_i > thr_b, divided by Σ a_i (all pixels).
    M2 = Σ b_i over pixels where a_i > thr_a, divided by Σ b_i (all pixels).

    Sums are taken over non-negative intensities only — negative values (from a
    background-subtracted float image) would otherwise make the ratio
    uninterpretable.
    """
    a_pos = np.clip(a, 0.0, None)
    b_pos = np.clip(b, 0.0, None)
    sum_a = float(a_pos.sum())
    sum_b = float(b_pos.sum())
    m1 = float(a_pos[b > thr_b].sum() / sum_a) if sum_a > 0 else None
    m2 = float(b_pos[a > thr_a].sum() / sum_b) if sum_b > 0 else None
    return m1, m2


def colocalization(labels: Any, planes: Any, *,
                   channel_a: int,
                   channel_b: int,
                   threshold_mode: str = "otsu",
                   threshold_a: Optional[float] = None,
                   threshold_b: Optional[float] = None,
                   threshold_scope: str = "image",
                   channel_names: Optional[Sequence[str]] = None,
                   cells: Optional[CellPixels] = None) -> dict:
    """Pearson r and Manders M1/M2 between two channels — per cell and image-wide.

    Definitions (standard, Manders et al. 1993 / Bolte & Cordelières 2006)::

        r  = Σ(a_i − ā)(b_i − b̄) / sqrt( Σ(a_i − ā)² · Σ(b_i − b̄)² )
        M1 = Σ_{i : b_i > T_b} a_i / Σ_i a_i
        M2 = Σ_{i : a_i > T_a} b_i / Σ_i b_i

    Manders thresholding (documented, because M1/M2 are meaningless without it)
    ----------------------------------------------------------------------------
    ``threshold_mode``:

    * ``"otsu"`` (default) — one Otsu threshold per channel, computed **once**
      over the scope given by ``threshold_scope`` and then reused for the
      image-wide and every per-cell computation. Per-cell Otsu on a few hundred
      pixels is noise, so it is deliberately not offered.
    * ``"manual"`` — use ``threshold_a`` / ``threshold_b`` verbatim. BOTH must
      be supplied; a missing one is an error, not a silent 0.0.
    * ``"zero"`` — T_a = T_b = 0, i.e. every non-zero pixel counts. This is the
      "no thresholding" convention; M1/M2 then approach 1 for any pair of
      non-negative images, so use it only for already-background-subtracted data.

    ``threshold_scope``: ``"image"`` (default — every pixel) or ``"in_cells"``
    (only pixels inside a cell mask). Whichever is used, the resolved thresholds
    and the scope are echoed in ``result["thresholds"]``.

    **Why "image" is the default.** A Manders threshold is meant to separate
    SIGNAL from BACKGROUND, and Otsu can only do that if background pixels are
    in the sample it sees. Restricted to foreground pixels there is no
    background left, so Otsu bisects the signal itself and M1/M2 collapse
    towards the fraction of signal above its own median. Measured on two
    channels made pixel-identical inside every cell (ground truth M1 = M2 = 1):
    ``in_cells`` → 0.64, ``image`` → 0.995, ``zero`` → 1.000. Pearson r is
    unaffected (1.000 in all three) — the damage is confined to the
    threshold-dependent coefficients. Keep ``"in_cells"`` only when the
    background has already been subtracted to zero, and say so in the methods.

    Result carries three scopes: ``image`` (all pixels), ``in_cells`` (the union
    of cell masks; present only when the label map has cells), ``per_cell`` +
    ``per_cell_summary``.
    """
    assay = "colocalization"
    bad = _check_inputs(assay, labels, planes, 2, [channel_a, channel_b])
    if bad is not None:
        return bad
    if int(channel_a) == int(channel_b):
        return _fail(assay, "same-channel",
                     "Colocalization needs two different channels; channel A "
                     "and channel B are the same.")

    arr = as_hwc(planes)
    h, w, _ = arr.shape
    a_full = arr[:, :, int(channel_a)].reshape(h * w)
    b_full = arr[:, :, int(channel_b)].reshape(h * w)

    cp = cells if cells is not None else CellPixels(labels)
    if len(cp):
        fg = np.concatenate([cp.index_of[int(l)] for l in cp.labels_present])
    else:
        fg = np.asarray([], dtype=np.int64)

    scope = (threshold_scope or "image").lower()
    if scope == "in_cells" and fg.size:
        thr_source_a, thr_source_b = a_full[fg], b_full[fg]
        scope_used = "in_cells"
    else:
        thr_source_a, thr_source_b = a_full, b_full
        scope_used = "image"

    mode = (threshold_mode or "otsu").lower()
    if mode == "manual":
        # A missing manual threshold used to fall back to 0.0 and still call
        # itself "manual" — i.e. silently switch to the "no thresholding"
        # convention (measured: M1 0.51 → 0.94) under a label that says the
        # opposite. Refuse instead.
        missing = [n for n, v in (("threshold_a", threshold_a),
                                  ("threshold_b", threshold_b)) if v is None]
        if missing:
            return _fail(assay, "manual-threshold-missing",
                         "Manual Manders thresholding needs a threshold for "
                         "BOTH channels; " + " and ".join(missing) + " "
                         + ("was" if len(missing) == 1 else "were")
                         + " not supplied. Pass --threshold-a and "
                         "--threshold-b, or use --coloc-threshold-mode otsu "
                         "(automatic) or zero (no thresholding, for "
                         "background-subtracted data).",
                         channel_a=int(channel_a), channel_b=int(channel_b),
                         missing=missing)
        ta = float(threshold_a)
        tb = float(threshold_b)
        mode_used = "manual"
    elif mode == "zero":
        ta = tb = 0.0
        mode_used = "zero"
    else:
        ota = otsu_threshold(thr_source_a)
        otb = otsu_threshold(thr_source_b)
        ta = float(ota) if ota is not None else (float(threshold_a) if threshold_a is not None else 0.0)
        tb = float(otb) if otb is not None else (float(threshold_b) if threshold_b is not None else 0.0)
        mode_used = "otsu" if (ota is not None and otb is not None) else "otsu-degraded"

    def _scope_stats(idx: Optional[Any]) -> dict:
        a = a_full if idx is None else a_full[idx]
        b = b_full if idx is None else b_full[idx]
        m1, m2 = _manders(a, b, ta, tb)
        return {
            "pearson": _pearson(a, b),
            "manders_m1": m1,
            "manders_m2": m2,
            "n_pixels": int(a.size),
        }

    per_cell: list[dict] = []
    for lab_id in cp.labels_present:
        idx = cp.index_of[int(lab_id)]
        s = _scope_stats(idx)
        s["label"] = int(lab_id)
        per_cell.append(s)

    def _summ(key: str) -> tuple[Optional[float], Optional[float], int]:
        vals = [c[key] for c in per_cell if c[key] is not None]
        if not vals:
            return None, None, 0
        v = np.asarray(vals, dtype=np.float64)
        return float(v.mean()), float(np.median(v)), int(v.size)

    p_mean, p_med, p_n = _summ("pearson")
    m1_mean, m1_med, _ = _summ("manders_m1")
    m2_mean, m2_med, _ = _summ("manders_m2")

    out = {
        "assay": assay,
        "ok": True,
        "channel_a": int(channel_a),
        "channel_b": int(channel_b),
        "channel_a_name": channel_name(channel_names, int(channel_a)),
        "channel_b_name": channel_name(channel_names, int(channel_b)),
        "thresholds": {
            "mode": mode_used,
            "requested_mode": mode,
            "scope": scope_used,
            "threshold_a": float(ta),
            "threshold_b": float(tb),
            "note": "M1/M2 are threshold-dependent — always report these values "
                    "alongside the coefficients."
                    + (" scope='in_cells' thresholds a sample that contains no "
                       "background, so Otsu splits SIGNAL from signal rather "
                       "than signal from background and M1/M2 are deflated "
                       "(measured ~0.64 where the truth was 1.0). Use "
                       "scope='image' unless the background is already "
                       "subtracted to zero."
                       if scope_used == "in_cells" and mode_used.startswith("otsu")
                       else ""),
        },
        "image": _scope_stats(None),
        "per_cell": per_cell,
        "per_cell_summary": {
            "n_cells": int(len(per_cell)),
            "n_cells_evaluated": p_n,
            "pearson_mean": p_mean,
            "pearson_median": p_med,
            "manders_m1_mean": m1_mean,
            "manders_m1_median": m1_med,
            "manders_m2_mean": m2_mean,
            "manders_m2_median": m2_med,
        },
    }
    if fg.size:
        out["in_cells"] = _scope_stats(fg)
    return out


# ---------------------------------------------------------------------------
# Assay 4 — live / dead viability.
# ---------------------------------------------------------------------------

def live_dead(labels: Any, planes: Any, *,
              live_channel: int,
              dead_channel: int,
              live_threshold_mode: str = "otsu",
              dead_threshold_mode: str = "otsu",
              live_threshold: Optional[float] = None,
              dead_threshold: Optional[float] = None,
              metric: str = "mean",
              k: float = 3.0,
              live_negative_values: Optional[Any] = None,
              dead_negative_values: Optional[Any] = None,
              channel_names: Optional[Sequence[str]] = None,
              min_bimodality_ratio: float = MIN_BIMODALITY_RATIO,
              min_cells_for_auto_threshold: int = MIN_CELLS_FOR_AUTO_THRESHOLD,
              cells: Optional[CellPixels] = None) -> dict:
    """Two-channel viability (e.g. calcein-AM / ethidium homodimer).

    Classification (stated explicitly because conventions differ):

    * **dead**       — positive in the dead channel, regardless of the live
      channel. A cell that is double-positive is counted dead: the
      membrane-impermeant dead stain only enters compromised cells, so its
      signal dominates a residual live-stain signal.
    * **live**       — positive in the live channel AND negative in the dead one.
    * **unlabelled** — negative in both. Reported separately rather than being
      silently folded into either class.

    ``pct_viable`` = live / (live + dead) × 100 — the standard readout, which
    excludes unlabelled cells. ``pct_viable_of_all`` divides by every segmented
    cell instead; both are returned so the caller can state which it used.

    Both channels go through the same automatic-threshold bimodality gate as
    :func:`marker_positive`: an untreated, 100%-viable well has no dead
    population for Otsu to find, and without the gate it would still report a
    confident % dead. On a failure this returns ``ok=False`` and no percentage.
    """
    assay = "live_dead"
    bad = _check_inputs(assay, labels, planes, 2, [live_channel, dead_channel])
    if bad is not None:
        return bad
    if int(live_channel) == int(dead_channel):
        return _fail(assay, "same-channel",
                     "Live/dead needs two different channels; the live and "
                     "dead channels are the same.")

    cp = cells if cells is not None else CellPixels(labels)
    if len(cp) == 0:
        return _fail(assay, "no-cells", "No segmented cells in this image.")

    lab_ids, live_vals = _metric_values(labels, planes, live_channel, metric, cells=cp)
    _, dead_vals = _metric_values(labels, planes, dead_channel, metric, cells=cp)

    t_live, d_live = resolve_threshold(live_vals, mode=live_threshold_mode,
                                       manual=live_threshold, k=k,
                                       negative_values=live_negative_values)
    t_dead, d_dead = resolve_threshold(dead_vals, mode=dead_threshold_mode,
                                       manual=dead_threshold, k=k,
                                       negative_values=dead_negative_values)
    if t_live is None or t_dead is None:
        missing = "live" if t_live is None else "dead"
        detail = d_live if t_live is None else d_dead
        return _fail(assay, detail.get("error") or "threshold-unresolved",
                     detail.get("message") or
                     (f"Could not determine a threshold for the {missing} "
                      f"channel (its per-cell intensities are constant). Switch "
                      f"that channel to the manual threshold mode."),
                     failed_channel=missing,
                     live_threshold_detail=d_live,
                     dead_threshold_detail=d_dead)

    # Same gate as marker_positive: an automatic threshold on a population that
    # is entirely live (or entirely dead) has nothing to separate, and Otsu will
    # bisect the noise and report a confident, wrong % viable.
    live_gate = bimodality_gate(live_vals, t_live, d_live,
                                min_bimodality_ratio=min_bimodality_ratio,
                                min_cells=min_cells_for_auto_threshold)
    dead_gate = bimodality_gate(dead_vals, t_dead, d_dead,
                                min_bimodality_ratio=min_bimodality_ratio,
                                min_cells=min_cells_for_auto_threshold)
    for which, g in (("live", live_gate), ("dead", dead_gate)):
        if not g["passed"]:
            return _fail(assay, g["error"],
                         f"{which.capitalize()} channel: {g['message']}",
                         failed_channel=which,
                         live_channel=int(live_channel),
                         dead_channel=int(dead_channel),
                         live_threshold=float(t_live),
                         dead_threshold=float(t_dead),
                         live_threshold_detail=d_live,
                         dead_threshold_detail=d_dead,
                         live_bimodality_gate=live_gate,
                         dead_bimodality_gate=dead_gate,
                         n_cells=int(live_vals.size))

    live_pos = live_vals > float(t_live)
    dead_pos = dead_vals > float(t_dead)
    is_dead = dead_pos
    is_live = live_pos & ~dead_pos
    is_unlabelled = ~live_pos & ~dead_pos
    is_double = live_pos & dead_pos

    n_total = int(live_vals.size)
    n_live = int(is_live.sum())
    n_dead = int(is_dead.sum())
    n_unl = int(is_unlabelled.sum())
    n_dbl = int(is_double.sum())
    denom = n_live + n_dead

    return {
        "assay": assay,
        "ok": True,
        "live_channel": int(live_channel),
        "dead_channel": int(dead_channel),
        "live_channel_name": channel_name(channel_names, int(live_channel)),
        "dead_channel_name": channel_name(channel_names, int(dead_channel)),
        "metric": (metric or "mean").lower(),
        "live_threshold": float(t_live),
        "dead_threshold": float(t_dead),
        "live_threshold_detail": d_live,
        "dead_threshold_detail": d_dead,
        "live_bimodality_gate": live_gate,
        "dead_bimodality_gate": dead_gate,
        "n_cells": n_total,
        "n_live": n_live,
        "n_dead": n_dead,
        "n_unlabelled": n_unl,
        "n_double_positive": n_dbl,
        "pct_viable": (100.0 * n_live / denom) if denom else 0.0,
        "pct_viable_of_all": (100.0 * n_live / n_total) if n_total else 0.0,
        "pct_dead": (100.0 * n_dead / denom) if denom else 0.0,
        "convention": "double-positive cells are counted dead; pct_viable "
                      "excludes unlabelled cells (see pct_viable_of_all)",
        "per_cell": [
            {"label": int(lab_ids[i]),
             "live_value": float(live_vals[i]),
             "dead_value": float(dead_vals[i]),
             "state": ("dead" if is_dead[i] else
                       "live" if is_live[i] else "unlabelled")}
            for i in range(n_total)
        ],
    }


# ---------------------------------------------------------------------------
# Assay 6 — cell cycle from DNA content (ESTIMATE).
# ---------------------------------------------------------------------------

def _smooth(counts: Any, width: int = 3):
    """Moving average over a histogram, edge-padded. width is forced odd."""
    w = max(1, int(width))
    if w % 2 == 0:
        w += 1
    if w == 1 or counts.size < w:
        return counts.astype(np.float64)
    pad = w // 2
    padded = np.pad(counts.astype(np.float64), pad, mode="edge")
    kernel = np.ones(w, dtype=np.float64) / float(w)
    return np.convolve(padded, kernel, mode="valid")


def _local_maxima(y: Any) -> list[int]:
    """Indices of strict-ish local maxima (plateau-tolerant), pure NumPy."""
    idxs: list[int] = []
    n = int(y.size)
    for i in range(n):
        left = y[i - 1] if i > 0 else -np.inf
        right = y[i + 1] if i < n - 1 else -np.inf
        if y[i] >= left and y[i] >= right and y[i] > 0:
            if idxs and idxs[-1] == i - 1 and y[i] == y[i - 1]:
                continue  # collapse plateaus to their first index
            idxs.append(i)
    return idxs


def cell_cycle(labels: Any, planes: Any, *,
               dna_channel: int,
               bins: int = 64,
               gate_width: float = 0.15,
               smoothing: int = 3,
               percentile_cap: float = 99.5,
               channel_names: Optional[Sequence[str]] = None,
               cells: Optional[CellPixels] = None) -> dict:
    """G1 / S / G2-M **estimate** from per-cell integrated DNA intensity.

    This is a peak-and-gate heuristic, NOT a Watson pragmatic / Dean-Jett-Fox
    model fit. It reports ``is_estimate: True`` and a caveat string; present it
    as an estimate and never as a fitted cell-cycle distribution.

    Method
    ------
    1. Per-cell integrated intensity in ``dna_channel`` (Σ pixel values in the
       mask) — the DNA-content proxy.
    2. Histogram into ``bins`` over ``[min, percentile_cap-th percentile]`` so a
       handful of polyploid outliers don't flatten the 2n/4n structure, then
       smooth with a ``smoothing``-wide moving average.
    3. The tallest peak is taken as **G1 (2n)**. The tallest additional peak
       inside ``[1.6 × G1, 2.4 × G1]`` is taken as **G2/M (4n)**; if no peak
       falls in that window, ``2 × G1`` is used and ``g2_peak_found`` is False.
    4. Gates, with half-width ``gate_width`` (fraction of the peak position):

           sub-G1  : I < G1·(1 − gate_width)      (apoptotic / debris)
           G1      : within ±gate_width of G1
           S       : between the G1 and G2 gates
           G2/M    : within ±gate_width of G2
           > G2/M  : above the G2 gate (polyploid or doublets)

    Result carries the peaks, the gate boundaries, per-phase counts and
    percentages, the histogram (counts + bin centres) for plotting, and a
    per-cell ``{label, integrated, phase}`` list.
    """
    assay = "cell_cycle"
    bad = _check_inputs(assay, labels, planes, 1, [dna_channel])
    if bad is not None:
        return bad

    cp = cells if cells is not None else CellPixels(labels)
    if len(cp) == 0:
        return _fail(assay, "no-cells", "No segmented cells in this image.")
    if len(cp) < 20:
        return _fail(assay, "too-few-cells",
                     f"DNA-content gating needs a population to find 2n and 4n "
                     f"peaks; this image has only {len(cp)} cells. "
                     f"Pool more fields of view.",
                     n_cells=len(cp))

    lab_ids, values = _metric_values(labels, planes, dna_channel, "integrated",
                                     cells=cp)
    v = np.asarray(values, dtype=np.float64)
    finite = v[np.isfinite(v)]
    if finite.size == 0 or float(finite.max()) <= 0:
        return _fail(assay, "no-signal",
                     "The DNA channel has no positive integrated signal inside "
                     "the cell masks — check the channel selection.")

    cap = float(np.percentile(finite, float(percentile_cap)))
    lo = float(finite.min())
    if not (cap > lo):
        cap = float(finite.max())
    if not (cap > lo):
        return _fail(assay, "constant-signal",
                     "Every cell has the same integrated DNA intensity, so no "
                     "2n/4n structure can be found.")

    nbins = max(8, int(bins))
    counts, edges = np.histogram(finite, bins=nbins, range=(lo, cap))
    centers = (edges[:-1] + edges[1:]) / 2.0
    smoothed = _smooth(counts, smoothing)

    peaks = _local_maxima(smoothed)
    if not peaks:
        return _fail(assay, "no-peaks",
                     "No peak could be found in the DNA-content histogram.")
    g1_idx = max(peaks, key=lambda i: (smoothed[i], -i))
    g1 = float(centers[g1_idx])
    if not (g1 > 0):
        return _fail(assay, "no-peaks",
                     "The G1 peak resolved to a non-positive DNA content.")

    window = [i for i in peaks
              if 1.6 * g1 <= float(centers[i]) <= 2.4 * g1 and i != g1_idx]
    if window:
        g2_idx = max(window, key=lambda i: smoothed[i])
        g2 = float(centers[g2_idx])
        g2_found = True
    else:
        g2 = 2.0 * g1
        g2_found = False

    gw = max(0.01, float(gate_width))
    g1_lo, g1_hi = g1 * (1.0 - gw), g1 * (1.0 + gw)
    g2_lo, g2_hi = g2 * (1.0 - gw), g2 * (1.0 + gw)
    if g2_lo <= g1_hi:  # gates overlap — split the difference so S isn't empty.
        mid = 0.5 * (g1_hi + g2_lo)
        g1_hi, g2_lo = mid, mid

    phases: list[str] = []
    for x in v:
        if not np.isfinite(x):
            phases.append("unclassified")
        elif x < g1_lo:
            phases.append("sub_g1")
        elif x <= g1_hi:
            phases.append("g1")
        elif x < g2_lo:
            phases.append("s")
        elif x <= g2_hi:
            phases.append("g2m")
        else:
            phases.append("above_g2m")

    n_total = int(v.size)

    def _count(name: str) -> int:
        return int(sum(1 for p in phases if p == name))

    counts_by_phase = {name: _count(name) for name in
                       ("sub_g1", "g1", "s", "g2m", "above_g2m", "unclassified")}
    pct_by_phase = {name: (100.0 * c / n_total if n_total else 0.0)
                    for name, c in counts_by_phase.items()}

    return {
        "assay": assay,
        "ok": True,
        "is_estimate": True,
        "caveat": "Peak-and-gate estimate from integrated DNA intensity — not a "
                  "Watson/Dean-Jett-Fox model fit. Treat the phase fractions as "
                  "approximate and verify against flow cytometry before "
                  "reporting them.",
        "dna_channel": int(dna_channel),
        "dna_channel_name": channel_name(channel_names, int(dna_channel)),
        "metric": "integrated",
        "n_cells": n_total,
        "g1_peak": g1,
        "g2_peak": g2,
        "g2_peak_found": bool(g2_found),
        "g2_over_g1": float(g2 / g1) if g1 else None,
        "gate_width": gw,
        "gates": {"sub_g1_max": float(g1_lo), "g1": [float(g1_lo), float(g1_hi)],
                  "s": [float(g1_hi), float(g2_lo)],
                  "g2m": [float(g2_lo), float(g2_hi)],
                  "above_g2m_min": float(g2_hi)},
        "counts": counts_by_phase,
        "percent": pct_by_phase,
        "histogram": {
            "counts": [int(c) for c in counts],
            "bin_centers": [float(c) for c in centers],
            "bin_width": float(edges[1] - edges[0]) if edges.size > 1 else 0.0,
            "range": [lo, cap],
            "percentile_cap": float(percentile_cap),
        },
        "per_cell": [
            {"label": int(lab_ids[i]), "integrated": float(v[i]),
             "phase": phases[i]}
            for i in range(n_total)
        ],
    }


# ---------------------------------------------------------------------------
# image_stats flattening — mirrors _cellpose_common.emit_payload's namespace.
# ---------------------------------------------------------------------------

def _put(out: dict, key: str, value: Any) -> None:
    """Add a scalar to the flat namespace, skipping None / non-finite."""
    if value is None:
        return
    if isinstance(value, bool):
        out[key] = 1.0 if value else 0.0
        return
    try:
        f = float(value)
    except (TypeError, ValueError):
        return
    if not _math.isfinite(f):
        return
    out[key] = f


def flatten_for_image_stats(results: Any) -> dict[str, float]:
    """Collapse assay result dict(s) into the flat ``image_stats`` namespace.

    Accepts a single assay dict or an iterable of them. Every emitted key is
    prefixed ``assay_`` and every value is a float, so the result merges
    directly into the ``image_stats`` blob that `_cellpose_common.emit_payload`
    already writes (and that the Swift host decodes as ``[String: Double]``).

    Booleans are emitted as 1.0 / 0.0. Failed assays contribute nothing.
    """
    if isinstance(results, dict):
        items = [results]
    else:
        items = list(results or [])

    out: dict[str, float] = {}
    for res in items:
        if not isinstance(res, dict) or not res.get("ok"):
            continue
        name = res.get("assay", "")

        if name in ("marker_positive", "transfection_efficiency"):
            p = "assay_transfection" if name == "transfection_efficiency" else "assay_marker"
            _put(out, f"{p}_channel", res.get("channel"))
            _put(out, f"{p}_threshold", res.get("threshold"))
            _put(out, f"{p}_n_cells", res.get("n_cells"))
            _put(out, f"{p}_n_positive", res.get("n_positive"))
            _put(out, f"{p}_pct_positive", res.get("pct_positive"))
            _put(out, f"{p}_mean_positive", res.get("mean_positive"))
            _put(out, f"{p}_mean_negative", res.get("mean_negative"))
            _put(out, f"{p}_separation_ratio", res.get("separation_ratio"))
            _put(out, f"{p}_bimodality_ratio", res.get("bimodality_ratio"))

        elif name == "nuclear_cytoplasmic":
            _put(out, "assay_nc_channel", res.get("channel"))
            _put(out, "assay_nc_n_cells", res.get("n_cells"))
            _put(out, "assay_nc_n_skipped", res.get("n_skipped"))
            _put(out, "assay_nc_mean", res.get("mean_nc_ratio"))
            _put(out, "assay_nc_median", res.get("median_nc_ratio"))
            _put(out, "assay_nc_sd", res.get("sd_nc_ratio"))

        elif name == "colocalization":
            _put(out, "assay_coloc_channel_a", res.get("channel_a"))
            _put(out, "assay_coloc_channel_b", res.get("channel_b"))
            thr = res.get("thresholds") or {}
            _put(out, "assay_coloc_threshold_a", thr.get("threshold_a"))
            _put(out, "assay_coloc_threshold_b", thr.get("threshold_b"))
            img = res.get("image") or {}
            # NOT `assay_coloc_pearson_image`: the whole-image Pearson counts
            # every background pixel, where both channels are ~0 together, and
            # that shared zero baseline inflates r towards 1 (measured 0.9284
            # against a true in-cell r of -0.0135). Under the old name it sat in
            # the flat namespace as an unqualified peer of the in-cell value —
            # and sorted first. The name now says what it includes.
            _put(out, "assay_coloc_pearson_image_incl_background",
                 img.get("pearson"))
            _put(out, "assay_coloc_m1_image", img.get("manders_m1"))
            _put(out, "assay_coloc_m2_image", img.get("manders_m2"))
            inc = res.get("in_cells") or {}
            _put(out, "assay_coloc_pearson_in_cells", inc.get("pearson"))
            _put(out, "assay_coloc_m1_in_cells", inc.get("manders_m1"))
            _put(out, "assay_coloc_m2_in_cells", inc.get("manders_m2"))
            s = res.get("per_cell_summary") or {}
            _put(out, "assay_coloc_n_cells", s.get("n_cells"))
            _put(out, "assay_coloc_pearson_cells_mean", s.get("pearson_mean"))
            _put(out, "assay_coloc_pearson_cells_median", s.get("pearson_median"))
            _put(out, "assay_coloc_m1_cells_mean", s.get("manders_m1_mean"))
            _put(out, "assay_coloc_m2_cells_mean", s.get("manders_m2_mean"))

        elif name == "live_dead":
            _put(out, "assay_viability_live_channel", res.get("live_channel"))
            _put(out, "assay_viability_dead_channel", res.get("dead_channel"))
            _put(out, "assay_viability_live_threshold", res.get("live_threshold"))
            _put(out, "assay_viability_dead_threshold", res.get("dead_threshold"))
            _put(out, "assay_viability_n_cells", res.get("n_cells"))
            _put(out, "assay_viability_n_live", res.get("n_live"))
            _put(out, "assay_viability_n_dead", res.get("n_dead"))
            _put(out, "assay_viability_n_unlabelled", res.get("n_unlabelled"))
            _put(out, "assay_viability_pct", res.get("pct_viable"))
            _put(out, "assay_viability_pct_of_all", res.get("pct_viable_of_all"))

        elif name == "cell_cycle":
            _put(out, "assay_cellcycle_channel", res.get("dna_channel"))
            _put(out, "assay_cellcycle_n_cells", res.get("n_cells"))
            _put(out, "assay_cellcycle_g1_peak", res.get("g1_peak"))
            _put(out, "assay_cellcycle_g2_peak", res.get("g2_peak"))
            _put(out, "assay_cellcycle_g2_peak_found",
                 1.0 if res.get("g2_peak_found") else 0.0)
            _put(out, "assay_cellcycle_is_estimate", 1.0)
            pct = res.get("percent") or {}
            _put(out, "assay_cellcycle_pct_sub_g1", pct.get("sub_g1"))
            _put(out, "assay_cellcycle_pct_g1", pct.get("g1"))
            _put(out, "assay_cellcycle_pct_s", pct.get("s"))
            _put(out, "assay_cellcycle_pct_g2m", pct.get("g2m"))
            _put(out, "assay_cellcycle_pct_above_g2m", pct.get("above_g2m"))

    return out


# ---------------------------------------------------------------------------
# Registry — lets a CLI / UI enumerate the assays by the name users search for.
# ---------------------------------------------------------------------------

ASSAYS: dict[str, dict[str, Any]] = {
    "marker_positive": {
        "title": "% marker-positive",
        "aliases": ["ki67", "edu", "brdu", "cleaved-caspase", "proliferation",
                    "apoptosis"],
        "min_channels": 1,
        "fn": "marker_positive",
    },
    "nuclear_cytoplasmic": {
        "title": "Nuclear : cytoplasmic ratio",
        "aliases": ["nc-ratio", "translocation", "nuclear-translocation"],
        "min_channels": 1,
        "fn": "nuclear_cytoplasmic",
        "needs": "a nuclear mask in addition to the cell masks",
    },
    "colocalization": {
        "title": "Colocalization (Pearson, Manders)",
        "aliases": ["coloc", "pearson", "manders", "overlap"],
        "min_channels": 2,
        "fn": "colocalization",
    },
    "live_dead": {
        "title": "Live / dead viability",
        "aliases": ["viability", "calcein", "propidium-iodide", "ethd-1"],
        "min_channels": 2,
        "fn": "live_dead",
    },
    "transfection_efficiency": {
        "title": "Transfection efficiency",
        "aliases": ["transfection", "gfp-positive", "reporter"],
        "min_channels": 1,
        "fn": "transfection_efficiency",
    },
    "cell_cycle": {
        "title": "Cell cycle from DNA content (estimate)",
        "aliases": ["cell-cycle", "dna-content", "g1", "s-phase", "g2m",
                    "ploidy"],
        "min_channels": 1,
        "fn": "cell_cycle",
    },
}
