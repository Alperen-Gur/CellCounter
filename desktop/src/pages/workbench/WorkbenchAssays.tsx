import { useEffect, useRef, useState } from "react";
import type { ParameterSpec, ParameterValue } from "../../../../shared/workbench/extensionProtocol";
import type { VolumeWorkflowConfiguration } from "../../../../shared/workbench/volumeProtocol";
import AssayParameters from "./AssayParameters";
import ScientificOutput from "./ScientificOutput";
import type { AnalysisParameters, WorkbenchImage } from "../../../../shared/workbench/protocol";
import type { AssaySeriesActions } from "../../../../shared/workbench/assaySeriesProtocol";
import WorkbenchAssaySeries from "./WorkbenchAssaySeries";
import WorkbenchCatalogueBrowser, { useCatalogueEntries } from "./WorkbenchCatalogueBrowser";

type Definition = { id: string; name: string; dimensions: number[];
  requiresAnalysis?: boolean;
  parameters: { properties: Record<string, ParameterSpec>; required: string[] } };
type Run = { runId: string; imageId?: string; assay: string; stale: boolean; revision: number; output?: unknown };
type Props = { imageId: string; images: WorkbenchImage[]; revision: number; busy: boolean; volumeMode: boolean; volume?: VolumeWorkflowConfiguration;
  sourceParameters: Pick<AnalysisParameters, "channel" | "zProjection">; writeBlocked: boolean; seriesActions: AssaySeriesActions;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  act: (operation: string, args: Record<string, unknown>) => Promise<void> };

export default function WorkbenchAssays({ imageId, images, revision, busy, volumeMode, volume, read, act, sourceParameters, writeBlocked, seriesActions }: Props) {
  const [definitions, setDefinitions] = useState<Definition[]>([]);
  const [assay, setAssay] = useState("morphology");
  const [parameters, setParameters] = useState<Record<string, ParameterValue>>({});
  const [output, setOutput] = useState<unknown>();
  const runs = useCatalogueEntries<Run>("assayRuns").filter(run => run.imageId === imageId);
  const [showRuns, setShowRuns] = useState(false);
  const [preview, setPreview] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const epoch = useRef(0);
  const latest = useRef({ read, revision });
  latest.current = { read, revision };
  const definition = definitions.find((item) => item.id === assay);
  const dimension = volumeMode ? 3 : 2;
  const change = (next: Record<string, ParameterValue>) => {
    epoch.current++; setParameters(next); setOutput(undefined); setLoading(false);
  };
  const selection = { imageId, assay, parameters, ...(volumeMode && volume
    ? { target: "volume", timeIndex: volume.timeIndex, channel: volume.channel } : { target: "plane", ...(definition?.requiresAnalysis === false ? { sourceParameters } : {}) }) };

  useEffect(() => {
    let active = true;
    void latest.current.read<{ assays: Definition[] }>("assay.catalog").then((result) => {
      if (active) setDefinitions(result.assays);
    }).catch((cause) => { if (active) setError(String(cause)); });
    return () => { active = false; };
  }, []);
  useEffect(() => {
    epoch.current++; setOutput(undefined); setShowRuns(false); setLoading(false); setError("");
    return () => { epoch.current++; };
  }, [imageId, revision, volumeMode, volume?.timeIndex, volume?.channel, sourceParameters.channel, sourceParameters.zProjection]);
  const inspect = async <T,>(operation: string, args: Record<string, unknown>, apply: (result: T) => void) => {
    const generation = ++epoch.current;
    setLoading(true); setError("");
    try {
      const result = await read<T>(operation, args);
      if (generation === epoch.current && latest.current.revision === revision) apply(result);
    } catch (cause) { if (generation === epoch.current) setError(String(cause)); }
    finally { if (generation === epoch.current) setLoading(false); }
  };
  return <div className="workbench-automation"><details><summary>Measurements and assays</summary>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    <p>Mask-based assays use saved labels and source intensities. Raw-intensity assays use the explicit source selection without inventing objects. Saved results retain their inputs and show when changes require recomputation.</p>
    <WorkbenchCatalogueBrowser catalogues={["assayRuns"]} title="Browse all retained assay records" disabled={busy || loading} onChoose={() => setShowRuns(true)} />
    <fieldset disabled={busy || loading || !imageId}>
      <label>Assay<select value={assay} onChange={(event) => { setAssay(event.target.value); change({}); }}>
        {definitions.map((item) => <option key={item.id} value={item.id} disabled={!item.dimensions.includes(dimension)}>{item.name}</option>)}
      </select></label>
      {definition ? <AssayParameters schema={definition.parameters} values={parameters} onChange={change} imageId={imageId} images={images} /> : null}
      {definition?.requiresAnalysis === false && !volumeMode ? <p>Raw source: channel {sourceParameters.channel + 1} · {sourceParameters.zProjection} Z projection. Uses the active source selectors.</p> : null}
      <div className="workbench-actions">
        <button className="cc-btn" disabled={!definition?.dimensions.includes(dimension) || (volumeMode && !volume)}
          onClick={() => void inspect<{ output: unknown }>("assay.preview", selection, (result) => { setOutput(result.output); setPreview(true); })}>Preview results</button>
        <button className="cc-btn" disabled={writeBlocked || !definition?.dimensions.includes(dimension) || (volumeMode && !volume)}
          onClick={() => void act("assay.run", selection)}>Save results</button>
        <button className="cc-btn" onClick={() => setShowRuns(true)}>Show available saved assays for this image</button>
      </div>
    </fieldset>
    {showRuns && runs.length ? <ul>{runs.map((run) => <li key={run.runId}>
      {definitions.find((item) => item.id === run.assay)?.name ?? run.assay} · revision {run.revision} · {run.stale ? "needs recomputation" : "current"}
      <div className="workbench-actions">
        <button className="cc-btn" disabled={busy || loading} onClick={() => void inspect<{ runs: Run[] }>(
          "assay.results", { runId: run.runId }, (result) => { setOutput(result.runs[0]?.output); setPreview(false); })}>View saved result</button>
        <button className="cc-btn" disabled={busy || loading || writeBlocked} onClick={() => void act("assay.recompute", { runId: run.runId })}>Recompute with current inputs</button>
      </div>
    </li>)}</ul> : null}
    {output ? <><h3>{preview ? "Unsaved preview" : "Saved results"}</h3><ScientificOutput key={`${assay}:${preview}`} output={output} /></> : null}
    <WorkbenchAssaySeries imageId={imageId} revision={revision} busy={busy} writeBlocked={writeBlocked} sourceParameters={sourceParameters} read={read} actions={seriesActions} />
  </details></div>;
}
