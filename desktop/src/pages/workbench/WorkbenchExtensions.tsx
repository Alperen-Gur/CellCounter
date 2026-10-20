import WorkbenchImageSelector from "./WorkbenchImageSelector";
import { useEffect, useRef, useState } from "react";
import { open, save } from "@tauri-apps/plugin-dialog";
import type { AnalysisParameters, ProjectSnapshot, ImageAssignment, Specimen } from "../../../../shared/workbench/protocol";
import { useCatalogueMany, useCataloguePins } from "./WorkbenchCatalogueBrowser";
import type { AdaptationDataset, ParameterValue } from "../../../../shared/workbench/extensionProtocol";
import type { VolumeWorkflowConfiguration } from "../../../../shared/workbench/volumeProtocol";
import PluginParameters from "./PluginParameters";
import ScientificOutput from "./ScientificOutput";

type Props = {
  snapshot: ProjectSnapshot; imageId: string; busy: boolean; volumeMode: boolean;
  parameters: AnalysisParameters; volume?: VolumeWorkflowConfiguration;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  act: (operation: string, args: Record<string, unknown>) => Promise<void>;
};
type Suggestion = { imageId: string; name: string; selectionReason: string; difficultyScore: number };
type Run = { runId: string; pluginId: string; stale: boolean; output?: unknown };

export default function WorkbenchExtensions({ snapshot, imageId, busy, volumeMode, parameters, volume, read, act }: Props) {
  const plugins = snapshot.plugins ?? [];
  const datasets = snapshot.adaptationDatasets ?? [];
  const image = snapshot.images.find((item) => item.id === imageId);
  const [pluginId, setPluginId] = useState("");
  const [values, setValues] = useState<Record<string, ParameterValue>>({});
  const [runs, setRuns] = useState<Run[]>([]);
  const [selectedRun, setSelectedRun] = useState<Run>();
  const [error, setError] = useState("");
  const [reading, setReading] = useState(false);
  const [note, setNote] = useState("");
  const [suggestions, setSuggestions] = useState<Suggestion[]>([]);
  const [suggestionCandidates, setSuggestionCandidates] = useState<string[]>([]);
  const [chosen, setChosen] = useState<string[]>([]);
  const [partitions, setPartitions] = useState<Record<string, "train" | "validation" | "test">>({});
  const [name, setName] = useState("Reference dataset");
  const [datasetId, setDatasetId] = useState("");
  const [datasetDetail, setDatasetDetail] = useState<{ revision: number; value: AdaptationDataset }>();
  const [baselineId, setBaselineId] = useState("");
  const [candidateId, setCandidateId] = useState("");
  const [baselineValues, setBaselineValues] = useState<Record<string, ParameterValue>>({});
  const [candidateValues, setCandidateValues] = useState<Record<string, ParameterValue>>({});
  const epoch = useRef(0);
  const revisionRef = useRef(snapshot.project.revision);
  revisionRef.current = snapshot.project.revision;
  const plugin = plugins.find((item) => item.pluginId === pluginId);
  const dataset = datasetDetail?.revision === snapshot.project.revision && datasetDetail.value.id === datasetId
    ? datasetDetail.value : datasets.find((item) => item.id === datasetId);
  const segmenters = plugins.filter((item) => item.enabled && item.manifest.kind === "segmentation" && item.manifest.supportedDimensions.includes(2));
  const assignmentScope = useCatalogueMany<ImageAssignment>("assignments", chosen);
  const specimenScope = useCatalogueMany<Specimen>("specimens", assignmentScope.entries.map(item => item.specimenId));
  const specimens = specimenScope.entries;
  const assignments = assignmentScope.entries;
  const pinError = useCataloguePins([{ catalogue: "plugins", entryId: pluginId }, { catalogue: "plugins", entryId: baselineId },
    { catalogue: "plugins", entryId: candidateId }, { catalogue: "adaptationDatasets", entryId: datasetId }]);
  const validChosen = chosen;
  const groups = new Set(validChosen.map((id) => assignments.find((item) => item.imageId === id)?.specimenId).filter((id): id is string => !!id));
  const parts = [...groups].map((id) => partitions[id] ?? "train");

  useEffect(() => {
    epoch.current++;
    setRuns([]); setSelectedRun(undefined); setSuggestions([]); setReading(false); setError("");
    setDatasetId((old) => old || datasets[0]?.id || "");
    return () => { epoch.current++; };
  }, [snapshot.project.revision, imageId]);

  const inspect = async <T,>(operation: string, args: Record<string, unknown>, apply: (result: T) => void) => {
    const generation = ++epoch.current;
    const revision = snapshot.project.revision;
    setReading(true); setError("");
    try {
      const value = await read<T>(operation, args);
      if (epoch.current === generation && revisionRef.current === revision) apply(value);
    } catch (cause) {
      if (epoch.current === generation && revisionRef.current === revision) setError(String(cause));
    } finally { if (epoch.current === generation) setReading(false); }
  };

  return <div className="workbench-automation">
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    {pinError || assignmentScope.error || specimenScope.error ? <p className="workbench-error" role="alert">{pinError || assignmentScope.error || specimenScope.error}</p> : null}
    <details><summary>Local plugins</summary>
      <p>Installed plugins retain their exact Python source and version. Enabling a plugin trusts its code with your account.
        Measurement outputs record their inputs and show when a correction makes them outdated.</p>
      <fieldset disabled={busy || reading}>
        <button className="cc-btn" onClick={() => void (async () => {
          const path = await open({ title: "Install local plugin manifest", multiple: false,
            filters: [{ name: "Plugin manifest", extensions: ["json"] }] });
          if (typeof path === "string") await act("plugin.install", { manifestPath: path });
        })().catch((cause) => setError(String(cause)))}>Install manifest</button>
        <label>Plugin<select value={pluginId} onChange={(event) => { setPluginId(event.target.value); setValues({}); }}>
          <option value="">Select an installed version</option>
          {plugins.map((item) => <option key={item.pluginId} value={item.pluginId}>{item.manifest.name} · {item.manifest.version} · {item.enabled ? "enabled" : "disabled"}</option>)}
        </select></label>
        {plugin ? <>
          <p>{plugin.manifest.description} · {plugin.manifest.kind} · {plugin.manifest.supportedDimensions.map((value) => `${value}D`).join(", ")}</p>
          <p className="workbench-project-path">Package SHA-256: {plugin.packageHash}</p>
          <button className="cc-btn" onClick={() => void act("plugin.setEnabled", { pluginId, enabled: !plugin.enabled })}>
            {plugin.enabled ? "Disable this version" : "Trust and enable this version"}</button>
          <PluginParameters plugin={plugin} values={values} onChange={setValues} />
          {["segmentation", "measurement"].includes(plugin.manifest.kind) ? <button className="cc-btn" disabled={!imageId || !plugin.enabled ||
            !plugin.manifest.supportedDimensions.includes(volumeMode ? 3 : 2) || (volumeMode && !volume)}
            onClick={() => void act("plugin.run", { pluginId, imageId, parameters: values,
              ...(volumeMode && volume ? { target: "volume", timeIndex: volume.timeIndex, channel: volume.channel }
                : { target: "plane", ...(plugin.manifest.kind === "segmentation" ? { sourceParameters: parameters } : {}) }),
            })}>Run on selected {volumeMode ? "volume frame" : "image"}</button> : null}
          {plugin.manifest.kind === "reader" ? <button className="cc-btn" disabled={!plugin.enabled} onClick={() => void (async () => {
            const generation = epoch.current;
            const path = await open({ title: `Import with ${plugin.manifest.name}`, multiple: false });
            if (typeof path === "string" && generation === epoch.current) await act("plugin.read", { pluginId, path, parameters: values });
          })().catch((cause) => setError(String(cause)))}>Import with reader</button> : null}
          {plugin.manifest.kind === "exporter" ? <button className="cc-btn" disabled={!plugin.enabled || !imageId ||
            !plugin.manifest.supportedDimensions.includes(volumeMode ? 3 : 2) || (volumeMode && !volume)} onClick={() => void (async () => {
            const generation = epoch.current;
            const destination = await save({ title: `Export with ${plugin.manifest.name}` });
            if (destination && generation === epoch.current) await act("plugin.export", { pluginId, imageId, destination, parameters: values,
              ...(volumeMode && volume ? { target: "volume", timeIndex: volume.timeIndex, channel: volume.channel }
                : { target: "plane", sourceParameters: parameters }),
            });
          })().catch((cause) => setError(String(cause)))}>Export selected {volumeMode ? "volume frame" : "image"}</button> : null}
        </> : null}
        <button className="cc-btn" disabled={!imageId} onClick={() => void inspect<{ runs: Run[] }>(
          "plugin.results", { imageId }, (result) => { setRuns(result.runs); setSelectedRun(undefined); })}>Inspect saved outputs</button>
      </fieldset>
      {runs.length ? <ul>{runs.map((run) => <li key={run.runId}>{run.pluginId} · {run.stale ? "outdated" : "current"}
        <button className="cc-btn" disabled={busy || reading} onClick={() => void inspect<{ runs: Run[] }>(
          "plugin.results", { runId: run.runId }, (result) => setSelectedRun(result.runs[0]))}>View output</button></li>)}</ul> : null}
      {selectedRun ? <ScientificOutput key={selectedRun.runId} output={selectedRun.output} /> : null}
    </details>
    <details><summary>Reference datasets and model comparison</summary>
      <p>Approve reviewed 2D masks, assign biological specimens, then freeze train, validation and test specimens.
        Suggestions alternate image diversity with a difficulty heuristic. Previously held-out specimens stay excluded.</p>
      <fieldset disabled={busy || reading}>
        <label>Review note<input value={note} onChange={(event) => setNote(event.target.value)} maxLength={2000} /></label>
        <div className="workbench-actions">
          <button className="cc-btn" disabled={!image?.analysisRevision || volumeMode} onClick={() => void act("adaptation.reference.set", {
            imageId, approved: !image?.referenceCurrent, ...(note.trim() ? { note: note.trim() } : {}),
          })}>{image?.referenceCurrent ? "Revoke reference approval" : "Approve selected 2D mask as reference"}</button>
        </div>
        <WorkbenchImageSelector label="Candidate images for review suggestions" multiple selectedIds={suggestionCandidates}
          onChange={ids => { setSuggestionCandidates(ids); setSuggestions([]); }} maxSelected={200} disabled={busy || reading} />
        <p>Choose at most 200 candidate acquisitions. This scope ranks review candidates; it does not assign specimens, approve masks or increase biological n.</p>
        <button className="cc-btn" disabled={!suggestionCandidates.length} onClick={() => void inspect<{ suggestions: Suggestion[] }>(
          "adaptation.suggest", { imageIds: suggestionCandidates, limit: 12 }, result => setSuggestions(result.suggestions))}>Suggest images from candidate scope</button>
        {suggestions.length ? <ul>{suggestions.map((item) => <li key={item.imageId}>{item.name} · {item.selectionReason}</li>)}</ul> : null}
        <div className="workbench-editor-grid">
          <div><h3>Approved images with specimen assignments</h3>
            <WorkbenchImageSelector label="Approved reference images" multiple selectedIds={chosen} onChange={setChosen} disabled={busy || reading}
              maxSelected={200} filters={{ referenceCurrent: true }}
              eligibilityNote="Choose up to 200 approved masks. Exact specimen assignments are read for this selection, independently of catalogue pages; unassigned references must be assigned before freezing." />
            {assignmentScope.missingIds.length ? <p className="workbench-error">{assignmentScope.missingIds.length} selected images have no specimen assignment.</p> : null}
            {!assignmentScope.ready || !specimenScope.ready ? <p role="status">Reading selected specimen identities…</p> : null}
          </div>
          <div><h3>Partition whole specimens</h3>
            {specimens.filter((item) => groups.has(item.id)).map((item) => <label key={item.id}>{item.name}
              <select value={partitions[item.id] ?? "train"} onChange={(event) => setPartitions((old) => ({
                ...old, [item.id]: event.target.value as "train" | "validation" | "test",
              }))}><option value="train">Train</option><option value="validation">Validation</option><option value="test">Held-out test</option></select>
            </label>)}
          </div>
        </div>
        <label>Dataset name<input value={name} onChange={(event) => setName(event.target.value)} /></label>
        <button className="cc-btn" disabled={!name.trim() || !assignmentScope.ready || !specimenScope.ready || !!assignmentScope.error || !!specimenScope.error || assignmentScope.missingIds.length > 0 || specimenScope.missingIds.length > 0 || !["train", "validation", "test"].every((part) => parts.includes(part as typeof parts[number]))}
          onClick={() => void act("adaptation.dataset.create", { name, imageIds: validChosen,
            validationSpecimenIds: [...groups].filter((id) => partitions[id] === "validation"),
            testSpecimenIds: [...groups].filter((id) => partitions[id] === "test"),
          })}>Freeze reference dataset</button>
        <label>Frozen dataset<select value={datasetId} onChange={(event) => setDatasetId(event.target.value)}>
          <option value="">Select a dataset</option>{datasets.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}
        </select></label>
        <button className="cc-btn" disabled={!datasetId} onClick={() => void inspect<{ dataset: AdaptationDataset }>("adaptation.dataset.get", { datasetId }, result => setDatasetDetail({ revision: snapshot.project.revision, value: result.dataset }))}>Read selected reference samples and comparisons</button>
        {dataset ? <p>{dataset.counts.train} train, {dataset.counts.validation} validation, {dataset.counts.test} test images.
          {dataset.samples?.some((item) => !item.currentReference) ? " Some current masks differ; frozen references remain unchanged." : ""}</p> : null}
        <div className="workbench-editor-grid">{(["baseline", "candidate"] as const).map((role) => {
          const id = role === "baseline" ? baselineId : candidateId;
          const setId = role === "baseline" ? setBaselineId : setCandidateId;
          const setParameters = role === "baseline" ? setBaselineValues : setCandidateValues;
          return <div key={role}><h3>{role === "baseline" ? "Baseline segmenter" : "Candidate segmenter"}</h3>
            <select aria-label={`${role} segmenter`} value={id} onChange={(event) => { setId(event.target.value); setParameters({}); }}>
              <option value="">Choose an enabled 2D segmenter</option>
              {segmenters.map((item) => <option key={item.pluginId} value={item.pluginId}>{item.manifest.name} · {item.manifest.version}</option>)}
            </select>
            <PluginParameters plugin={segmenters.find((item) => item.pluginId === id)}
              values={role === "baseline" ? baselineValues : candidateValues} onChange={setParameters} />
          </div>;
        })}</div>
        <button className="cc-btn" disabled={!dataset || !segmenters.some((item) => item.pluginId === baselineId) ||
          !segmenters.some((item) => item.pluginId === candidateId)} onClick={() => void act("adaptation.evaluate", {
            datasetId, baseline: { pluginId: baselineId, parameters: baselineValues },
            candidate: { pluginId: candidateId, parameters: candidateValues },
          })}>Compare on frozen test specimens</button>
      </fieldset>
      {dataset?.evaluations?.map((evaluation) => <div key={evaluation.id} className="workbench-table"><table>
        <caption>Comparison {evaluation.evaluationNumber} · {evaluation.biologicalTestN} biological test specimens</caption>
        <thead><tr><th>Segmenter</th><th>AP50</th><th>F1</th><th>Precision</th><th>Recall</th></tr></thead>
        <tbody>{(["baseline", "candidate"] as const).map((role) => <tr key={role}><td>{role}</td>
          {(["ap50", "f1", "precision", "recall"] as const).map((metric) => <td key={metric}>{evaluation[role][metric].toFixed(3)}</td>)}</tr>)}</tbody>
      </table><p>{evaluation.notes.join(" ")}</p></div>)}
    </details>
  </div>;
}
