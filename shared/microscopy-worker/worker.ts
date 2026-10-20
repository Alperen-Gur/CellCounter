/** Trusted fixed-operation worker. No UI, networking, dynamic modules or user code. */
import { open } from "node:fs/promises";
import { resolve } from "node:path";
import { createWorkspace, composePlane, setPosition } from "../microscopy/workspace";
import { exportProject, importProject, replayWorkflow, validateWorkspace } from "../microscopy/project";
import { PaintingSession, encodeLabelTIFF } from "../microscopy/paint";
import { buildLineage, lineageTracks, validateLineage } from "../microscopy/lineage";
import { animationStates, encodeGIF } from "../microscopy/animation";
import { loadZarrPlane, openOMEZarr } from "../microscopy/zarr";
import { fail, integer, product, resourceLimits, validatePlane } from "../microscopy/guards";
import type { Calibration, Coordinate, ImagePlane, LineageGraph, LineageNode, MicroscopyWorkspace, WorkspaceAxis, WorkspaceLayer, ZarrDataset, ZarrPlaneSelection } from "../microscopy/types";
import { catalogue, OPERATION_SCHEMAS } from "./catalogue";
import { ENGINE_VERSION, NODE_VERSION, WORKER_LIMITS, type PlaneInput, type WorkerRequest, type WorkerResponse, type ZarrBinding } from "./protocol";
import { canonicalDirectory, contained, prepareOutput, readFileBounded, requestDirectory, WorkerIO } from "./io";

function validate(value: unknown, schema: Record<string, any>, name = "arguments", depth = 0): void {
  if (depth > 24) fail("invalid-arguments", "Worker arguments exceed their nesting limit.");
  if (schema.type === "object") {
    if (!value || typeof value !== "object" || Array.isArray(value)) fail("invalid-arguments", `${name} must be an object.`);
    const row = value as Record<string, unknown>;
    if (Object.keys(row).length > (schema.maxProperties ?? 1024)) fail("resource-limit", `${name} has too many fields.`);
    for (const field of schema.required ?? []) if (!(field in row)) fail("invalid-arguments", `${name}.${field} is required.`);
    for (const [key, item] of Object.entries(row)) {
      if (["__proto__", "constructor", "prototype"].includes(key)) fail("invalid-arguments", "Reserved object key.");
      const rule = schema.properties?.[key] ?? schema.additionalProperties;
      if (!rule || rule === false) fail("invalid-arguments", `${name}.${key} is unsupported.`);
      validate(item, rule, `${name}.${key}`, depth + 1);
    }
  } else if (schema.type === "array") {
    if (!Array.isArray(value) || value.length > (schema.maxItems ?? 1024)) fail("invalid-arguments", `${name} must be a bounded array.`);
    value.forEach((item, index) => validate(item, schema.items, `${name}[${index}]`, depth + 1));
  } else if (schema.type === "string") {
    if (typeof value !== "string" || value.length < (schema.minLength ?? 0) || value.length > (schema.maxLength ?? 4096) || value.includes("\0")) fail("invalid-arguments", `${name} must be a bounded string.`);
  } else if (schema.type === "number" || schema.type === "integer") {
    if (typeof value !== "number" || !Number.isFinite(value) || (schema.type === "integer" && !Number.isSafeInteger(value))
      || value < (schema.minimum ?? -Infinity) || value > (schema.maximum ?? Infinity)
      || (schema.exclusiveMinimum !== undefined && value <= schema.exclusiveMinimum)) fail("invalid-arguments", `${name} is outside its numeric bounds.`);
  } else if (schema.type === "boolean" && typeof value !== "boolean") fail("invalid-arguments", `${name} must be boolean.`);
  if (schema.enum && !schema.enum.includes(value)) fail("invalid-arguments", `${name} is not a supported value.`);
}
const summary = (workspace: MicroscopyWorkspace) => ({ id: workspace.id, name: workspace.name, layerCount: workspace.layers.length,
  axes: workspace.axes, position: workspace.position, layers: workspace.layers.map((layer) => ({ id: layer.id, name: layer.name, kind: layer.kind, source: layer.source })),
  semanticDocumentCount: Object.keys(workspace.paintDocuments).length, lineageNodeCount: workspace.lineage.nodes.length,
  lineageEdgeCount: workspace.lineage.edges.length, workflowCount: workspace.workflows.length, animationCount: workspace.animationPlans.length });
const datasetSummary = (dataset: ZarrDataset) => ({ name: dataset.name, source: dataset.source, arrays: dataset.arrays,
  channels: dataset.channels, plate: dataset.plate, format: "Zarr v2", metadata: "OME-NGFF 0.4", codecs: [...new Set(dataset.arrays.map((array) => array.compressor ?? "uncompressed"))] });
function position(workspace: MicroscopyWorkspace, value?: Record<string, number>) {
  for (const [id, index] of Object.entries(value ?? {})) setPosition(workspace, id, index);
}
async function writePlane(io: WorkerIO, id: string, plane: ImagePlane) {
  validatePlane(plane); const data = new Uint8Array(plane.values.length * 4); const view = new DataView(data.buffer);
  for (let index = 0; index < plane.values.length; index++) view.setFloat32(index * 4, plane.values[index], true);
  return io.write(id, data, "float32-plane", { dtype: "float32-le", shape: [plane.height, plane.width] });
}
async function writeWorkspace(io: WorkerIO, workspace: MicroscopyWorkspace, planes: Map<string, ImagePlane> = new Map(), planePositions: Map<string, Record<string, number>> = new Map(), derivations: Map<string, unknown> = new Map()) {
  validateWorkspace(workspace);
  const workspaceOutput = await io.writeJSON("workspace.json", workspace, "microscopy-workspace");
  const outputs = [];
  for (const [layerId, plane] of planes) outputs.push({ layerId, outputId: await writePlane(io, `plane-${outputs.length}.f32`, plane),
    ...(plane.support ? { supportOutput: await io.write(`support-${outputs.length}.u8`, plane.support, "valid-support", { dtype: "uint8", shape: [plane.height, plane.width] }) } : {}),
    width: plane.width, height: plane.height, calibration: plane.calibration, position: planePositions.get(layerId) ?? workspace.position, derivation: derivations.get(layerId) });
  return { workspaceOutput, planes: outputs, summary: summary(workspace) };
}

class PlaneResolver {
  private datasets = new Map<string, ZarrDataset>();
  private planes = new Map<string, ImagePlane>();
  private bytes = 0;
  readonly options;
  constructor(readonly io: WorkerIO, readonly args: Record<string, any>) { this.options = { limits: resourceLimits({ limits: io.request.limits }) }; }
  async dataset(id: string) {
    if (this.datasets.has(id)) return this.datasets.get(id)!;
    const dataset = await openOMEZarr(this.io.store(id), this.options);
    const expected = this.io.grant(id).metadataSha256;
    if (expected !== undefined && expected !== dataset.source.metadataSha256) fail("source-mismatch", "Zarr metadata differs from its frozen directory binding.");
    this.datasets.set(id, dataset); return dataset;
  }
  async resolve(layer: WorkspaceLayer, workspace: MicroscopyWorkspace): Promise<ImagePlane> {
    const semantic = workspace.paintDocuments[layer.id];
    if (semantic) {
      const session = new PaintingSession(semantic.width, semantic.height, semantic.classes, { document: semantic, position: workspace.position });
      return { width: semantic.width, height: semantic.height, values: Float32Array.from(session.labels) };
    }
    const entries = (this.args.planes ?? []) as PlaneInput[];
    const candidates = entries.filter((entry) => entry.layerId === layer.id && workspace.axes.every((axis) => {
      if (["x", "y"].includes(axis.kind) || !layer.axisIDs.includes(axis.id)) return true;
      if (axis.length > 1 && entry.position?.[axis.id] === undefined) return false;
      return (entry.position?.[axis.id] ?? 0) === (workspace.position[axis.id] ?? 0);
    }) && Object.entries(entry.position ?? {}).every(([id, index]) => (workspace.position[id] ?? 0) === index));
    if (candidates.length > 1) fail("ambiguous-plane", "Multiple retained planes match the same layer and position.");
    if (candidates.length === 1) {
      const descriptor = candidates[0]; const key = JSON.stringify(descriptor);
      const existing = this.planes.get(key); if (existing) return existing;
      const count = product([descriptor.width, descriptor.height], "Input plane pixels", this.options.limits.maxPixels);
      if (this.bytes + count * (descriptor.supportInput ? 5 : 4) > this.options.limits.maxWorkingBytes / 2) fail("resource-limit", "Retained plane inputs exceed half the worker memory budget.");
      const raw = await this.io.input(descriptor.inputId, count * 4);
      if (raw.byteLength !== count * 4) fail("invalid-plane", "Float32 plane bytes do not match its declared shape.");
      const values = new Float32Array(count); const view = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
      for (let index = 0; index < count; index++) values[index] = view.getFloat32(index * 4, true);
      const support = descriptor.supportInput ? await this.io.input(descriptor.supportInput, count) : undefined;
      const plane = { width: descriptor.width, height: descriptor.height, values, calibration: descriptor.calibration, support };
      validatePlane(plane, this.options); this.planes.set(key, plane); this.bytes += values.byteLength + (support?.byteLength ?? 0); return plane;
    }
    const bindings = ((this.args.zarrBindings ?? []) as ZarrBinding[]).filter((binding) => binding.layerId === layer.id);
    if (bindings.length !== 1) fail("missing-plane", `Layer ${layer.name} has no exact retained plane or unique local dataset binding for this position.`);
    const binding = bindings[0]; const dataset = await this.dataset(binding.storeId);
    const selected = structuredClone(binding.selection ?? {});
    selected.level ??= layer.source.level ?? 0;
    if (selected.level !== (layer.source.level ?? 0)) fail("source-grid-mismatch", "The selected display pyramid differs from the layer grid. Bind a layer at that exact level instead of reusing its coordinates.");
    const array = dataset.arrays[selected.level];
    if (!array) fail("invalid-selection", "Selected Zarr pyramid level does not exist.");
    selected.indices = { ...selected.indices };
    for (const axis of workspace.axes.filter((item) => layer.axisIDs.includes(item.id) && !["x", "y"].includes(item.kind))) {
      const name = binding.axisMapping?.[axis.id]; const target = array.axes.find((item) => name ? item.name === name : item.id === axis.id);
      if (!target) fail("missing-axis-binding", "Map each nonspatial layer axis explicitly to its local dataset axis.");
      selected.indices[target.name] = workspace.position[axis.id] ?? 0;
    }
    return loadZarrPlane(this.io.store(binding.storeId), dataset, selected, this.options);
  }
  async visible(workspace: MicroscopyWorkspace) {
    const planes = new Map<string, ImagePlane>(); let bytes = 0;
    for (const layer of workspace.layers.filter((item) => item.visible && ["image", "labels"].includes(item.kind))) {
      const plane = await this.resolve(layer, workspace); bytes += plane.values.byteLength;
      if (bytes > this.options.limits.maxWorkingBytes / 2) fail("resource-limit", "Visible raster layers exceed the shared working-memory budget.");
      planes.set(layer.id, plane);
    }
    return planes;
  }
}

async function execute(io: WorkerIO): Promise<Record<string, unknown>> {
  const args = io.request.arguments as Record<string, any>; const resolver = new PlaneResolver(io, args); const options = resolver.options;
  switch (io.request.operation) {
    case "catalogue": return catalogue();
    case "workspace.create": return writeWorkspace(io, createWorkspace(args.name, args.axes as WorkspaceAxis[] | undefined));
    case "workspace.import": {
      const raw = await io.input(args.inputId, WORKER_LIMITS.jsonBytes);
      const imported = await importProject(new TextDecoder("utf8", { fatal: true }).decode(raw), options);
      return writeWorkspace(io, imported.workspace, imported.planes);
    }
    case "zarr.inspect": {
      const dataset = await resolver.dataset(args.storeId);
      return { datasetOutput: await io.writeJSON("dataset.json", dataset, "zarr-metadata"), summary: datasetSummary(dataset) };
    }
    case "zarr.plane": {
      const dataset = await resolver.dataset(args.storeId);
      const plane = await loadZarrPlane(io.store(args.storeId), dataset, args.selection, options);
      return { planeOutput: await writePlane(io, "plane.f32", plane), width: plane.width, height: plane.height,
        calibration: plane.calibration, selection: args.selection ?? {}, datasetSummary: datasetSummary(dataset) };
    }
    case "lineage.validate": case "lineage.build": {
      const raw = await io.json<LineageGraph | LineageNode[]>(args.inputId);
      const graph = io.request.operation === "lineage.validate" ? raw as LineageGraph
        : await buildLineage(Array.isArray(raw) ? raw : raw.nodes, { ...options, maxDistance: args.maxDistance, calibration: args.calibration,
          maxDistanceEvaluations: args.maxDistanceEvaluations });
      validateLineage(graph);
      return { graphOutput: await io.writeJSON("lineage.json", graph, "point-lineage"),
        tracksOutput: await io.writeJSON("tracks.json", lineageTracks(graph), "point-tracks"), nodeCount: graph.nodes.length, edgeCount: graph.edges.length };
    }
  }
  const workspace = await io.json<MicroscopyWorkspace>(args.workspaceInput); validateWorkspace(workspace);
  switch (io.request.operation) {
    case "workspace.validate": return { summary: summary(workspace) };
    case "workspace.positions": {
      if (args.workflowId && args.planId) fail("invalid-arguments", "Select a workflow or animation plan, not both.");
      const requests = new Map<string, { layerId: string; position: Record<string, number> }>();
      const add = (layerId: string, current: Record<string, number>) => {
        const layer = workspace.layers.find(item => item.id === layerId);
        if (!layer || !["image", "labels"].includes(layer.kind) || workspace.paintDocuments[layerId]) return;
        const position = { ...current };
        requests.set(JSON.stringify([layerId, Object.entries(position).sort(([a], [b]) => a.localeCompare(b))]), { layerId, position });
        if (requests.size > 256) fail("resource-limit", "An execution resolves at most 256 exact layer/position planes.");
      };
      if (args.planId) {
        const plan = workspace.animationPlans.find(item => item.id === args.planId);
        if (!plan) fail("animation-not-found", "Choose a retained animation plan.");
        for (const state of animationStates(plan, workspace.axes)) for (const id of state.visibleLayerIDs) add(id, state.position);
      } else if (args.workflowId) {
        const workflow = workspace.workflows.find(item => item.id === args.workflowId);
        if (!workflow) fail("workflow-not-found", "Choose a retained workflow.");
        for (const step of workflow.steps) {
          if (step.type === "position") position(workspace, { [step.axisID]: step.index });
          else if (step.type === "register") { add(step.referenceID, workspace.position); add(step.movingID, workspace.position); }
          else if (step.type === "stitch") for (const id of step.layerIDs) add(id, workspace.position);
        }
      } else for (const layer of workspace.layers) if (layer.visible) add(layer.id, workspace.position);
      const positions = new Map([...requests.values()].map(item => [JSON.stringify(Object.entries(item.position).sort(([a], [b]) => a.localeCompare(b))), item.position]));
      return { positions: [...positions.values()], requests: [...requests.values()] };
    }
    case "workspace.export": {
      const planes = new Map<string, ImagePlane>();
      // Only explicitly bound or generated raster snapshots are embedded. External sources stay reattachable.
      for (const layer of workspace.layers) if ((args.planes ?? []).some((entry: PlaneInput) => entry.layerId === layer.id)
        || ((layer.kind === "image" || layer.kind === "labels") && layer.source.identity.kind === "generated" && !workspace.paintDocuments[layer.id]))
        planes.set(layer.id, await resolver.resolve(layer, workspace));
      return { projectOutput: await io.write("project.json", await exportProject(workspace, planes, options), "microscopy-project"), summary: summary(workspace) };
    }
    case "workspace.compose": {
      position(workspace, args.position); const planes = await resolver.visible(workspace);
      const frame = await composePlane(workspace, planes, { ...options, width: args.width, height: args.height, origin: args.origin as Coordinate,
        center: args.center as Coordinate, zoom: args.zoom });
      const rgba = new Uint8Array(frame.rgba.buffer, frame.rgba.byteOffset, frame.rgba.byteLength);
      return { rgbaOutput: await io.write("composite.rgba", rgba, "display-rgba", { dtype: "uint8", shape: [frame.height, frame.width, 4] }),
        width: frame.width, height: frame.height, position: workspace.position, presentationOnly: true };
    }
    case "workspace.replay": {
      const workflow = workspace.workflows.find((item) => item.id === args.workflowId);
      if (!workflow) fail("workflow-not-found", "Choose a retained layer workflow from this workspace.");
      const result = await replayWorkflow(workspace, workflow, (layer, current) => resolver.resolve(layer, current), options);
      return writeWorkspace(io, result.workspace, result.planes, result.planePositions, result.derivations);
    }
    case "semantic.render": {
      position(workspace, args.position); const document = workspace.paintDocuments[args.layerId];
      if (!document || !workspace.layers.some((layer) => layer.id === args.layerId && layer.kind === "labels")) fail("paint-not-found", "Choose a semantic-label layer with a retained stroke journal.");
      const session = new PaintingSession(document.width, document.height, document.classes, { document, position: workspace.position });
      const bytes = new Uint8Array(session.labels.length * 2); const view = new DataView(bytes.buffer);
      for (let index = 0; index < session.labels.length; index++) view.setUint16(index * 2, session.labels[index], true);
      return { labelsOutput: await io.write("semantic.u16", bytes, "semantic-labels", { dtype: "uint16-le", shape: [document.height, document.width] }),
        tiffOutput: await io.write("semantic.tif", encodeLabelTIFF(document.width, document.height, session.labels, args.calibration as Calibration), "semantic-label-tiff"),
        width: document.width, height: document.height, classes: document.classes, position: workspace.position, semantic: true };
    }
    case "animation.gif": {
      const plan = workspace.animationPlans.find((item) => item.id === args.planId);
      if (!plan) fail("animation-not-found", "Choose a retained animation plan from this workspace.");
      const states = animationStates(plan, workspace.axes);
      const pixels = product([args.width, args.height], "Animation frame pixels", options.limits.maxPixels);
      if (states.length * pixels * 4 > options.limits.maxWorkingBytes / 3) fail("resource-limit", "Animation frames exceed their memory budget. Reduce size, duration or frame rate.");
      const frames = [];
      for (const state of states) {
        position(workspace, state.position); for (const layer of workspace.layers) layer.visible = state.visibleLayerIDs.includes(layer.id);
        frames.push(await composePlane(workspace, await resolver.visible(workspace), { ...options, width: args.width, height: args.height, zoom: state.zoom, center: state.center }));
      }
      return { gifOutput: await io.write("animation.gif", await encodeGIF(frames, plan.framesPerSecond, options), "presentation-gif"),
        width: args.width, height: args.height, frameCount: frames.length, framesPerSecond: plan.framesPerSecond, presentationOnly: true };
    }
    default: fail("unsupported-operation", "This worker exposes only the fixed published operations.");
  }
}

async function main() {
  const argv = process.argv.slice(2);
  if (argv.length !== 4 || argv[0] !== "--request" || argv[2] !== "--response") throw new Error("Use --request <absolute JSON> --response <outputDirectory/result.json>.");
  const requestPath = argv[1], responsePath = argv[3]; const root = await canonicalDirectory(requestDirectory(requestPath));
  contained(root, requestPath);
  const request = JSON.parse(new TextDecoder("utf8", { fatal: true }).decode(await readFileBounded(requestPath, WORKER_LIMITS.requestBytes, root))) as WorkerRequest;
  if (request.schemaVersion !== 1 || typeof request.requestId !== "string" || !request.requestId || request.requestId.length > 256
    || typeof request.operation !== "string" || !Object.hasOwn(OPERATION_SCHEMAS, request.operation)) fail("invalid-request", "Worker request schema, identity or operation is invalid.");
  if (resolve(responsePath) !== resolve(request.outputDirectory, "result.json")) fail("unsafe-path", "Worker response must be outputDirectory/result.json.");
  const outputRoot = await prepareOutput(root, request.outputDirectory); const io = new WorkerIO(request, root, outputRoot);
  const base = { schemaVersion: 1 as const, requestId: request.requestId, operation: request.operation, engineVersion: ENGINE_VERSION, nodeVersion: process.versions.node };
  let response: WorkerResponse;
  try {
    if (process.versions.node !== NODE_VERSION) fail("node-version", `This worker requires the pinned Node ${NODE_VERSION} runtime.`);
    if (process.env.NODE_OPTIONS || process.env.NODE_PATH) fail("unsafe-runtime", "The canonical parent must clear NODE_OPTIONS and NODE_PATH before launching this worker.");
    validate(request.arguments, OPERATION_SCHEMAS[request.operation]); await io.initialize();
    response = { ...base, ok: true, result: await execute(io), outputs: io.outputs, readSet: io.readSet };
  } catch (cause) {
    const error = cause as Error & { code?: string };
    response = { ...base, ok: false, error: { code: typeof error.code === "string" ? error.code : "worker-error", message: String(error.message ?? cause).slice(0, 4096) }, outputs: [], readSet: io.readSet };
  }
  let encoded = JSON.stringify(response);
  if (Buffer.byteLength(encoded) > WORKER_LIMITS.responseBytes) encoded = JSON.stringify({ ...base, ok: false,
    error: { code: "resource-limit", message: "Worker response exceeded its metadata budget; no outputs may be committed." }, outputs: [], readSet: [] });
  const file = await open(responsePath, "wx", 0o600);
  try { await file.writeFile(encoded); await file.sync(); } finally { await file.close(); }
}
void main().catch((cause) => { process.stderr.write(`${String((cause as Error)?.message ?? cause).slice(0, 4096)}\n`); process.exitCode = 1; });
