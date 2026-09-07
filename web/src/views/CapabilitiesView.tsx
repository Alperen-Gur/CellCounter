import { useMemo, useState } from "react";
import { AlertTriangle, Check, Construction, ExternalLink, ListChecks, Search, ShieldAlert } from "lucide-react";
import { WEB_PARITY_AREAS, WEB_PARITY_CAPABILITIES, webParityCounts, type WebParityState } from "../parity/webParity";

const stateCopy: Record<WebParityState, { label: string; icon: typeof Check }> = {
  available: { label: "Available", icon: Check },
  buildRequired: { label: "Not yet available", icon: Construction },
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
          <span className="eyebrow">Browser v0.2.0 · Platform support</span>
          <h1>Browser capability inventory</h1>
          <p>Available browser workflows and the native features this version does not support. Expand a feature for its implementation reference.</p>
        </div>
        <div className="capability-total"><ListChecks size={19} /><strong>{WEB_PARITY_CAPABILITIES.length}</strong><span>documented capabilities</span></div>
      </header>

      <section className="parity-summary" aria-label="Capability summary">
        <button className={state === "available" ? "active available" : "available"} onClick={() => setState(state === "available" ? "all" : "available")}>
          <Check size={16} /><strong>{counts.available}</strong><span>Available now</span>
        </button>
        <button className={state === "buildRequired" ? "active build" : "build"} onClick={() => setState(state === "buildRequired" ? "all" : "buildRequired")}>
          <Construction size={16} /><strong>{counts.buildRequired}</strong><span>Not yet available</span>
        </button>
        <button className={state === "unsupported" ? "active unsupported" : "unsupported"} onClick={() => setState(state === "unsupported" ? "all" : "unsupported")}>
          <ShieldAlert size={16} /><strong>{counts.unsupported}</strong><span>Unavailable on web</span>
        </button>
        <p><AlertTriangle size={14} /> Available features run in this browser. Learned segmentation, training, and the native microscopy workspace remain unavailable.</p>
      </section>

      <div className="capability-tools">
        <label className="search-field"><Search size={15} /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Find import, assay, export…" aria-label="Search capabilities" /></label>
        <span>{visible.length} of {WEB_PARITY_CAPABILITIES.length} shown</span>
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
