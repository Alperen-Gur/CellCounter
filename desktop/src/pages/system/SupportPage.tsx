import { useMemo, useState } from "react";
import {
  WINDOWS_PARITY_CAPABILITIES,
  parityCounts,
  type ParityArea,
  type ParityState,
} from "../../platform/windowsParity";
import "./support.css";

const AREAS: readonly ParityArea[] = [
  "Input", "Detection", "Analysis", "Editing", "Workflow", "Export", "System",
];

const STATE_LABEL: Record<ParityState, string> = {
  ready: "Ready",
  adapted: "Windows-adapted",
  pending: "Not yet available",
};

export default function SupportPage() {
  const counts = parityCounts();
  const [showPendingOnly, setShowPendingOnly] = useState(false);
  const grouped = useMemo(
    () => AREAS.map((area) => ({
      area,
      rows: WINDOWS_PARITY_CAPABILITIES.filter(
        (item) => item.area === area && (!showPendingOnly || item.state === "pending"),
      ),
    })).filter((group) => group.rows.length > 0),
    [showPendingOnly],
  );

  return (
    <main className="cc-support" aria-labelledby="support-title">
      <header className="cc-support__header">
        <div>
          <h1 id="support-title">Windows support &amp; platform parity</h1>
          <p>
            CellCounter runs locally. Images, measurements and model inference
            stay on this PC. This inventory tracks every macOS v1.0.8 workflow;
            unavailable work is shown explicitly instead of silently omitted.
          </p>
        </div>
        {counts.pending > 0 ? (
          <button
            type="button"
            className="cc-btn"
            aria-pressed={showPendingOnly}
            onClick={() => setShowPendingOnly((value) => !value)}
          >
            {showPendingOnly ? "Show all capabilities" : `Show ${counts.pending} unavailable`}
          </button>
        ) : <span role="status">All inventoried workflows are available.</span>}
      </header>

      <div className="cc-support__summary" aria-label="Parity summary">
        <Summary value={counts.ready} label="Ready" />
        <Summary value={counts.adapted} label="Windows-adapted" />
        <Summary value={counts.pending} label="Not yet available" />
      </div>

      {grouped.map(({ area, rows }) => (
        <section className="cc-support__section" key={area} aria-labelledby={`parity-${area}`}>
          <h2 id={`parity-${area}`}>{area}</h2>
          <div className="cc-support__table" role="table" aria-label={`${area} capabilities`}>
            {rows.map((row) => (
              <div className="cc-support__row" role="row" key={row.id}>
                <div className="cc-support__capability" role="cell">
                  <strong>{row.name}</strong>
                  <span>{row.note}</span>
                </div>
                <span className="cc-support__surface" role="cell">{row.windowsSurface}</span>
                <span className={`cc-support__state cc-support__state--${row.state}`} role="cell">
                  {STATE_LABEL[row.state]}
                </span>
              </div>
            ))}
          </div>
        </section>
      ))}
    </main>
  );
}

function Summary({ value, label }: { value: number; label: string }) {
  return (
    <div className="cc-support__summary-card">
      <strong>{value}</strong>
      <span>{label}</span>
    </div>
  );
}
