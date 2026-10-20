import { useEffect, useRef, useState } from "react";
import type { WorkflowSourceSelection } from "../../../../shared/workbench/protocol";
import type { SweepExportArguments, SweepExportFormat, SweepResults, SweepValue } from "../../../../shared/workbench/sweepProtocol";
import { sweepAddressLabel } from "../../../../shared/workbench/sweepProtocol";
import ScientificOutput from "./ScientificOutput";

type Props = {
  sweepId: string; revision: number; busy: boolean; workerActive: boolean;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  exportResults: (format: SweepExportFormat, args: SweepExportArguments, name: string) => Promise<void>;
};
const number = (value: number | null | undefined) => value == null ? "—"
  : value.toLocaleString(undefined, { maximumFractionDigits: 4 });
const setting = (values: SweepValue[]) => values.map((value) =>
  `${sweepAddressLabel(value)} ${value.path}: ${value.value === null ? "omitted (default)" : JSON.stringify(value.value)}`).join(" · ");
const selection = (value: WorkflowSourceSelection, target: "plane" | "volume") =>
  target === "volume" && "timeIndex" in value ? `Time ${value.timeIndex + 1} · channel ${value.channel + 1}`
    : `Channel ${value.channel + 1}${"zProjection" in value ? ` · ${value.zProjection} projection` : ""}`;
const physicalUnit = (unit: "um2" | "um3" | null) => unit === "um3" ? "µm³" : unit === "um2" ? "µm²" : "";

export default function WorkbenchSweepResults({ sweepId, revision, busy, workerActive, read, exportResults }: Props) {
  const [open, setOpen] = useState(false);
  const [offset, setOffset] = useState(0);
  const [attempt, setAttempt] = useState(0);
  const [loaded, setLoaded] = useState<{ revision: number; offset: number; result: SweepResults }>();
  const [formats, setFormats] = useState<SweepExportFormat[]>([]);
  const [formatId, setFormatId] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [formatError, setFormatError] = useState("");
  const latest = useRef(read); latest.current = read;
  const result = loaded?.revision === revision && loaded.offset === offset && loaded.result.sweepId === sweepId ? loaded.result : undefined;
  const chosenFormat = formats.find((format) => format.id === formatId);
  const branching = result?.baseWorkflow?.kind === "dag" || result?.combinations.some((item) => item.branchResults !== undefined) === true;
  const settings = (values: SweepValue[]) => setting(values.map((value) => ({ ...value, nodeName: value.nodeName ||
    (value.nodeId ? result?.baseWorkflow?.graph?.nodes.find((node) => node.id === value.nodeId)?.name : undefined) })));
  const locked = busy || workerActive;

  useEffect(() => { setOffset(0); setLoaded(undefined); }, [sweepId]);
  useEffect(() => {
    if (!open || locked) return;
    let active = true; setLoading(true); setError("");
    void latest.current<SweepResults>("sweep.results", { sweepId, offset, limit: 100 }).then((value) => {
      if (active) setLoaded({ revision, offset, result: value });
    }).catch((cause) => { if (active) setError(String(cause)); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [open, sweepId, revision, offset, locked, attempt]);
  useEffect(() => {
    if (!open || locked || formats.length) return;
    let active = true; setFormatError("");
    void latest.current<{ formats: SweepExportFormat[] }>("sweep.export.catalogue").then((value) => {
      if (active) { setFormats(value.formats); setFormatId(value.formats[0]?.id ?? ""); }
    }).catch((cause) => { if (active) setFormatError(String(cause)); });
    return () => { active = false; };
  }, [open, locked, formats.length, attempt]);

  return <details onToggle={(event) => setOpen(event.currentTarget.open)}>
    <summary>Compare results and export all inputs</summary>
    {open ? <>
      <p>Compare settings using saved object measurements and raw-intensity assay outputs. Object observations count image and time-point measurements;
        they are not biological replicates or an accuracy ranking.</p>
      {branching ? <p>Branching combinations keep object counts separate for each segmentation node. The combination table reports coverage only; object totals are never pooled across technical alternatives.</p> : null}
      {workerActive ? <p role="status">A background worker is updating this project. Results and export controls refresh when it stops.</p> : null}
      {loading && !locked ? <p role="status">Loading saved sweep results…</p> : null}
      {error ? <p className="workbench-error" role="alert">{error}</p> : null}
      {formatError ? <p className="workbench-error" role="alert">Export formats: {formatError}</p> : null}
      <div className="workbench-actions">
        <button type="button" className="cc-btn" disabled={locked || loading} onClick={() => setAttempt((value) => value + 1)}>Refresh results</button>
      </div>
      {result ? <>
        <p>Results at project revision {result.sourceRevision}. {result.complete
          ? "Every comparison input has current measurements."
          : "Some inputs have no current measurements. Complete totals are withheld for affected combinations."}</p>
        {!result.sourceInputsCurrent ? <p className="workbench-error">Source inputs changed after the sweep was created. Stale measurements are excluded.</p> : null}
        <div className="workbench-table"><table>
          <caption>Parameter combinations · all sweep inputs</caption>
          <thead><tr><th scope="col">Combination</th><th scope="col">Settings</th><th scope="col">Job status</th>
            <th scope="col">Current {branching ? "branch/input records" : "inputs"}</th><th scope="col">Pending inputs</th><th scope="col">Stale inputs</th>
            {branching ? <th scope="col">Coverage complete</th> : <><th scope="col">Complete object total</th><th scope="col">Available object observations</th></>}</tr></thead>
          <tbody>{result.combinations.map((combination) => <tr key={combination.index}>
            <th scope="row">{combination.index + 1}</th><td>{settings(combination.values)}</td><td>{combination.status}</td>
            <td>{number(combination.currentInputs)} / {number(combination.totalInputs)}</td>
            <td>{number(combination.pendingInputs)}</td><td>{number(combination.staleInputs)}</td>
            {branching ? <td>{combination.comparisonComplete ? "Yes" : "No"}</td> : <>
              <td>{combination.comparisonComplete ? number(combination.objectObservations) : "Incomplete"}</td>
              <td>{number(combination.availableObjectObservations)}{!combination.comparisonComplete ? " (partial)" : ""}</td>
            </>}
          </tr>)}</tbody>
        </table></div>
        {branching ? <div className="workbench-table"><table>
          <caption>Measurement coverage by branch · no pooling between branches</caption>
          <thead><tr><th scope="col">Combination</th><th scope="col">Branch</th><th scope="col">Current inputs</th>
            <th scope="col">Pending inputs</th><th scope="col">Stale inputs</th><th scope="col">Complete object total</th><th scope="col">Available observations</th></tr></thead>
          <tbody>{result.combinations.flatMap((combination) => (combination.branchResults ?? []).map((branch) => <tr key={`${combination.index}:${branch.nodeId}`}>
            <td>{combination.index + 1}</td><th scope="row">{branch.nodeName || branch.nodeId}</th>
            <td>{number(branch.currentInputs)} / {number(branch.totalInputs)}</td><td>{number(branch.pendingInputs)}</td><td>{number(branch.staleInputs)}</td>
            <td>{branch.objectsAvailable === false ? "No object analysis" : branch.comparisonComplete ? number(branch.objectObservations) : "Incomplete"}</td>
            <td>{branch.objectsAvailable === false ? "Not applicable" : <>{number(branch.availableObjectObservations)}{!branch.comparisonComplete ? " (partial)" : ""}</>}</td>
          </tr>))}</tbody>
        </table></div> : null}
        <div className="workbench-table"><table>
          <caption>Per-input measurements · {result.pagination.total.toLocaleString()} rows in the complete sweep</caption>
          <thead><tr><th scope="col">Combination</th>{branching ? <th scope="col">Branch</th> : null}<th scope="col">Source image</th><th scope="col">Source selection</th>
            <th scope="col">Status</th><th scope="col">Objects</th><th scope="col">Foreground pixels / voxels</th>
            <th scope="col">Mean object pixels / voxels</th><th scope="col">Total area / volume</th>
            <th scope="col">Mean object area / volume</th><th scope="col">Mean object intensity</th><th scope="col">Provenance</th></tr></thead>
          <tbody>{result.rows.map((row, index) => <tr key={`${row.combinationIndex}-${row.sourceImageId}-${result.pagination.offset + index}`}>
            <td>{row.combinationIndex + 1}</td>{branching ? <td>{row.nodeName || row.nodeId || "—"}</td> : null}<th scope="row">{row.sourceName}</th>
            <td>{selection(row.sourceSelection, row.target)}</td>
            <td>{row.status}{row.reason ? <p>{row.reason}</p> : null}{row.assayMetrics ? <details><summary>Source-intensity assay results</summary><ScientificOutput output={row.assayMetrics} />{row.assayMetrics.truncated ? <p>This metric view is bounded. Read the retained assay run for the complete result.</p> : null}</details> : null}</td>
            <td>{row.objectsAvailable === false ? "No object analysis" : number(row.metrics?.objectCount)}</td><td>{number(row.metrics?.foregroundSamples)}</td>
            <td>{number(row.metrics?.meanObjectSizeSamples)}</td>
            <td>{number(row.metrics?.totalPhysicalSize)}{row.metrics?.totalPhysicalSize != null ? ` ${physicalUnit(row.metrics.physicalSizeUnit)}` : ""}</td>
            <td>{number(row.metrics?.meanObjectPhysicalSize)}{row.metrics?.meanObjectPhysicalSize != null ? ` ${physicalUnit(row.metrics.physicalSizeUnit)}` : ""}</td>
            <td>{number(row.metrics?.meanObjectIntensity)}{row.intensityUnits ? <small>{row.intensityUnits}</small> : null}</td>
            <td><details><summary>Input provenance</summary>
              <dl>
                <dt>Analysis selection</dt><dd>{selection(row.selection, row.target)}</dd>
                <dt>Checkpoint</dt><dd>{row.checkpointStatus}</dd>
                <dt>Source image</dt><dd>{row.sourceImageId}</dd>
                <dt>Source SHA-256</dt><dd>{row.sourceHash ?? "—"}</dd>
                {row.nodeId ? <><dt>Branch node</dt><dd>{row.nodeId}</dd></> : null}
                <dt>{row.nodeId ? "Isolated sweep source" : "Variant image"}</dt><dd>{row.variantImageId}</dd>
                <dt>{row.nodeId ? "Segmentation branch output" : "Working image"}</dt><dd>{row.workingImageId ?? (row.nodeId ? "Not produced" : row.variantImageId)}</dd>
                <dt>Job</dt><dd>{row.jobId}</dd>
                <dt>Analysis revision</dt><dd>{row.analysisRevision ?? "—"}</dd>
                <dt>Measurement revision</dt><dd>{row.measurementRevision ?? "—"}</dd>
                <dt>Labels SHA-256</dt><dd>{row.labelsSha256 ?? "—"}</dd>
                {row.assayRunId ? <><dt>Retained assay run</dt><dd>{row.assayRunId}</dd></> : null}
                <dt>Voxel spacing (µm)</dt><dd>{row.voxelSizeUm
                  ? `X ${number(row.voxelSizeUm.x)} · Y ${number(row.voxelSizeUm.y)} · Z ${number(row.voxelSizeUm.z)}` : "Uncalibrated"}</dd>
              </dl>
            </details></td>
          </tr>)}</tbody>
        </table></div>
        {!result.rows.length ? <p>No input rows are available on this page.</p> : null}
        <div className="workbench-actions">
          <button type="button" className="cc-btn" disabled={locked || loading || result.pagination.offset === 0}
            onClick={() => setOffset(Math.max(0, result.pagination.offset - result.pagination.limit))}>Previous inputs</button>
          <span>{result.rows.length ? `${result.pagination.offset + 1}–${result.pagination.offset + result.rows.length}` : "0"} of {result.pagination.total.toLocaleString()} inputs</span>
          <button type="button" className="cc-btn" disabled={locked || loading || result.pagination.nextOffset === null}
            onClick={() => { if (result.pagination.nextOffset !== null) setOffset(result.pagination.nextOffset); }}>Next inputs</button>
        </div>
        {result.notes.length ? <p>{result.notes.join(" ")}</p> : null}
        <fieldset disabled={locked || loading}>
          <legend>Export the complete comparison</legend>
          <label>Format<select value={formatId} onChange={(event) => setFormatId(event.target.value)}>
            {!formats.length ? <option value="">Export formats unavailable</option> : null}
            {formats.map((format) => <option key={format.id} value={format.id}>{format.name}</option>)}
          </select></label>
          {chosenFormat ? <p>{chosenFormat.description}</p> : null}
          <p>The export contains every input row, including explicit pending and stale states. Pagination does not limit exported results.</p>
          <button type="button" className="cc-btn" disabled={!chosenFormat}
            onClick={() => { if (chosenFormat) void exportResults(chosenFormat, { sweepId, format: chosenFormat.id }, result.name); }}>Save complete comparison…</button>
        </fieldset>
      </> : null}
    </> : null}
  </details>;
}
