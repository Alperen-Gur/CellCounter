/**
 * pages/batch/BatchTable.tsx — the per-image batch table (feature `feat-batch`).
 *
 * Columns (Swift `BatchView` order): Filename · Status · Cells · Mean Ø (µm) ·
 * Size distribution. Clicking a row opens that image in Results by setting the
 * store's current image index and navigating — the batch page never imports a
 * sibling page's internals (it routes through the shell's `navigate`).
 *
 * The body is WINDOWED with react-window (`FixedSizeList`) so a batch of 100+
 * images only mounts the visible rows (+ a small overscan) instead of every
 * row. Because react-window cannot virtualize `<tr>`s inside a real `<table>`,
 * the table is expressed as a shared CSS-grid column template: one fixed
 * header row plus a virtualized list of grid rows. The template lives in one
 * constant so the header and rows always share the exact same column layout.
 * Row height is FIXED (the size-distribution mini-chart's 2 lines are the
 * tallest cell) — see the PR risks note. Behavior (row click, Enter/Space to
 * open, tooltips, status pills, SizeDistBar) is unchanged.
 */

import { useMemo } from "react";
import { FixedSizeList, type ListChildComponentProps } from "react-window";

import { Icon } from "../../components/Icon";
import { navigate } from "../../components/useHashRoute";
import { useAppStore } from "../../kernel/store/store";
import type { BatchRow, BatchRowStatus } from "./batchStats";
import { SizeDistBar } from "./SizeDistBar";
import { useMeasuredSize } from "../../kernel/viewport/useMeasuredSize";

const STATUS_META: Record<
  BatchRowStatus,
  { label: string; className: string }
> = {
  done: { label: "Done", className: "cc-batch__status--done" },
  queued: { label: "Queued", className: "cc-batch__status--queued" },
  running: { label: "Running", className: "cc-batch__status--running" },
  error: { label: "Error", className: "cc-batch__status--error" },
};

function StatusPill({ status }: { status: BatchRowStatus }) {
  const meta = STATUS_META[status];
  return (
    <span className={`cc-batch__status ${meta.className}`}>
      <span className="cc-batch__status-dot" aria-hidden="true" />
      {meta.label}
    </span>
  );
}

/**
 * Fixed height of one virtualized row, in px. Sized for the tallest cell — the
 * SizeDistBar (6px bar + 8px gap + ~16px legend line) plus the row's 12px
 * top/bottom padding. Kept a hair generous so a wrapped legend never clips.
 * If the row's content grows, bump this (see risks).
 */
const ROW_HEIGHT = 56;

/** Height of the header row (matches its 12px padding + uppercase label line).
 *  The header sits above the internally-scrolling body, so it stays put without
 *  needing position:sticky. */
const HEADER_HEIGHT = 41;

/** Overscan a couple of rows so fast scrolling stays smooth. */
const OVERSCAN = 4;

/**
 * Shared grid column template for the header + every row, so columns line up
 * exactly. Mirrors the previous <table> column intent:
 *   Filename (flex) · Status · Cells · Mean Ø · Size distribution · open-chevron
 */
const GRID_TEMPLATE =
  "minmax(160px, 1fr) 110px 72px 108px 220px 40px";

/**
 * Minimum row width = the filename column's floor (160px) + every fixed column.
 * When the pane is narrower than this, the header + rows render at this width
 * and the wrap scrolls horizontally — exactly like the old `overflow-x: auto`
 * table. Keep in sync with GRID_TEMPLATE.
 */
const MIN_ROW_WIDTH = 160 + 110 + 72 + 108 + 220 + 40;

interface BatchTableProps {
  rows: BatchRow[];
  thresholds: number[];
  /**
   * Canonical image order (`batch.imageIds`) — what `currentImageIdx` indexes
   * into (Results / `useResultsData`), independent of `rows`' natural-sort
   * display order. Used to resolve a clicked row to the right image.
   */
  imageIds: string[];
}

export function BatchTable({ rows, thresholds, imageIds }: BatchTableProps) {
  const setCurrentImageIdx = useAppStore((s) => s.setCurrentImageIdx);
  const { ref, size } = useMeasuredSize<HTMLDivElement>();

  // Resolve a row's stable image id to its position in the canonical order,
  // so a click always opens the TAPPED row's image — never a stale index left
  // over from the table's differently-ordered (natural-sort) display list.
  const canonicalIndex = useMemo(
    () => new Map(imageIds.map((id, i) => [id, i])),
    [imageIds],
  );

  const openInResults = (imageId: string) => {
    const idx = canonicalIndex.get(imageId);
    if (idx === undefined) return;
    setCurrentImageIdx(idx);
    navigate("results");
  };

  // One virtualized row. `style` positions it absolutely inside the list; we
  // overlay the shared grid template on top so cells align with the header.
  const Row = ({ index, style }: ListChildComponentProps) => {
    const row = rows[index];
    return (
      <div
        style={{ ...style, gridTemplateColumns: GRID_TEMPLATE }}
        className="cc-batch__row"
        role="row"
        onClick={() => openInResults(row.imageId)}
        tabIndex={0}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            openInResults(row.imageId);
          }
        }}
        title={`Open ${row.fileName} in Results`}
      >
        <span className="cc-batch__cell cc-batch__col-name" title={row.fileName}>
          <span className="cc-batch__name-text">{row.fileName}</span>
        </span>
        <span className="cc-batch__cell cc-batch__col-status">
          <StatusPill status={row.status} />
        </span>
        <span className="cc-batch__cell cc-batch__col-num">
          {row.cellCount === null ? "—" : row.cellCount}
        </span>
        <span className="cc-batch__cell cc-batch__col-num">
          {row.meanDiameterUm === null ? "—" : row.meanDiameterUm.toFixed(1)}
        </span>
        <span className="cc-batch__cell cc-batch__col-dist">
          <SizeDistBar binCounts={row.binCounts} thresholds={thresholds} />
        </span>
        <span
          className="cc-batch__cell cc-batch__col-go"
          aria-hidden="true"
        >
          <Icon name="chevronRight" size={16} />
        </span>
      </div>
    );
  };

  // List height: fill the measured pane, but never draw taller than the rows
  // need (so a short batch doesn't leave a big empty scroll area).
  const listHeight =
    size.height > 0
      ? Math.min(size.height, rows.length * ROW_HEIGHT)
      : rows.length * ROW_HEIGHT;

  // Render at the pane width, or the row's minimum if the pane is narrower —
  // then the wrap scrolls horizontally, matching the old table. Header + rows
  // share this width so their columns stay aligned while scrolled.
  const contentWidth = Math.max(size.width, MIN_ROW_WIDTH);

  return (
    <div className="cc-batch__table-wrap" role="table" aria-rowcount={rows.length}>
      {/* Header — a single non-virtualized grid row sharing the row column
          template so headings line up with the windowed cells below. */}
      <div
        className="cc-batch__thead"
        role="row"
        style={{
          gridTemplateColumns: GRID_TEMPLATE,
          height: HEADER_HEIGHT,
          width: contentWidth,
        }}
      >
        <span className="cc-batch__th cc-batch__col-name">Filename</span>
        <span className="cc-batch__th cc-batch__col-status">Status</span>
        <span className="cc-batch__th cc-batch__col-num">Cells</span>
        <span className="cc-batch__th cc-batch__col-num">Mean Ø (µm)</span>
        <span className="cc-batch__th cc-batch__col-dist">Size distribution</span>
        <span className="cc-batch__th cc-batch__col-go" aria-label="Open" />
      </div>

      {/* Measured, flex-grow body: react-window owns the vertical scroll. Its
          width equals the content width so no nested horizontal scrollbar
          appears — the wrap (overflow-x: auto) handles narrow panes. */}
      <div ref={ref} className="cc-batch__tbody-viewport">
        {size.width > 0 && rows.length > 0 ? (
          <FixedSizeList
            className="cc-batch__tbody-inner"
            height={listHeight}
            width={contentWidth}
            itemCount={rows.length}
            itemSize={ROW_HEIGHT}
            overscanCount={OVERSCAN}
          >
            {Row}
          </FixedSizeList>
        ) : null}
      </div>
    </div>
  );
}
