import { useEffect, useMemo, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { open } from "@tauri-apps/plugin-dialog";

import type { BatchDTO, CellDTO, ImageDTO } from "../../kernel/types";
import { getPort } from "../../kernel/persistence";

type Assay = "intensity" | "area" | "puncta" | "tracking" | "neurite";
type ResultState =
  | { kind: "idle" }
  | { kind: "running" }
  | { kind: "done"; value: unknown }
  | { kind: "error"; message: string };

function detectionPayload(image: ImageDTO, cells: CellDTO[]) {
  return {
    width: image.widthPx,
    height: image.heightPx,
    cells: cells.map((cell) => ({
      id: cell.id,
      cx: cell.cx,
      cy: cell.cy,
      contour_px: cell.contourPx,
    })),
  };
}

function flatten(value: unknown, prefix = "", out: Array<[string, string]> = []): Array<[string, string]> {
  if (out.length >= 42) return out;
  if (value === null || typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
    out.push([prefix || "result", value === null ? "—" : String(value)]);
  } else if (Array.isArray(value)) {
    out.push([prefix || "items", `${value.length} item${value.length === 1 ? "" : "s"}`]);
    value.slice(0, 4).forEach((item, index) => flatten(item, `${prefix}[${index}]`, out));
  } else if (typeof value === "object") {
    Object.entries(value as Record<string, unknown>).forEach(([key, child]) =>
      flatten(child, prefix ? `${prefix}.${key}` : key, out),
    );
  }
  return out;
}

export function AdvancedAssaysPanel({
  batch,
  image,
  cells,
  pxPerUm,
}: {
  batch: BatchDTO | null;
  image: ImageDTO;
  cells: CellDTO[];
  pxPerUm: number;
}) {
  const analysisPath = image.analysisPath ?? image.storedPath;
  const [assay, setAssay] = useState<Assay>("intensity");
  const [intensityMode, setIntensityMode] = useState("marker_positive");
  const [areaMode, setAreaMode] = useState("confluence");
  const [primaryChannel, setPrimaryChannel] = useState(0);
  const [secondaryChannel, setSecondaryChannel] = useState(1);
  const [threshold, setThreshold] = useState(0.1);
  const [frameInterval, setFrameInterval] = useState(10);
  const [maxDisplacement, setMaxDisplacement] = useState(50);
  const [neuriteMask, setNeuriteMask] = useState("");
  const [result, setResult] = useState<ResultState>({ kind: "idle" });
  const activeRunId = useRef<string | null>(null);

  useEffect(() => {
    const previous = activeRunId.current;
    if (previous) void invoke("cancel_assay", { runId: previous });
    activeRunId.current = null;
    setResult({ kind: "idle" });
  }, [image.id, cells, assay]);

  useEffect(() => () => {
    const previous = activeRunId.current;
    if (previous) void invoke("cancel_assay", { runId: previous });
  }, []);

  const rows = useMemo(
    () => (result.kind === "done" ? flatten(result.value) : []),
    [result],
  );

  const pickNeuriteMask = async () => {
    const selected = await open({
      title: "Choose neurite mask",
      multiple: false,
      directory: false,
      filters: [{ name: "Mask image", extensions: ["png", "tif", "tiff", "bmp"] }],
    });
    if (typeof selected === "string") setNeuriteMask(selected);
  };

  const run = async () => {
    const runId = globalThis.crypto.randomUUID();
    activeRunId.current = runId;
    setResult({ kind: "running" });
    try {
      let args: string[] = [];
      let payload: unknown = null;
      if (assay === "intensity") {
        args = ["--image", analysisPath, "--assay", intensityMode, "--per-cell"];
        if (intensityMode === "colocalization") {
          args.push("--channel-a", String(primaryChannel), "--channel-b", String(secondaryChannel));
        } else if (intensityMode === "live_dead") {
          args.push("--live-channel", String(primaryChannel), "--dead-channel", String(secondaryChannel));
        } else if (intensityMode === "nuclear_cytoplasmic") {
          args.push("--channel", String(primaryChannel), "--nuclear-channel", String(secondaryChannel));
        } else if (intensityMode === "cell_cycle") {
          args.push("--dna-channel", String(primaryChannel));
        } else {
          args.push("--channel", String(primaryChannel), "--threshold-mode", "otsu");
        }
        payload = detectionPayload(image, cells);
      } else if (assay === "area") {
        args = ["--mode", areaMode, "--pxPerUm", String(pxPerUm)];
        if (areaMode === "scratch-wound" && batch) {
          const all = await getPort().allImages();
          const byId = new Map(all.map((item) => [item.id, item]));
          for (const id of batch.imageIds) {
            const frame = byId.get(id);
            if (frame) args.push("--image", frame.analysisPath ?? frame.storedPath);
          }
        } else {
          args.push("--image", analysisPath);
        }
      } else if (assay === "puncta") {
        args = [
          "--image", analysisPath,
          "--channel", String(primaryChannel),
          "--pxPerUm", String(pxPerUm),
          "--threshold", String(threshold),
        ];
        payload = cells.map((cell) => ({
          label: cell.id,
          polygon: cell.contourPx,
          cx: cell.cx,
          cy: cell.cy,
        }));
      } else if (assay === "tracking") {
        if (!batch || batch.imageIds.length < 2) throw new Error("Tracking needs a batch with at least two ordered frames.");
        const frames = await Promise.all(
          batch.imageIds.map(async (id) => {
            const detection = await getPort().getDetection(id);
            return (detection?.cells ?? []).map((cell) => ({ id: cell.id, cx: cell.cx, cy: cell.cy }));
          }),
        );
        args = [
          "--px-per-um", String(pxPerUm),
          "--frame-interval-min", String(frameInterval),
          "--max-displacement-um", String(maxDisplacement),
        ];
        payload = { frames };
      } else {
        if (!neuriteMask) throw new Error("Choose a neurite mask first.");
        args = [
          "--neurite-mask", neuriteMask,
          "--px-per-um", String(pxPerUm),
          "--soma-radius-um", "8",
        ];
        payload = { cells: cells.map((cell) => ({ id: cell.id, cx: cell.cx, cy: cell.cy })) };
      }
      const value = await invoke<unknown>("run_assay", {
        kind: assay,
        args,
        payloadJson: payload === null ? null : JSON.stringify(payload),
        runId,
      });
      if (activeRunId.current === runId) setResult({ kind: "done", value });
    } catch (reason) {
      if (activeRunId.current === runId) {
        setResult({ kind: "error", message: reason instanceof Error ? reason.message : String(reason) });
      }
    } finally {
      if (activeRunId.current === runId) activeRunId.current = null;
    }
  };

  const cancel = async () => {
    const runId = activeRunId.current;
    if (!runId) return;
    await invoke("cancel_assay", { runId });
  };

  return (
    <section className="rv-assay" aria-label="Advanced assays">
      <div className="rv-assay__title">Advanced assays</div>
      <p className="rv-assay__hint">Local analysis of channels, regions, foci, sequences, and neurites.</p>
      <div className="rv-assay__controls">
        <select value={assay} onChange={(event) => setAssay(event.target.value as Assay)} aria-label="Assay family">
          <option value="intensity">Intensity</option>
          <option value="area">Area / wound / spheroid</option>
          <option value="puncta">Puncta / foci</option>
          <option value="tracking">Tracking / migration</option>
          <option value="neurite">Neurite outgrowth</option>
        </select>
        {assay === "intensity" ? (
          <select value={intensityMode} onChange={(event) => setIntensityMode(event.target.value)} aria-label="Intensity assay">
            <option value="marker_positive">Marker positive</option>
            <option value="nuclear_cytoplasmic">Nuclear : cytoplasmic</option>
            <option value="colocalization">Colocalization</option>
            <option value="live_dead">Live / dead</option>
            <option value="transfection_efficiency">Transfection efficiency</option>
            <option value="cell_cycle">Cell cycle</option>
          </select>
        ) : null}
        {assay === "area" ? (
          <select value={areaMode} onChange={(event) => setAreaMode(event.target.value)} aria-label="Area assay">
            <option value="confluence">Confluence</option>
            <option value="scratch-wound">Scratch / wound series</option>
            <option value="spheroid">Spheroid / organoid</option>
          </select>
        ) : null}
      </div>
      {assay === "intensity" || assay === "puncta" ? (
        <div className="rv-assay__numbers">
          <label>Channel <input type="number" min="0" value={primaryChannel} onChange={(event) => setPrimaryChannel(Number(event.target.value))} /></label>
          {assay === "intensity" ? <label>Second / nuclear <input type="number" min="0" value={secondaryChannel} onChange={(event) => setSecondaryChannel(Number(event.target.value))} /></label> : null}
          {assay === "puncta" ? <label>Threshold <input type="number" min="0" step="0.01" value={threshold} onChange={(event) => setThreshold(Number(event.target.value))} /></label> : null}
        </div>
      ) : null}
      {assay === "tracking" ? (
        <div className="rv-assay__numbers">
          <label>Frame interval <input type="number" min="0.01" value={frameInterval} onChange={(event) => setFrameInterval(Number(event.target.value))} /> min</label>
          <label>Max movement <input type="number" min="0.1" value={maxDisplacement} onChange={(event) => setMaxDisplacement(Number(event.target.value))} /> µm</label>
        </div>
      ) : null}
      {assay === "neurite" ? (
        <button type="button" className="rv-assay__secondary" onClick={() => void pickNeuriteMask()}>
          {neuriteMask ? "Change neurite mask…" : "Choose neurite mask…"}
        </button>
      ) : null}
      <div className="rv-assay__actions">
        <button type="button" className="rv-assay__run" onClick={() => void run()} disabled={result.kind === "running"}>
          {result.kind === "running" ? "Running locally…" : "Run assay"}
        </button>
        {result.kind === "running" ? (
          <button type="button" className="rv-assay__secondary" onClick={() => void cancel()} aria-label="Cancel running assay">Cancel</button>
        ) : null}
      </div>
      {result.kind === "error" ? <div className="rv-assay__error" role="alert">{result.message}</div> : null}
      {rows.length ? (
        <dl className="rv-assay__result">
          {rows.map(([label, value], index) => (
            <div key={`${label}-${index}`}><dt>{label.replace(/_/g, " ")}</dt><dd>{value}</dd></div>
          ))}
        </dl>
      ) : null}
    </section>
  );
}
