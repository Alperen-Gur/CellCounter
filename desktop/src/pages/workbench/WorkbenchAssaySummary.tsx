import { useEffect, useRef, useState } from "react";
import type { ProjectSnapshot } from "../../../../shared/workbench/protocol";
import type { AssayExperimentSummary, AssayMetrics } from "../../../../shared/workbench/assayProtocol";
import ScientificOutput from "./ScientificOutput";
import WorkbenchCatalogueBrowser, { useCataloguePins } from "./WorkbenchCatalogueBrowser";

type Props = { snapshot: ProjectSnapshot; busy: boolean;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T> };
const fmt = (value: number | null) => value == null ? "—" : value.toLocaleString(undefined, { maximumFractionDigits: 4 });

export default function WorkbenchAssaySummary({ snapshot, busy, read }: Props) {
  const runs = snapshot.assayRuns ?? [];
  const [runId, setRunId] = useState("");
  const [metrics, setMetrics] = useState<AssayMetrics>();
  const [metricPath, setMetricPath] = useState("");
  const [summary, setSummary] = useState<AssayExperimentSummary>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [page, setPage] = useState(0);
  const pinError = useCataloguePins([{ catalogue: "assayRuns", entryId: runId }]);
  const epoch = useRef(0);
  const latest = useRef(read); latest.current = read;
  useEffect(() => {
    setRunId((id) => id || runs[0]?.runId || "");
  }, [snapshot.project.revision]);
  useEffect(() => {
    const generation = ++epoch.current;
    setMetrics(undefined); setSummary(undefined); setLoading(false); setError(""); setPage(0);
    if (!runId || busy) return;
    setLoading(true);
    void latest.current<AssayMetrics>("assay.metrics", { runId }).then((result) => {
      if (generation === epoch.current) {
        setMetrics(result);
        setMetricPath((path) => result.metrics.some((metric) => metric.path === path) ? path : result.metrics[0]?.path ?? "");
      }
    }).catch((cause) => { if (generation === epoch.current) setError(String(cause)); })
      .finally(() => { if (generation === epoch.current) setLoading(false); });
    return () => { epoch.current++; };
  }, [runId, snapshot.project.revision, busy]);
  const summarize = async () => {
    const generation = ++epoch.current; setLoading(true); setError(""); setSummary(undefined); setPage(0);
    try {
      const result = await read<AssayExperimentSummary>("experiment.assay.summary", { runId, metricPath });
      if (epoch.current === generation) setSummary(result);
    } catch (cause) { if (epoch.current === generation) setError(String(cause)); }
    finally { if (epoch.current === generation) setLoading(false); }
  };
  return <section aria-label="Biological specimen assay summaries">
    <h3>Assays across biological specimens</h3>
    <p>Choose a saved assay and an image-level metric. Compatible current results are averaged within each specimen;
      complete specimens receive equal weight within a condition.</p>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    {pinError ? <p className="workbench-error" role="alert">{pinError}</p> : null}
    <WorkbenchCatalogueBrowser catalogues={["assayRuns"]} title="Browse all reference assay settings" disabled={busy || loading} onChoose={(_, entry) => setRunId(String(entry.runId))} />
    <fieldset disabled={busy || loading}>
      <label>Reference assay settings<select value={runId} onChange={(event) => setRunId(event.target.value)}>
        {!runs.length ? <option value="">Save an assay result first</option> : null}
        {runs.map((run) => <option key={run.runId} value={run.runId}>
          {run.assay.replaceAll("_", " ")} · {snapshot.images.find((image) => image.id === run.imageId)?.name ?? run.imageId} · revision {run.revision}{run.stale ? " · previous inputs" : ""}
        </option>)}
      </select></label>
      <label>Image-level metric<select value={metricPath} onChange={(event) => {
        epoch.current++; setMetricPath(event.target.value); setSummary(undefined); setLoading(false);
      }}>
        {!metrics?.metrics.length ? <option value="">No numeric image-level metrics</option> : null}
        {metrics?.metrics.map((metric) => <option key={metric.path} value={metric.path}>{metric.path} · reference value {fmt(metric.value)}</option>)}
      </select></label>
      <button className="cc-btn" disabled={!metrics?.current || !metricPath} onClick={() => void summarize()}>Summarize assay by specimen</button>
    </fieldset>
    {metrics && !metrics.current ? <p>This reference assay has outdated inputs. Recompute it in Measurements and assays, then select the current result.</p> : null}
    {summary ? <>
      <p>{summary.assay.replaceAll("_", " ")} · {summary.metricPath} · revision {summary.sourceRevision}
        {summary.selection.target === "volume" ? ` · time ${(summary.selection.timeIndex ?? 0) + 1} · channel ${(summary.selection.channel ?? 0) + 1}` : " · saved projections"}</p>
      <div className="workbench-table"><table><caption>Condition summaries</caption>
        <thead><tr><th>Experiment</th><th>Condition</th><th>Biological n</th><th>Incomplete specimens</th><th>Mean</th><th>SD across specimens</th></tr></thead>
        <tbody>{summary.conditions.map((condition) => <tr key={JSON.stringify([condition.experiment, condition.condition])}>
          <td>{condition.experiment}</td><td>{condition.condition}</td><td>{condition.biologicalN}</td>
          <td>{condition.excludedIncompleteSpecimens}</td><td>{fmt(condition.mean)}</td><td>{fmt(condition.sd)}</td>
        </tr>)}</tbody>
      </table></div>
      <div className="workbench-table"><table><caption>Individual biological specimens</caption>
        <thead><tr><th>Specimen</th><th>Condition</th><th>Measured / assigned images</th><th>Included</th><th>Mean</th></tr></thead>
        <tbody>{summary.specimens.map((specimen) => <tr key={specimen.id}>
          <td>{specimen.name}</td><td>{specimen.condition}</td><td>{specimen.measuredImageCount} / {specimen.imageCount}</td>
          <td>{specimen.complete ? "Yes" : "No"}</td><td>{fmt(specimen.mean)}</td>
        </tr>)}</tbody>
      </table></div>
      <details><summary>Image contributions and exclusions</summary>
        <div className="workbench-table"><table><thead><tr><th>Image</th><th>Value</th><th>Measurement status</th><th>Assignment</th><th>Reason</th></tr></thead>
          <tbody>{summary.images.slice(page * 100, (page + 1) * 100).map((image) => <tr key={image.imageId}>
            <td>{image.name}</td><td>{fmt(image.value)}</td><td>{image.status}</td><td>{image.assignmentStatus ?? (image.specimenId ? "assigned" : "unassigned")}</td>
            <td>{image.reason ?? "—"}</td>
          </tr>)}</tbody></table></div>
        <div className="workbench-actions">
          <button className="cc-btn" disabled={!page} onClick={() => setPage((value) => value - 1)}>Previous 100</button>
          <span>Page {page + 1}</span>
          <button className="cc-btn" disabled={(page + 1) * 100 >= summary.images.length} onClick={() => setPage((value) => value + 1)}>Next 100</button>
        </div>
      </details>
      <p>{summary.notes.join(" ")}</p>
      <ScientificOutput output={{ units: summary.comparison?.units, parameters: summary.parameters,
        selection: summary.selection, sourceProjection: summary.comparison?.sourceProjection }} />
    </> : null}
  </section>;
}
