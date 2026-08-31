import { Boxes, CheckCircle2, FileKey2, ShieldCheck } from "lucide-react";
import { MODEL_OPTIONS } from "../components/Inspector";
import { getModelManifest } from "../models/catalog";

export function ModelsView({ readyModels, onModelFile }: { readyModels: ReadonlySet<string>; onModelFile: (modelId: "cpsam_v2" | "cp-cyto3" | "sd-fluo") => void }) {
  return (
    <main className="page-view models-view">
      <header className="page-heading"><div><span className="eyebrow">WebGPU catalog</span><h1>Analysis models</h1><p>Exactly three audited model identities. Files are verified before local caching; another model is never substituted.</p></div></header>
      <div className="model-list">
        {MODEL_OPTIONS.map((model, index) => {
          const ready = readyModels.has(model.id);
          const buildRequired = getModelManifest(model.id).artifact.availability === "buildRequired";
          return <article key={model.id} className="model-row"><span className="model-index">0{index + 1}</span><div className="model-symbol"><Boxes size={21} /></div><div className="model-copy"><h2>{model.name}</h2><p>{model.detail} · {model.size}</p><code>{model.id}</code></div><div className="model-state">{ready ? <span className="state-ready"><CheckCircle2 size={15} /> Verified locally</span> : <span><FileKey2 size={15} /> {buildRequired ? "Validated build pending" : "Artifact required"}</span>}<button className="secondary-button" disabled={buildRequired} onClick={() => onModelFile(model.id)}>{ready ? "Replace" : buildRequired ? "Not packaged" : "Add model file"}</button></div></article>;
        })}
      </div>
      <aside className="integrity-note"><ShieldCheck size={19} /><div><strong>Checksum-first by design</strong><p>CellCounter validates the complete ONNX artifact against its versioned manifest before opening a WebGPU session. Invalid or missing artifacts produce a visible error.</p></div></aside>
    </main>
  );
}
