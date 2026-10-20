import { useEffect, useRef, useState } from "react";
import type { AnalysisParameters, ProjectSnapshot, WorkbenchWorkflow } from "../../../../shared/workbench/protocol";
import { DEFAULT_ANALYSIS, updateAnalysisParameters } from "../../../../shared/workbench/protocol";
import { DEFAULT_VOLUME_PARAMETERS, type VolumeWorkflowConfiguration } from "../../../../shared/workbench/volumeProtocol";
import type { ParameterSpec } from "../../../../shared/workbench/extensionProtocol";
import type { GraphCatalogue, GraphObjectSchema, GraphPreview, SaveWorkflow, WorkflowGraph, WorkflowGraphNode, GraphNodeType, GraphOutputKind } from "../../../../shared/workbench/graphProtocol";
import { inferenceSchemaFor } from "../../../../shared/workbench/modelProtocol";
import { recipeFromDraft, recipeToDraft, type PreprocessingDraftStep } from "../../../../shared/workbench/preprocessingProtocol";
import PreprocessingRecipeEditor from "./PreprocessingRecipeEditor";
import PluginParameters from "./PluginParameters";
import AssayParameters from "./AssayParameters";
import usePreprocessingCatalogue from "./usePreprocessingCatalogue";
import useModelCatalogue from "./useModelCatalogue";
import useGraphCatalogue from "./useGraphCatalogue";
import PlaneSegmentationParameters from "./PlaneSegmentationParameters";
import { useCataloguePins } from "./WorkbenchCatalogueBrowser";

type AssayDefinition = { id: string; name: string; dimensions: number[];
  parameters: { properties: Record<string, ParameterSpec>; required: string[] } };
type Props = {
  active: boolean; snapshot: ProjectSnapshot; imageId: string; imageIds: string[];
  volumeMode: boolean; volume?: VolumeWorkflowConfiguration; parameters: AnalysisParameters;
  currentTimeOnly: boolean; busy: boolean; writeBlocked: boolean;
  load?: { serial: number; workflow: WorkbenchWorkflow };
  selectedWorkflowId: string; assays: AssayDefinition[];
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  saveWorkflow: SaveWorkflow; onSaved: (workflow: WorkbenchWorkflow) => void;
};
const segmentationTypes = ["analysis", "volume-analysis", "model-segmentation", "plugin-segmentation"];
const scientific = (node: WorkflowGraphNode) => node.type !== "summary" && node.type !== "export";
const inputsOf = (node: WorkflowGraphNode) => [...(node.inputs ?? (node.input ? [node.input] : [])), ...(node.nuclearInput ? [node.nuclearInput] : []), ...(node.somaInput ? [node.somaInput] : [])];
const graphOutputKind = (nodes: WorkflowGraphNode[], node: WorkflowGraphNode, catalogue?: GraphCatalogue, visited = new Set<string>()): GraphOutputKind | undefined => {
  if (visited.has(node.id)) return undefined;
  visited.add(node.id);
  const kind = catalogue?.nodeTypes.find(value => value.type === node.type)?.outputKind;
  if (kind !== "input-dependent") return kind;
  const assay = catalogue?.assayPorts?.find(value => value.assay === node.assay);
  if (assay?.requiresAnalysis !== false) return "analyzed";
  const parent = nodes.find(value => value.id === node.input);
  return parent && graphOutputKind(nodes, parent, catalogue, visited) === "analyzed" ? "analyzed" : "raw-measured";
};
const label = (node: WorkflowGraphNode) => node.name?.trim() || node.id;
const isProcessed = (nodes: WorkflowGraphNode[], id: string, visited = new Set<string>()): boolean => {
  if (id === "$source" || visited.has(id)) return false;
  visited.add(id);
  const node = nodes.find((item) => item.id === id);
  return !!node && (node.type === "preprocessing" || (!!node.input && isProcessed(nodes, node.input, visited)));
};
const reaches = (nodes: WorkflowGraphNode[], from: string, to: string, visited = new Set<string>()): boolean => {
  if (from === to) return true;
  if (visited.has(from)) return false;
  visited.add(from);
  const node = nodes.find((item) => item.id === from);
  return !!node && inputsOf(node).some((id) => reaches(nodes, id, to, visited));
};
const terminals = (nodes: WorkflowGraphNode[]) => nodes.filter(scientific).filter((node) =>
  !nodes.some((other) => scientific(other) && inputsOf(other).includes(node.id))).map((node) => node.id);

/** Source selectors are inherited by the engine; method settings remain editable. */
function prepareGraph(graph: WorkflowGraph, catalogue?: GraphCatalogue): WorkflowGraph {
  const terminalIds = terminals(graph.nodes);
  const analyzed = new Set(graph.nodes.filter(node => ["analyzed", "raw-measured"].includes(graphOutputKind(graph.nodes, node, catalogue) ?? "")).map(node => node.id));
  return { ...graph, nodes: graph.nodes.map((node) => {
    const { name: _name, ...withoutName } = node;
    node = node.name?.trim() ? { ...node, name: node.name.trim() } : withoutName;
    if (node.type === "summary") return { ...node, inputs: [...new Set([
      ...(node.inputs ?? []).filter((id) => analyzed.has(id)), ...terminalIds.filter((id) => analyzed.has(id)),
    ])] };
    if (!segmentationTypes.includes(node.type)) return node;
    const { sourceParameters: _source, channel: _channel, target: _target, ...next } = node;
    if (next.type === "analysis" && next.parameters) {
      const { channel: _c, zProjection: _z, ...parameters } = next.parameters;
      return { ...next, parameters };
    }
    return next;
  }) };
}

function RecipeNode({ node, dimension, disabled, read, onChange }: {
  node: WorkflowGraphNode; dimension: 2 | 3; disabled: boolean; read: Props["read"];
  onChange: (recipe: WorkflowGraphNode["recipe"]) => void;
}) {
  const { catalogue, error, retry } = usePreprocessingCatalogue(read);
  const [steps, setSteps] = useState<PreprocessingDraftStep[]>(() => recipeToDraft(node.recipe ?? []));
  return <>
    {error ? <p className="workbench-error">{error} <button className="cc-btn" onClick={retry}>Retry filters</button></p> : null}
    <PreprocessingRecipeEditor catalogue={catalogue} steps={steps} dimension={dimension} disabled={disabled}
      onChange={(next) => { setSteps(next); onChange(recipeFromDraft(next)); }} />
  </>;
}

export default function WorkbenchGraphEditor(props: Props) {
  const { snapshot, imageId, busy, writeBlocked, read, saveWorkflow, onSaved } = props;
  const { catalogue, error: catalogueError, retry: retryCatalogue } = useGraphCatalogue(read, props.active);
  const [name, setName] = useState("Branching cell analysis");
  const [editing, setEditing] = useState<{ id: string; version: number }>();
  const [draftSerial, setDraftSerial] = useState(0);
  const [graph, setGraph] = useState<WorkflowGraph>(() => ({ schemaVersion: 1, target: props.volumeMode ? "volume" : "plane",
    ...(props.volumeMode ? { channel: props.volume?.channel ?? 0 } : {
      sourceParameters: { channel: props.parameters.channel, zProjection: props.parameters.zProjection },
    }), nodes: [{ id: "summary", type: "summary", inputs: [] }] }));
  const [addType, setAddType] = useState<GraphNodeType>("preprocessing");
  const [preview, setPreview] = useState<{ identity: string; result: GraphPreview }>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const pinError = useCataloguePins(graph.nodes.flatMap(node => [
    ...(node.modelId ? [{ catalogue: "models" as const, entryId: node.modelId }] : []),
    ...(node.pluginId ? [{ catalogue: "plugins" as const, entryId: node.pluginId }] : []),
  ]));
  const epoch = useRef(0);
  const { catalogue: modelCatalogue } = useModelCatalogue(read);
  const definition = (type: GraphNodeType) => catalogue?.nodeTypes.find((kind) => kind.type === type);
  const outputKind = (node: WorkflowGraphNode) => graphOutputKind(graph.nodes, node, catalogue);
  const nodes = graph.nodes.filter(scientific);
  const terminalIds = terminals(graph.nodes);
  const dimension = graph.target === "volume" ? 3 : 2;
  const outgoing = prepareGraph(graph, catalogue);
  const timeIndices = graph.target === "volume" && props.currentTimeOnly && props.volume ? [props.volume.timeIndex] : undefined;
  const scopeValid = !(graph.target === "volume" && props.currentTimeOnly && (!props.volumeMode || !props.volume));
  const args = { graph: outgoing, ...(props.imageIds.length ? { imageIds: props.imageIds } : {}), ...(timeIndices ? { timeIndices } : {}) };
  const identity = JSON.stringify({ projectId: snapshot.project.id, revision: snapshot.project.revision, args });
  const latestIdentity = useRef(identity); latestIdentity.current = identity;
  const currentPreview = preview?.identity === identity ? preview.result : undefined;
  const locked = busy || loading || writeBlocked;
  const maxNodes = catalogue?.limits.nodes ?? 32;
  const maxSegments = catalogue?.limits.segmentationBranches ?? 8;
  const segmentCount = nodes.filter((node) => segmentationTypes.includes(node.type)).length;

  useEffect(() => {
    const saved = props.load?.workflow;
    if (!saved?.graph) return;
    const loaded = structuredClone(saved.graph);
    // Terminal references are required automatically; retain optional extra references separately.
    const terminalIds = terminals(loaded.nodes);
    loaded.nodes = loaded.nodes.map((node) => node.type === "summary"
      ? { ...node, inputs: node.inputs?.filter((id) => !terminalIds.includes(id)) } : node);
    setGraph(loaded); setName(saved.name); setEditing({ id: saved.id, version: saved.version });
    setDraftSerial((value) => value + 1); setError(""); setMessage(`Loaded ${saved.name} · version ${saved.version}.`);
    setPreview(undefined); epoch.current++;
  }, [props.load?.serial]);
  useEffect(() => { epoch.current++; setLoading(false); }, [identity]);

  const patch = (id: string, changes: Partial<WorkflowGraphNode>) => {
    setGraph((old) => ({ ...old, nodes: old.nodes.map((node) => node.id === id ? { ...node, ...changes } : node) }));
    setError(""); setMessage("");
  };
  const addNode = () => {
    if (!catalogue || graph.nodes.length >= maxNodes || (segmentationTypes.includes(addType) && segmentCount >= maxSegments)) return;
    const type = addType;
    const id = `${type}-${crypto.randomUUID().slice(0, 8)}`;
    const inputKinds: GraphOutputKind[] = type === "assay" ? ["analyzed"] : definition(type)?.inputKinds ?? [];
    const input = inputKinds.includes("raw") ? "$source" : [...nodes].reverse().find((node) => inputKinds.includes(outputKind(node)!))?.id ?? "";
    const scalarParameters = (parameters: object) => Object.fromEntries(Object.entries(parameters).filter(([key]) => !["channel", "zProjection"].includes(key)));
    const node: WorkflowGraphNode = { id, type, ...(type === "mask-merge" ? { inputs: [input, ""], mode: "union", connectivity: "faces" } : { input }), name: `${definition(type)?.name ?? type} ${nodes.length + 1}`,
      ...(type === "analysis" ? { parameters: scalarParameters(props.parameters ?? DEFAULT_ANALYSIS) } : {}),
      ...(type === "volume-analysis" ? { parameters: { ...(props.volume?.parameters ?? DEFAULT_VOLUME_PARAMETERS) } } : {}),
      ...(type === "preprocessing" ? { recipe: [] } : {}),
      ...(type === "assay" ? { assay: "morphology", assayParameters: {} } : {}),
      ...(type === "review" ? { prompt: "Review the exact saved mask before continuing.", requireHuman: true } : {}),
    };
    setGraph((old) => ({ ...old, nodes: [...old.nodes.filter(scientific), node, ...old.nodes.filter((item) => !scientific(item))] }));
    setMessage("");
  };
  const inspect = async () => {
    if (locked || !scopeValid) return;
    const generation = ++epoch.current; setLoading(true); setError(""); setMessage("");
    try {
      const result = await read<GraphPreview>("workflow.graph.preview", args);
      if (epoch.current === generation && latestIdentity.current === identity) setPreview({ identity, result });
    } catch (cause) { if (epoch.current === generation) setError(String(cause)); }
    finally { if (epoch.current === generation) setLoading(false); }
  };
  const save = (update: boolean) => {
    if (!currentPreview || locked || !name.trim() || (update && editing?.id !== props.selectedWorkflowId)) return;
    return saveWorkflow("workflow.graph.save", { name: name.trim(), graph: outgoing, ...(update ? { workflowId: editing!.id } : {}) }, (workflow) => {
      setEditing({ id: workflow.id, version: workflow.version }); onSaved(workflow);
      setMessage(`Saved ${workflow.name} · version ${workflow.version}. Create a batch from this saved version to execute it.`);
    });
  };
  const parameterSchema = (node: WorkflowGraphNode) => {
    const schema = definition(node.type)?.schema.properties?.parameters as GraphObjectSchema | undefined;
    return { properties: Object.fromEntries(Object.entries(schema?.properties ?? {}).filter(([key]) =>
      !["channel", "zProjection"].includes(key))) as Record<string, ParameterSpec>, required: (schema?.required ?? []).filter((key) => !["channel", "zProjection"].includes(key)) };
  };
  const summary = graph.nodes.find((node) => node.type === "summary");
  const exportNode = graph.nodes.find((node) => node.type === "export");
  return <section hidden={!props.active} className="workbench-graph-editor" aria-label="Branching workflow editor">
    {pinError ? <p className="workbench-error" role="alert">{pinError}</p> : null}
    <fieldset disabled={locked}>
      <h3>Branching workflow</h3>
      <p>Connect each operation to a named source. Segmentation branches keep independent masks; alternatives are technical comparisons, not extra biological replicates.</p>
      <label>Workflow name<input maxLength={200} value={name} onChange={(event) => setName(event.target.value)} /></label>
      {editing ? <p>Editing version {editing.version}. Saving creates a new immutable version.</p> : null}
      <label>Source dimension<select value={graph.target} onChange={(event) => {
        const target = event.target.value as WorkflowGraph["target"];
        setGraph((old) => ({ schemaVersion: 1, target, nodes: old.nodes, ...(target === "plane"
          ? { sourceParameters: { channel: old.channel ?? 0, zProjection: props.parameters.zProjection } }
          : { channel: old.sourceParameters?.channel ?? 0 }) }));
      }}><option value="plane">2D plane or projection</option><option value="volume">3D volume per time point</option></select></label>
      <label>Source channel<input type="number" min={1} max={32} step={1}
        value={(graph.target === "plane" ? graph.sourceParameters?.channel ?? 0 : graph.channel ?? 0) + 1}
        onChange={(event) => {
          const channel = Number(event.target.value) - 1;
          setGraph((old) => old.target === "plane" ? { ...old, sourceParameters: { channel, zProjection: old.sourceParameters?.zProjection ?? "max" } }
            : { ...old, channel });
        }} /></label>
      {graph.target === "plane" ? <label>Z projection<select value={graph.sourceParameters?.zProjection ?? "max"}
        onChange={(event) => setGraph((old) => ({ ...old, sourceParameters: { channel: old.sourceParameters?.channel ?? 0,
          zProjection: event.target.value as "max" | "mean" | "middle" } }))}>
        <option value="max">Maximum</option><option value="mean">Mean</option><option value="middle">Middle slice</option>
      </select></label> : <p>Batch time-point scope selects the source frames. Each processed branch uses its own first channel and time point.</p>}
      {catalogueError ? <p role="alert" className="workbench-error">{catalogueError} <button className="cc-btn" onClick={retryCatalogue}>Retry node catalogue</button></p> : null}
      {!catalogue && !catalogueError ? <p role="status">Loading supported workflow nodes…</p> : null}
      <label>Add operation<select value={addType} onChange={(event) => setAddType(event.target.value as GraphNodeType)}>
        {(catalogue?.nodeTypes ?? []).filter((kind) => !["summary", "export"].includes(kind.type)).map((kind) => <option key={kind.type} value={kind.type}
          disabled={(graph.target === "volume" && ["analysis", "model-segmentation"].includes(kind.type)) || (graph.target === "plane" && kind.type === "volume-analysis")}>{kind.name}</option>)}
      </select></label>
      <button type="button" className="cc-btn" disabled={!catalogue || graph.nodes.length >= maxNodes ||
        (segmentationTypes.includes(addType) && segmentCount >= maxSegments) ||
        (graph.target === "volume" && ["analysis", "model-segmentation"].includes(addType)) || (graph.target === "plane" && addType === "volume-analysis")}
        onClick={addNode}>Add operation</button>
      <p>{graph.nodes.length} / {maxNodes} nodes · {segmentCount} / {maxSegments} segmentation branches.</p>
      <ol className="workbench-graph-nodes">{nodes.map((node) => {
        const kind = definition(node.type);
        const assayPort = node.type === "assay" ? catalogue?.assayPorts?.find(value => value.assay === node.assay) : undefined;
        const allowed: GraphOutputKind[] = node.type === "assay" && assayPort?.requiresAnalysis !== false ? ["analyzed"] : kind?.inputKinds ?? [];
        const candidates = nodes.filter((other) => other.id !== node.id && allowed.includes(outputKind(other)!) && !reaches(nodes, other.id, node.id));
        const inputValid = node.input === "$source" ? allowed.includes("raw") : candidates.some((other) => other.id === node.input);
        const consumers = nodes.filter((other) => inputsOf(other).includes(node.id));
        const processed = isProcessed(nodes, node.input ?? "");
        const plugin = snapshot.plugins?.find((item) => item.pluginId === node.pluginId);
        const model = snapshot.models?.find((item) => item.id === node.modelId);
        const assay = props.assays.find((item) => item.id === node.assay);
        const dimensionValid = graph.target === "volume" ? !["analysis", "model-segmentation"].includes(node.type) : node.type !== "volume-analysis";
        const availablePlugins = (snapshot.plugins ?? []).filter((item) => item.manifest.kind ===
          (node.type === "plugin-segmentation" ? "segmentation" : "measurement") && item.manifest.supportedDimensions.includes(dimension));
        return <li key={`${draftSerial}:${node.id}`}>
          <h4>{kind?.name ?? node.type}</h4>
          <label>Node name<input maxLength={100} value={node.name ?? ""} placeholder={node.id} onChange={(event) => patch(node.id, { name: event.target.value })} /></label>
          {node.type !== "mask-merge" ? <label>{node.type === "assay" && node.assay === "nuclear_cytoplasmic" ? "Cell-mask input" : "Input source"}<select value={node.input ?? ""} onChange={(event) => patch(node.id, { input: event.target.value })}>
            <option value="">Choose an input</option>
            {allowed.includes("raw") ? <option value="$source">Original source image</option> : null}
            {!inputValid && node.input ? <option value={node.input} disabled>Unavailable input · {node.input}</option> : null}
            {candidates.map((other) => <option key={other.id} value={other.id}>{label(other)} · {definition(other.type)?.name ?? other.type}</option>)}
          </select></label> : <><div className="workbench-editor-grid">{[0, 1].map(index => <label key={index}>{index ? "Second mask input" : "First mask input"}<select value={node.inputs?.[index] ?? ""} onChange={event => patch(node.id, { inputs: [0, 1].map(slot => slot === index ? event.target.value : node.inputs?.[slot] ?? "") })}><option value="">Choose analyzed branch</option>{candidates.map(other => <option key={other.id} value={other.id} disabled={node.inputs?.[1 - index] === other.id}>{label(other)}</option>)}</select></label>)}</div>
            <label>Foreground combination<select value={node.mode ?? "union"} onChange={event => patch(node.id, { mode: event.target.value as "union" | "intersection" })}><option value="union">Union</option><option value="intersection">Intersection</option></select></label>
            <label>Connected-component neighborhood<select value={node.connectivity ?? "faces"} onChange={event => patch(node.id, { connectivity: event.target.value as "faces" | "full" })}><option value="faces">Face neighbors</option><option value="full">Full neighborhood including diagonals</option></select></label><p>Requires identical source grid, calibration and valid support. New connected-component IDs are assigned; touching union objects may merge.</p></>}
          {!dimensionValid ? <p role="alert" className="workbench-error">This node does not support {dimension}D sources. Remove it or change the source dimension; existing settings have been retained.</p> : null}
          {processed ? <p>Uses the retained processed image from this branch (channel 1{graph.target === "volume" ? ", time point 1" : ", saved plane"}).</p> : null}
          {segmentationTypes.includes(node.type) ? <><label><input type="checkbox" checked={node.sourceChannel !== undefined} onChange={event => patch(node.id, { sourceChannel: event.target.checked ? processed ? 0 : graph.sourceParameters?.channel ?? graph.channel ?? 0 : undefined })} /> Select this branch's source channel explicitly</label>{node.sourceChannel !== undefined ? <label>Branch source channel<input type="number" min={1} max={processed ? 1 : 32} step={1} value={node.sourceChannel + 1} onChange={event => patch(node.id, { sourceChannel: Number(event.target.value) - 1 })} /></label> : null}<p>Projection and time stay bound to the workflow source. A processed single-channel input can only use channel 1.</p></> : null}
          {node.type === "review" ? <><label>Review prompt<textarea value={node.prompt ?? ""} maxLength={2000} onChange={event => patch(node.id, { prompt: event.target.value })} /></label><label><input type="checkbox" checked={node.requireHuman !== false} onChange={event => patch(node.id, { requireHuman: event.target.checked })} /> Require an explicit human decision</label><p>The batch and background worker stop at this exact mask binding. Recommendations remain separate from decisions and do not release a human-required gate.</p></> : null}
          {node.type === "preprocessing" ? <RecipeNode node={node} dimension={dimension} disabled={locked} read={read} onChange={(recipe) => patch(node.id, { recipe })} /> : null}
          {node.type === "analysis" ? <PlaneSegmentationParameters values={{ ...DEFAULT_ANALYSIS, ...node.parameters } as AnalysisParameters}
            onChange={change => patch(node.id, { parameters: Object.fromEntries(Object.entries(updateAnalysisParameters({ ...DEFAULT_ANALYSIS, ...node.parameters } as AnalysisParameters, change)).filter(([key]) => !["channel", "zProjection"].includes(key))) })} /> : null}
          {node.type === "volume-analysis" ? <PluginParameters schema={parameterSchema(node)} values={node.parameters ?? {}}
            onChange={(parameters) => patch(node.id, { parameters })} /> : null}
          {node.type === "model-segmentation" ? <>
            <label>Registered model<select value={node.modelId ?? ""} onChange={(event) => patch(node.id, { modelId: event.target.value,
              modelParameters: {}, backend: undefined, inferenceSchemaHash: undefined, checkpointHash: undefined,
              pythonHash: undefined, pythonPath: undefined, environmentHash: undefined, usesExecutableCode: undefined })}>
              <option value="">Choose a registered model</option>
              {(snapshot.models ?? []).map((item) => <option key={item.id} value={item.id} disabled={!item.enabled}>{item.name} · {item.backend}{!item.enabled ? " · disabled" : ""}</option>)}
              {node.modelId && !model ? <option value={node.modelId} disabled>Unavailable saved model</option> : null}
            </select></label>
            {model ? <PluginParameters schema={inferenceSchemaFor(model, modelCatalogue)} values={node.modelParameters ?? {}} onChange={(modelParameters) => patch(node.id, { modelParameters })} /> : null}
          </> : null}
          {["plugin-segmentation", "plugin-measurement"].includes(node.type) ? <>
            <label>{node.type === "plugin-segmentation" ? "Segmentation plugin" : "Measurement plugin"}<select value={node.pluginId ?? ""}
              onChange={(event) => patch(node.id, { pluginId: event.target.value, pluginParameters: {}, packageHash: undefined })}>
              <option value="">Choose an installed plugin</option>{availablePlugins.map((item) => <option key={item.pluginId} value={item.pluginId} disabled={!item.enabled || item.available === false}>
                {item.manifest.name} · {item.manifest.version}{!item.enabled ? " · disabled" : item.available === false ? " · unavailable" : ""}</option>)}
              {node.pluginId && !availablePlugins.some((item) => item.pluginId === node.pluginId) ? <option value={node.pluginId} disabled>Unavailable saved plugin</option> : null}
            </select></label>
            {plugin ? <PluginParameters plugin={plugin} values={node.pluginParameters ?? {}} onChange={(pluginParameters) => patch(node.id, { pluginParameters })} /> : null}
          </> : null}
          {node.type === "assay" ? <>
            <label>Assay<select value={node.assay ?? ""} onChange={(event) => patch(node.id, { assay: event.target.value, assayParameters: {}, nuclearInput: undefined, somaInput: undefined, assayDefinitionHash: undefined })}>
              {props.assays.map((item) => <option key={item.id} value={item.id} disabled={!item.dimensions.includes(dimension)}>{item.name}</option>)}
            </select></label>
            {assayPort?.pairedPort ? <label>{assayPort.pairedPort === "somaInput" ? "Soma-mask input" : "Nuclear-mask input"}<select value={node[assayPort.pairedPort] ?? ""} onChange={event => patch(node.id, { [assayPort.pairedPort!]: event.target.value })}><option value="">Choose a distinct analyzed branch</option>{nodes.filter(other => other.id !== node.id && other.id !== node.input && outputKind(other) === "analyzed" && !reaches(nodes, other.id, node.id)).map(other => <option key={other.id} value={other.id}>{label(other)}</option>)}</select></label> : null}
            {assayPort?.requiresAnalysis === false ? <p>This assay may measure acquired source intensity without object masks. Raw-only results have no object count; source channel, projection and time follow the connected input.</p> : null}
            {assay ? <AssayParameters schema={{ properties: Object.fromEntries(Object.entries(assay.parameters.properties).filter(([key]) => !["nuclearImageId", "somaImageId"].includes(key))), required: assay.parameters.required.filter(key => !["nuclearImageId", "somaImageId"].includes(key)) }} values={node.assayParameters ?? {}} imageId={imageId}
              images={processed ? snapshot.images.map((item) => item.id === imageId ? { ...item, channels: 1 } : item) : snapshot.images}
              zProjection={graph.sourceParameters?.zProjection} onChange={(assayParameters) => patch(node.id, { assayParameters })} /> : null}
          </> : null}
          {node.type === "measurements" ? <p>Read the exact labels and current calibrated measurements from the selected analysis branch.</p> : null}
          <details><summary>Node identity</summary><code>{node.id}</code></details>
          <button type="button" className="cc-btn" disabled={consumers.length > 0} onClick={() => setGraph((old) => ({ ...old,
            nodes: old.nodes.filter((item) => item.id !== node.id).map((item) => item.inputs ? { ...item, inputs: item.inputs.filter((id) => id !== node.id) } : item),
          }))}>Remove node</button>
          {consumers.length ? <small>Change the input of {consumers.map(label).join(", ")} before removing this node.</small> : null}
        </li>;
      })}</ol>
      <section aria-label="Branch summary"><h4>Summary</h4>
        <p>Every terminal measurement or analyzed output is included. A summary retains branch references and never merges masks, pixels or biological replicates. Raw-only assays do not fabricate objects.</p>
        {nodes.filter(node => ["analyzed", "raw-measured"].includes(outputKind(node) ?? "")).map((node) => <label className="workbench-inline" key={node.id}>
          <input type="checkbox" checked={terminalIds.includes(node.id) || summary?.inputs?.includes(node.id) === true} disabled={terminalIds.includes(node.id)}
            onChange={(event) => summary && patch(summary.id, { inputs: event.target.checked ? [...(summary.inputs ?? []), node.id] : summary.inputs?.filter((id) => id !== node.id) })} />
          {label(node)}{terminalIds.includes(node.id) ? " · terminal output (required)" : " · optional intermediate reference"}
        </label>)}
        {nodes.some((node) => terminalIds.includes(node.id) && outputKind(node) === "raw") ? <p className="workbench-error">Connect every preprocessing output to segmentation or a supported raw-intensity assay before saving.</p> : null}
      </section>
      <label className="workbench-inline"><input type="checkbox" checked={!!exportNode} disabled={!exportNode && graph.nodes.length >= maxNodes}
        onChange={(event) => setGraph((old) => ({ ...old, nodes: event.target.checked
          ? [...old.nodes, { id: "export", type: "export", input: summary?.id ?? "summary" }] : old.nodes.filter((node) => node.type !== "export") }))} />Export package after the summary</label>
      <p>Saved branches can run as batches, node-parameter sweeps or whole-graph distributed tasks. Supported joins include same-grid mask union/intersection and explicit paired nuclear/soma mask inputs; cycles, arbitrary pixel merges and mixed dimensions remain unsupported.</p>
      {!scopeValid ? <p className="workbench-error">Choose all time points above or select an available source time point.</p> : null}
      <div className="workbench-actions">
        <button type="button" className="cc-btn" disabled={!catalogue || !nodes.length || !scopeValid} onClick={() => void inspect()}>Preview branches</button>
        <button type="button" className="cc-btn" disabled={!currentPreview || !name.trim()} onClick={() => void save(false)}>Save new workflow</button>
        <button type="button" className="cc-btn" disabled={!currentPreview || !name.trim() || !editing || editing.id !== props.selectedWorkflowId}
          onClick={() => void save(true)}>Save as next version</button>
      </div>
    </fieldset>
    {writeBlocked ? <p>Save or discard pending scientific edits before saving or running a workflow.</p> : null}
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    {message ? <p role="status">{message}</p> : null}
    {loading ? <p role="status">Preparing the branch plan…</p> : null}
    {preview && !currentPreview ? <p role="status">Workflow settings, input scope or project results changed. Preview the branches again before saving.</p> : null}
    {currentPreview ? <section aria-label="Branching workflow preview">
      <h4>Branch plan</h4>
      {currentPreview.plan ? <p>{currentPreview.plan.sourceCount} source image/time inputs · {currentPreview.plan.segmentationBranchCount} segmentation branches ·{" "}
        {currentPreview.plan.newImageCount} new independent images · {currentPreview.plan.checkpointCount} checkpoints.</p> : <p>Workflow definition only. Choose input images to estimate batch work.</p>}
      <ol className="workbench-steps">{currentPreview.order.map((id) => {
        const node = currentPreview.graph.nodes.find((item) => item.id === id);
        if (!node) return null;
        const from = inputsOf(node);
        const output = currentPreview.nodeOutputs.find((item) => item.nodeId === id);
        return <li key={id}><strong>{label(node)} · {definition(node.type)?.name ?? node.type}</strong>
          <span>Input: {from.map((source) => source === "$source" ? "Original source" : currentPreview.graph.nodes.find((item) => item.id === source)?.name || source).join(" + ") || "None"}</span>
          <span>Output: {output?.outputKind ?? definition(node.type)?.outputKind}{output?.selection ? ` · channel ${output.selection.channel + 1}` : ""}</span>
        </li>;
      })}</ol>
      <p>{currentPreview.notes.join(" ")}</p>
    </section> : null}
  </section>;
}
