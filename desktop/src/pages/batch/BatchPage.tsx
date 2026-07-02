/**
 * pages/batch/BatchPage.tsx — Batch / folder detection screen (feature `feat-batch`).
 *
 * Per-image table for the *current* batch (filename, status, cell count, mean
 * diameter, size-class mini-distribution) plus batch aggregates (total cells,
 * mean±σ cells/image, mean±σ diameter) computed from the saved detections. A
 * ⌘E action hands off to the export feature's per-image summary CSV.
 *
 * BOUNDARIES honored:
 *   - Owns only `pages/batch/`. Routes via the shell's `navigate`; never imports
 *     a sibling page's internals.
 *   - Does NOT run detection (Home dispatches it) — this page only reads saved
 *     results via `PersistencePort` and reflects live status from the store.
 *   - Does NOT implement the CSV writer body. ⌘E opens the shell-provided
 *     `ExportPanel` entry point (the handoff to `feat-export`), which owns the
 *     save-location UX and calls `export_batch_summary_csv`. We deliberately do
 *     not fabricate an output path or pull in a file-dialog dependency here.
 *   - Size-class mini-distribution uses `binIndex` (via batchStats) against the
 *     batch's own thresholds; nothing re-implements binning.
 */

import { useEffect, useState } from "react";

import { ExportPanel } from "../../components/ExportPanel";
import { Icon } from "../../components/Icon";
import { navigate } from "../../components/useHashRoute";
import { useAppStore } from "../../kernel/store/store";
import { BatchTable } from "./BatchTable";
import { batchLabel, meanPmSd } from "./batchStats";
import { useBatchData } from "./useBatchData";
import "./BatchPage.css";

function AggregateCard({
  label,
  value,
  hint,
}: {
  label: string;
  value: string;
  hint?: string;
}) {
  return (
    <div className="cc-batch__stat">
      <div className="cc-batch__stat-value">{value}</div>
      <div className="cc-batch__stat-label">{label}</div>
      {hint ? <div className="cc-batch__stat-hint">{hint}</div> : null}
    </div>
  );
}

export default function BatchPage() {
  const { batch, rows, aggregates, loading, error, reload } = useBatchData();
  const currentBatchId = useAppStore((s) => s.currentBatchId);
  const [exportOpen, setExportOpen] = useState(false);

  // ⌘E → open the export entry point for this batch (feat-export owns the
  // format + save location). Only meaningful when a batch is loaded.
  //
  // The FROZEN keymap (kernel/shortcuts/keymap.ts) has no batch/export scope
  // (same gap feat-compare recorded for its own ⌘E), so we bind ⌘E with a
  // page-local keydown listener rather than adding a scope to the frozen scheme.
  const canExport = batch !== null && rows.length > 0;
  const openExport = () => {
    if (canExport) setExportOpen(true);
  };
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      const typing =
        !!target &&
        (target.tagName === "INPUT" ||
          target.tagName === "TEXTAREA" ||
          target.tagName === "SELECT" ||
          target.isContentEditable);
      if (typing) return;
      if ((e.metaKey || e.ctrlKey) && (e.key === "e" || e.key === "E")) {
        e.preventDefault();
        if (canExport) setExportOpen(true);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [canExport]);

  // ---- empty state: no batch selected ----
  if (!currentBatchId) {
    return (
      <section className="cc-batch cc-batch--empty" aria-label="Batch">
        <div className="cc-batch__empty">
          <span className="cc-batch__empty-glyph" aria-hidden="true">
            <Icon name="batches" size={26} />
          </span>
          <div className="cc-batch__empty-title">No batch open</div>
          <p className="cc-batch__empty-msg">
            Import images from Home to create a batch, then return here to see
            the per-image detection table and aggregate statistics.
          </p>
          <button
            type="button"
            className="cc-btn"
            onClick={() => navigate("home")}
          >
            Go to Home
          </button>
        </div>
      </section>
    );
  }

  return (
    <section className="cc-batch" aria-label="Batch detection">
      <header className="cc-batch__header">
        <div className="cc-batch__title-block">
          <h1 className="cc-batch__title">
            {batch ? batchLabel(batch) : "Batch"}
          </h1>
          {batch ? (
            <div className="cc-batch__subtitle">
              {aggregates
                ? `${aggregates.analyzedImages}/${aggregates.totalImages} images analyzed`
                : `${batch.imageIds.length} images`}
              {batch.condition ? ` · ${batch.condition}` : ""}
            </div>
          ) : null}
        </div>
        <div className="cc-batch__actions">
          <button
            type="button"
            className="cc-btn"
            onClick={reload}
            disabled={loading}
            title="Reload saved detections"
          >
            <Icon name="refresh" size={16} />
            Refresh
          </button>
          <button
            type="button"
            className="cc-btn cc-batch__export-btn"
            onClick={openExport}
            disabled={!canExport}
            title="Export per-image summary CSV (⌘E)"
          >
            <Icon name="download" size={16} />
            Export summary CSV
            <span className="cc-batch__kbd">⌘E</span>
          </button>
        </div>
      </header>

      {aggregates ? (
        <div className="cc-batch__section">
          <div className="cc-batch__section-label">Aggregate</div>
          <div className="cc-batch__stats">
            <AggregateCard
              label="Total cells"
              value={String(aggregates.totalCells)}
              hint={`across ${aggregates.analyzedImages} image${
                aggregates.analyzedImages === 1 ? "" : "s"
              }`}
            />
            <AggregateCard
              label="Cells / image"
              value={meanPmSd(
                aggregates.meanCellsPerImage,
                aggregates.sdCellsPerImage,
              )}
              hint="mean ± σ"
            />
            <AggregateCard
              label="Diameter (µm)"
              value={meanPmSd(
                aggregates.meanDiameterUm,
                aggregates.sdDiameterUm,
              )}
              hint="mean ± σ"
            />
          </div>
        </div>
      ) : null}

      {error ? (
        <div className="cc-batch__error" role="alert">
          <Icon name="alert" size={16} />
          <span>Failed to load batch: {error}</span>
        </div>
      ) : null}

      <div className="cc-batch__section">
        <div className="cc-batch__section-label">Images</div>
        {loading && rows.length === 0 ? (
          <div className="cc-batch__loading">
            <Icon name="clock" size={16} />
            Loading batch…
          </div>
        ) : rows.length === 0 && !error ? (
          <div className="cc-batch__loading">
            <Icon name="image" size={16} />
            This batch has no images yet.
          </div>
        ) : (
          <BatchTable rows={rows} thresholds={batch?.thresholds ?? []} />
        )}
      </div>

      {exportOpen ? (
        <div
          className="cc-batch__export-overlay"
          role="dialog"
          aria-label="Export"
          onClick={(e) => {
            if (e.target === e.currentTarget) setExportOpen(false);
          }}
        >
          <div className="cc-batch__export-sheet">
            <div className="cc-batch__export-head">
              <span className="cc-batch__export-title">
                Export — {batch ? batchLabel(batch) : "batch"}
              </span>
              <button
                type="button"
                className="cc-iconbtn"
                onClick={() => setExportOpen(false)}
                title="Close"
                aria-label="Close"
              >
                <Icon name="close" size={18} />
              </button>
            </div>
            {/* The export feature (feat-export) owns the actual per-image
                summary CSV flow + save location. We mount its entry point here;
                until it lands this shows the export stub. */}
            <ExportPanel />
          </div>
        </div>
      ) : null}
    </section>
  );
}
