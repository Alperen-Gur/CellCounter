import { useMemo, useState } from "react";
import { AlertTriangle, Check, Construction, ExternalLink, ListChecks, Search, ShieldAlert } from "lucide-react";
import { WEB_PARITY_AREAS, WEB_PARITY_CAPABILITIES, webParityCounts, type WebParityState } from "../parity/webParity";

const stateCopy: Record<WebParityState, { label: string; icon: typeof Check }> = {
  available: { label: "Available", icon: Check },
  buildRequired: { label: "Build required", icon: Construction },
  unsupported: { label: "Unavailable on web", icon: ShieldAlert },
};

export function CapabilitiesView() {
  const [query, setQuery] = useState("");
  const [state, setState] = useState<WebParityState | "all">("all");
  const counts = webParityCounts();
  const visible = useMemo(() => {
    const term = query.trim().toLocaleLowerCase();
    return WEB_PARITY_CAPABILITIES.filter((capability) =>
      (state === "all" || capability.state === state)
      && (!term || `${capability.name} ${capability.area} ${capability.note} ${capability.webSurface}`.toLocaleLowerCase().includes(term)),
    );
  }, [query, state]);

  return (
    <main className="page-view capabilities-view">
      <header className="page-heading capability-heading">
        <div>
          <span className="eyebrow">macOS v1.0.8 parity</span>
          <h1>Every capability, accounted for</h1>
          <p>A source-derived inventory. Browser limits and missing artifacts stay visible instead of disappearing from the product.</p>
        </div>
        <div className="capability-total"><ListChecks size={19} /><strong>47</strong><span>audited capabilities</span></div>
      </header>

      <section className="parity-summary" aria-label="Capability summary">
        <button className={state === "available" ? "active available" : "available"} onClick={() => setState(state === "available" ? "all" : "available")}>
          <Check size={16} /><strong>{counts.available}</strong><span>Available now</span>
        </button>
        <button className={state === "buildRequired" ? "active build" : "build"} onClick={() => setState(state === "buildRequired" ? "all" : "buildRequired")}>
          <Construction size={16} /><strong>{counts.buildRequired}</strong><span>Build required</span>
        </button>
        <button className={state === "unsupported" ? "active unsupported" : "unsupported"} onClick={() => setState(state === "unsupported" ? "all" : "unsupported")}>
          <ShieldAlert size={16} /><strong>{counts.unsupported}</strong><span>Unavailable on web</span>
        </button>
        <p><AlertTriangle size={14} /> “Available” means the browser path exists. Learned segmentation remains separately gated until exact model artifacts pass parity.</p>
      </section>

      <div className="capability-tools">
        <label className="search-field"><Search size={15} /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Find import, assay, export…" aria-label="Search capabilities" /></label>
        <span>{visible.length} of 47 shown</span>
      </div>

      <div className="capability-ledger">
        {WEB_PARITY_AREAS.map((area) => {
          const capabilities = visible.filter((capability) => capability.area === area);
          if (!capabilities.length) return null;
          return (
            <section key={area} className="capability-area">
              <header><h2>{area}</h2><span>{capabilities.length}</span></header>
              <div>
                {capabilities.map((capability) => {
                  const StateIcon = stateCopy[capability.state].icon;
                  return (
                    <article key={capability.id} className={`capability-row state-${capability.state}`}>
                      <span className="capability-state" title={stateCopy[capability.state].label}><StateIcon size={15} /></span>
                      <div className="capability-copy"><h3>{capability.name}</h3><p>{capability.note}</p></div>
                      <div className="capability-surface"><span>{stateCopy[capability.state].label}</span><strong>{capability.webSurface}</strong></div>
                      <details>
                        <summary aria-label={`Show source evidence for ${capability.name}`}><ExternalLink size={14} /></summary>
                        <div>{capability.sourceEvidence.map((path) => <code key={path}>{path}</code>)}</div>
                      </details>
                    </article>
                  );
                })}
              </div>
            </section>
          );
        })}
      </div>
    </main>
  );
}
