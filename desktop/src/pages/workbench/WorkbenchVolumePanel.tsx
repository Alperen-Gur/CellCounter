import type { MeasurementPage } from "../../../../shared/workbench/pagingProtocol";
import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import type { WorkbenchImage } from "../../../../shared/workbench/protocol";
import {
  DEFAULT_VOLUME_PARAMETERS, type Vec3, type VolumeDisplay, type VolumeInspection,
  type VolumeMeasurements, type VolumeParameters, type VolumePlane, type VolumeSlice, type VolumeTracks,
} from "../../../../shared/workbench/volumeProtocol";
import VolumeRenderer from "./VolumeRenderer";
import WorkbenchLineage from "./WorkbenchLineage";
import WorkbenchComposite, { type CompositeVolumeState } from "./WorkbenchComposite";
import type { LineageExportArguments, LineageExportFormat } from "../../../../shared/workbench/lineageProtocol";
import type { CompositeExportArguments, CompositeExportFormat } from "../../../../shared/workbench/compositeProtocol";
import type { DisplayPresetFileActions, DisplayPresetMutation } from "../../../../shared/workbench/displayPresetProtocol";
import { carriesCompletedDisplay, carriesDisplayRevision, type DisplayRevisionTransition } from "./displayRevision";
import type { SessionNavigation } from "../../../../shared/workbench/sessionProtocol";

type Props = {
  image: WorkbenchImage; revision: number; busy: boolean;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  act: (operation: string, args: Record<string, unknown>) => Promise<void>;
  runRead: (action: () => Promise<void>) => Promise<void>;
  temporalWriteBlocked: boolean;
  exportLineage: (format: LineageExportFormat, args: LineageExportArguments) => Promise<void>;
  exportComposite: (format: CompositeExportFormat, args: CompositeExportArguments) => Promise<void>;
  compositeExportBlocked: boolean;
  mutatePreset: DisplayPresetMutation;
  presetFiles: DisplayPresetFileActions;
  displayTransition?: DisplayRevisionTransition;
  navigation?: SessionNavigation;
  onWorkflowChange: (configuration: { imageId: string; parameters: VolumeParameters; channel: number; timeIndex: number; plane?: VolumePlane; index?: number }) => void;
  onEditingChange: (editing: boolean) => void;
  onCalibrationEditingChange: (editing: boolean) => void;
  calibrationTarget: HTMLElement | null;
  measurementsTarget: HTMLElement | null;
  contextTarget: HTMLElement | null;
};
const fmt = (value: number | null | undefined) => value == null ? "—" : value.toLocaleString(undefined, { maximumFractionDigits: 3 });
const planeAxis = (plane: VolumePlane) => plane === "xy" ? 2 : plane === "xz" ? 1 : 0;

export default function WorkbenchVolumePanel({ image, revision, busy, read, act, runRead, temporalWriteBlocked, exportLineage, exportComposite, compositeExportBlocked, mutatePreset, presetFiles, displayTransition, navigation, onWorkflowChange, onEditingChange, onCalibrationEditingChange, calibrationTarget, measurementsTarget, contextTarget }: Props) {
  const [timeIndex, setTimeIndex] = useState(image.preferredVolumeSelection?.timeIndex ?? 0);
  const [channel, setChannel] = useState(image.preferredVolumeSelection?.channel ?? 0);
  const [inspection, setInspection] = useState<VolumeInspection>();
  const [display, setDisplay] = useState<VolumeDisplay>();
  const [compositeVolume, setCompositeVolume] = useState<CompositeVolumeState>();
  const [measurements, setMeasurements] = useState<Pick<VolumeMeasurements, "cells" | "cellCount">>();
  const [measurementPage, setMeasurementPage] = useState<MeasurementPage<VolumeMeasurements["cells"][number]>>();
  const [measurementCursors, setMeasurementCursors] = useState<(string | undefined)[]>([undefined]);
  const [slice, setSlice] = useState<VolumeSlice>();
  const [sliceMask, setSliceMask] = useState<{ key: string; dataUrl: string }>();
  const sliceMaskCache = useRef<{ key: string; dataUrl: string } | undefined>(undefined);
  const [parameters, setParameters] = useState<VolumeParameters>({ ...DEFAULT_VOLUME_PARAMETERS });
  const [crosshair, setCrosshair] = useState<Vec3>([0, 0, 0]);
  const [plane, setPlane] = useState<VolumePlane>("xy");
  const [calibration, setCalibration] = useState({ x: "", y: "", z: "", time: "" });
  const [loading, setLoading] = useState(false);
  const [sliceLoading, setSliceLoading] = useState(false);
  const [loadedRevision, setLoadedRevision] = useState<number>();
  const [loadedSliceKey, setLoadedSliceKey] = useState("");
  const loadedAt = useRef<number | undefined>(undefined);
  const sliceLoadedAt = useRef<number | undefined>(undefined);
  const [error, setError] = useState("");
  const [previewing, setPreviewing] = useState(false);
  const [selected, setSelected] = useState<number[]>([]);
  const [polygon, setPolygon] = useState<[number, number][]>([]);
  const [tool, setTool] = useState<"select" | "polygon" | "brush">("select");
  const [radius, setRadius] = useState(3);
  const [brushMode, setBrushMode] = useState<"paint" | "erase">("paint");
  const [brushCenter, setBrushCenter] = useState<Vec3>();
  const [page, setPage] = useState(0);
  const [tracks, setTracks] = useState<VolumeTracks>();
  const [maxDistance, setMaxDistance] = useState(20);
  const [units, setUnits] = useState<"voxel" | "um">("voxel");
  const [maxGap, setMaxGap] = useState(0);
  const [link, setLink] = useState({ sourceTimeIndex: 0, sourceLabelId: 1, targetTimeIndex: 1, targetLabelId: 1 });
  const generation = useRef(0);
  const firstLoad = useRef(true);
  const alive = useRef(true);
  const latestRead = useRef(read);
  latestRead.current = read;
  const workflowCallback = useRef(onWorkflowChange);
  workflowCallback.current = onWorkflowChange;
  const sourceSliceKey = `${image.id}:${revision}:${timeIndex}:${channel}:${plane}:${crosshair[planeAxis(plane)]}`;
  const sliceKey = `${sourceSliceKey}:${selected.join(",")}`;
  const previousSliceKey = carriesDisplayRevision(displayTransition, image, revision, displayTransition?.fromRevision)
    ? `${image.id}:${displayTransition!.fromRevision}:${timeIndex}:${channel}:${plane}:${crosshair[planeAxis(plane)]}:${selected.join(",")}` : undefined;
  const latestSliceKey = useRef(sliceKey);
  latestSliceKey.current = sliceKey;
  const sliceWorker = useRef(false);
  const pendingSlice = useRef<{ key: string; maskKey: string; hasAnalysis: boolean; read: Props["read"]; args: Record<string, unknown> } | undefined>(undefined);
  const measurementKey = `${image.id}:${revision}:${timeIndex}:${channel}`;
  const latestMeasurementKey = useRef(measurementKey); latestMeasurementKey.current = measurementKey;
  const dimensions = inspection?.dimensions ?? [image.width, image.height, image.zCount || 1];
  const index = Math.round(crosshair[planeAxis(plane)]);
  const savedFrame = inspection?.frames.find((frame) => frame.timeIndex === timeIndex && frame.channel === channel);
  const dirty = savedFrame && (["method", "threshold", "polarity", "minVolumeVox", "minDistanceVox"] as const)
    .some((key) => parameters[key] !== savedFrame.parameters[key]);
  const frameCurrent = loadedRevision === revision || carriesCompletedDisplay(displayTransition, image, revision, loadedRevision, loadedAt.current);
  const sliceCurrent = loadedSliceKey === sliceKey || (loadedSliceKey === previousSliceKey &&
    sliceLoadedAt.current !== undefined && sliceLoadedAt.current <= displayTransition!.startedAt);
  const canEdit = !!savedFrame && frameCurrent && sliceCurrent &&
    display?.timeIndex === timeIndex && display.channel === channel &&
    !previewing && !dirty && !busy && !loading && !sliceLoading;
  const selection = { imageId: image.id, timeIndex, channel };
  const calibrationDirty = Boolean(inspection && ((["x", "y", "z"] as const).some((axis) =>
    (calibration[axis] === "" ? null : Number(calibration[axis])) !== inspection.voxelSizeUm[axis]) ||
    (calibration.time === "" ? null : Number(calibration.time)) !== inspection.timeStepSeconds));

  useEffect(() => {
    onEditingChange(Boolean(dirty || previewing || polygon.length || brushCenter || selected.length));
  }, [dirty, previewing, polygon.length, brushCenter, selected.length, onEditingChange]);
  useEffect(() => { onCalibrationEditingChange(calibrationDirty); }, [calibrationDirty, onCalibrationEditingChange]);
  useEffect(() => () => onCalibrationEditingChange(false), [onCalibrationEditingChange]);
  useEffect(() => () => onEditingChange(false), [onEditingChange]);

  useEffect(() => {
    alive.current = true;
    return () => { alive.current = false; generation.current++; pendingSlice.current = undefined; };
  }, []);

  useEffect(() => {
    workflowCallback.current({ imageId: image.id, parameters, channel, timeIndex, plane, index });
  }, [image.id, parameters, channel, timeIndex, plane, index]);

  useEffect(() => {
    if (!navigation || navigation.selection.imageId !== image.id || navigation.selection.target !== "volume") return;
    const target = navigation.selection;
    firstLoad.current = false;
    setTimeIndex(target.timeIndex ?? 0); setChannel(target.channel ?? 0); setPlane(target.plane ?? "xy");
    setCrosshair(previous => {
      const next = [...previous] as Vec3;
      next[planeAxis(target.plane ?? "xy")] = target.index ?? 0;
      return next;
    });
  }, [navigation?.id, image.id]);

  useEffect(() => {
    if (busy) return;
    // Completed exact frames survive UI locking and a proven preset-only CAS.
    // In-flight loads have no loadedRevision and always restart at the new revision.
    if (frameCurrent && inspection && display?.imageId === image.id && display.timeIndex === timeIndex && display.channel === channel) {
      if (loadedRevision !== revision) setLoadedRevision(revision);
      return;
    }
    const epoch = ++generation.current;
    setLoading(true); setError(""); setPreviewing(false); setSelected([]); setPolygon([]); setBrushCenter(undefined);
    setLoadedRevision(undefined);
    loadedAt.current = undefined;
    setMeasurements(undefined); setMeasurementPage(undefined); setMeasurementCursors([undefined]); setTracks(undefined); setDisplay(undefined); setPage(0);
    const request = latestRead.current;
    void (async () => {
      try {
        const metadata = await request<VolumeInspection>("volume.inspect", { imageId: image.id });
        if (!alive.current || epoch !== generation.current) return;
        setInspection(metadata);
        setCalibration({ x: metadata.voxelSizeUm.x?.toString() ?? "", y: metadata.voxelSizeUm.y?.toString() ?? "",
          z: metadata.voxelSizeUm.z?.toString() ?? "", time: metadata.timeStepSeconds?.toString() ?? "" });
        if (firstLoad.current) {
          firstLoad.current = false;
          setCrosshair(metadata.dimensions.map((size) => Math.floor((size - 1) / 2)) as Vec3);
        }
        const frame = metadata.frames.find((item) => item.timeIndex === timeIndex && item.channel === channel);
        setParameters(frame?.parameters ?? { ...DEFAULT_VOLUME_PARAMETERS });
        const picture = await request<VolumeDisplay>("volume.display", { imageId: image.id, timeIndex, channel, maxDimension: 128 });
        if (!alive.current || epoch !== generation.current) return;
        setDisplay(picture);
        if (frame) {
          const measured = await request<MeasurementPage<VolumeMeasurements["cells"][number]>>("measurements.page", { imageId: image.id, target: "volume", timeIndex, channel, limit: 100, includeContours: false });
          if (alive.current && epoch === generation.current) {
            setMeasurements({ cells: measured.cells, cellCount: measured.total }); setMeasurementPage(measured);
            setMeasurementCursors([undefined, ...(measured.nextCursor ? [measured.nextCursor] : [])]);
          }
        }
        if (alive.current && epoch === generation.current) { loadedAt.current = performance.now(); setLoadedRevision(revision); }
      } catch (cause) { if (alive.current && epoch === generation.current) { setError(String(cause)); setDisplay(undefined); } }
      finally { if (alive.current && epoch === generation.current) setLoading(false); }
    })();
    return () => { generation.current++; };
  }, [image.id, revision, timeIndex, channel, busy, displayTransition]);

  const changeMeasurementPage = (nextPage: number) => {
    if (previewing) { setPage(nextPage); return; }
    const requestedKey = measurementKey;
    void runRead(async () => {
      const cursor = measurementCursors[nextPage];
      if (nextPage > 0 && !cursor) return;
      try {
        const value = await latestRead.current<MeasurementPage<VolumeMeasurements["cells"][number]>>("measurements.page", {
          imageId: image.id, target: "volume", timeIndex, channel, limit: 100, includeContours: false, ...(cursor ? { cursor } : {}),
        });
        if (!alive.current || latestMeasurementKey.current !== requestedKey || value.sourceRevision !== revision) return;
        setMeasurements({ cells: value.cells, cellCount: value.total }); setMeasurementPage(value); setPage(nextPage);
        setMeasurementCursors(previous => [...previous.slice(0, nextPage + 1), ...(value.nextCursor ? [value.nextCursor] : [])]);
      } catch (cause) { if (alive.current && latestMeasurementKey.current === requestedKey) setError(String(cause)); }
    });
  };

  // At most one authoritative slice request is in flight. Scrubbing coalesces
  // pending positions, and a reply is displayed only for its exact selection.
  useEffect(() => {
    if (busy || loading || !inspection) return;
    if (sliceCurrent && slice?.timeIndex === timeIndex && slice.channel === channel && slice.plane === plane && slice.index === index) {
      if (loadedSliceKey !== sliceKey) setLoadedSliceKey(sliceKey);
      return;
    }
    const timer = window.setTimeout(() => {
      pendingSlice.current = { key: sliceKey, maskKey: sourceSliceKey, hasAnalysis: !!savedFrame, read: latestRead.current, args: {
        imageId: image.id, timeIndex, channel, plane, index, maxSize: 1536,
        includeContours: selected.length > 0, ...(selected.length ? { labelIds: selected } : {}),
      } };
      if (sliceWorker.current) return;
      sliceWorker.current = true;
      setSliceLoading(true);
      void (async () => {
        try {
          while (pendingSlice.current && alive.current) {
            const next = pendingSlice.current;
            pendingSlice.current = undefined;
            try {
              const result = await next.read<VolumeSlice>("volume.slice", next.args);
              let mask = sliceMaskCache.current;
              if (next.hasAnalysis && mask?.key !== next.maskKey) {
                const { includeContours: _contours, labelIds: _labels, ...maskArgs } = next.args;
                const overlay = await next.read<{ maskDataUrl: string }>("mask.overlay", { ...maskArgs, target: "volume" });
                mask = { key: next.maskKey, dataUrl: overlay.maskDataUrl }; sliceMaskCache.current = mask;
              }
              if (alive.current && latestSliceKey.current === next.key) {
                setSliceMask(next.hasAnalysis ? mask : undefined);
                sliceLoadedAt.current = performance.now(); setSlice(result); setLoadedSliceKey(next.key);
              }
            } catch (cause) { if (alive.current && latestSliceKey.current === next.key) setError(String(cause)); }
          }
        } finally { sliceWorker.current = false; if (alive.current) setSliceLoading(false); }
      })();
    }, 150);
    return () => window.clearTimeout(timer);
  }, [sliceKey, busy, loading, inspection, previousSliceKey]);

  useEffect(() => { setPolygon([]); setBrushCenter(undefined); }, [sliceKey]);

  const navigate = (coordinates: Vec3) => setCrosshair(coordinates.map((value, axis) =>
    Math.max(0, Math.min(dimensions[axis] - 1, Math.round(value)))) as Vec3);
  const update = (change: Partial<VolumeParameters>) => setParameters((old) => {
    const next = { ...old, ...change };
    if (next.method === "otsu") delete next.threshold;
    else if (next.threshold === undefined) next.threshold = 0;
    return next;
  });
  const preview = async () => {
    const epoch = ++generation.current;
    setLoading(true); setError(""); setSelected([]); setPolygon([]);
    try {
      const result = await read<VolumeMeasurements>("volume.analysis.preview", { ...selection, parameters, cellLimit: 200 });
      if (!alive.current || epoch !== generation.current) return;
      setMeasurements(result); setPreviewing(true); setPage(0);
      if (result.display) setDisplay(result.display);
    } catch (cause) { if (alive.current && epoch === generation.current) setError(String(cause)); }
    finally { if (alive.current && epoch === generation.current) setLoading(false); }
  };
  const select = (id: number) => setSelected((old) => old.includes(id) ? old.filter((item) => item !== id) : old.length < 1000 ? [...old, id] : old);
  const displayedSlice = sliceCurrent && slice?.timeIndex === timeIndex && slice.channel === channel &&
    slice.plane === plane && slice.index === index ? slice : undefined;
  const compositeForFrame = compositeVolume?.imageId === image.id && compositeVolume.sourceHash === image.sourceHash &&
    (compositeVolume.revision === revision || carriesCompletedDisplay(displayTransition, image, revision, compositeVolume.revision, compositeVolume.completedAt)) &&
    compositeVolume.timeIndex === timeIndex && compositeVolume.labelChannel === channel
    ? compositeVolume : undefined;
  const currentComposite = !previewing && !dirty && frameCurrent ? compositeForFrame?.descriptor : undefined;
  const sourceDisplay = (frameCurrent || previewing) && display?.imageId === image.id &&
    display.timeIndex === timeIndex && display.channel === channel ? display : undefined;
  const renderedVolume = currentComposite ?? sourceDisplay;

  return <section className="workbench-volume-panel" aria-label="Volumetric analysis">
    {contextTarget ? createPortal(<>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    <div className="workbench-volume-toolbar">
      <label>Time point<select disabled={busy || loading || Boolean(dirty || previewing || polygon.length || brushCenter || selected.length || calibrationDirty)} value={timeIndex} onChange={(event) => setTimeIndex(Number(event.target.value))}>
        {Array.from({ length: image.timeCount || 1 }, (_, value) => <option key={value} value={value}>{value + 1}</option>)}</select></label>
      <label>Analysis channel<select disabled={busy || loading || Boolean(dirty || previewing || polygon.length || brushCenter || selected.length || calibrationDirty)} value={channel} onChange={(event) => setChannel(Number(event.target.value))}>
        {Array.from({ length: image.channels }, (_, value) => <option key={value} value={value}>{value + 1}</option>)}</select></label>
      <p role="status">{loading ? "Loading volume…" : previewing ? "Unsaved segmentation preview" :
        `${dimensions.join(" × ")} source voxels · ${measurements?.cellCount ?? 0} saved objects`}</p>
    </div></>, contextTarget) : null}
    <VolumeRenderer descriptor={renderedVolume} crosshair={crosshair} onCrosshair={navigate}
      onPlanePick={(pickedPlane, voxel) => { setPlane(pickedPlane); navigate(voxel); }} />
    <p role="status">{compositeForFrame?.loading ? "Preparing the 3D composite…" : currentComposite
      ? `3D composite · time ${timeIndex + 1} · ${currentComposite.channels.filter((item) => item.enabled).length} visible display channels · ${currentComposite.labelStatus === "current" ? `saved masks on analysis channel ${channel + 1}` : `no saved masks on analysis channel ${channel + 1}`}`
      : `3D display: analysis channel ${channel + 1}`}
      {currentComposite && compositeForFrame?.settingsChanged ? " · Display settings have changed; the previous 3D render remains shown." : ""}</p>
    {compositeForFrame?.error ? <p role="status">The 3D composite was not updated. Channel display below contains the error and render controls.</p> : null}
    <p>The 3D display uses a bounded preview. Measurements and edits use source voxels.</p>
    <div className="workbench-editor-grid">
      <div>
        <h3>Source slice editor</h3>
        <fieldset disabled={busy || loading}>
          <label>Plane<select value={plane} onChange={(event) => setPlane(event.target.value as VolumePlane)}>
            <option value="xy">XY</option><option value="xz">XZ</option><option value="yz">YZ</option></select></label>
          <label>Slice {index + 1} / {dimensions[planeAxis(plane)]}<input type="range" min="0" max={dimensions[planeAxis(plane)] - 1}
            value={index} onChange={(event) => { const next = [...crosshair] as Vec3; next[planeAxis(plane)] = Number(event.target.value); navigate(next); }} /></label>
        </fieldset>
        <WorkbenchComposite image={image} revision={revision} busy={busy || loading || sliceLoading}
          selection={{ target: "volume", timeIndex, plane, index }} read={read} exportComposite={exportComposite}
          mutatePreset={mutatePreset} presetFiles={presetFiles}
          displayTransition={displayTransition}
          volume={{ labelChannel: channel, available: !previewing && !dirty && frameCurrent, onChange: setCompositeVolume }}
          exportBlocked={compositeExportBlocked || Boolean(dirty || previewing || polygon.length || brushCenter || selected.length || calibrationDirty)}>
        {(composite) => <div className="workbench-stage">
          {displayedSlice ? <svg viewBox={`0 0 ${displayedSlice.width} ${displayedSlice.height}`} tabIndex={0}
            aria-label={`${plane.toUpperCase()} source slice ${index + 1}`}
            onKeyDown={(event) => {
              if (event.key === "Escape") {
                event.preventDefault(); setPolygon([]); setSelected([]); setBrushCenter(undefined); return;
              }
              if (!canEdit || event.repeat) return;
              if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "z" && !event.shiftKey) {
                event.preventDefault(); void act("volume.mask.undo", selection);
              } else if (event.key === "Delete" || event.key === "Backspace") {
                if (tool === "polygon" && polygon.length) {
                  event.preventDefault(); setPolygon((old) => old.slice(0, -1));
                } else if (tool === "select" && selected.length) {
                  event.preventDefault(); void act("volume.mask.edit", { ...selection, action: "delete", labelIds: selected });
                }
              } else if (event.key === "Enter" && tool === "polygon" && polygon.length >= 3 && selected.length <= 1) {
                event.preventDefault(); void act("volume.mask.edit", {
                  ...selection, action: "polygon", plane, index, polygon, ...(selected.length ? { labelId: selected[0] } : {}),
                });
              }
            }} onClick={(event) => {
              event.currentTarget.focus();
              if (!canEdit) return;
              const matrix = event.currentTarget.getScreenCTM();
              if (!matrix) return;
              const p = new DOMPoint(event.clientX, event.clientY).matrixTransform(matrix.inverse());
              if (p.x < 0 || p.y < 0 || p.x >= displayedSlice.width || p.y >= displayedSlice.height) return;
              if (tool === "polygon") setPolygon((old) => [...old, [p.x, p.y]]);
              else if (tool === "select") {
                const coordinate = plane === "xy" ? { x: p.x, y: p.y, z: index + 0.5 } : plane === "xz" ? { x: p.x, y: index + 0.5, z: p.y } : { x: index + 0.5, y: p.x, z: p.y };
                const requestedKey = measurementKey;
                void runRead(async () => {
                  try { const picked = await latestRead.current<{ labelId: number }>("mask.pick", { ...selection, target: "volume", ...coordinate });
                    if (alive.current && latestMeasurementKey.current === requestedKey && picked.labelId > 0) select(picked.labelId);
                  } catch (cause) { if (alive.current && latestMeasurementKey.current === requestedKey) setError(String(cause)); }
                });
              } else setBrushCenter(plane === "xy" ? [p.x, p.y, index + 0.5] : plane === "xz" ? [p.x, index + 0.5, p.y] : [index + 0.5, p.x, p.y]);
            }}>
            <image href={composite?.dataUrl ?? displayedSlice.dataUrl} width={displayedSlice.width} height={displayedSlice.height}
              preserveAspectRatio="none" style={composite ? { imageRendering: "pixelated" } : undefined} />
            {!previewing && !dirty && sliceMask && (sliceMask.key === sourceSliceKey || sliceMask.key === `${image.id}:${displayTransition?.fromRevision}:${timeIndex}:${channel}:${plane}:${index}` && sliceCurrent) ? <image href={sliceMask.dataUrl} width={displayedSlice.width} height={displayedSlice.height} preserveAspectRatio="none" pointerEvents="none" style={{ imageRendering: "pixelated" }} /> : null}
            {!previewing && !dirty ? displayedSlice.contours.map((cell) => <path key={cell.labelId}
              d={cell.contoursPx.map((loop) => loop.length ? `M${loop.map((point) => point.join(",")).join("L")}Z` : "").join("")}
              fillRule="evenodd" className={selected.includes(cell.labelId) ? "selected" : ""} vectorEffect="non-scaling-stroke"
              onClick={(event) => { if (tool === "select" && canEdit) { event.stopPropagation(); select(cell.labelId); } }} />) : null}
            {polygon.length ? <polyline points={polygon.map((point) => point.join(",")).join(" ")}
              stroke="#ffcd38" fill="none" strokeWidth="2" vectorEffect="non-scaling-stroke" /> : null}
          </svg> : <p>{sliceLoading ? "Loading source slice…" : "Select a source slice."}</p>}
        </div>}
        </WorkbenchComposite>
        <fieldset disabled={!canEdit}>
          <label>Edit tool<select value={tool} onChange={(event) => { setTool(event.target.value as typeof tool); setPolygon([]); setBrushCenter(undefined); }}>
            <option value="select">Select objects</option><option value="polygon">Slice polygon</option><option value="brush">Spherical brush</option></select></label>
          {tool === "polygon" ? <>
            <p>Click a polygon on this source slice. Replacing a selected object changes its voxels on this slice only.</p>
            <button className="cc-btn" disabled={polygon.length < 3 || selected.length > 1} onClick={() => void act("volume.mask.edit", {
              ...selection, action: "polygon", plane, index, polygon, ...(selected.length === 1 ? { labelId: selected[0] } : {}),
            })}>{selected.length === 1 ? "Replace selected on slice" : "Add object on slice"}</button>
          </> : null}
          {tool === "brush" ? <>
            <label>Brush radius (voxels)<input type="number" min="0.5" max="128" step="0.5" value={radius} onChange={(event) => setRadius(Number(event.target.value))} /></label>
            <label>Brush mode<select value={brushMode} onChange={(event) => setBrushMode(event.target.value as "paint" | "erase")}><option value="paint">Paint</option><option value="erase">Erase</option></select></label>
            <p>{brushCenter ? `Center: ${brushCenter.map((value) => fmt(value)).join(", ")} source voxel coordinates` : "Click the source slice to place the brush."}</p>
            <button className="cc-btn" disabled={!brushCenter || selected.length > 1} onClick={() => void act("volume.mask.edit", {
              ...selection, action: "brush", center: brushCenter, radiusVox: radius, mode: brushMode,
              ...(selected.length === 1 ? { labelId: selected[0] } : {}),
            })}>Apply spherical brush</button>
          </> : null}
          <div className="workbench-actions">
            <button className="cc-btn" disabled={!selected.length} onClick={() => void act("volume.mask.edit", { ...selection, action: "delete", labelIds: selected })}>Delete selected objects</button>
            <button className="cc-btn" disabled={selected.length < 2} onClick={() => void act("volume.mask.edit", { ...selection, action: "merge", labelIds: selected })}>Merge selected objects</button>
            <button className="cc-btn" onClick={() => void act("volume.mask.undo", selection)}>Undo volume edit</button>
          </div>
        </fieldset>
      </div>
      <div>
        <h3>3D segmentation</h3>
        <fieldset disabled={busy || loading}>
          <label>Threshold method<select value={parameters.method} onChange={(event) => update({ method: event.target.value as "otsu" | "manual" })}>
            <option value="otsu">Otsu</option><option value="manual">Manual</option></select></label>
          {parameters.method === "manual" ? <label>Raw threshold<input type="number" value={parameters.threshold ?? 0} onChange={(event) => update({ threshold: Number(event.target.value) })} /></label> : null}
          <label>Objects<select value={parameters.polarity} onChange={(event) => update({ polarity: event.target.value as "bright" | "dark" })}>
            <option value="bright">Bright</option><option value="dark">Dark</option></select></label>
          <label>Minimum volume (voxels)<input type="number" min="1" value={parameters.minVolumeVox} onChange={(event) => update({ minVolumeVox: Number(event.target.value) })} /></label>
          <label>Seed spacing (voxels)<input type="number" min="1" value={parameters.minDistanceVox} onChange={(event) => update({ minDistanceVox: Number(event.target.value) })} /></label>
          {dirty ? <p>Settings differ from the saved analysis. Preview or run to use them.</p> : null}
          <div className="workbench-actions"><button className="cc-btn" onClick={() => void preview()}>Preview 3D</button>
            <button className="cc-btn workbench-primary" onClick={() => void act("volume.analysis.run", { ...selection, parameters, cellLimit: 200 })}>Run 3D analysis</button></div>
        </fieldset>
        {calibrationTarget ? createPortal(<section aria-label="Voxel calibration">
        <h3>Voxel calibration</h3>
        <fieldset disabled={busy || loading || Boolean(dirty || previewing || polygon.length || brushCenter || selected.length)}>
          {(["x", "y", "z"] as const).map((axis) => <label key={axis}>{axis.toUpperCase()} voxel size (µm)<input type="number" step="any" min="0" placeholder="Unknown"
            value={calibration[axis]} onChange={(event) => setCalibration((old) => ({ ...old, [axis]: event.target.value }))} /></label>)}
          <label>Time interval (seconds)<input type="number" step="any" min="0" placeholder="Unknown" value={calibration.time} onChange={(event) => setCalibration((old) => ({ ...old, time: event.target.value }))} /></label>
          <button className="cc-btn" onClick={() => void act("volume.calibration.set", { imageId: image.id,
            voxelSizeUm: { x: calibration.x === "" ? null : Number(calibration.x), y: calibration.y === "" ? null : Number(calibration.y), z: calibration.z === "" ? null : Number(calibration.z) },
            timeStepSeconds: calibration.time === "" ? null : Number(calibration.time),
          })}>Apply voxel calibration</button>
          <button type="button" className="cc-btn" disabled={!inspection || !calibrationDirty} onClick={() => {
            if (inspection) setCalibration({ x: inspection.voxelSizeUm.x == null ? "" : String(inspection.voxelSizeUm.x),
              y: inspection.voxelSizeUm.y == null ? "" : String(inspection.voxelSizeUm.y),
              z: inspection.voxelSizeUm.z == null ? "" : String(inspection.voxelSizeUm.z),
              time: inspection.timeStepSeconds == null ? "" : String(inspection.timeStepSeconds) });
          }}>Discard calibration changes</button>
          <p>Empty fields remain unknown. Physical volume requires all three spatial axes.</p>
        </fieldset></section>, calibrationTarget) : null}
      </div>
    </div>
    <div className="workbench-table"><table><caption>{previewing ? "Unsaved 3D preview" : "Saved 3D measurements"} · {measurements?.cellCount ?? 0} objects</caption>
      <thead><tr><th>Select</th><th>Object</th><th>Voxels</th><th>Volume µm³</th><th>Equivalent diameter µm</th><th>Mean intensity</th></tr></thead>
      <tbody>{(previewing ? measurements?.cells.slice(page * 100, (page + 1) * 100) : measurements?.cells)?.map((cell) => <tr key={cell.labelId}>
        <td><input type="checkbox" aria-label={`Select volume object ${cell.labelId}`} disabled={!canEdit} checked={selected.includes(cell.labelId)} onChange={() => select(cell.labelId)} /></td>
        <td>{cell.labelId}</td><td>{fmt(cell.voxelCount)}</td><td>{fmt(cell.volumeUm3)}</td><td>{fmt(cell.equivalentDiameterUm)}</td><td>{fmt(cell.meanIntensity)}</td>
      </tr>)}</tbody></table></div>
    <div className="workbench-actions"><button className="cc-btn" disabled={busy || loading || !page || (!previewing && measurementPage?.sourceRevision !== revision)} onClick={() => changeMeasurementPage(page - 1)}>Previous 100</button>
      <span>Page {page + 1}</span>{!previewing ? <button className="cc-btn" disabled={busy || loading || !savedFrame} onClick={() => changeMeasurementPage(0)}>Refresh measurement pages</button> : null}<button className="cc-btn" disabled={busy || loading || (previewing ? (page + 1) * 100 >= (measurements?.cells.length ?? 0) : !measurementPage?.nextCursor || measurementPage.sourceRevision !== revision)} onClick={() => changeMeasurementPage(page + 1)}>Next 100</button></div>
    {previewing && (measurements?.cellCount ?? 0) > (measurements?.cells.length ?? 0) ? <p>The full bounded volume preview contains all labels; this temporary table shows the first {measurements?.cells.length} of {measurements?.cellCount} objects. Save analysis to page all object records.</p> : null}
    {measurementsTarget ? createPortal(<section aria-label="Tracking and lineage">
    <details><summary>Time tracking</summary>
      <p>Centroid matching produces one-to-one tracks. Use lineage inference below to review possible divisions.</p>
      <fieldset disabled={busy || loading || temporalWriteBlocked || Boolean(dirty || previewing || polygon.length || brushCenter || selected.length || calibrationDirty)}>
        <div className="workbench-editor-grid">
          <label>Maximum displacement<input type="number" min="0.01" step="any" value={maxDistance} onChange={(event) => setMaxDistance(Number(event.target.value))} /></label>
          <label>Distance units<select value={units} onChange={(event) => setUnits(event.target.value as "voxel" | "um")}><option value="voxel">Voxels</option><option value="um">Micrometres</option></select></label>
          <label>Maximum missing frames<input type="number" min="0" max="10" value={maxGap} onChange={(event) => setMaxGap(Number(event.target.value))} /></label>
        </div>
        <div className="workbench-actions">
          <button className="cc-btn" onClick={() => void act("tracks.run", { imageId: image.id, channel, maxDistance, units, maxGapFrames: maxGap })}>Track analyzed time points</button>
          <button className="cc-btn" onClick={() => {
            const epoch = generation.current;
            void read<VolumeTracks>("tracks.get", { imageId: image.id, channel }).then((result) => {
              if (alive.current && generation.current === epoch) setTracks(result);
            }).catch((cause) => { if (alive.current && generation.current === epoch) setError(String(cause)); });
          }}>Inspect tracks</button>
        </div>
        <div className="workbench-editor-grid">{([
          ["sourceTimeIndex", "Source time point"], ["sourceLabelId", "Source object"],
          ["targetTimeIndex", "Target time point"], ["targetLabelId", "Target object"],
        ] as const).map(([key, label]) => <label key={key}>{label}<input type="number" min="1"
          value={link[key] + (key.endsWith("TimeIndex") ? 1 : 0)} onChange={(event) => setLink((old) => ({
            ...old, [key]: Number(event.target.value) - (key.endsWith("TimeIndex") ? 1 : 0),
          }))} /></label>)}</div>
        <div className="workbench-actions"><button className="cc-btn" onClick={() => void act("tracks.link", { imageId: image.id, channel, ...link })}>Link objects</button>
          <button className="cc-btn" onClick={() => void act("tracks.unlink", { imageId: image.id, channel, ...link })}>Unlink objects</button></div>
      </fieldset>
      {tracks ? <><p>{tracks.tracks.length} tracks · {tracks.edges.length} links · {tracks.status}
        {tracks.status === "stale" ? " — analyze the current masks and rerun tracking." : ""}</p>
        <div className="workbench-table"><table><thead><tr><th>Track</th><th>Time point → object</th></tr></thead>
          <tbody>{tracks.tracks.slice(0, 200).map((track) => <tr key={track.trackId}><td>{track.trackId}</td>
            <td>{track.observations.map((item) => `${item.timeIndex + 1} → ${item.labelId}`).join("; ")}</td></tr>)}</tbody></table></div>
        {tracks.tracks.length > 200 ? <p>Showing the first 200 tracks. The export retains all tracks.</p> : null}</> : null}
    </details>
    <WorkbenchLineage key={`${image.id}:${channel}`} imageId={image.id} channel={channel} timeIndex={timeIndex}
      exportLineage={exportLineage}
      timeCount={image.timeCount || 1} revision={revision}
      busy={busy || temporalWriteBlocked || Boolean(dirty || previewing || polygon.length || brushCenter || selected.length || calibrationDirty)}
      read={read} act={act} runRead={runRead} /></section>, measurementsTarget) : null}
  </section>;
}
