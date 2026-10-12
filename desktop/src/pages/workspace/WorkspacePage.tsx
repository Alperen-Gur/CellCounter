import { useCallback, useEffect, useRef, useState, type PointerEvent } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { open, save } from '@tauri-apps/plugin-dialog';
import { getPort } from '../../kernel/persistence';
import type { ImageDTO } from '../../kernel/types';
import { loadWorkflowDocument, saveWorkflowDocument } from '../../kernel/workflow/workflowDocuments';
import {
  addLineageNode, animationStates, applyTransform, buildLineage, bundledExtensions, composePlane,
  concatenateTransform, createLayer, createWorkspace, encodeGIF, encodeLabelTIFF, exportProject,
  importProject, inverseTransform, lineageTracks, linkLineage, loadZarrPlane, openOMEZarr,
  PaintingSession, planeRange, registerTranslation, removeLineageNode, replayWorkflow,
  setPosition, stitchGrid, unlinkLineage, validateWorkspace,
  type AffineTransform, type ComposedPlane, type Coordinate, type ImagePlane, type LineageEdgeKind, type LocalByteStore,
  type MicroscopyWorkspace, type WorkflowStep, type WorkspaceLayer, type ZarrDataset,
} from '../../../../shared/microscopy/index';
import './workspace.css';

// The native byte adapter currently crosses JSON IPC, so cap encoded chunks
// below the portable limit to reserve space for temporary numeric JS arrays.
const LIMITS = { maxPixels: 4_000_000, maxWorkingBytes: 192 * 1024 * 1024, maxEncodedChunkBytes: 4 * 1024 * 1024, maxDecodedChunkBytes: 16 * 1024 * 1024 };
const CACHE_BYTES = 64 * 1024 * 1024;
interface SourcePlaneReply { path: string; width: number; height: number; previewWidth: number; previewHeight: number; stride: number; values: number[]; channelCount: number; tCount: number; zCount: number; pxPerUm?: number; sourceHash?: string; calibrationSource?: string }
type Tool = 'inspect' | 'paint' | 'erase' | 'point' | 'rectangle' | 'lineage';
const copy = (workspace: MicroscopyWorkspace) => ({ ...structuredClone(workspace), modifiedAt: new Date().toISOString() });
const positionKey = (position: Record<string, number>) => JSON.stringify(Object.entries(position).sort(([a], [b]) => a.localeCompare(b)));
function planeBytes(planes: Iterable<ImagePlane>): number { return [...new Set(planes)].reduce((sum, plane) => sum + plane.values.byteLength, 0); }
interface WorkspaceViewport { origin: Coordinate; worldWidth: number; worldHeight: number; zoom: number; width: number; height: number }
function workspaceViewport(workspace: MicroscopyWorkspace, planes: ReadonlyMap<string, ImagePlane>): WorkspaceViewport {
  let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
  for (const layer of workspace.layers) {
    const plane = planes.get(layer.id); if (!layer.visible || !plane) continue;
    for (const point of [{ x: 0, y: 0 }, { x: plane.width, y: 0 }, { x: 0, y: plane.height }, { x: plane.width, y: plane.height }]) {
      const world = applyTransform(layer.transform, point);
      if (!Number.isFinite(world.x) || !Number.isFinite(world.y)) throw new Error('Layer bounds exceed finite workspace coordinates.');
      left = Math.min(left, world.x); right = Math.max(right, world.x); top = Math.min(top, world.y); bottom = Math.max(bottom, world.y);
    }
  }
  if (!Number.isFinite(left)) { left = 0; top = 0; right = 1024; bottom = 1024; }
  left = Math.floor(left); top = Math.floor(top);
  const worldWidth = Math.max(1, Math.ceil(right) - left), worldHeight = Math.max(1, Math.ceil(bottom) - top);
  if (!Number.isFinite(worldWidth) || !Number.isFinite(worldHeight)) throw new Error('Workspace extent is not finite.');
  const zoom = Math.min(1, 1200 / worldWidth, 1200 / worldHeight);
  if (!(zoom > 0)) throw new Error('Workspace extent cannot fit the local viewport.');
  return { origin: { x: left, y: top }, worldWidth, worldHeight, zoom, width: Math.max(1, Math.ceil(worldWidth * zoom)), height: Math.max(1, Math.ceil(worldHeight * zoom)) };
}

export default function WorkspacePage() {
  const [workspace, setWorkspace] = useState(() => createWorkspace('Microscopy workspace'));
  const [images, setImages] = useState<ImageDTO[]>([]), [imageID, setImageID] = useState('');
  const [selectedID, setSelectedID] = useState(''), [referenceID, setReferenceID] = useState('');
  const [rendered, setRendered] = useState<{ width: number; height: number; rgba: Uint8ClampedArray } & WorkspaceViewport>();
  const [busy, setBusy] = useState(false), [painting, setPainting] = useState(false), [rendering, setRendering] = useState(false), [paintRevision, setPaintRevision] = useState(0);
  const [error, setError] = useState(''), [status, setStatus] = useState(''), [tool, setTool] = useState<Tool>('inspect');
  const [radius, setRadius] = useState(8), [classValue, setClassValue] = useState(1);
  const [columns, setColumns] = useState(2), [overlap, setOverlap] = useState(.1), [maxShift, setMaxShift] = useState(40);
  const [recording, setRecording] = useState(false), [steps, setSteps] = useState<WorkflowStep[]>([]);
  const [parentID, setParentID] = useState(''), [childID, setChildID] = useState(''), [relation, setRelation] = useState<LineageEdgeKind>('continuation');
  const [keyTime, setKeyTime] = useState(0), [fps, setFPS] = useState(8), [saved, setSaved] = useState(false);
  const canvas = useRef<HTMLCanvasElement>(null); const model = useRef(workspace); model.current = workspace;
  const mounted = useRef(true), operation = useRef<AbortController | undefined>(undefined), locked = useRef(false);
  const viewerAbort = useRef<AbortController | undefined>(undefined), renderedModel = useRef<MicroscopyWorkspace | undefined>(undefined);
  const sources = useRef(new Map<string, { store: LocalByteStore; dataset: ZarrDataset }>());
  const sourceInfo = useRef(new Map<string, { t: number; z: number; c: number }>());
  const generated = useRef(new Map<string, ImagePlane>()), snapshotPositions = useRef(new Map<string, string>());
  const livePlanes = useRef(new Map<string, ImagePlane>()), paint = useRef<{ id: string; session: PaintingSession } | undefined>(undefined);
  const loadedKeys = useRef(new Map<string, string>());
  const drag = useRef<Coordinate | undefined>(undefined);
  const gesture = useRef<{ layerID: string; inverse: AffineTransform; viewport: WorkspaceViewport; position: Record<string, number> } | undefined>(undefined);
  const selected = workspace.layers.find(layer => layer.id === selectedID);

  useEffect(() => {
    mounted.current = true;
    void getPort().allImages().then(list => { if (mounted.current) { setImages(list); setImageID(list[0]?.id ?? ''); } }).catch(cause => { if (mounted.current) setError(String(cause)); });
    void loadWorkflowDocument<unknown>('workspace').then(document => { if (mounted.current) setSaved(Boolean(document)); }).catch(cause => { if (mounted.current) setError(String(cause)); });
    return () => { mounted.current = false; operation.current?.abort(); viewerAbort.current?.abort(); paint.current?.session.cancelStroke(); };
  }, []);
  const publish = (next: MicroscopyWorkspace) => { validateWorkspace(next); model.current = next; setWorkspace(next); };
  const mutate = (change: (next: MicroscopyWorkspace) => void) => {
    if (locked.current || painting || gesture.current) return;
    try { const next = copy(model.current); change(next); publish(next); setError(''); } catch (cause) { setError(cause instanceof Error ? cause.message : String(cause)); }
  };
  const record = (step: WorkflowStep) => { if (recording) setSteps(old => { if (old.length >= 1024) { setError('Workflow recording reached 1,024 steps. Save the workflow before recording more.'); return old; } return [...old, step]; }); };
  const run = async (action: (signal: AbortSignal) => Promise<void>) => {
    if (locked.current || painting || gesture.current) return; const controller = new AbortController(); operation.current = controller; locked.current = true; setBusy(true); setError(''); setStatus('');
    try { await action(controller.signal); } catch (cause) { if (mounted.current && !controller.signal.aborted) setError(cause instanceof Error ? cause.message : String(cause)); }
    finally { if (operation.current === controller) { operation.current = undefined; locked.current = false; if (mounted.current) setBusy(false); } }
  };
  const storeGenerated = (id: string, plane: ImagePlane) => { const next = new Map(generated.current); next.set(id, plane); if (planeBytes([...next.values(), ...livePlanes.current.values()]) > CACHE_BYTES) throw new Error('Workspace rasters exceed the 64 MiB cache. Hide layers or create a smaller workspace.'); generated.current = next; };
  // Painting journals are the durable representation. Reuse the existing
  // snapshot buffer so committing/undoing an edit cannot fail on cache growth.
  const refreshPaintSnapshot = (id: string, session: PaintingSession) => { const plane = generated.current.get(id); if (plane && plane.values.length === session.labels.length) for (let i = 0; i < plane.values.length; i++) plane.values[i] = session.labels[i]; };

  const resolvePlane = useCallback(async (layer: WorkspaceLayer, current: MicroscopyWorkspace, signal?: AbortSignal): Promise<ImagePlane> => {
    const embedded = generated.current.get(layer.id);
    if (layer.kind === 'labels' && current.paintDocuments[layer.id]) {
      const document = current.paintDocuments[layer.id]; const active = paint.current;
      const session = active?.id === layer.id && positionKey(current.position) === positionKey(model.current.position) ? active.session : new PaintingSession(document.width, document.height, document.classes, { document, position: current.position });
      return { width: document.width, height: document.height, values: Float32Array.from(session.labels), calibration: embedded?.calibration };
    }
    if (embedded && (layer.source.identity.kind === 'generated' || snapshotPositions.current.get(layer.id) === positionKey(current.position))) return embedded;
    const key = JSON.stringify([layer.source.identity.id, layer.source.identity.sha256, layer.source.arrayPath, layer.source.channel, positionKey(current.position)]);
    const cached = livePlanes.current.get(layer.id); if (cached && loadedKeys.current.get(layer.id) === key) return cached;
    if (layer.source.identity.kind === 'zarr') {
      const attached = sources.current.get(layer.source.identity.id); if (!attached) throw new Error(`Reattach the local OME-Zarr folder “${layer.source.identity.name}” to browse its source planes.`);
      const level = attached.dataset.arrays.findIndex(array => array.path === layer.source.arrayPath); if (level < 0) throw new Error('The recorded Zarr array is missing.');
      const array = attached.dataset.arrays[level]; const indices: Record<string, number> = {};
      for (const axis of array.axes) { const shared = current.axes.find(a => a.kind === axis.kind && (axis.kind !== 'other' || a.name === axis.name)); indices[axis.name] = axis.kind === 'channel' && layer.source.channel !== undefined ? layer.source.channel : shared ? current.position[shared.id] ?? 0 : 0; }
      return loadZarrPlane(attached.store, attached.dataset, { level, indices }, { limits: LIMITS, signal });
    }
    const image = images.find(item => item.id === layer.source.identity.id); if (!image || (layer.source.identity.sha256 && image.fileHash !== layer.source.identity.sha256)) throw new Error('The preserved library source is missing or changed.');
    const t = current.axes.find(axis => axis.kind === 'time'), z = current.axes.find(axis => axis.kind === 'z'), c = current.axes.find(axis => axis.kind === 'channel'); const runId = crypto.randomUUID();
    const cancel = () => { void invoke('cancel_assay', { runId }).catch(() => {}); }; signal?.addEventListener('abort', cancel, { once: true }); let preview: SourcePlaneReply | undefined;
    try {
      if (signal?.aborted) throw new DOMException('Cancelled', 'AbortError');
      preview = await invoke<SourcePlaneReply>('parity_source', { imageId: image.id, operation: 'source', runId, request: { workspaceExact: true, includeValues: true, channel: layer.source.channel ?? (c ? current.position[c.id] ?? 0 : 0), projection: 'none', timeIndex: t ? current.position[t.id] ?? 0 : 0, zIndex: z ? current.position[z.id] ?? 0 : 0 } });
      if (signal?.aborted) throw new DOMException('Cancelled', 'AbortError');
      if (preview.stride !== 1 || preview.width * preview.height > LIMITS.maxPixels || preview.values.length !== preview.width * preview.height) throw new Error('This source cannot provide an exact workspace plane within four million pixels. Use a smaller field or a local OME-Zarr level.');
      if (layer.source.identity.sha256 && preview.sourceHash && preview.sourceHash !== layer.source.identity.sha256) throw new Error('The source content changed after the layer was created.');
      sourceInfo.current.set(image.id, { t: preview.tCount, z: preview.zCount, c: preview.channelCount });
      const calibration = preview.calibrationSource && preview.calibrationSource !== 'default' && preview.pxPerUm && preview.pxPerUm > 0 ? { x: 1 / preview.pxPerUm, y: 1 / preview.pxPerUm, unit: 'µm' } : undefined;
      return { width: preview.width, height: preview.height, values: Float32Array.from(preview.values), calibration };
    } finally { signal?.removeEventListener('abort', cancel); if (preview?.path) void invoke('release_source_preview', { path: preview.path }).catch(() => {}); }
  }, [images]);
  useEffect(() => {
    const controller = new AbortController(); let active = true; viewerAbort.current = controller; setRendering(true);
    void (async () => {
      const planes = new Map<string, ImagePlane>();
      for (const layer of workspace.layers) if (layer.visible && (layer.kind === 'image' || layer.kind === 'labels')) { const plane = await resolvePlane(layer, workspace, controller.signal); planes.set(layer.id, plane); if (planeBytes([...planes.values(), ...generated.current.values(), ...livePlanes.current.values()]) > CACHE_BYTES) throw new Error('Visible source planes exceed the 64 MiB workspace cache. Hide layers or use smaller images.'); }
      const viewport = workspaceViewport(workspace, planes);
      const result = await composePlane(workspace, planes, { width: viewport.width, height: viewport.height, origin: viewport.origin, zoom: viewport.zoom, limits: LIMITS, signal: controller.signal });
      if (active) { livePlanes.current = planes; loadedKeys.current = new Map(workspace.layers.map(layer => [layer.id, JSON.stringify([layer.source.identity.id, layer.source.identity.sha256, layer.source.arrayPath, layer.source.channel, positionKey(workspace.position)])])); renderedModel.current = workspace; setRendered({ ...result, ...viewport }); setError(''); }
    })().catch(cause => { if (active) { renderedModel.current = undefined; setRendered(undefined); if (!controller.signal.aborted) setError(cause instanceof Error ? cause.message : String(cause)); } }).finally(() => { if (active) setRendering(false); });
    return () => { active = false; controller.abort(); };
  }, [workspace, paintRevision, resolvePlane]);
  useEffect(() => { const element = canvas.current; if (!element) return; if (!rendered) { element.getContext('2d')?.clearRect(0, 0, element.width, element.height); return; } element.width = rendered.width; element.height = rendered.height; element.getContext('2d')?.putImageData(new ImageData(rendered.rgba, rendered.width, rendered.height), 0, 0); }, [rendered]);
  const saveBytes = async (name: string, bytes: Uint8Array, signal: AbortSignal) => { const outPath = await save({ defaultPath: name }); if (!outPath || signal.aborted) return; await invoke('export_workspace_bytes', { outPath, bytes: Array.from(bytes) }); if (!signal.aborted) setStatus(`Saved ${name}.`); };
  const saveProject = (download: boolean) => void run(async signal => { const json = await exportProject(model.current, generated.current, { signal, limits: LIMITS }); if (signal.aborted) return; const bytes = new TextEncoder().encode(json); if (bytes.byteLength > 16 * 1024 * 1024) throw new Error('This host supports project documents up to 16 MiB. Use a smaller workspace before saving.'); if (download) await saveBytes('microscopy.ccworkspace.json', bytes, signal); else { await saveWorkflowDocument('workspace', JSON.parse(json)); if (!signal.aborted) { setSaved(true); setStatus('Workspace saved locally with generated rasters and editing journals.'); } } });
  const restore = async (json: string, signal: AbortSignal) => { const result = await importProject(json, { limits: LIMITS, signal }); if (signal.aborted) return; generated.current = result.planes; snapshotPositions.current = new Map([...result.planes.keys()].map(id => [id, positionKey(result.workspace.position)])); paint.current = undefined; livePlanes.current.clear(); sources.current.clear(); publish(result.workspace); setSelectedID(result.workspace.layers[0]?.id ?? ''); setStatus('Workspace opened. Reattach local Zarr sources to browse other positions.'); };
  const addSource = () => void run(async signal => {
    const image = images.find(item => item.id === imageID); if (!image) throw new Error('Choose a preserved library source.');
    const next = copy(model.current); if (next.layers.length >= 256) throw new Error('Workspace layer limit reached.');
    const layer = createLayer(image.fileName, { identity: { id: image.id, name: image.fileName, kind: 'local', sha256: image.fileHash } });
    const plane = await resolvePlane(layer, next, signal); layer.display = { ...layer.display, ...planeRange(plane) }; next.layers.push(layer);
    if (!next.axes.length) {
      const info = sourceInfo.current.get(image.id)!;
      next.axes = [
        { id: 'x', name: 'X', kind: 'x', length: plane.width, scale: plane.calibration?.x ?? 1, unit: plane.calibration?.unit, calibrated: Boolean(plane.calibration) },
        { id: 'y', name: 'Y', kind: 'y', length: plane.height, scale: plane.calibration?.y ?? 1, unit: plane.calibration?.unit, calibrated: Boolean(plane.calibration) },
        { id: 't', name: 'Time', kind: 'time', length: info.t, scale: 1, calibrated: false },
        { id: 'z', name: 'Z', kind: 'z', length: info.z, scale: 1, calibrated: false },
        { id: 'c', name: 'Channel', kind: 'channel', length: info.c, scale: 1, calibrated: false },
      ]; next.position = Object.fromEntries(next.axes.map(axis => [axis.id, 0]));
    }
    if (signal.aborted) return; publish(next); setSelectedID(layer.id);
  });
  const attachZarr = () => void run(async signal => {
    const root = await open({ directory: true, multiple: false, title: 'Open local OME-Zarr directory' }); if (!root || typeof root !== 'string' || signal.aborted) return;
    const rootParts = root.split(/[\\/]/).filter(Boolean); const name = rootParts[rootParts.length - 1] ?? 'Local OME-Zarr'; const store: LocalByteStore = { id: crypto.randomUUID(), name, async read(path, maxBytes = LIMITS.maxEncodedChunkBytes, readSignal) { if (readSignal?.aborted) throw new DOMException('Cancelled', 'AbortError'); const bytes = await invoke<number[] | null>('workspace_read', { root, path, maxBytes }); if (readSignal?.aborted) throw new DOMException('Cancelled', 'AbortError'); return bytes ? Uint8Array.from(bytes) : null; } };
    const dataset = await openOMEZarr(store, { limits: LIMITS, signal }); const next = copy(model.current); const old = next.layers.find(layer => layer.source.identity.metadataSha256 === dataset.source.metadataSha256)?.source.identity;
    if (old) { dataset.source.id = old.id; store.id = old.id; sources.current.set(old.id, { store, dataset }); for (const layer of next.layers) if (layer.source.identity.id === old.id) { generated.current.delete(layer.id); snapshotPositions.current.delete(layer.id); livePlanes.current.delete(layer.id); loadedKeys.current.delete(layer.id); } if (!signal.aborted) { publish(next); setStatus('Local dataset reattached after metadata identity verification.'); } return; }
    if (next.layers.length) throw new Error('Open a Zarr dataset in an empty workspace, or reattach the dataset belonging to this project. This keeps axis/calibration identities consistent.');
    const level = dataset.arrays.findIndex(array => { const x = array.axes.findIndex(axis => axis.kind === 'x'), y = array.axes.findIndex(axis => axis.kind === 'y'); return array.shape[x] <= LIMITS.maxPixels / array.shape[y]; }); if (level < 0) throw new Error('No pyramid plane fits the four-million-pixel workspace limit.');
    const array = dataset.arrays[level]; next.axes = structuredClone(array.axes); next.position = Object.fromEntries(next.axes.map(axis => [axis.id, 0])); next.plate = dataset.plate;
    const layer = createLayer(dataset.name, { identity: dataset.source, arrayPath: array.path, level }); const plane = await loadZarrPlane(store, dataset, { level }, { limits: LIMITS, signal }); layer.display = { ...layer.display, ...planeRange(plane) }; next.layers.push(layer); sources.current.set(store.id, { store, dataset }); if (!signal.aborted) { publish(next); setSelectedID(layer.id); setStatus(`Opened ${array.path}. Local planes are loaded by selected array and position.`); }
  });
  const switchArray = (path: string) => void run(async signal => { if (!selected) return; const attached = sources.current.get(selected.source.identity.id); if (!attached) throw new Error('Reattach the local dataset first.'); if (model.current.layers.length !== 1) throw new Error('Select the pyramid array/field before adding annotations or other layers; saved geometry stays tied to that array.'); const level = attached.dataset.arrays.findIndex(array => array.path === path); const array = attached.dataset.arrays[level]; if (!array) return; const plane = await loadZarrPlane(attached.store, attached.dataset, { level }, { limits: LIMITS, signal }); const next = copy(model.current); next.axes = structuredClone(array.axes); next.position = Object.fromEntries(next.axes.map(axis => [axis.id, 0])); next.layers[0].source = { ...next.layers[0].source, arrayPath: path, level }; next.layers[0].display = { ...next.layers[0].display, ...planeRange(plane) }; if (!signal.aborted) publish(next); });
  const addLayer = (kind: 'labels' | 'points' | 'shapes') => {
    if (!rendered || busy || painting || renderedModel.current !== model.current) return;
    try { const next = copy(model.current); const layer = createLayer(`${kind} ${next.layers.length + 1}`, { identity: { id: crypto.randomUUID(), name: kind, kind: 'generated' } }, { kind, opacity: kind === 'labels' ? .55 : 1, points: kind === 'points' ? [] : undefined, shapes: kind === 'shapes' ? [] : undefined }); next.layers.push(layer);
      let pending: { plane: ImagePlane; session: PaintingSession } | undefined;
      if (kind === 'labels') { const width = rendered.worldWidth, height = rendered.worldHeight; if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width > LIMITS.maxPixels / height) throw new Error('A semantic label layer supports at most four million world pixels. Use a smaller workspace extent.'); const session = new PaintingSession(width, height, [{ value: 1, name: 'Cell', colorHex: '#5bc6ae' }, { value: 2, name: 'Nucleus', colorHex: '#f5c868' }]); layer.transform.tx = rendered.origin.x; layer.transform.ty = rendered.origin.y; const x = next.axes.find(axis => axis.kind === 'x'), y = next.axes.find(axis => axis.kind === 'y'); const calibration = x?.calibrated && y?.calibrated && x.unit && x.unit === y.unit ? { x: x.scale, y: y.scale, unit: x.unit } : undefined; pending = { plane: { width, height, values: new Float32Array(width * height), calibration }, session }; next.paintDocuments[layer.id] = structuredClone(session.document); }
      validateWorkspace(next); if (pending) { storeGenerated(layer.id, pending.plane); paint.current = { id: layer.id, session: pending.session }; }
      publish(next); setSelectedID(layer.id);
    } catch (cause) { setError(String(cause)); }
  };
  const canvasPoint = (event: PointerEvent<HTMLCanvasElement>): Coordinate => { const rect = event.currentTarget.getBoundingClientRect(), viewport = gesture.current?.viewport ?? rendered; const x = (event.clientX - rect.left) * (viewport?.width ?? event.currentTarget.width) / Math.max(1, rect.width), y = (event.clientY - rect.top) * (viewport?.height ?? event.currentTarget.height) / Math.max(1, rect.height); return { x: x / (viewport?.zoom ?? 1) + (viewport?.origin.x ?? 0), y: y / (viewport?.zoom ?? 1) + (viewport?.origin.y ?? 0) }; };
  const selectedPoint = (event: PointerEvent<HTMLCanvasElement>): Coordinate => gesture.current ? applyTransform(gesture.current.inverse, canvasPoint(event)) : selected ? applyTransform(inverseTransform(selected.transform), canvasPoint(event)) : canvasPoint(event);
  const pointerDown = (event: PointerEvent<HTMLCanvasElement>) => {
    if (busy || painting || !selected || !rendered || renderedModel.current !== model.current) return;
    try { const point = selectedPoint(event);
      if (tool === 'paint' || tool === 'erase') { if (selected.kind !== 'labels') throw new Error('Select a semantic label layer before painting.'); let active = paint.current; const doc = model.current.paintDocuments[selected.id]; if (!active || active.id !== selected.id) active = { id: selected.id, session: new PaintingSession(doc.width, doc.height, doc.classes, { document: doc, position: model.current.position }) }; paint.current = active; active.session.beginStroke(classValue, radius, model.current.position, tool === 'erase'); active.session.paint(point); gesture.current = { layerID: selected.id, inverse: inverseTransform(selected.transform), viewport: rendered, position: { ...model.current.position } }; setPainting(true); event.currentTarget.setPointerCapture(event.pointerId); setPaintRevision(n => n + 1); }
      else if (tool === 'point') { if (selected.kind !== 'points') throw new Error('Select a points layer.'); mutate(next => { const layer = next.layers.find(layer => layer.id === selected.id)!; layer.points!.push({ id: crypto.randomUUID(), coordinate: point, position: { ...next.position } }); }); }
      else if (tool === 'rectangle') { if (selected.kind !== 'shapes') throw new Error('Select a shapes layer.'); drag.current = point; gesture.current = { layerID: selected.id, inverse: inverseTransform(selected.transform), viewport: rendered, position: { ...model.current.position } }; setPainting(true); event.currentTarget.setPointerCapture(event.pointerId); }
      else if (tool === 'lineage') mutate(next => { const time = next.axes.find(axis => axis.kind === 'time'); addLineageNode(next.lineage, { frame: time ? next.position[time.id] ?? 0 : 0, coordinate: canvasPoint(event) }); });
    } catch (cause) { paint.current?.session.cancelStroke(); drag.current = undefined; gesture.current = undefined; setPainting(false); setError(String(cause)); }
  };
  const pointerMove = (event: PointerEvent<HTMLCanvasElement>) => { if (!paint.current?.session.isPainting) return; try { paint.current.session.paint(selectedPoint(event)); setPaintRevision(n => n + 1); } catch (cause) { paint.current.session.cancelStroke(); gesture.current = undefined; setPainting(false); setPaintRevision(n => n + 1); setError(String(cause)); } };
  const pointerUp = (event: PointerEvent<HTMLCanvasElement>) => {
    if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId);
    let pending: { id: string; session: PaintingSession } | undefined;
    try {
      const active = paint.current;
      if (active?.session.isPainting) {
        const stroke = active.session.endStroke();
        if (stroke) pending = active;
        const next = copy(model.current); next.paintDocuments[active.id] = structuredClone(active.session.document);
        publish(next); pending = undefined; refreshPaintSnapshot(active.id, active.session);
      } else if (drag.current && gesture.current) {
        const a = drag.current, b = selectedPoint(event), captured = gesture.current;
        const next = copy(model.current), layer = next.layers.find(item => item.id === captured.layerID);
        if (!layer || layer.kind !== 'shapes' || positionKey(next.position) !== positionKey(captured.position)) throw new Error('The rectangle source position changed during its gesture.');
        layer.shapes!.push({ id: crypto.randomUUID(), kind: 'rectangle', vertices: [a, b], position: captured.position }); publish(next);
      }
    } catch (cause) {
      // A rejected document keeps both the saved journal and visible pixels
      // at the preceding committed state; the latest undo snapshot is reserved.
      if (pending) { pending.session.undo(); refreshPaintSnapshot(pending.id, pending.session); }
      setError(String(cause));
    } finally { drag.current = undefined; gesture.current = undefined; setPainting(false); setPaintRevision(n => n + 1); }
  };
  const align = () => void run(async signal => { const next = copy(model.current), ref = next.layers.find(layer => layer.id === referenceID), moving = next.layers.find(layer => layer.id === selectedID); if (!ref || !moving || ref.id === moving.id) throw new Error('Select two different image layers.'); const a = await resolvePlane(ref, next, signal), b = await resolvePlane(moving, next, signal); const result = await registerTranslation(a, b, { ...{ limits: LIMITS, signal }, maxShift }); moving.transform = concatenateTransform(result.transform, ref.transform); if (!signal.aborted) { publish(next); record({ type: 'register', referenceID: ref.id, movingID: moving.id, maxShift }); setStatus(`Correlation ${result.score.toFixed(3)}; ${result.samples} samples; translation ${result.transform.tx}, ${result.transform.ty} reference pixels.`); } });
  const mosaic = () => void run(async signal => { const next = copy(model.current), layers = next.layers.filter(layer => layer.kind === 'image' && layer.visible); if (layers.length < 2 || layers.length > 16) throw new Error('Show 2…16 image tiles for a grid mosaic.'); const inputs: ImagePlane[] = []; for (const layer of layers) { inputs.push(await resolvePlane(layer, next, signal)); if (planeBytes([...inputs, ...generated.current.values(), ...livePlanes.current.values()]) > CACHE_BYTES) throw new Error('Mosaic inputs exceed the workspace cache budget.'); } const result = await stitchGrid(inputs, { columns, overlap, limits: LIMITS, signal }); const layer = createLayer('Grid mosaic', { identity: { id: crypto.randomUUID(), name: 'Grid mosaic', kind: 'generated' }, operation: 'grid-stitch' }, { display: { ...planeRange(result.plane), gamma: 1, color: [255, 255, 255] }, transform: { a: 1, b: 0, c: 0, d: 1, tx: result.origin.x, ty: result.origin.y } }); if (signal.aborted) return; next.layers.push(layer); validateWorkspace(next); storeGenerated(layer.id, result.plane); publish(next); setSelectedID(layer.id); record({ type: 'stitch', layerIDs: layers.map(layer => layer.id), columns, overlap, outputName: layer.name }); });
  const importGeometry = () => void run(async signal => { const path = await open({ multiple: false, filters: [{ name: 'Geometry JSON', extensions: ['json'] }] }); if (!path || typeof path !== 'string') return; const raw = await invoke<string>('import_workspace_project', { path }); const value = JSON.parse(raw) as Partial<WorkspaceLayer>; if (!['points', 'shapes', 'tracks', 'surface'].includes(value.kind ?? '')) throw new Error('Import points, shapes, tracks or a projected surface layer.'); const next = copy(model.current); const parts = path.split(/[\\/]/); const layer = createLayer(value.name ?? 'Imported geometry', { identity: { id: crypto.randomUUID(), name: parts[parts.length - 1] ?? 'Geometry', kind: 'generated' } }, { kind: value.kind, points: value.points, shapes: value.shapes, tracks: value.tracks, surface: value.surface }); next.layers.push(layer); validateWorkspace(next); if (!signal.aborted) { publish(next); setSelectedID(layer.id); } });
  const lineageFromLayers = () => void run(async signal => { const nodes = model.current.layers.flatMap(layer => (layer.points ?? []).map(point => { const time = model.current.axes.find(axis => axis.kind === 'time'); return { id: point.id, frame: time ? point.position[time.id] ?? 0 : 0, coordinate: applyTransform(layer.transform, point.coordinate) }; })); if (!nodes.length) throw new Error('Add points at successive time positions first.'); const graph = await buildLineage(nodes, { maxDistance: 120, signal }); const next = copy(model.current); next.lineage = graph; const layer = createLayer('Lineage tracks', { identity: { id: crypto.randomUUID(), name: 'Lineage tracks', kind: 'generated' } }, { kind: 'tracks', tracks: lineageTracks(graph), display: { min: 0, max: 1, gamma: 1, color: [245, 200, 104] } }); next.layers.push(layer); if (!signal.aborted) publish(next); });
  const gif = () => void run(async signal => { const current = copy(model.current), plan = current.animationPlans[0]; if (!plan || !rendered || renderedModel.current !== model.current) throw new Error('Wait for the current source plane, then capture at least two keyframes.'); const states = animationStates(plan, current.axes); if (states.length > 120) throw new Error('This host GIF export is bounded to 120 frames. Reduce duration or frame rate.'); const width = Math.max(1, Math.round(rendered.width * Math.min(1, 512 / Math.max(rendered.width, rendered.height)))), height = Math.max(1, Math.round(rendered.height * Math.min(1, 512 / Math.max(rendered.width, rendered.height)))); const frames: ComposedPlane[] = [];
    const pixels = width * height, retainedBytes = states.length * pixels * 4;
    const compressedBytes = Math.ceil((pixels + Math.ceil(pixels / 200) + 1) * 9 / 8), outputBytes = 801 + states.length * (21 + compressedBytes + Math.ceil(compressedBytes / 255));
    const encodingExtra = outputBytes * 2 + compressedBytes + 1024 * 1024;
    const cached = () => planeBytes([...generated.current.values(), ...livePlanes.current.values()]);
    if (retainedBytes + encodingExtra + cached() + LIMITS.maxPixels * 4 > LIMITS.maxWorkingBytes) throw new Error('GIF frames and retained workspace planes exceed the memory budget. Reduce duration, frame rate or visible layers.');
    for (const state of states) {
      const frame = copy(current); frame.position = state.position; frame.layers.forEach(layer => { layer.visible = state.visibleLayerIDs.includes(layer.id); }); const planes = new Map<string, ImagePlane>();
      for (const layer of frame.layers) if (layer.visible && (layer.kind === 'image' || layer.kind === 'labels')) {
        const priorBytes = planeBytes([...planes.values(), ...generated.current.values(), ...livePlanes.current.values()]);
        if (priorBytes + LIMITS.maxPixels * 4 > CACHE_BYTES || priorBytes + LIMITS.maxPixels * 4 + retainedBytes + encodingExtra > LIMITS.maxWorkingBytes) throw new Error('Animation source planes exceed the bounded workspace memory budget. Hide layers or choose smaller planes.');
        planes.set(layer.id, await resolvePlane(layer, frame, signal));
        if (planeBytes([...planes.values(), ...generated.current.values(), ...livePlanes.current.values()]) > CACHE_BYTES) throw new Error('Animation source planes exceed the workspace cache budget.');
      }
      const extraBytes = cached() + frames.length * pixels * 4;
      frames.push(await composePlane(frame, planes, { width, height, center: state.center, zoom: Math.min(width / rendered.worldWidth, height / rendered.worldHeight) * state.zoom, limits: { ...LIMITS, maxWorkingBytes: LIMITS.maxWorkingBytes - extraBytes }, signal }));
    }
    const bytes = await encodeGIF(frames, plan.framesPerSecond, { limits: { ...LIMITS, maxWorkingBytes: LIMITS.maxWorkingBytes - cached() }, signal }); await saveBytes('microscopy-sequence.gif', bytes, signal);
  });
  const disabled = busy || painting || rendering;
  return <main className="workspace-page"><header><div><h1>Microscopy workspace</h1><p>Local source planes, semantic labels, annotations and lineage. Ordinary image planes are bounded to four million pixels.</p></div><button disabled={!busy && !rendering} onClick={() => { operation.current?.abort(); viewerAbort.current?.abort(); }}>Cancel operation</button></header>
    <div className="workspace-actions"><select disabled={disabled} value={imageID} aria-label="Library source" onChange={event => setImageID(event.target.value)}><option value="">Choose library image</option>{images.map(image => <option key={image.id} value={image.id}>{image.fileName}</option>)}</select><button disabled={disabled || !imageID} onClick={addSource}>Add source</button><button disabled={disabled} onClick={attachZarr}>Open / reattach OME-Zarr</button><button disabled={disabled} onClick={() => void run(async signal => { const path = await open({ multiple: false, filters: [{ name: 'Workspace project', extensions: ['json'] }] }); if (typeof path === 'string') await restore(await invoke('import_workspace_project', { path }), signal); })}>Open project</button><button disabled={disabled || !saved} onClick={() => void run(async signal => { const document = await loadWorkflowDocument('workspace'); if (document) await restore(JSON.stringify(document), signal); })}>Restore local</button><button disabled={disabled} onClick={() => saveProject(false)}>Save locally</button><button disabled={disabled} onClick={() => saveProject(true)}>Export project</button></div>
    {error && <p className="workspace-error" role="alert">{error}</p>}{status && <p role="status">{status}</p>}
    <div className="workspace-layout"><aside><label>Workspace name<input disabled={disabled} value={workspace.name} onChange={event => { if (event.target.value.trim()) mutate(next => { next.name = event.target.value; }); }} /></label>
      {workspace.axes.filter(axis => !['x', 'y'].includes(axis.kind)).map(axis => <label key={axis.id}>{axis.name}: {workspace.position[axis.id] ?? 0} / {axis.length - 1}<input disabled={disabled} type="range" min={0} max={axis.length - 1} value={workspace.position[axis.id] ?? 0} onChange={event => { const index = Number(event.target.value); paint.current = undefined; mutate(next => setPosition(next, axis.id, index)); record({ type: 'position', axisID: axis.id, index }); }} /></label>)}
      <h2>Layers</h2>{workspace.layers.map(layer => <div className={`workspace-layer ${selectedID === layer.id ? 'selected' : ''}`} key={layer.id}><button disabled={disabled} onClick={() => { paint.current = undefined; setSelectedID(layer.id); }}>{layer.kind} · {layer.name}</button><label><input disabled={disabled} type="checkbox" checked={layer.visible} onChange={event => { const visible = event.target.checked; mutate(next => { next.layers.find(item => item.id === layer.id)!.visible = visible; }); record({ type: 'visibility', layerID: layer.id, visible }); }} /> Visible</label><label>Opacity<input disabled={disabled} type="range" min={0} max={1} step={.05} value={layer.opacity} onChange={event => { const opacity = Number(event.target.value); mutate(next => { next.layers.find(item => item.id === layer.id)!.opacity = opacity; }); record({ type: 'opacity', layerID: layer.id, opacity }); }} /></label></div>)}
      <div className="workspace-actions"><button disabled={disabled || !rendered} onClick={() => addLayer('labels')}>Labels</button><button disabled={disabled || !rendered} onClick={() => addLayer('points')}>Points</button><button disabled={disabled || !rendered} onClick={() => addLayer('shapes')}>Shapes</button><button disabled={disabled} onClick={importGeometry}>Import geometry</button></div>
      {selected && <><label>Layer name<input disabled={disabled} value={selected.name} onChange={event => { if (event.target.value.trim()) mutate(next => { next.layers.find(layer => layer.id === selected.id)!.name = event.target.value; }); }} /></label>
        {selected.source.identity.kind === 'zarr' && <label>Field / pyramid array<select disabled={disabled || workspace.layers.length !== 1} value={selected.source.arrayPath} onChange={event => switchArray(event.target.value)}>{sources.current.get(selected.source.identity.id)?.dataset.arrays.map(array => <option key={array.path} value={array.path}>{array.path} · {array.shape.join(' × ')}</option>)}</select></label>}
        <label>Channel (-1 follows axis)<input disabled={disabled} type="number" min={-1} value={selected.source.channel ?? -1} onChange={event => { const channel = Number(event.target.value); if (Number.isSafeInteger(channel) && channel >= -1 && channel < 65536) mutate(next => { const source = next.layers.find(layer => layer.id === selected.id)!.source; if (channel === -1) delete source.channel; else source.channel = channel; }); }} /></label>
        <label>Blend<select disabled={disabled} value={selected.blendMode} onChange={event => mutate(next => { next.layers.find(layer => layer.id === selected.id)!.blendMode = event.target.value as WorkspaceLayer['blendMode']; })}>{['normal', 'additive', 'multiply', 'screen', 'difference'].map(mode => <option key={mode}>{mode}</option>)}</select></label>
        <label>Color<input disabled={disabled} type="color" value={`#${selected.display.color.map(value => value.toString(16).padStart(2, '0')).join('')}`} onChange={event => { const value = event.target.value; mutate(next => { next.layers.find(layer => layer.id === selected.id)!.display.color = [parseInt(value.slice(1, 3), 16), parseInt(value.slice(3, 5), 16), parseInt(value.slice(5, 7), 16)]; }); }} /></label>
        {(['min', 'max', 'gamma'] as const).map(key => <label key={key}>Display {key}<input disabled={disabled} type="number" step={.1} value={selected.display[key]} onChange={event => { const value = Number(event.target.value); if (Number.isFinite(value)) mutate(next => { next.layers.find(layer => layer.id === selected.id)!.display[key] = value; }); }} /></label>)}
        {(['tx', 'ty'] as const).map(key => <label key={key}>Translation {key}<input disabled={disabled} type="number" value={selected.transform[key]} onChange={event => { const value = Number(event.target.value); if (!Number.isFinite(value)) return; const delta = value - selected.transform[key]; mutate(next => { next.layers.find(layer => layer.id === selected.id)!.transform[key] = value; }); record({ type: 'translate', layerID: selected.id, x: key === 'tx' ? delta : 0, y: key === 'ty' ? delta : 0 }); }} /></label>)}
        <p>{livePlanes.current.get(selected.id)?.calibration ? `Pixel sizes: ${livePlanes.current.get(selected.id)!.calibration!.x} × ${livePlanes.current.get(selected.id)!.calibration!.y} ${livePlanes.current.get(selected.id)!.calibration!.unit}` : 'Physical calibration unavailable; coordinates use pixels.'}</p>
      </>}
      <h2>Registration & mosaic</h2><label>Reference<select disabled={disabled} value={referenceID} onChange={event => setReferenceID(event.target.value)}><option value="">Choose image layer</option>{workspace.layers.filter(layer => layer.kind === 'image').map(layer => <option key={layer.id} value={layer.id}>{layer.name}</option>)}</select></label><label>Maximum shift (pixels)<input disabled={disabled} type="number" min={0} max={512} value={maxShift} onChange={event => { const value = Number(event.target.value); if (Number.isInteger(value) && value >= 0 && value <= 512) setMaxShift(value); }} /></label><button disabled={disabled || !selected || selected.kind !== 'image' || !referenceID || selected.id === referenceID} onClick={align}>Align translation</button><label>Grid columns<input disabled={disabled} type="number" min={1} max={16} value={columns} onChange={event => { const value = Number(event.target.value); if (Number.isInteger(value) && value >= 1 && value <= 16) setColumns(value); }} /></label><label>Overlap fraction<input disabled={disabled} type="number" min={0} max={.95} step={.05} value={overlap} onChange={event => { const value = Number(event.target.value); if (Number.isFinite(value) && value >= 0 && value <= .95) setOverlap(value); }} /></label><button disabled={disabled} onClick={mosaic}>Stitch visible grid</button>
    </aside><section className="workspace-stage"><div className="workspace-actions">{(['inspect', 'paint', 'erase', 'point', 'rectangle', 'lineage'] as Tool[]).map(item => <button key={item} disabled={disabled} aria-pressed={item === tool} onClick={() => setTool(item)}>{item}</button>)}<label>Brush radius px<input disabled={disabled} type="number" min={1} max={512} value={radius} onChange={event => { const value = Number(event.target.value); if (Number.isFinite(value) && value >= 1 && value <= 512) setRadius(value); }} /></label><label>Class<select disabled={disabled} value={classValue} onChange={event => setClassValue(Number(event.target.value))}><option value={1}>Cell</option><option value={2}>Nucleus</option></select></label><button disabled={disabled || !paint.current?.session.undoCount} onClick={() => { const active = paint.current; if (active?.session.undo()) { mutate(next => { next.paintDocuments[active.id] = structuredClone(active.session.document); }); refreshPaintSnapshot(active.id, active.session); setPaintRevision(n => n + 1); } }}>Undo paint</button><button disabled={disabled || selected?.kind !== 'labels'} onClick={() => void run(async signal => { if (!selected) return; const plane = await resolvePlane(selected, model.current, signal); const labels = new Uint16Array(plane.values.length); plane.values.forEach((value, i) => { if (!Number.isInteger(value) || value < 0 || value > 65535) throw new Error('Labels must be uint16 class IDs.'); labels[i] = value; }); const bytes = encodeLabelTIFF(plane.width, plane.height, labels, plane.calibration); await saveBytes('semantic-labels.tif', bytes, signal); })}>16-bit label TIFF</button></div>
      <canvas ref={canvas} aria-label="Local microscopy layer canvas" onPointerDown={pointerDown} onPointerMove={pointerMove} onPointerUp={pointerUp} onPointerCancel={() => { paint.current?.session.cancelStroke(); drag.current = undefined; gesture.current = undefined; setPainting(false); setPaintRevision(n => n + 1); }} />
      <details><summary>Lineage</summary><p>Automatic links use consecutive observed frames and a 120-pixel matching radius. Edit divisions, merges and gaps manually.</p><button disabled={disabled} onClick={lineageFromLayers}>Link time-positioned points</button><select disabled={disabled} aria-label="Parent observation" value={parentID} onChange={event => setParentID(event.target.value)}><option value="">Parent observation</option>{workspace.lineage.nodes.map(node => <option key={node.id} value={node.id}>{node.frame}: {node.label ?? node.id}</option>)}</select><select disabled={disabled} aria-label="Child observation" value={childID} onChange={event => setChildID(event.target.value)}><option value="">Child observation</option>{workspace.lineage.nodes.map(node => <option key={node.id} value={node.id}>{node.frame}: {node.label ?? node.id}</option>)}</select><select disabled={disabled} value={relation} onChange={event => setRelation(event.target.value as LineageEdgeKind)}>{['continuation', 'gap', 'division', 'merge'].map(kind => <option key={kind}>{kind}</option>)}</select><button disabled={disabled || !parentID || !childID} onClick={() => mutate(next => { linkLineage(next.lineage, parentID, childID, relation); })}>Link</button><button disabled={disabled || !childID} onClick={() => mutate(next => removeLineageNode(next.lineage, childID))}>Remove child observation</button>{workspace.lineage.edges.slice(0, 1000).map(edge => <p key={edge.id}>{edge.kind} · {edge.parentID} → {edge.childID}<button disabled={disabled} onClick={() => mutate(next => unlinkLineage(next.lineage, edge.id))}>Unlink</button></p>)}</details>
      <details><summary>Workflows</summary><label><input disabled={disabled} type="checkbox" checked={recording} onChange={event => setRecording(event.target.checked)} /> Record layer/axis operations</label><button disabled={disabled || !steps.length} onClick={() => { mutate(next => { next.workflows.push({ id: crypto.randomUUID(), name: `Workflow ${next.workflows.length + 1}`, createdAt: new Date().toISOString(), steps: structuredClone(steps) }); }); setSteps([]); setRecording(false); }}>Save {steps.length} steps</button>{workspace.workflows.map(workflow => <button key={workflow.id} disabled={disabled} onClick={() => void run(async signal => { const result = await replayWorkflow(model.current, workflow, resolvePlane, { limits: LIMITS, signal }); const next = new Map(generated.current); for (const [id, plane] of result.planes) if (result.workspace.layers.find(layer => layer.id === id)?.source.identity.kind === 'generated') next.set(id, plane); if (planeBytes([...next.values(), ...livePlanes.current.values()]) > CACHE_BYTES) throw new Error('Workflow outputs exceed the workspace cache budget.'); if (!signal.aborted) { generated.current = next; paint.current = undefined; publish(result.workspace); } })}>Replay {workflow.name}</button>)}</details>
      <details><summary>Keyframes & GIF</summary><label>Time seconds<input disabled={disabled} type="number" min={0} max={60} value={keyTime} onChange={event => { const value = Number(event.target.value); if (Number.isFinite(value) && value >= 0 && value <= 60) setKeyTime(value); }} /></label><label>Frames per second<input disabled={disabled} type="number" min={1} max={30} value={fps} onChange={event => { const value = Number(event.target.value); if (Number.isInteger(value) && value >= 1 && value <= 30) setFPS(value); }} /></label><button disabled={disabled || !rendered} onClick={() => { if (!rendered) return; mutate(next => { let plan = next.animationPlans[0]; if (!plan) { plan = { id: crypto.randomUUID(), name: 'Workspace animation', framesPerSecond: fps, easing: 'linear', keyframes: [] }; next.animationPlans.push(plan); } plan.framesPerSecond = fps; plan.keyframes.push({ id: crypto.randomUUID(), timeSeconds: keyTime, position: { ...next.position }, zoom: 1, center: { x: rendered.origin.x + rendered.worldWidth / 2, y: rendered.origin.y + rendered.worldHeight / 2 }, visibleLayerIDs: next.layers.filter(layer => layer.visible).map(layer => layer.id) }); }); setKeyTime(value => Math.min(60, value + 1)); }}>Capture keyframe</button><span>{workspace.animationPlans[0]?.keyframes.length ?? 0} keyframes</span><button disabled={disabled || (workspace.animationPlans[0]?.keyframes.length ?? 0) < 2} onClick={gif}>Export GIF</button></details>
      <details><summary>Built-in workspace capabilities</summary>{bundledExtensions(['readOMEZarr', 'exportAnimation']).map(extension => <p key={extension.id}><strong>{extension.name}</strong> · {extension.summary}</p>)}<p>Common image decoding is provided by the native reader. Executable third-party workspace extensions are unavailable.</p></details>
    </section></div>
  </main>;
}
