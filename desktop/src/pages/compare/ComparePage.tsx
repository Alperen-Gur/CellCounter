/**
 * pages/compare/ComparePage.tsx — the Compare screen (feature `feat-compare`).
 *
 * Objective (docs/tasks.json `feat-compare`): condition chips (select 1–4),
 * pooled per-condition diameter histograms sharing one Y-axis, a size-class
 * breakdown per condition, and a Mann–Whitney U + effect-size panel shown ONLY
 * when exactly two conditions are selected; plus a comparison CSV export.
 *
 * Composition:
 *   ChipRow → panels (ConditionPanel × selected) → MannWhitneyPanel (iff 2) →
 *   bottom export bar. State + pooling live in `useCompareData`; the stats math
 *   is the frozen kernel `mannWhitneyU`; binning is kernel calibration; the CSV
 *   columns are the frozen `condition,bin_label,count,percent,total_cells,batches`.
 *
 * BOUNDARIES honored (docs/tasks.json):
 *   - Owns only `pages/compare/`. Routes via the shell's `navigate`; never imports
 *     a sibling page's internals. The bin/histogram/color helpers this page needs
 *     from Results are re-declared locally (byte-for-byte, sourced from the same
 *     Swift originals) rather than imported across page dirs.
 *   - Does NOT modify kernel-stats — it only calls `mannWhitneyU`.
 *   - Implements ONLY the comparison CSV (the Swift Compare view wrote its own,
 *     not via ExportService); no other export format is added here.
 *   - ⌘E is wired with a page-local keydown listener: the frozen keymap
 *     (`kernel/shortcuts/keymap.ts`) defines no `compare`/export scope, and this
 *     task must not edit that kernel file, so the shortcut is handled here as a
 *     page concern (mirrors the Swift ⌘E on CompareView).
 */

import { useCallback, useEffect, useState } from "react";

import { navigate } from "../../components/useHashRoute";
import { Icon } from "../../components/Icon";
import { useAppStore } from "../../kernel/store/store";
import { useCompareData } from "./useCompareData";
import { ChipRow } from "./ChipRow";
import { ConditionPanel } from "./ConditionPanel";
import { MannWhitneyPanel } from "./MannWhitneyPanel";
import {
  buildCompareCsv,
  saveCompareCsv,
  csvTimestamp,
} from "./compareCsv";
import "./ComparePage.css";

/** Transient status shown in the bottom bar after an export attempt. */
type ExportStatus =
  | { kind: "idle" }
  | { kind: "saving" }
  | { kind: "ok"; message: string }
  | { kind: "error"; message: string };

export default function ComparePage() {
  const thresholds = useAppStore((s) => s.thresholds);
  const {
    conditions,
    selected,
    pools,
    bucketsByPool,
    sharedYMax,
    loading,
    minHint,
    error,
    toggle,
    reload,
  } = useCompareData();

  const [status, setStatus] = useState<ExportStatus>({ kind: "idle" });

  const hasSelection = selected.size > 0;
  const canExport = pools.length > 0;

  const doExport = useCallback(async () => {
    if (pools.length === 0) return;
    setStatus({ kind: "saving" });
    const csv = buildCompareCsv(pools, thresholds);
    const filename = `compare-conditions-${csvTimestamp()}.csv`;
    const res = await saveCompareCsv(csv, filename);
    if (res.ok) {
      setStatus({
        kind: "ok",
        message: res.path ? `Saved to ${res.path}` : "Comparison CSV exported.",
      });
    } else if (res.cancelled) {
      setStatus({ kind: "idle" });
    } else {
      setStatus({ kind: "error", message: `Export failed: ${res.error}` });
    }
  }, [pools, thresholds]);

  // ⌘E → export (page-local; the frozen keymap has no compare/export scope).
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      const mod = e.metaKey || e.ctrlKey;
      if (mod && !e.shiftKey && !e.altKey && e.key.toLowerCase() === "e") {
        if (!canExport) return;
        e.preventDefault();
        void doExport();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [canExport, doExport]);

  return (
    <section className="cc-compare" aria-label="Compare conditions">
      {/* chip row */}
      <div className="cc-compare__top">
        <ChipRow
          conditions={conditions}
          selected={selected}
          minHint={minHint}
          onToggle={toggle}
        />
      </div>

      <div className="cc-compare__divider" />

      {/* main body */}
      {conditions.length === 0 ? (
        <EmptyConditions loading={loading} />
      ) : !hasSelection ? (
        <EmptySelection />
      ) : (
        <div className="cc-compare__scroll">
          {error ? (
            <div className="cc-compare__error" role="alert">
              Failed to load comparison: {error}
            </div>
          ) : null}

          {loading && pools.length === 0 ? (
            <div className="cc-compare__loading">Pooling cells…</div>
          ) : null}

          <div className="cc-compare__panels">
            {pools.map((pool, i) => (
              <ConditionPanel
                key={pool.condition}
                pool={pool}
                buckets={bucketsByPool[i] ?? []}
                sharedYMax={sharedYMax}
                thresholds={thresholds}
              />
            ))}
          </div>

          {/* Mann–Whitney only for exactly two selected conditions. */}
          {pools.length === 2 ? (
            <MannWhitneyPanel a={pools[0]} b={pools[1]} />
          ) : null}
        </div>
      )}

      <div className="cc-compare__divider" />

      {/* bottom bar / export */}
      <div className="cc-compare__bottom">
        <span
          className={
            "cc-compare__bottom-note" +
            (status.kind === "error" ? " cc-compare__bottom-note--warn" : "") +
            (status.kind === "ok" ? " cc-compare__bottom-note--ok" : "")
          }
        >
          {status.kind === "error"
            ? status.message
            : status.kind === "ok"
              ? status.message
              : status.kind === "saving"
                ? "Saving…"
                : "CSV: one row per (condition × bin) with count and percentage."}
        </span>
        <div className="cc-compare__bottom-actions">
          <button
            type="button"
            className="cc-btn"
            onClick={reload}
            disabled={loading}
            title="Reload conditions and pooled detections"
          >
            Refresh
          </button>
          <button
            type="button"
            className="cc-btn cc-btn--primary cc-compare__export-btn"
            onClick={() => void doExport()}
            disabled={!canExport || status.kind === "saving"}
            title="Export comparison CSV (⌘E)"
          >
            <Icon name="download" size={16} />
            Export comparison CSV
            <span className="cc-compare__kbd">⌘E</span>
          </button>
        </div>
      </div>
    </section>
  );
}

// ---------------------------------------------------------------------------
// Empty states (port of EmptyConditionsState / EmptySelectionState)
// ---------------------------------------------------------------------------

function EmptyConditions({ loading }: { loading: boolean }) {
  return (
    <div className="cc-compare__empty">
      <span className="cc-compare__empty-glyph" aria-hidden="true">
        <Icon name="compare" size={26} />
      </span>
      <div className="cc-compare__empty-title">
        {loading ? "Loading conditions…" : "No conditions yet"}
      </div>
      <p className="cc-compare__empty-msg">
        Create conditions in Settings → Conditions, then tag your batches when
        importing. Compare pools every batch sharing a condition.
      </p>
      <button
        type="button"
        className="cc-btn"
        onClick={() => navigate("settings")}
      >
        Open Settings
      </button>
    </div>
  );
}

function EmptySelection() {
  return (
    <div className="cc-compare__empty">
      <span className="cc-compare__empty-glyph" aria-hidden="true">
        <Icon name="chevronUp" size={26} />
      </span>
      <div className="cc-compare__empty-title">Pick at least one condition</div>
      <p className="cc-compare__empty-msg">
        Select a chip above to add it to the comparison. Choose two to see the
        Mann–Whitney U test.
      </p>
    </div>
  );
}
