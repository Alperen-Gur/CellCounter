/**
 * pages/batch/BatchTable.tsx — the per-image batch table (feature `feat-batch`).
 *
 * Columns (Swift `BatchView` order): Filename · Status · Cells · Mean Ø (µm) ·
 * Size distribution. Clicking a row opens that image in Results by setting the
 * store's current image index and navigating — the batch page never imports a
 * sibling page's internals (it routes through the shell's `navigate`).
 */

import { Icon } from "../../components/Icon";
import { navigate } from "../../components/useHashRoute";
import { useAppStore } from "../../kernel/store/store";
import type { BatchRow, BatchRowStatus } from "./batchStats";
import { SizeDistBar } from "./SizeDistBar";

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

interface BatchTableProps {
  rows: BatchRow[];
  thresholds: number[];
}

export function BatchTable({ rows, thresholds }: BatchTableProps) {
  const setCurrentImageIdx = useAppStore((s) => s.setCurrentImageIdx);

  const openInResults = (index: number) => {
    setCurrentImageIdx(index);
    navigate("results");
  };

  return (
    <div className="cc-batch__table-wrap">
      <table className="cc-batch__table">
        <thead>
          <tr>
            <th className="cc-batch__col-name">Filename</th>
            <th className="cc-batch__col-status">Status</th>
            <th className="cc-batch__col-num">Cells</th>
            <th className="cc-batch__col-num">Mean Ø (µm)</th>
            <th className="cc-batch__col-dist">Size distribution</th>
            <th className="cc-batch__col-go" aria-label="Open" />
          </tr>
        </thead>
        <tbody>
          {rows.map((row, i) => (
            <tr
              key={row.imageId}
              className="cc-batch__row"
              onClick={() => openInResults(i)}
              tabIndex={0}
              onKeyDown={(e) => {
                if (e.key === "Enter" || e.key === " ") {
                  e.preventDefault();
                  openInResults(i);
                }
              }}
              title={`Open ${row.fileName} in Results`}
            >
              <td className="cc-batch__col-name" title={row.fileName}>
                {row.fileName}
              </td>
              <td className="cc-batch__col-status">
                <StatusPill status={row.status} />
              </td>
              <td className="cc-batch__col-num">
                {row.cellCount === null ? "—" : row.cellCount}
              </td>
              <td className="cc-batch__col-num">
                {row.meanDiameterUm === null
                  ? "—"
                  : row.meanDiameterUm.toFixed(1)}
              </td>
              <td className="cc-batch__col-dist">
                <SizeDistBar binCounts={row.binCounts} thresholds={thresholds} />
              </td>
              <td className="cc-batch__col-go" aria-hidden="true">
                <Icon name="chevronRight" size={16} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
