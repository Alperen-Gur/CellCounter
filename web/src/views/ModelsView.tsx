import { Boxes, CheckCircle2, CircleHelp, ShieldCheck } from "lucide-react";
import { MODEL_OPTIONS } from "../components/Inspector";
import { getModelManifest } from "../models/catalog";

export function ModelsView({ readyModels, onModelFile }: { readyModels: ReadonlySet<string>; onModelFile: (modelId: import("../domain/types").ModelId) => void }) {
  return <main className="page-view models-view">
    <header className="page-heading"><div><span className="eyebrow">Analysis methods</span><h1>Models</h1><p>The classical method is included and ready to use. Learned models are not available in this browser version.</p></div></header>
    <div className="model-list">{MODEL_OPTIONS.map((model) => {
      const ready = readyModels.has(model.id);
      const buildRequired = model.id !== "classical" && getModelManifest(model.id).artifact.availability === "buildRequired";
      return <article key={model.id} className="model-row"><div className="model-symbol"><Boxes size={22} /></div><div className="model-copy"><h2>{model.name}</h2><p>{model.detail}</p><details><summary>Model details</summary><p>{model.id === "classical" ? "Runs locally using intensity thresholds and optional watershed splitting. No download required. It does not estimate learned confidence." : `${model.size} estimated model size. A tested browser-compatible model file is not yet included. Existing native model files cannot be used directly here.`}</p><code>{model.id}</code></details></div><div className="model-state">{ready ? <span className="state-ready"><CheckCircle2 size={16} /> {model.id === "classical" ? "Available · built in" : "Available on this device"}</span> : <span><CircleHelp size={16} /> {buildRequired ? "Not available in this browser version" : "Model file needed"}</span>}{model.id !== "classical" && !buildRequired && <button className="secondary-button" onClick={() => onModelFile(model.id)}>{ready ? "Replace model file" : "Add model file"}</button>}</div></article>;
    })}</div>
    <aside className="integrity-note"><ShieldCheck size={20} /><div><strong>Analysis stays on your device</strong><p>Choose the built-in classical method in Analyze to get started. Inspect the preview before processing your study.</p></div></aside>
  </main>;
}
