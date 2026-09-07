import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { open } from "@tauri-apps/plugin-dialog";

import { Icon } from "../../components/Icon";
import { useAppStore } from "../../kernel/store/store";
import "./finetune.css";

interface ModelVersion {
  id: string;
  modelId: "cp-cyto3";
  version: number;
  createdAt: string;
  trainedOnImages: number;
  trainedOnCorrections: number;
  checkpointPath: string;
  metrics: Record<string, number>;
}

interface TrainingEvent {
  runId: string;
  stream: "stdout" | "stderr";
  line: string;
}

type RunState =
  | { kind: "idle" }
  | { kind: "running"; runId: string }
  | { kind: "error"; message: string }
  | { kind: "done"; version: ModelVersion };

function newRunId(): string {
  return globalThis.crypto?.randomUUID?.() ?? `train-${Date.now()}-${Math.random()}`;
}

function formatMetric(value: number | undefined): string {
  return Number.isFinite(value) ? value!.toFixed(3) : "unavailable";
}

export default function FineTunePage() {
  const activeModelId = useAppStore((state) => state.activeModelId);
  const setActiveModelId = useAppStore((state) => state.setActiveModelId);
  const [datasetDir, setDatasetDir] = useState("");
  const [epochs, setEpochs] = useState(40);
  const [learningRate, setLearningRate] = useState(0.0002);
  const [batchSize, setBatchSize] = useState(8);
  const [augment, setAugment] = useState(true);
  const [earlyStop, setEarlyStop] = useState(true);
  const [resumeVersionId, setResumeVersionId] = useState("");
  const [versions, setVersions] = useState<ModelVersion[]>([]);
  const [run, setRun] = useState<RunState>({ kind: "idle" });
  const [log, setLog] = useState<string[]>([]);
  const activeRun = useRef<string | null>(null);

  const refreshVersions = async () => {
    setVersions(await invoke<ModelVersion[]>("model_versions"));
  };

  useEffect(() => {
    void refreshVersions();
    let disposed = false;
    let unlisten: (() => void) | undefined;
    void listen<TrainingEvent>("training://progress", (event) => {
      if (disposed || event.payload.runId !== activeRun.current) return;
      setLog((current) => [...current.slice(-79), event.payload.line]);
    }).then((cleanup) => {
      if (disposed) cleanup();
      else unlisten = cleanup;
    });
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, []);

  const chooseDataset = async () => {
    const selected = await open({
      title: "Choose training dataset",
      directory: true,
      multiple: false,
    });
    if (typeof selected === "string") setDatasetDir(selected);
  };

  const start = async () => {
    const runId = newRunId();
    activeRun.current = runId;
    setLog([]);
    setRun({ kind: "running", runId });
    try {
      const version = await invoke<ModelVersion>("run_fine_tune", {
        request: {
          runId,
          datasetDir,
          epochs,
          learningRate,
          batchSize,
          augment,
          earlyStop,
          mixedPrecision: false,
          resumeVersionId: resumeVersionId || null,
        },
      });
      setRun({ kind: "done", version });
      await refreshVersions();
    } catch (reason) {
      setRun({ kind: "error", message: String(reason) });
    } finally {
      activeRun.current = null;
    }
  };

  const cancel = async () => {
    if (run.kind !== "running") return;
    await invoke("cancel_fine_tune", { runId: run.runId });
  };

  return (
    <main className="ft-page">
      <header className="ft-header">
        <div>
          <h1>Fine-tune cyto3</h1>
          <p>Train privately on this computer. Every result stays a version of the built-in cp-cyto3 family.</p>
        </div>
        <span className="ft-local"><Icon name="check" size={14} /> Local only</span>
      </header>

      <section className="ft-card" aria-labelledby="dataset-title">
        <div className="ft-card__number">1</div>
        <div className="ft-card__body">
          <h2 id="dataset-title">Training data</h2>
          <p>Choose reviewed image/mask pairs from at least three independent specimen groups. Each image needs a sibling mask named <code>image_masks.png</code>, <code>.tif</code>, or <code>.npy</code>.</p>
          <div className="ft-picker">
            <button type="button" onClick={() => void chooseDataset()} disabled={run.kind === "running"}>
              <Icon name="folder" size={16} /> Choose folder…
            </button>
            <span title={datasetDir}>{datasetDir || "No dataset selected"}</span>
          </div>
        </div>
      </section>

      <p className="ft-note">Add a <code>groups.json</code> file mapping each image filename to its specimen ID, for example <code>{'{"field1.png":"specimen-A","field2.png":"specimen-B","field3.png":"specimen-C"}'}</code>. Recognized patient filename prefixes can supply groups too. Related fields stay together; duplicate source images are rejected.</p>
      <section className="ft-card" aria-labelledby="config-title">
        <div className="ft-card__number">2</div>
        <div className="ft-card__body">
          <h2 id="config-title">Configuration</h2>
          <div className="ft-grid">
            <label>Epochs<input type="number" min="6" max="500" value={epochs} onChange={(event) => setEpochs(Number(event.target.value))} /></label>
            <label>Learning rate<input type="number" min="0.0000001" max="0.1" step="0.0001" value={learningRate} onChange={(event) => setLearningRate(Number(event.target.value))} /></label>
            <label>Batch size<input type="number" min="1" max="128" value={batchSize} onChange={(event) => setBatchSize(Number(event.target.value))} /></label>
            <label>Resume from<select value={resumeVersionId} onChange={(event) => setResumeVersionId(event.target.value)}><option value="">Base cyto3</option>{versions.map((version) => <option key={version.id} value={version.id}>Version {version.version}</option>)}</select></label>
          </div>
          <div className="ft-checks">
            <label><input type="checkbox" checked={augment} onChange={(event) => setAugment(event.target.checked)} /> Geometric augmentation</label>
            <label><input type="checkbox" checked={earlyStop} onChange={(event) => setEarlyStop(event.target.checked)} /> Early stopping</label>
            <span>CPU training · mixed precision is unavailable in Windows v1.0.8</span>
          </div>
        </div>
      </section>

      <section className="ft-card" aria-labelledby="train-title">
        <div className="ft-card__number">3</div>
        <div className="ft-card__body">
          <h2 id="train-title">Train and evaluate</h2>
          <p>The dataset is split deterministically into train, validation, and held-out test groups. Activation is always a separate explicit action.</p>
          <div className="ft-actions">
            <button className="ft-primary" type="button" onClick={() => void start()} disabled={!datasetDir || run.kind === "running"}>{run.kind === "running" ? "Training…" : "Start fine-tuning"}</button>
            {run.kind === "running" ? <button className="ft-danger" type="button" onClick={() => void cancel()}>Cancel and clean up</button> : null}
          </div>
          {log.length ? <pre className="ft-log" aria-live="polite">{log.join("\n")}</pre> : null}
          {run.kind === "error" ? <div className="ft-error" role="alert">{run.message}</div> : null}
          {run.kind === "done" ? <div className="ft-success" role="status">Version {run.version.version} saved with held-out F1 {formatMetric(run.version.metrics.f1)}. It was not activated automatically.</div> : null}
        </div>
      </section>

      <section className="ft-lineage" aria-labelledby="lineage-title">
        <div className="ft-lineage__head"><div><h2 id="lineage-title">cp-cyto3 lineage</h2><p>Derived checkpoints do not add a fourth built-in model.</p></div><span>{versions.length} version{versions.length === 1 ? "" : "s"}</span></div>
        {versions.length === 0 ? <div className="ft-empty">No fine-tuned versions yet.</div> : (
          <ul>{versions.map((version) => {
            const derivedId = `cp-cyto3@${version.id}`;
            const active = activeModelId === derivedId;
            return <li key={version.id}><div><strong>Version {version.version}</strong><span>{new Date(version.createdAt).toLocaleString()} · {version.trainedOnImages} images · {version.trainedOnCorrections} corrections</span><span>F1 {formatMetric(version.metrics.f1)} · AP50 {formatMetric(version.metrics.ap50)}</span></div><button type="button" disabled={active || run.kind === "running"} onClick={() => setActiveModelId(derivedId)}>{active ? "Active" : "Activate"}</button></li>;
          })}</ul>
        )}
      </section>
    </main>
  );
}
