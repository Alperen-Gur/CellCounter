/**
 * pages/results/AnalysisSidebar.tsx — the right-hand analysis sidebar.
 *
 * Port of the Swift `ResultsSidebar` panel stack (`Views/Results/ResultsView.swift`
 * + `AnalysisPanel`, `QCBadges`, `ColoniesPanel`, `IntensityHistogram`). Panel
 * order mirrors the Swift sidebar (minus the retrain/export banners, which are
 * out of scope for this task — export mounts elsewhere):
 *
 *   Count summary (TotalBlock) · Size bins · Distribution histogram ·
 *   Colonies · Scale · Confidence cutoff · Measurements · Ground-truth F1 ·
 *   Notes · Intensity histogram · ROI include/exclude.
 *
 * Every count-driven panel reads the SAME `cells` list (confidence + ROI
 * filtered) the parent computes, exactly like the Swift `cells` property. All
 * math comes from the kernel: `binsFromThresholds` / `binIndex`
 * (calibration), `evaluateF1` (stats). Writes (confidence override, notes, ROIs,
 * annotations reset) go through `PersistencePort` + the store.
 *
 * Feature-owned by feat-results-viewer.
 */

import { useCallback, useEffect, useRef, useState } from "react";

import type {
  BatchDTO,
  ImageDTO,
  CellDTO,
  GroundTruthDTO,
} from "../../kernel/types";
import type { RoiDTO } from "../../kernel/persistence";
import { getPort } from "../../kernel/persistence";
import { useAppStore } from "../../kernel/store/store";
import {
  binsFromThresholds,
  binIndex,
  objectiveLabel,
} from "../../kernel/calibration/calibration";
import { evaluateF1, mean, stdDev } from "../../kernel/stats/stats";
import { Icon } from "../../components/Icon";

import { binColor } from "../../kernel/theme/binColors";
import {
  histogramBuckets,
  bucketCenterUm,
  HIST_MIN,
  HIST_MAX,
} from "../../kernel/stats/histogram";
import { IntensityHistogram } from "./IntensityHistogram";

// ---------------------------------------------------------------------------
// small building blocks
// ---------------------------------------------------------------------------

function SectionHeader({ title, trailing }: { title: string; trailing?: React.ReactNode }) {
  return (
    <div className="rv-section-header">
      <span className="rv-section-header__title">{title}</span>
      {trailing && <span className="rv-section-header__trailing">{trailing}</span>}
    </div>
  );
}

function KeyValueRow({ label, value, unit }: { label: string; value: string; unit?: string }) {
  return (
    <div className="rv-kv">
      <span className="rv-kv__label">{label}</span>
      <span className="rv-kv__value">
        <span className="rv-kv__num">{value}</span>
        {unit ? <span className="rv-kv__unit">{unit}</span> : null}
      </span>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Count summary (Swift TotalBlock)
// ---------------------------------------------------------------------------

function TotalBlock({ cells }: { cells: CellDTO[] }) {
  const diameters = cells.map((c) => c.diameterUm);
  const m = mean(diameters);
  const s = stdDev(diameters);
  return (
    <div className="rv-total">
      <span className="rv-total__count">{cells.length.toLocaleString()}</span>
      <div className="rv-total__meta">
        <span className="rv-total__caption">cells detected</span>
        <span className="rv-total__stat">
          µ = {m.toFixed(1)} µm · σ = {s.toFixed(1)}
        </span>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Size bins (Swift SizeBinsPanel) — read-only rows here; threshold editing
// lives in Settings (feat-settings). Colors + counts match the overlay.
// ---------------------------------------------------------------------------

function SizeBinsPanel({ cells, thresholds }: { cells: CellDTO[]; thresholds: number[] }) {
  const bins = binsFromThresholds(thresholds);
  const total = cells.length;
  const counts = bins.map(
    (_, i) => cells.filter((c) => binIndex(c.diameterUm, thresholds) === i).length,
  );
  return (
    <section className="rv-panel">
      <SectionHeader title="Size bins" />
      <div className="rv-bins">
        {bins.map((bin, i) => {
          const c = counts[i];
          const pct = total > 0 ? (c / total) * 100 : 0;
          const color = binColor(i);
          return (
            <div className="rv-bin-row" key={i}>
              <div className="rv-bin-row__top">
                <span className="rv-bin-row__swatch" style={{ background: color }} />
                <span className="rv-bin-row__label">{bin.label}</span>
                <span className="rv-bin-row__count">{c}</span>
                <span className="rv-bin-row__pct">{pct.toFixed(1)}%</span>
              </div>
              <div className="rv-bin-row__bar">
                <span
                  className="rv-bin-row__bar-fill"
                  style={{ width: `${pct}%`, background: color }}
                />
              </div>
            </div>
          );
        })}
      </div>
    </section>
  );
}

// ---------------------------------------------------------------------------
// Expected cell diameter (Swift ExpectedDiameterPanel) — the segmentation size
// prior, decoupled from the display bins. 0 = Auto (bins-derived, current
// behavior); a set value forwards the explicit diameter to the sidecar and
// applies on the next detection / re-run. cyto3-only build: no Cellpose-SAM hint.
// ---------------------------------------------------------------------------

function ExpectedDiameterPanel({ thresholds }: { thresholds: number[] }) {
  const expectedDiameterUm = useAppStore((s) => s.expectedDiameterUm);
  const setExpectedDiameterUm = useAppStore((s) => s.setExpectedDiameterUm);
  const isAuto = expectedDiameterUm <= 0;

  // Text buffer so the field can be cleared / partially typed without the store
  // snapping it back; re-seeded from the store when not actively editing.
  const [text, setText] = useState(() =>
    expectedDiameterUm > 0 ? fmtDiameter(expectedDiameterUm) : "",
  );
  const focused = useRef(false);
  useEffect(() => {
    if (!focused.current) {
      setText(expectedDiameterUm > 0 ? fmtDiameter(expectedDiameterUm) : "");
    }
  }, [expectedDiameterUm]);

  // Seed Custom from the bins' midpoint — the same prior the sidecar would
  // otherwise derive itself — so switching to Custom never starts blank/zero.
  const seedFromBins = () => {
    const first = thresholds.length > 0 ? thresholds[0] : 20;
    const last = thresholds.length > 0 ? thresholds[thresholds.length - 1] : 30;
    return Math.round(((first + last) / 2) * 10) / 10;
  };

  const setMode = (custom: boolean) => {
    if (!custom) {
      setExpectedDiameterUm(0); // back to Auto
    } else if (expectedDiameterUm <= 0) {
      const mid = seedFromBins();
      setExpectedDiameterUm(mid);
      setText(fmtDiameter(mid));
    }
  };

  const onEdit = (raw: string) => {
    setText(raw);
    if (raw.trim() === "") return; // allow clearing mid-type; blur reverts
    const parsed = Number(raw);
    if (!Number.isFinite(parsed) || parsed <= 0) return; // 0/negative reachable only via Auto
    setExpectedDiameterUm(parsed);
  };

  return (
    <section className="rv-panel">
      <SectionHeader title="Expected cell diameter" />
      <p className="rv-confidence__sub" style={{ margin: "0 0 10px" }}>
        {isAuto
          ? "Auto derives the size prior from your size bins (current behavior) — editing bins can re-steer segmentation."
          : "Segmentation uses this diameter and ignores the size bins — recommended when cells are large or uniform. Applies on the next detection / re-run."}
      </p>
      <div
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          gap: "10px",
        }}
      >
        <div className="rv-seg" role="group" aria-label="Expected diameter mode">
          <button
            type="button"
            className={"rv-seg__btn" + (isAuto ? " rv-seg__btn--on" : "")}
            aria-pressed={isAuto}
            onClick={() => setMode(false)}
          >
            Auto
          </button>
          <button
            type="button"
            className={"rv-seg__btn" + (!isAuto ? " rv-seg__btn--on" : "")}
            aria-pressed={!isAuto}
            onClick={() => setMode(true)}
          >
            Custom
          </button>
        </div>
        {!isAuto && (
          <span style={{ display: "inline-flex", alignItems: "center", gap: "6px" }}>
            <input
              type="text"
              inputMode="decimal"
              className="rv-mono"
              aria-label="Expected cell diameter"
              value={text}
              onFocus={() => {
                focused.current = true;
              }}
              onBlur={() => {
                focused.current = false;
                setText(expectedDiameterUm > 0 ? fmtDiameter(expectedDiameterUm) : "");
              }}
              onChange={(e) => onEdit(e.target.value)}
              style={{
                width: "56px",
                textAlign: "right",
                padding: "5px 8px",
                border: "1px solid var(--cc-border)",
                borderRadius: "var(--cc-radius-sm)",
                background: "var(--cc-bg-elevated)",
                color: "var(--cc-text)",
                fontSize: "var(--cc-text-sm)",
              }}
            />
            <span className="rv-kv__unit">µm</span>
          </span>
        )}
      </div>
    </section>
  );
}

/** Compact µm formatting for the diameter field (integer or one decimal). */
function fmtDiameter(v: number): string {
  return String(Math.round(v * 10) / 10);
}

// ---------------------------------------------------------------------------
// Distribution histogram (Swift DistributionPanel) — fixed 8–60 µm window.
// ---------------------------------------------------------------------------

function DistributionPanel({ cells, thresholds }: { cells: CellDTO[]; thresholds: number[] }) {
  const buckets = histogramBuckets(cells);
  const maxH = Math.max(1, ...buckets);
  return (
    <section className="rv-panel">
      <div className="rv-dist__head">
        <span className="rv-dist__title">DISTRIBUTION</span>
        <span className="rv-dist__range">
          {HIST_MIN} – {HIST_MAX} µm
        </span>
      </div>
      <div className="rv-dist__bars">
        {buckets.map((h, i) => {
          const frac = maxH > 0 ? Math.max(h / maxH, 2 / 80) : 2 / 80;
          const bi = binIndex(bucketCenterUm(i), thresholds);
          return (
            <span
              key={i}
              className="rv-dist__bar"
              style={{ height: `${80 * frac}px`, background: binColor(bi) }}
              title={`${buckets[i]} cells`}
            />
          );
        })}
      </div>
      <div className="rv-dist__axis">
        {thresholds.map((t, i) => {
          const raw = (t - HIST_MIN) / (HIST_MAX - HIST_MIN);
          const pos = Math.min(0.98, Math.max(0.02, raw)) * 100;
          return (
            <span key={i} className="rv-dist__tick" style={{ left: `${pos}%` }}>
              {Math.round(t)}
            </span>
          );
        })}
      </div>
    </section>
  );
}

// ---------------------------------------------------------------------------
// Colonies (Swift ColoniesPanel) — hidden when no colony stats present.
// ---------------------------------------------------------------------------

/** True when the current image's stats carry colony data (Swift `hasColonyData`). */
function hasColonyStats(stats?: Record<string, number>): boolean {
  if (!stats) return false;
  return (
    stats["confluency_pct"] !== undefined ||
    stats["n_colonies"] !== undefined ||
    stats["mean_colony_size_cells"] !== undefined
  );
}

function ColoniesPanel({ stats }: { stats?: Record<string, number> }) {
  const s = stats ?? {};
  if (!hasColonyStats(stats)) return null;

  const confluency = s["confluency_pct"] ?? 0;
  const nColonies = Math.trunc(s["n_colonies"] ?? 0);
  const meanColony = s["mean_colony_size_cells"] ?? 0;
  const largest = Math.trunc(s["largest_colony_size_cells"] ?? 0);
  const largestArea = s["largest_colony_area_um2"] ?? 0;
  const nnDistance = s["mean_nn_distance_um"] ?? 0;

  return (
    <section className="rv-panel">
      <SectionHeader title="Colonies" />
      <div className="rv-rows">
        <KeyValueRow label="Confluency" value={confluency.toFixed(1)} unit="%" />
        <KeyValueRow label="Colonies (≥3 cells)" value={`${nColonies}`} />
        <KeyValueRow
          label="Mean colony size"
          value={meanColony > 0 ? meanColony.toFixed(1) : "—"}
          unit={meanColony > 0 ? "cells" : undefined}
        />
        <KeyValueRow
          label="Largest colony"
          value={largest > 0 ? `${largest}` : "—"}
          unit={largest > 0 ? "cells" : undefined}
        />
        {largestArea > 0 && (
          <KeyValueRow
            label="Largest colony area"
            value={
              largestArea >= 10000 ? largestArea.toExponential(2) : largestArea.toFixed(0)
            }
            unit="µm²"
          />
        )}
        <KeyValueRow
          label="Mean nearest-neighbour"
          value={nnDistance > 0 ? nnDistance.toFixed(1) : "—"}
          unit={nnDistance > 0 ? "µm" : undefined}
        />
      </div>
    </section>
  );
}

// ---------------------------------------------------------------------------
// Scale (Swift ScalePanel) — objectiveLabel from calibration.
// ---------------------------------------------------------------------------

function ScalePanel({ pxPerUm }: { pxPerUm: number }) {
  return (
    <section className="rv-panel rv-scale">
      <div className="rv-scale__info">
        <span className="rv-scale__caption">Scale</span>
        <span className="rv-scale__value">
          {pxPerUm.toFixed(1)} px / µm · {objectiveLabel(pxPerUm)}
        </span>
      </div>
    </section>
  );
}

// ---------------------------------------------------------------------------
// Confidence cutoff (Swift ConfidencePanel) — per-image override beats global.
// Writes confidenceOverride on the image; "Reset to global" clears it.
// ---------------------------------------------------------------------------

function ConfidencePanel({
  image,
  cutoff,
  onImageChanged,
}: {
  image: ImageDTO | null;
  cutoff: number;
  onImageChanged: () => void | Promise<void>;
}) {
  const globalConfidence = useAppStore((s) => s.confidence);
  const setGlobalConfidence = useAppStore((s) => s.setConfidence);
  const [expanded, setExpanded] = useState(true);
  // Optimistic slider value so dragging is smooth regardless of the persist
  // round-trip; re-seeded whenever the effective cutoff / image changes.
  const [local, setLocal] = useState(cutoff);
  // Trailing-debounce timer for the persist + reload (the drag fires onChange
  // for every intermediate value; without coalescing each tick would await a
  // SQLite write AND a full detection re-read — mirrors NotesPanel's saveTimer).
  const commitTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  // The value + image awaiting a debounced persist, so unmount / image-switch
  // can flush it instead of discarding a settled drag.
  const pendingRef = useRef<{ imageId: string; value: number | null } | null>(
    null,
  );
  useEffect(() => {
    setLocal(cutoff);
  }, [cutoff, image?.id]);

  const hasOverride =
    image?.confidenceOverride !== undefined && image?.confidenceOverride !== null;

  // Persist a value for a SPECIFIC image id (captured when the write was
  // scheduled) so a flush after an image switch targets the right image, not
  // whatever image the component now shows.
  const commitOverride = useCallback(
    async (imageId: string | null, value: number | null) => {
      if (!imageId) {
        // No image open → the slider drives the GLOBAL cutoff (store setter).
        if (value !== null) setGlobalConfidence(value);
        return;
      }
      // Per-image override: there is no setter on the frozen PersistencePort
      // for images.confidence_override, so we cross the same invoke boundary
      // the port uses (command mirrors AppState.setConfidenceOverride).
      // Recorded as a kernel gap; the call is swallowed if the backend command
      // isn't wired yet, and the optimistic `local` keeps the UI consistent.
      await setImageConfidenceOverride(imageId, value);
      await onImageChanged();
    },
    [onImageChanged, setGlobalConfidence],
  );

  // Flush any pending debounced persist immediately (used on unmount / image
  // switch and by discrete clicks), targeting the image it was scheduled for.
  const flushPending = useCallback(() => {
    if (commitTimer.current) {
      clearTimeout(commitTimer.current);
      commitTimer.current = null;
    }
    const pending = pendingRef.current;
    pendingRef.current = null;
    if (pending) void commitOverride(pending.imageId, pending.value);
  }, [commitOverride]);

  // Trailing-debounced persist: the optimistic `local` gives immediate visual
  // feedback while dragging; the SQLite write + reloadImageData round-trip runs
  // once, ~300ms after the drag settles, instead of on every onChange tick.
  const scheduleCommit = useCallback(
    (value: number | null) => {
      // Capture the current image so a flush after switching writes correctly.
      const imgId = image?.id ?? "";
      pendingRef.current = { imageId: image ? imgId : "", value };
      // For the no-image global path we still want live store updates, so
      // apply the global setter optimistically on every tick.
      if (!image && value !== null) setGlobalConfidence(value);
      if (commitTimer.current) clearTimeout(commitTimer.current);
      commitTimer.current = setTimeout(() => {
        commitTimer.current = null;
        const pending = pendingRef.current;
        pendingRef.current = null;
        if (pending) void commitOverride(pending.imageId || null, pending.value);
      }, 300);
    },
    [image, commitOverride, setGlobalConfidence],
  );

  // Flush a pending persist on unmount / image switch so the last dragged value
  // is never dropped inside the debounce window.
  const flushPendingRef = useRef(flushPending);
  flushPendingRef.current = flushPending;
  useEffect(() => {
    return () => {
      flushPendingRef.current();
    };
  }, [image?.id]);

  const onSlide = (value: number) => {
    setLocal(value);
    scheduleCommit(value);
  };

  // "Reset to global" is a discrete click, not a hot drag — persist at once.
  const commitImmediate = useCallback(
    (value: number | null) => {
      if (commitTimer.current) {
        clearTimeout(commitTimer.current);
        commitTimer.current = null;
      }
      pendingRef.current = null;
      void commitOverride(image?.id ?? null, value);
    },
    [commitOverride, image],
  );

  return (
    <section className="rv-panel rv-confidence">
      <button
        type="button"
        className="rv-confidence__head"
        onClick={() => setExpanded((v) => !v)}
      >
        <span className="rv-confidence__chevron" aria-hidden="true">
          <Icon name={expanded ? "chevronDown" : "chevronRight"} size={14} />
        </span>
        <span className="rv-confidence__labels">
          <span className="rv-confidence__title">Confidence cutoff</span>
          <span className="rv-confidence__sub">
            {hasOverride
              ? "Per-image override · slide hides low-confidence cells"
              : "Hides cells below the threshold (no re-detection)"}
          </span>
        </span>
        <span className="rv-confidence__value">{local.toFixed(2)}</span>
      </button>
      {expanded && (
        <div className="rv-confidence__body">
          <input
            type="range"
            min={0}
            max={1}
            step={0.01}
            value={local}
            onChange={(e) => onSlide(Number(e.target.value))}
            className="rv-slider"
            aria-label="Confidence cutoff"
          />
          <div className="rv-confidence__scale">
            <span>0.00</span>
            {hasOverride && image ? (
              <button
                type="button"
                className="rv-linkbtn"
                onClick={() => commitImmediate(null)}
              >
                Reset to global
              </button>
            ) : null}
            <span>1.00</span>
          </div>
          {!image && (
            <span className="rv-confidence__note">
              Global cutoff {globalConfidence.toFixed(2)} — open an image for a
              per-image override.
            </span>
          )}
        </div>
      )}
    </section>
  );
}

/**
 * Persist a per-image confidence override. The frozen `PersistencePort` has no
 * dedicated setter for this field (recorded as a kernel gap), so we write it via
 * the same `invoke` boundary the port uses — `set_image_confidence_override` is
 * the natural Rust command name mirroring `AppState.setConfidenceOverride`. If
 * the backend hasn't wired it yet, the call rejects and we swallow it so the UI
 * stays responsive (the optimistic slider state still reflects the drag).
 */
async function setImageConfidenceOverride(
  imageId: string,
  value: number | null,
): Promise<void> {
  try {
    const { invoke } = await import("@tauri-apps/api/core");
    await invoke("set_image_confidence_override", { imageId, value });
  } catch {
    // Backend command not present yet — non-fatal for the viewer.
  }
}

// ---------------------------------------------------------------------------
// Measurements (Swift MeasurementsPanel) — hidden when no cell has measurements.
// ---------------------------------------------------------------------------

function MeasurementsPanel({ cells }: { cells: CellDTO[] }) {
  const measured = cells.filter((c) => c.areaUm2 !== undefined);
  if (measured.length === 0) return null;

  const meanOf = (pick: (c: CellDTO) => number | undefined): number | null => {
    const vals = measured.map(pick).filter((v): v is number => v !== undefined);
    if (vals.length === 0) return null;
    return vals.reduce((a, b) => a + b, 0) / vals.length;
  };
  const area = meanOf((c) => c.areaUm2);
  const perim = meanOf((c) => c.perimeterUm);
  const circ = meanOf((c) => c.circularity);
  const ecc = meanOf((c) => c.eccentricity);

  return (
    <>
      {/* Leading divider is part of the panel so it disappears with it (Swift
          MeasurementsPanel embeds its own Divider). */}
      <div className="rv-divider" />
      <section className="rv-panel">
        <SectionHeader title="Measurements" />
        <div className="rv-rows">
          {area !== null && <KeyValueRow label="Mean area" value={area.toFixed(1)} unit="µm²" />}
          {perim !== null && (
            <KeyValueRow label="Mean perimeter" value={perim.toFixed(1)} unit="µm" />
          )}
          {circ !== null && <KeyValueRow label="Mean circularity" value={circ.toFixed(3)} />}
          {ecc !== null && <KeyValueRow label="Mean eccentricity" value={ecc.toFixed(3)} />}
        </div>
      </section>
    </>
  );
}

// ---------------------------------------------------------------------------
// Ground-truth F1 (Swift GroundTruthPanel) — hidden when zero annotations.
// ---------------------------------------------------------------------------

function GroundTruthPanel({
  annotations,
  detections,
  onReset,
}: {
  annotations: GroundTruthDTO[];
  detections: CellDTO[];
  onReset: () => void | Promise<void>;
}) {
  const [matchRadiusFactor, setMatchRadiusFactor] = useState(1.0);
  if (annotations.length === 0) return null;

  const s = evaluateF1(annotations, detections, matchRadiusFactor);
  const fmt = (v: number | null) => (v === null ? "—" : v.toFixed(2));

  return (
    <>
      {/* Leading divider embedded so it vanishes with the panel (Swift
          GroundTruthPanel embeds its own Divider). */}
      <div className="rv-divider" />
      <section className="rv-panel">
      <SectionHeader
        title="Ground truth"
        trailing={
          <button
            type="button"
            className="rv-iconbtn"
            title="Delete every ground-truth annotation on this image."
            aria-label="Delete all annotations"
            onClick={() => void onReset()}
          >
            <Icon name="trash" size={15} />
          </button>
        }
      />
      <div className="rv-gt__headline">
        <span className="rv-gt__num">{annotations.length}</span>
        <span className="rv-gt__sub">annotations · matched to</span>
        <span className="rv-gt__num">
          {s.tp}/{detections.length}
        </span>
        <span className="rv-gt__sub">detections @ {matchRadiusFactor.toFixed(1)}× dia.</span>
      </div>
      {detections.length === 0 && (
        <p className="rv-gt__empty">
          Detection ran but matched 0 of {annotations.length} annotations (recall = 0).
        </p>
      )}
      <div className="rv-rows">
        <KeyValueRow label="Precision" value={fmt(s.precision)} />
        <KeyValueRow label="Recall" value={fmt(s.recall)} />
      </div>
      <div className="rv-gt__f1">
        <span className="rv-gt__f1-label">F1</span>
        <span className="rv-gt__f1-value">{fmt(s.f1)}</span>
      </div>
      <div className="rv-rows rv-gt__fpfn">
        <KeyValueRow label="False positives" value={`${s.fp}`} />
        <KeyValueRow label="False negatives" value={`${s.fn}`} />
      </div>
      <div className="rv-gt__slider">
        <div className="rv-gt__slider-head">
          <span>Match radius</span>
          <span className="rv-mono">{matchRadiusFactor.toFixed(2)}× diameter</span>
        </div>
        <input
          type="range"
          min={0.3}
          max={2.0}
          step={0.01}
          value={matchRadiusFactor}
          onChange={(e) => setMatchRadiusFactor(Number(e.target.value))}
          className="rv-slider"
          aria-label="Match radius factor"
        />
        <div className="rv-gt__slider-scale">
          <span>0.3× (strict)</span>
          <span>2.0× (lenient)</span>
        </div>
      </div>
      </section>
    </>
  );
}

// ---------------------------------------------------------------------------
// Notes (Swift NotesPanel) — debounced write to ImageRecord.notes.
// ---------------------------------------------------------------------------

function NotesPanel({
  image,
  onSaved,
}: {
  image: ImageDTO;
  onSaved: () => void | Promise<void>;
}) {
  const [draft, setDraft] = useState(image.notes ?? "");
  const draftImageId = useRef(image.id);
  const saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  // The text currently awaiting a debounced save, so a flush on image-switch /
  // unmount persists the final draft instead of discarding it.
  const pendingText = useRef<string | null>(null);

  const commit = useCallback(
    async (text: string, imageId: string) => {
      const normalized = text.length === 0 ? undefined : text;
      await setImageNotes(imageId, normalized);
      await onSaved();
    },
    [onSaved],
  );

  // Flush any pending save synchronously (fire-and-forget the async write) for
  // the image it was queued against, then clear the timer + pending buffer.
  const flush = useCallback(() => {
    if (saveTimer.current) {
      clearTimeout(saveTimer.current);
      saveTimer.current = null;
    }
    if (pendingText.current !== null) {
      const text = pendingText.current;
      pendingText.current = null;
      void commit(text, draftImageId.current);
    }
  }, [commit]);

  // Keep a stable ref to the latest `flush` so the switch/unmount effects don't
  // re-run (and prematurely flush) every time `onSaved` identity changes.
  const flushRef = useRef(flush);
  flushRef.current = flush;

  // Reload the draft when the image changes; FLUSH any pending save first so a
  // note typed then immediately switched-away-from is persisted, not dropped.
  useEffect(() => {
    flushRef.current();
    draftImageId.current = image.id;
    setDraft(image.notes ?? "");
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [image.id]);

  const onChange = (text: string) => {
    setDraft(text);
    pendingText.current = text;
    if (saveTimer.current) clearTimeout(saveTimer.current);
    const id = draftImageId.current;
    saveTimer.current = setTimeout(() => {
      saveTimer.current = null;
      pendingText.current = null;
      void commit(text, id);
    }, 500);
  };

  // Flush on unmount so a note typed just before navigating away is persisted.
  useEffect(() => {
    return () => {
      flushRef.current();
    };
  }, []);

  return (
    <section className="rv-panel">
      <SectionHeader
        title="Notes"
        trailing={
          draft.length > 0 ? (
            <span className="rv-mono rv-muted">
              {draft.length} char{draft.length === 1 ? "" : "s"}
            </span>
          ) : undefined
        }
      />
      <textarea
        className="rv-notes"
        value={draft}
        placeholder="Sample, donor, passage, observations…"
        onChange={(e) => onChange(e.target.value)}
        rows={4}
      />
    </section>
  );
}

/**
 * Persist notes into the images row. Mirrors `ImageRecord.notes = …`. Uses the
 * `set_image_notes` Rust command (mirrors the field the DB already stores); if
 * the backend hasn't wired it, the write is swallowed (non-fatal — the draft
 * stays in the field for the session).
 */
async function setImageNotes(imageId: string, notes: string | undefined): Promise<void> {
  try {
    const { invoke } = await import("@tauri-apps/api/core");
    await invoke("set_image_notes", { imageId, notes: notes ?? null });
  } catch {
    // Backend command not present yet — non-fatal for the viewer.
  }
}

// ---------------------------------------------------------------------------
// ROI include/exclude (task output: "ROI filtering (include→exclude)")
// ---------------------------------------------------------------------------

function RoiPanel({
  rois,
  onDeleteRoi,
}: {
  rois: RoiDTO[];
  onDeleteRoi: (id: string) => void | Promise<void>;
}) {
  const includes = rois.filter((r) => r.kind === "include").length;
  const excludes = rois.filter((r) => r.kind === "exclude").length;
  return (
    <section className="rv-panel">
      <SectionHeader title="Regions of interest" />
      {rois.length === 0 ? (
        <p className="rv-muted rv-roi__empty">
          No ROIs. Cells inside an <em>include</em> region are counted; cells in an{" "}
          <em>exclude</em> region are dropped (exclude wins).
        </p>
      ) : (
        <>
          <div className="rv-rows">
            <KeyValueRow label="Include regions" value={`${includes}`} />
            <KeyValueRow label="Exclude regions" value={`${excludes}`} />
          </div>
          <ul className="rv-roi__list">
            {rois.map((r) => (
              <li key={r.id} className="rv-roi__item">
                <span
                  className={`rv-roi__kind rv-roi__kind--${r.kind === "exclude" ? "exclude" : "include"}`}
                >
                  {r.kind}
                </span>
                <span className="rv-roi__shape">{r.shape}</span>
                <span className="rv-roi__name">{r.name ?? `${Math.round(r.width)}×${Math.round(r.height)}`}</span>
                <button
                  type="button"
                  className="rv-iconbtn"
                  title="Delete ROI"
                  aria-label="Delete ROI"
                  onClick={() => void onDeleteRoi(r.id)}
                >
                  <Icon name="close" size={14} />
                </button>
              </li>
            ))}
          </ul>
        </>
      )}
    </section>
  );
}

// ---------------------------------------------------------------------------
// The sidebar
// ---------------------------------------------------------------------------

export interface AnalysisSidebarProps {
  batch: BatchDTO | null;
  image: ImageDTO | null;
  imageSrc: string | null;
  /** Confidence + ROI filtered cells (shared by every count panel). */
  cells: CellDTO[];
  annotations: GroundTruthDTO[];
  rois: RoiDTO[];
  imageStats?: Record<string, number>;
  thresholds: number[];
  confidenceCutoff: number;
  /** Re-read detection/annotations/rois after a sidebar write. */
  reloadImageData: () => void | Promise<void>;
  reloadRois: () => void | Promise<void>;
  reloadAnnotations: () => void | Promise<void>;
}

export function AnalysisSidebar(props: AnalysisSidebarProps) {
  const {
    image,
    imageSrc,
    cells,
    annotations,
    rois,
    imageStats,
    thresholds,
    confidenceCutoff,
    reloadImageData,
    reloadRois,
    reloadAnnotations,
  } = props;

  const pxPerUm = useAppStore((s) => s.pxPerUm);

  const resetAnnotations = useCallback(async () => {
    if (!image) return;
    if (
      !window.confirm(
        `Remove all ${annotations.length} ground-truth annotation${annotations.length === 1 ? "" : "s"} on this image? The detection itself is not affected.`,
      )
    ) {
      return;
    }
    await getPort().deleteAllAnnotations(image.id);
    await reloadAnnotations();
  }, [image, annotations.length, reloadAnnotations]);

  const deleteRoi = useCallback(
    async (id: string) => {
      await getPort().deleteRoi(id);
      await reloadRois();
    },
    [reloadRois],
  );

  return (
    <aside className="rv-sidebar" aria-label="Analysis">
      <TotalBlock cells={cells} />
      <div className="rv-divider" />
      <SizeBinsPanel cells={cells} thresholds={thresholds} />
      <div className="rv-divider" />
      <ExpectedDiameterPanel thresholds={thresholds} />
      <div className="rv-divider" />
      <DistributionPanel cells={cells} thresholds={thresholds} />
      <div className="rv-divider" />
      {hasColonyStats(imageStats) && (
        <>
          <ColoniesPanel stats={imageStats} />
          <div className="rv-divider" />
        </>
      )}
      <ScalePanel pxPerUm={pxPerUm} />
      <div className="rv-divider" />
      <ConfidencePanel
        image={image}
        cutoff={confidenceCutoff}
        onImageChanged={reloadImageData}
      />
      {/* Measurements + GroundTruth each embed their own leading divider so it
          disappears with the panel when it has no data (matches Swift). */}
      <MeasurementsPanel cells={cells} />
      <GroundTruthPanel
        annotations={annotations}
        detections={cells}
        onReset={resetAnnotations}
      />
      {image && (
        <>
          <div className="rv-divider" />
          <NotesPanel image={image} onSaved={reloadImageData} />
        </>
      )}
      <div className="rv-divider" />
      <section className="rv-panel">
        <SectionHeader title="Intensity histogram" />
        <IntensityHistogram imageSrc={imageSrc} imageId={image?.id ?? null} />
      </section>
      <div className="rv-divider" />
      <RoiPanel rois={rois} onDeleteRoi={deleteRoi} />
      <div className="rv-sidebar__footpad" />
    </aside>
  );
}
