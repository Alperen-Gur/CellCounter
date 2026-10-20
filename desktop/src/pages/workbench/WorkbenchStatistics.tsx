import { useState } from "react";
import type { ProjectSnapshot, Specimen } from "../../../../shared/workbench/protocol";
import { useCataloguePins } from "./WorkbenchCatalogueBrowser";
import type { CataloguePage } from "../../../../shared/workbench/catalogueProtocol";
import type { AssayMetrics } from "../../../../shared/workbench/assayProtocol";
import type {
  StatisticalAnalysis, StatisticalBlocker, StatisticalDefinition, StatisticalDesign,
  StatisticalInputTable, StatisticalMetric, StatisticalResult, StatisticalRun, StatisticsActions,
  StatisticsCatalogue, StatisticsExportFormat,
} from "../../../../shared/workbench/statisticsProtocol";
import ScientificOutput from "./ScientificOutput";
import ExperimentFactorEditor, { factorDefinitions, factorDrafts, factorLevels as levels, invalidFactors, type FactorDraft } from "./ExperimentFactorEditor";
import type { AssaySeriesMetric } from "../../../../shared/workbench/assaySeriesProtocol";

type Props = { snapshot: ProjectSnapshot; busy: boolean; writeBlocked: boolean; actions: StatisticsActions;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T> };
type RowDraft = { specimenId: string; subjectId: string; blockId: string; values: Record<string, string>; excluded: boolean; reason: string };
const fmt = (value: number | null | undefined) => value == null ? "—" : value.toLocaleString(undefined, { maximumSignificantDigits: 5 });
const metricNames: Record<StatisticalMetric, string> = { count: "Objects per image", meanAreaPx: "Mean object area (pixels²)", meanAreaUm2: "Mean object area (µm²)", meanVolumeVox: "Mean object size (voxels)", meanVolumeUm3: "Mean object volume (µm³)", meanIntensity: "Mean object intensity" };
const emptyAnalysis = (): StatisticalAnalysis => ({ method: "welch-t", contrasts: [], blocking: "none", covariance: "classical", confidenceLevel: .95, multiplicity: "holm" });
function Blockers({ values }: { values: StatisticalBlocker[] }) {
  return values.length ? <ul className="workbench-error">{values.map((value, index) => <li key={index}>{value.message}{value.specimenId ? ` · specimen ${value.specimenId}` : ""}{value.imageId ? ` · image ${value.imageId}` : ""}</li>)}</ul> : null;
}
function InputTable({ table }: { table: StatisticalInputTable }) {
  const [page, setPage] = useState(0);
  return <><p>{table.rows.filter(row => row.included).length} included biological specimens · {table.imageRows.length} source images.</p>
    <Blockers values={table.blockers} />
    <div className="workbench-table"><table><thead><tr><th>Specimen</th><th>Included</th><th>Image count</th><th>Specimen mean</th><th>Subject / block</th><th>Exclusion</th></tr></thead>
      <tbody>{table.rows.slice(page * 50, (page + 1) * 50).map(row => <tr key={row.specimenId}><th>{row.name}</th><td>{row.included ? "Yes" : "No"}</td><td>{row.imageIds.length}</td><td>{fmt(row.value)}</td><td>{row.subjectId || "—"} / {row.blockId || "—"}</td><td>{row.reason || "—"}</td></tr>)}</tbody></table></div>
    <div className="workbench-actions"><button className="cc-btn" disabled={!page} onClick={() => setPage(value => value - 1)}>Previous specimens</button><button className="cc-btn" disabled={(page + 1) * 50 >= table.rows.length} onClick={() => setPage(value => value + 1)}>Next specimens</button></div>
    <details><summary>Units and image-level input status</summary><ScientificOutput output={{ units: table.units, images: table.imageRows.slice(page * 50, (page + 1) * 50), notes: table.notes }} /><p>Input reports retain the complete specimen table and all source references.</p></details>
  </>;
}
function ResultTable({ value }: { value: StatisticalResult }) {
  return <><p>{value.modelStatus.status} · {value.biologicalN} included biological specimens · {value.analysis.confidenceLevel * 100}% pointwise confidence intervals. Outcome units: {typeof value.units === "string" ? value.units : "assay-declared units (see details)"}.</p>
    <Blockers values={value.blockers} />
    <div className="workbench-table"><table><thead><tr><th>Effect / comparison</th><th>Estimate</th><th>Pointwise interval</th><th>Standard error</th><th>df</th><th>p</th><th>Adjusted p</th><th>Status</th></tr></thead>
      <tbody>{value.results.map(row => <tr key={row.id}><th>{row.id}</th><td>{fmt(row.estimate)}</td><td>{row.confidenceInterval?.map(fmt).join(" to ") ?? "—"}</td><td>{fmt(row.standardError)}</td><td>{fmt(row.degreesOfFreedom)}</td><td>{fmt(row.pValue)}</td><td>{fmt(row.adjustedPValue)}</td><td>{row.status}</td></tr>)}</tbody></table></div>
    <p>Contrasts are comparison minus reference. Adjustment: {value.analysis.multiplicity}; interval coverage is pointwise. Unavailable intervals and p-values remain blank.</p>
    <details><summary>Coefficients, assumptions and model details</summary><ScientificOutput output={{ units: value.units, modelStatus: value.modelStatus, coefficients: value.coefficients, notes: value.notes }} /></details>
  </>;
}

export default function WorkbenchStatistics({ snapshot, busy, writeBlocked, actions, read }: Props) {
  const revision = snapshot.project.revision;
  const specimens = snapshot.experimentalDesign?.specimens ?? [];
  const designs = snapshot.statisticsDesigns ?? [];
  const runs = snapshot.statisticsRuns ?? [];
  const [catalogue, setCatalogue] = useState<StatisticsCatalogue>();
  const [formats, setFormats] = useState<StatisticsExportFormat[]>([]);
  const [exportFormat, setExportFormat] = useState<StatisticsExportFormat["id"]>("results-json");
  const [error, setError] = useState("");
  const [name, setName] = useState("Biological specimen comparison");
  const [outcomeKind, setOutcomeKind] = useState<"measurement" | "assay" | "assay-series">("measurement");
  const [seriesRunId, setSeriesRunId] = useState("");
  const [seriesMetric, setSeriesMetric] = useState<AssaySeriesMetric>("rates.gapAreaPx.slopePerSecond");
  const [metric, setMetric] = useState<StatisticalMetric>("count");
  const [target, setTarget] = useState<"plane" | "volume">("plane");
  const [timeIndex, setTimeIndex] = useState(0);
  const [channel, setChannel] = useState(0);
  const [assayRunId, setAssayRunId] = useState("");
  const [metricPath, setMetricPath] = useState("");
  const [assayMetrics, setAssayMetrics] = useState<AssayMetrics>();
  const [factors, setFactors] = useState<FactorDraft[]>([]);
  const [rows, setRows] = useState<RowDraft[]>([]);
  const [rowPage, setRowPage] = useState(0);
  const [scopeSpecimens, setScopeSpecimens] = useState<Specimen[]>([]);
  const [designId, setDesignId] = useState("");
  const [version, setVersion] = useState(1);
  const [loadedDesign, setLoadedDesign] = useState<StatisticalDesign>();
  const [draftOrigin, setDraftOrigin] = useState<string>();
  const [applicationId, setApplicationId] = useState("");
  const [applicationNotes, setApplicationNotes] = useState<string[]>([]);
  const [designPreview, setDesignPreview] = useState<{ key: string; revision: number; table: StatisticalInputTable }>();
  const [analysis, setAnalysis] = useState<StatisticalAnalysis>(emptyAnalysis);
  const [inference, setInference] = useState<{ key: string; revision: number; result: StatisticalResult }>();
  const [runId, setRunId] = useState("");
  const [savedRun, setSavedRun] = useState<StatisticalRun>();
  const [recomputed, setRecomputed] = useState<{ runId: string; revision: number; result: StatisticalResult }>();
  const pinError = useCataloguePins([{ catalogue: "statisticsDesigns", entryId: designId }, { catalogue: "statisticsRuns", entryId: runId },
    { catalogue: "assayRuns", entryId: assayRunId }, { catalogue: "assaySeriesRuns", entryId: seriesRunId }, { catalogue: "experimentApplications", entryId: applicationId }]);
  const perform = (action: () => Promise<void>) => actions.run(async () => { setError(""); try { await action(); } catch (cause) { setError(String(cause)); } });
  const selectedDesign = designs.find(value => value.id === designId);
  const currentDesign = loadedDesign?.id === designId && loadedDesign.version === version ? loadedDesign : undefined;
  const inferenceFactors = currentDesign?.definition.factors ?? [];
  const selectedRun = runs.find(value => value.id === runId);
  const currentRun = savedRun?.id === runId ? savedRun : undefined;
  const definition: StatisticalDefinition = { name: name.trim(), outcome: outcomeKind === "assay-series" ? { kind: "assay-series", runId: seriesRunId, metricPath: seriesMetric }
    : outcomeKind === "assay" ? { kind: "assay", runId: assayRunId, metricPath }
    : { kind: "measurement", metric, target, ...(target === "volume" ? { timeIndex, channel } : {}) },
    factors: factorDefinitions(factors),
    rows: rows.map(row => ({ specimenId: row.specimenId, ...(row.subjectId.trim() ? { subjectId: row.subjectId.trim() } : {}), ...(row.blockId.trim() ? { blockId: row.blockId.trim() } : {}),
      values: Object.fromEntries(factors.map(factor => [factor.id, factor.kind === "numeric" ? Number(row.values[factor.id]) : row.values[factor.id] ?? ""])) })),
    exclusions: rows.filter(row => row.excluded).map(row => ({ specimenId: row.specimenId, reason: row.reason.trim() })) };
  const definitionKey = JSON.stringify(definition);
  const currentPreview = designPreview?.key === definitionKey && designPreview.revision === revision ? designPreview.table : undefined;
  const incomplete = !name.trim() || invalidFactors(factors) || rows.length === 0
    || rows.some(row => row.excluded && !row.reason.trim() || factors.some(factor => factor.kind === "numeric" ? !row.values[factor.id]?.trim() || !Number.isFinite(Number(row.values[factor.id])) : !levels(factor).includes(row.values[factor.id])))
    || outcomeKind === "assay" && (!assayRunId || !metricPath) || outcomeKind === "assay-series" && !seriesRunId;
  const inferenceArgs = { designId, version, analysis };
  const inferenceKey = JSON.stringify(inferenceArgs);
  const currentInference = inference?.key === inferenceKey && inference.revision === revision ? inference.result : undefined;
  const currentRecompute = recomputed?.runId === runId && recomputed.revision === revision ? recomputed.result : undefined;
  const chosenExport = formats.find(value => value.id === exportFormat);
  const specimenNames = new Map([...scopeSpecimens, ...specimens].map(value => [value.id, value.name]));
  const editRow = (id: string, changes: Partial<RowDraft>) => setRows(previous => previous.map(row => row.specimenId === id ? { ...row, ...changes } : row));
  const loadDraft = (source: StatisticalDefinition) => {
    setName(source.name);
    setOutcomeKind(source.outcome.kind);
    if (source.outcome.kind === "measurement") { setMetric(source.outcome.metric); setTarget(source.outcome.target); setTimeIndex(source.outcome.timeIndex ?? 0); setChannel(source.outcome.channel ?? 0); }
    else if (source.outcome.kind === "assay-series") { setSeriesRunId(source.outcome.runId); setSeriesMetric(source.outcome.metricPath); }
    else { setAssayRunId(source.outcome.runId); setMetricPath(source.outcome.metricPath); }
    setFactors(factorDrafts(source.factors));
    setRows(source.rows.map(row => ({ specimenId: row.specimenId, subjectId: row.subjectId ?? "", blockId: row.blockId ?? "", values: Object.fromEntries(Object.entries(row.values).map(([key, value]) => [key, String(value)])), excluded: !!source.exclusions?.some(item => item.specimenId === row.specimenId), reason: source.exclusions?.find(item => item.specimenId === row.specimenId)?.reason ?? "" })));
    setRowPage(0); setDesignPreview(undefined); setInference(undefined);
    const first = source.factors.find(factor => factor.kind === "categorical" && (factor.levels?.length ?? 0) > 1);
    setAnalysis({ ...emptyAnalysis(), contrasts: first ? [{ id: "comparison_1", factorId: first.id, reference: first.referenceLevel ?? first.levels![0], comparison: first.levels!.find(level => level !== (first.referenceLevel ?? first.levels![0]))! }] : [], ...(first ? {} : { method: "linear-model", terms: source.factors.map(factor => factor.id), interactions: [] }) });
  };
  const loadDefinition = (value: StatisticalDesign) => {
    setLoadedDesign(value); setDesignId(value.id); setVersion(value.version); setDraftOrigin(value.id); setApplicationNotes([]); loadDraft(value.definition);
  };
  const useSpecimens = async () => {
    const retained: Specimen[] = []; let cursor: string | undefined;
    do {
      const page = await read<CataloguePage<Specimen>>("project.catalogue", { catalogue: "specimens", limit: 100, ...(cursor ? { cursor } : {}) });
      if (page.total > 1000) throw new Error("This project has more than 1,000 specimens. Use an explicit layout application to define a bounded comparison.");
      retained.push(...page.entries); cursor = page.nextCursor ?? undefined;
      if (cursor && !page.returned) throw new Error("A specimen descriptor cannot fit the page budget. Resolve the reported record before selecting the full scope.");
    } while (cursor);
    const conditions = [...new Set(retained.map(value => value.condition).filter(Boolean))];
    setScopeSpecimens(retained);
    setDraftOrigin(undefined); setDesignPreview(undefined); setRowPage(0);
    setFactors([{ id: "condition", name: "Condition", kind: "categorical", levels: conditions, levelsText: conditions.join("\n"), referenceLevel: conditions[0] }]);
    setRows(retained.map(value => ({ specimenId: value.id, subjectId: "", blockId: "", values: { condition: value.condition }, excluded: false, reason: "" })));
  };
  const saveDesign = (asVersion: boolean) => {
    if (!currentPreview) return;
    void actions.mutate<{ design: StatisticalDesign }>("statistics.design.save", { ...definition, previewFingerprint: currentPreview.previewFingerprint, ...(asVersion && draftOrigin ? { designId: draftOrigin } : {}) }, result => loadDefinition(result.design));
  };
  const retainRun = () => {
    if (!currentInference) return;
    void actions.mutate<{ run: StatisticalRun }>("statistics.run", { ...inferenceArgs, previewFingerprint: currentInference.previewFingerprint }, result => { setSavedRun(result.run); setRunId(result.run.id); setInference(undefined); });
  };
  return <section className="workbench-automation"><details><summary>Biological-replicate statistics</summary>
    <p>Define the biological specimen table before inference. Image outcomes equally weight assigned fields within each specimen; series outcomes use one compatible current series per specimen. Objects, repeated frames and alternative masks do not create additional replicates.</p>
    <button className="cc-btn" disabled={busy} onClick={() => void perform(async () => { setCatalogue(await read<StatisticsCatalogue>("statistics.catalogue", {})); setFormats((await read<{ formats: StatisticsExportFormat[] }>("statistics.export.catalogue", {})).formats); })}>Read methods and export options</button>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    {pinError ? <p className="workbench-error" role="alert">{pinError}</p> : null}
    {writeBlocked ? <p>Save or discard pending scientific edits and stop conflicting workers before retaining a design, inference result or export.</p> : null}
    <details open><summary>1. Design and specimen inputs</summary>
      <fieldset disabled={busy}>
        <legend>Saved design versions</legend>
        <label>Design<select value={designId} onChange={event => { const item = designs.find(value => value.id === event.target.value); setDesignId(event.target.value); setVersion(item?.version ?? 1); }}><option value="">Choose a saved design</option>{designs.map(value => <option key={value.id} value={value.id}>{value.name} · v{value.version} · {value.inputStatus === "draft" ? `draft · ${value.blockerCount ?? 0} input blockers` : value.inputsCurrent ? "current" : "stale inputs"}</option>)}</select></label>
        <label>Version<input type="number" min={1} max={selectedDesign?.latestVersion ?? 1} step={1} value={version} onChange={event => setVersion(Number(event.target.value))} /></label>
        <button className="cc-btn" disabled={!selectedDesign || version < 1 || version > selectedDesign.latestVersion} onClick={() => void perform(async () => loadDefinition((await read<{ design: StatisticalDesign }>("statistics.design.get", { designId, version })).design))}>Load saved design into editor</button>
        <p>Loading explicitly replaces this design draft. Saved versions and inference runs remain unchanged.</p>
      </fieldset>
      <fieldset disabled={busy}><legend>Outcome</legend>
        <label>Design name<input value={name} maxLength={200} onChange={event => setName(event.target.value)} /></label>
        <label>Outcome source<select value={outcomeKind} onChange={event => setOutcomeKind(event.target.value as typeof outcomeKind)}><option value="measurement">Saved object measurements</option><option value="assay">Saved assay metric</option><option value="assay-series">Scratch-wound series rate</option></select></label>
        {outcomeKind === "measurement" ? <div className="workbench-editor-grid">
          <label>Analysis target<select value={target} onChange={event => { setTarget(event.target.value as typeof target); setMetric("count"); }}><option value="plane">Plane / saved projection</option><option value="volume">Volume at one time and channel</option></select></label>
          <label>Metric<select value={metric} onChange={event => setMetric(event.target.value as StatisticalMetric)}>{(catalogue?.outcomes ?? Object.keys(metricNames).map(id => ({ id: id as StatisticalMetric, targets: id.includes("Volume") ? ["volume"] : id.includes("Area") ? ["plane"] : ["plane", "volume"] }))).filter(value => value.targets.includes(target)).map(value => <option key={value.id} value={value.id}>{metricNames[value.id]}</option>)}</select></label>
          {target === "volume" ? <><label>Time point<input type="number" min={1} max={10001} step={1} value={timeIndex + 1} onChange={event => setTimeIndex(Number(event.target.value) - 1)} /></label><label>Channel<input type="number" min={1} max={32} step={1} value={channel + 1} onChange={event => setChannel(Number(event.target.value) - 1)} /></label></> : <p>Each image uses its saved analysis selection. Incompatible channels, projections or processing recipes remain explicit input blockers in a saved design draft.</p>}
        </div> : outcomeKind === "assay-series" ? <><label>Reference series<select value={seriesRunId} onChange={event => setSeriesRunId(event.target.value)}><option value="">Choose a current retained series</option>{snapshot.assaySeriesRuns?.map(value => <option key={value.runId} value={value.runId} disabled={!value.outputsCurrent}>{value.name} · r{value.revision}{value.outputsCurrent ? "" : " · stale"}</option>)}</select></label>
          <label>Series rate<select value={seriesMetric} onChange={event => setSeriesMetric(event.target.value as AssaySeriesMetric)}>{(catalogue?.seriesOutcomes ?? [
            { metricPath: "rates.gapAreaPx.slopePerSecond", units: "pixels²/s" }, { metricPath: "rates.gapAreaUm2.slopePerSecond", units: "µm²/s" }, { metricPath: "rates.closureFraction.slopePerSecond", units: "1/s" },
          ]).map(value => <option key={value.metricPath} value={value.metricPath}>{value.metricPath.includes("closureFraction") ? "Normalized closure" : value.metricPath.includes("Um2") ? "Calibrated gap-area rate" : "Gap-area rate in pixels"} · {value.units}</option>)}</select></label>
          <p>Each included specimen requires exactly one current, coherent and nonexcluded compatible series. Distinct repeated series block ambiguous selection; frames are never pooled as replicates.</p></> : <><label>Reference assay run<select value={assayRunId} onChange={event => { setAssayRunId(event.target.value); setAssayMetrics(undefined); setMetricPath(""); }}><option value="">Choose a current saved assay</option>{snapshot.assayRuns?.map(value => <option key={value.runId} disabled={value.stale} value={value.runId}>{value.assay} · {snapshot.images.find(image => image.id === value.imageId)?.name ?? value.imageId} · r{value.revision}{value.stale ? " · stale" : ""}</option>)}</select></label>
          <button className="cc-btn" disabled={!assayRunId} onClick={() => void perform(async () => { const value = await read<AssayMetrics>("assay.metrics", { runId: assayRunId }); setAssayMetrics(value); if (!value.metrics.some(item => item.path === metricPath)) setMetricPath(value.metrics[0]?.path ?? ""); })}>Read available assay metrics</button>
          <label>Image-level metric<select value={metricPath} onChange={event => setMetricPath(event.target.value)}><option value="">Choose a numeric summary</option>{assayMetrics?.runId === assayRunId ? assayMetrics.metrics.map(value => <option key={value.path} value={value.path}>{value.path}</option>) : metricPath ? <option value={metricPath}>{metricPath} · from saved design</option> : null}</select></label><p>The reference selects the exact assay recipe and time/channel. Each specimen uses matching current results, not the reference image's value.</p></>}
      </fieldset>
      <fieldset disabled={busy}><legend>Factors and biological specimens</legend>
        <details><summary>Use a retained layout application</summary>
          <label>Layout application<select value={applicationId} onChange={event => setApplicationId(event.target.value)}><option value="">Choose an application</option>{snapshot.experimentApplications?.map(value => <option key={value.id} value={value.id}>{value.experiment} · {value.instanceName} · {value.specimenCount} specimens</option>)}</select></label>
          <p>Choose the outcome above, then explicitly replace this design draft with the application's typed factors and specimen/subject/block rows. Current assignments and global exclusions are evaluated when previewing.</p>
          <button className="cc-btn" disabled={!applicationId || outcomeKind === "assay" && (!assayRunId || !metricPath) || outcomeKind === "assay-series" && !seriesRunId} onClick={() => void perform(async () => {
            const result = await read<{ definition: StatisticalDefinition; notes: string[] }>("experiment.layout.application.statistics", { applicationId, outcome: definition.outcome });
            setLoadedDesign(undefined); setDesignId(""); setDraftOrigin(undefined); setApplicationNotes(result.notes); loadDraft(result.definition);
          })}>Replace draft with application rows</button>
          {applicationNotes.length ? <p>{applicationNotes.join(" ")}</p> : null}
        </details>
        <button className="cc-btn" disabled={(snapshot.cataloguePages?.specimens?.total ?? specimens.length) === 0} onClick={() => void perform(useSpecimens)}>Replace draft with all retained specimens (up to 1,000)</button>
        {(snapshot.cataloguePages?.specimens?.total ?? specimens.length) === 0 ? <p>Create biological specimens in Workflows → Experiments first. Design drafts can be saved before image results are available.</p> : null}
        <p>This explicit action replaces factor and row drafts. It does not change specimen assignments.</p>
        <ExperimentFactorEditor factors={factors} onChange={setFactors} />
        <div className="workbench-table"><table><thead><tr><th>Specimen</th>{factors.map(factor => <th key={factor.id}>{factor.name}{factor.kind === "numeric" && factor.unit ? ` (${factor.unit})` : ""}</th>)}<th>Subject ID</th><th>Block ID</th><th>Exclude with reason</th></tr></thead><tbody>
          {rows.slice(rowPage * 50, (rowPage + 1) * 50).map(row => <tr key={row.specimenId}><th>{specimenNames.get(row.specimenId) ?? row.specimenId}</th>{factors.map(factor => <td key={factor.id}>{factor.kind === "categorical" ? <select aria-label={`${specimenNames.get(row.specimenId)} · ${factor.name}`} value={row.values[factor.id] ?? ""} onChange={event => editRow(row.specimenId, { values: { ...row.values, [factor.id]: event.target.value } })}><option value="">Choose level</option>{levels(factor).map(value => <option key={value} value={value}>{value}</option>)}</select> : <input aria-label={`${specimenNames.get(row.specimenId)} · ${factor.name}`} type="number" step="any" value={row.values[factor.id] ?? ""} onChange={event => editRow(row.specimenId, { values: { ...row.values, [factor.id]: event.target.value } })} />}</td>)}
            <td><input aria-label={`${specimenNames.get(row.specimenId)} subject ID`} value={row.subjectId} onChange={event => editRow(row.specimenId, { subjectId: event.target.value })} /></td><td><input aria-label={`${specimenNames.get(row.specimenId)} block ID`} value={row.blockId} onChange={event => editRow(row.specimenId, { blockId: event.target.value })} /></td>
            <td><label><input type="checkbox" checked={row.excluded} onChange={event => editRow(row.specimenId, { excluded: event.target.checked })} /> Exclude</label>{row.excluded ? <input aria-label={`${specimenNames.get(row.specimenId)} exclusion reason`} value={row.reason} maxLength={2000} onChange={event => editRow(row.specimenId, { reason: event.target.value })} /> : null}</td></tr>)}
        </tbody></table></div><div className="workbench-actions"><button className="cc-btn" disabled={!rowPage} onClick={() => setRowPage(value => value - 1)}>Previous rows</button><button className="cc-btn" disabled={(rowPage + 1) * 50 >= rows.length} onClick={() => setRowPage(value => value + 1)}>Next rows</button></div>
        <p>Subject IDs explicitly pair specimens across conditions. Block IDs specify fixed-effect blocks; neither is inferred from the specimen name.</p>
        {incomplete ? <p>Complete the outcome, at least one factor, every specimen value and each exclusion reason before previewing.</p> : null}
        <button className="cc-btn" disabled={incomplete} onClick={() => void perform(async () => setDesignPreview({ key: definitionKey, revision, table: (await read<{ plan: StatisticalInputTable }>("statistics.design.preview", { ...definition })).plan }))}>Preview specimen input table</button>
      </fieldset>
      {designPreview && !currentPreview ? <p>The design draft or project inputs changed. Preview again before saving.</p> : null}
      {currentPreview ? <><InputTable key={currentPreview.previewFingerprint} table={currentPreview} />{!currentPreview.ready ? <p>This definition can be retained as a design draft. Resolve its input blockers before inference.</p> : null}<div className="workbench-actions"><button className="cc-btn" disabled={busy || writeBlocked} onClick={() => saveDesign(false)}>Save as new design</button><button className="cc-btn" disabled={busy || writeBlocked || !draftOrigin} onClick={() => saveDesign(true)}>Save new version</button></div></> : null}
    </details>
    <details><summary>2. Inference from a saved design</summary>
      {!currentDesign ? <p>Save a design or explicitly load a saved version above before choosing inference settings.</p> : <>
        <p>{currentDesign.name} · version {currentDesign.version} · {currentDesign.includedCount} included specimens{!currentDesign.inputsCurrent ? " · frozen inputs are stale" : ""}. Unsaved design edits do not change this saved table.</p>
        {currentDesign.inputStatus === "draft" ? <p>This saved design has {currentDesign.blockerCount ?? 0} input blockers. Refresh its specimen input preview and save a new ready version before inference.</p> : null}
        <fieldset disabled={busy}><legend>Declared method and comparisons</legend>
          <label>Method<select value={analysis.method} onChange={event => setAnalysis(previous => ({ ...previous, method: event.target.value as StatisticalAnalysis["method"], blocking: "none", covariance: "classical", ...(event.target.value === "linear-model" ? { terms: inferenceFactors.map(value => value.id), interactions: [] } : { terms: [], interactions: [] }) }))}>
            <option value="welch-t">Independent Welch contrasts</option><option value="paired-t">Paired subject contrasts</option><option value="linear-model">Factorial linear model</option></select></label>
          <p>{analysis.method === "paired-t" ? "Every subject must have exactly one specimen at each contrasted level; incomplete or ambiguous pairing blocks inference." : analysis.method === "linear-model" ? "Explicit factor terms, reference levels and optional fixed effects. This is not a mixed or random-effects model." : "Independent biological specimens; approximately normal replicate means, with unequal variances allowed."}</p>
          {analysis.method === "linear-model" ? <><fieldset><legend>Main effects</legend>{inferenceFactors.map(factor => <label key={factor.id}><input type="checkbox" checked={analysis.terms?.includes(factor.id) ?? false} onChange={event => setAnalysis(previous => ({ ...previous, terms: event.target.checked ? [...(previous.terms ?? []), factor.id] : previous.terms?.filter(value => value !== factor.id), interactions: previous.interactions?.filter(pair => event.target.checked || !pair.includes(factor.id)) }))} /> {factor.name}</label>)}</fieldset>
            <fieldset><legend>Two-factor interactions</legend>{inferenceFactors.flatMap((left, index) => inferenceFactors.slice(index + 1).map(right => <label key={`${left.id}:${right.id}`}><input type="checkbox" disabled={!analysis.terms?.includes(left.id) || !analysis.terms?.includes(right.id)} checked={analysis.interactions?.some(pair => pair.includes(left.id) && pair.includes(right.id)) ?? false} onChange={event => setAnalysis(previous => ({ ...previous, interactions: event.target.checked ? [...(previous.interactions ?? []), [left.id, right.id]] : previous.interactions?.filter(pair => !(pair.includes(left.id) && pair.includes(right.id))) }))} /> {left.name} × {right.name}</label>))}</fieldset>
            <label>Fixed-effect blocking<select value={analysis.blocking} onChange={event => setAnalysis(previous => ({ ...previous, blocking: event.target.value as StatisticalAnalysis["blocking"] }))}><option value="none">None</option><option value="subject">Explicit subject ID</option><option value="block">Explicit block ID</option></select></label>
            <label>Covariance estimator<select value={analysis.covariance} onChange={event => setAnalysis(previous => ({ ...previous, covariance: event.target.value as StatisticalAnalysis["covariance"] }))}><option value="classical">Classical homoskedastic</option><option value="HC3">HC3 heteroskedasticity robust</option></select></label></> : null}
          {analysis.contrasts.map((contrast, index) => { const factor = inferenceFactors.find(value => value.id === contrast.factorId); const update = (changes: Partial<typeof contrast>) => setAnalysis(previous => ({ ...previous, contrasts: previous.contrasts.map((value, row) => row === index ? { ...value, ...changes } : value) })); return <fieldset key={index}><legend>Comparison {index + 1}</legend>
            <label>Effect name<input value={contrast.id} maxLength={200} onChange={event => update({ id: event.target.value })} /></label><label>Factor<select value={contrast.factorId} onChange={event => { const value = inferenceFactors.find(item => item.id === event.target.value); update({ factorId: event.target.value, reference: value?.referenceLevel ?? value?.levels?.[0] ?? "", comparison: value?.levels?.find(level => level !== (value.referenceLevel ?? value.levels?.[0])) ?? "" }); }}>{inferenceFactors.filter(value => value.kind === "categorical").map(value => <option key={value.id} value={value.id}>{value.name}</option>)}</select></label>
            <label>Reference<select value={contrast.reference} onChange={event => update({ reference: event.target.value })}>{factor?.levels?.map(value => <option key={value} value={value}>{value}</option>)}</select></label><label>Comparison<select value={contrast.comparison} onChange={event => update({ comparison: event.target.value })}>{factor?.levels?.map(value => <option key={value} value={value}>{value}</option>)}</select></label><button className="cc-btn" onClick={() => setAnalysis(previous => ({ ...previous, contrasts: previous.contrasts.filter((_, row) => row !== index) }))}>Remove comparison</button>
          </fieldset>; })}
          <button className="cc-btn" disabled={analysis.contrasts.length >= 64 || !inferenceFactors.some(value => value.kind === "categorical")} onClick={() => { const factor = inferenceFactors.find(value => value.kind === "categorical"); if (factor) setAnalysis(previous => ({ ...previous, contrasts: [...previous.contrasts, { id: `comparison_${crypto.randomUUID().slice(0, 8)}`, factorId: factor.id, reference: factor.referenceLevel ?? factor.levels![0], comparison: factor.levels!.find(value => value !== (factor.referenceLevel ?? factor.levels![0]))! }] })); }}>Add comparison</button>
          <label>Confidence level<input type="number" min={.8} max={.999} step={.001} value={analysis.confidenceLevel} onChange={event => setAnalysis(previous => ({ ...previous, confidenceLevel: Number(event.target.value) }))} /></label>
          <label>Multiple-testing adjustment<select value={analysis.multiplicity} onChange={event => setAnalysis(previous => ({ ...previous, multiplicity: event.target.value as StatisticalAnalysis["multiplicity"] }))}><option value="holm">Holm</option><option value="benjamini-hochberg">Benjamini–Hochberg</option><option value="none">None (explicitly unadjusted)</option></select></label>
          <button className="cc-btn" disabled={!currentDesign.inputsCurrent || currentDesign.inputStatus === "draft"} onClick={() => void perform(async () => setInference({ key: inferenceKey, revision, result: (await read<{ preview: StatisticalResult }>("statistics.preview", inferenceArgs)).preview }))}>Preview inference</button>
        </fieldset>
        {inference && !currentInference ? <p>Inference settings or saved inputs changed. Preview again before retaining results.</p> : null}
        {currentInference ? <><ResultTable value={currentInference} /><button className="cc-btn" disabled={busy || writeBlocked || currentInference.status !== "ready"} onClick={retainRun}>Save inference result</button></> : null}
      </>}
    </details>
    <details><summary>3. Retained results, recomputation and export</summary>
      <fieldset disabled={busy}><legend>Saved result</legend><label>Result<select value={runId} onChange={event => { setRunId(event.target.value); setRecomputed(undefined); }}><option value="">Choose a retained result</option>{runs.map(value => <option key={value.id} value={value.id}>{value.name} · {value.method} · {value.outputsCurrent ? "current" : "historical inputs"}{value.replacementRunId ? " · superseded" : ""}</option>)}</select></label>
        <button className="cc-btn" disabled={!selectedRun} onClick={() => void perform(async () => setSavedRun((await read<{ run: StatisticalRun }>("statistics.get", { runId })).run))}>Read retained result</button></fieldset>
      {currentRun?.result ? <><p>{selectedRun?.outputsCurrent ? "The retained input table is current." : "This report retains historical inputs. Existing exported files never update automatically."}</p><ResultTable value={currentRun.result} />
        {currentRun.inputTable ? <details><summary>Exact retained input table</summary><InputTable table={currentRun.inputTable} /></details> : null}
        <fieldset disabled={busy}><legend>Recompute from current inputs</legend><p>Recomputation preserves the original design and method, resolves current assigned-image results, and appends a linked replacement.</p>
          <button className="cc-btn" disabled={!!selectedRun?.replacementRunId} onClick={() => void perform(async () => setRecomputed({ runId, revision, result: (await read<{ preview: StatisticalResult }>("statistics.recompute.preview", { runId })).preview }))}>Preview recomputation</button>
          {selectedRun?.replacementRunId ? <p>This result already has a replacement. Select that retained run to continue.</p> : null}
          {currentRecompute ? <><ResultTable value={currentRecompute} /><button className="cc-btn" disabled={writeBlocked || currentRecompute.status !== "ready"} onClick={() => void actions.mutate<{ run: StatisticalRun }>("statistics.recompute.run", { runId, previewFingerprint: currentRecompute.previewFingerprint }, result => { setSavedRun(result.run); setRunId(result.run.id); setRecomputed(undefined); })}>Save replacement result</button></> : null}
        </fieldset>
        <fieldset disabled={busy || writeBlocked}><legend>Export retained report</legend><label>Format<select value={exportFormat} onChange={event => setExportFormat(event.target.value as StatisticsExportFormat["id"])}>{formats.map(value => <option key={value.id} value={value.id}>{value.name}</option>)}</select></label><button className="cc-btn" disabled={!chosenExport} onClick={() => chosenExport && void actions.exportReport(chosenExport, currentRun)}>Export retained result…</button><p>CSV/JSON preserve exact inputs, currentness and assumptions. Vector plots use pointwise intervals from the retained result; exporting performs no new inference.</p></fieldset>
      </> : null}
    </details>
    {catalogue ? <details><summary>Supported methods and limits</summary><ScientificOutput output={{ methods: catalogue.methods, limits: catalogue.limits, notes: catalogue.notes }} /></details> : null}
  </details></section>;
}
