import { useEffect, useRef, useState } from "react";
import type { AnalysisParameters, WorkbenchImage } from "../../../../shared/workbench/protocol";
import type { VolumePlane, VolumeWorkflowConfiguration } from "../../../../shared/workbench/volumeProtocol";
import type {
  AnnotationKind, AnnotationListItem, AnnotationMeasurement, AnnotationPoint, AnnotationRecord,
  AnnotationExportArguments, AnnotationExportFormat, AnnotationExportFormatId,
} from "../../../../shared/workbench/annotationProtocol";
import IntensityProfile from "./IntensityProfile";
import ScientificOutput from "./ScientificOutput";
import WorkbenchAnnotationImport from "./WorkbenchAnnotationImport";

type Props = { image?: WorkbenchImage; revision: number; parameters: AnalysisParameters;
  busy: boolean; volumeMode: boolean; volume?: VolumeWorkflowConfiguration;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  act: (operation: string, args: Record<string, unknown>, accepted: (annotation: AnnotationRecord) => void) => Promise<void>;
  exportAnnotation: (format: AnnotationExportFormat, args: AnnotationExportArguments, annotationName: string) => Promise<void>;
  chooseImportFile: (selected: (path: string) => void) => Promise<void>;
  importBlocked?: boolean;
  onEditingChange: (editing: boolean) => void };
type Preview = { dataUrl: string; width: number; height: number };
const minimumPoints: Record<AnnotationKind, number> = { point: 1, line: 2, polyline: 2, polygon: 3 };

export default function WorkbenchAnnotations({ image, revision, parameters, busy, volumeMode, volume, read, act, exportAnnotation, chooseImportFile, importBlocked = false, onEditingChange }: Props) {
  const [open, setOpen] = useState(false);
  const [annotations, setAnnotations] = useState<AnnotationListItem[]>([]);
  const [annotationId, setAnnotationId] = useState("");
  const [loadedGeometryRevision, setLoadedGeometryRevision] = useState<number | null>(null);
  const [name, setName] = useState("Annotation");
  const [notes, setNotes] = useState("");
  const [kind, setKind] = useState<AnnotationKind>("line");
  const [points, setPoints] = useState<AnnotationPoint[]>([]);
  const [target, setTarget] = useState<"plane" | "volume">("plane");
  const [channel, setChannel] = useState(0);
  const [projection, setProjection] = useState<AnalysisParameters["zProjection"]>("max");
  const [timeIndex, setTimeIndex] = useState(0);
  const [plane, setPlane] = useState<VolumePlane>("xy");
  const [slice, setSlice] = useState(0);
  const [measurementChannel, setMeasurementChannel] = useState(0);
  const [profileSamples, setProfileSamples] = useState(256);
  const [coordinate, setCoordinate] = useState<AnnotationPoint>([.5, .5]);
  const [vertex, setVertex] = useState(-1);
  const [preview, setPreview] = useState<Preview>();
  const [result, setResult] = useState<AnnotationMeasurement>();
  const [loading, setLoading] = useState(false);
  const [canvasLoading, setCanvasLoading] = useState(false);
  const [error, setError] = useState("");
  const [dirty, setDirty] = useState(false);
  const [exportFormats, setExportFormats] = useState<AnnotationExportFormat[]>([]);
  const [exportFormatId, setExportFormatId] = useState<AnnotationExportFormatId>("geometry-json");
  const [exportCatalogueError, setExportCatalogueError] = useState("");
  const [exportCatalogueAttempt, setExportCatalogueAttempt] = useState(0);
  const epoch = useRef(0);
  const canvasEpoch = useRef(0);
  const latest = useRef({ read, onEditingChange }); latest.current = { read, onEditingChange };
  const saved = annotations.find((item) => item.id === annotationId);
  const exportFormat = exportFormats.find((item) => item.id === exportFormatId);
  const hasProfile = kind === "line" || kind === "polyline";
  const validProfileSamples = Number.isInteger(profileSamples) && profileSamples >= 2 && profileSamples <= 4096;
  const validMeasurementChannel = !!image && Number.isInteger(measurementChannel) && measurementChannel >= 0 && measurementChannel < image.channels;
  const savedGeometryMatches = !!saved && saved.geometryRevision === loadedGeometryRevision;
  const canExport = !!image && !!exportFormat && !!annotationId && savedGeometryMatches && !saved?.deleted && !dirty &&
    (exportFormat.id !== "profile-csv" || hasProfile) &&
    (exportFormat.id === "geometry-json" || (validMeasurementChannel && (!hasProfile || validProfileSamples)));
  const sliceCount = plane === "xy" ? image?.zCount ?? 1 : plane === "xz" ? image?.height ?? 1 : image?.width ?? 1;
  const selection = target === "plane" ? { target, sourceParameters: { channel, zProjection: projection } }
    : { target, timeIndex, channel, plane, index: slice };
  const geometry = { type: kind, points };
  const validGeometry = points.length >= minimumPoints[kind] &&
    (kind !== "point" || points.length === 1) && (kind !== "line" || points.length === 2);
  const validSelection = !!image && channel >= 0 && channel < image.channels &&
    (target === "plane" ? image.timeCount === 1 : Number.isInteger(timeIndex) && timeIndex >= 0 &&
      timeIndex < image.timeCount && Number.isInteger(slice) && slice >= 0 && slice < sliceCount);
  const canMeasure = validGeometry && validSelection && validMeasurementChannel && (!hasProfile || validProfileSamples);
  const coordinatesValid = !!preview && coordinate.every(Number.isFinite) &&
    coordinate[0] >= 0 && coordinate[0] <= preview.width && coordinate[1] >= 0 && coordinate[1] <= preview.height;

  const invalidate = () => { epoch.current++; setResult(undefined); setLoading(false); setDirty(true); setError(""); };
  const changePoints = (next: AnnotationPoint[]) => { invalidate(); setPoints(next); };
  const fresh = () => {
    epoch.current++; setAnnotationId(""); setLoadedGeometryRevision(null); setName("Annotation"); setNotes(""); setKind("line"); setPoints([]);
    setVertex(-1); setResult(undefined); setDirty(false); setError(""); setLoading(false);
  };
  useEffect(() => {
    fresh();
    const isVolume = volumeMode && !!volume;
    setTarget(isVolume ? "volume" : "plane");
    setChannel(isVolume ? volume!.channel : parameters.channel);
    setMeasurementChannel(isVolume ? volume!.channel : parameters.channel);
    setProjection(parameters.zProjection); setTimeIndex(isVolume ? volume!.timeIndex : 0);
    setPlane("xy"); setSlice(Math.floor((image?.zCount ?? 1) / 2));
  }, [image?.id, volumeMode, volume?.timeIndex, volume?.channel, parameters.channel, parameters.zProjection]);
  useEffect(() => { setAnnotations([]); }, [image?.id]);
  useEffect(() => {
    if (!open || exportFormats.length) return;
    let active = true;
    setExportCatalogueError("");
    void latest.current.read<{ formats: AnnotationExportFormat[] }>("annotation.export.catalogue")
      .then((value) => { if (active) setExportFormats(value.formats); })
      .catch((cause) => { if (active) setExportCatalogueError(String(cause)); });
    return () => { active = false; };
  }, [open, exportFormats.length, exportCatalogueAttempt]);
  useEffect(() => {
    latest.current.onEditingChange(dirty);
    return () => { latest.current.onEditingChange(false); };
  }, [dirty]);
  useEffect(() => {
    let active = true;
    if (!open || !image || busy) return;
    void latest.current.read<{ annotations: AnnotationListItem[] }>("annotation.list", { imageId: image.id, includeDeleted: true })
      .then((value) => { if (active) setAnnotations(value.annotations); })
      .catch((cause) => { if (active) setError(String(cause)); });
    return () => { active = false; };
  }, [image?.id, revision, busy, open]);
  useEffect(() => {
    epoch.current++; setResult(undefined); setLoading(false);
    // A project refresh accepts the persisted revision and leaves geometry
    // available as a draft until the user loads a saved annotation explicitly.
    return () => { epoch.current++; };
  }, [revision]);
  useEffect(() => {
    const generation = ++canvasEpoch.current;
    setPreview(undefined); setCanvasLoading(false);
    if (!open || !image || busy || !validSelection) return;
    setCanvasLoading(true);
    const operation = target === "plane" ? "image.preview" : "volume.slice";
    const args = target === "plane"
      ? { imageId: image.id, parameters: { channel, zProjection: projection }, maxSize: 1024 }
      : { imageId: image.id, timeIndex, channel, plane, index: slice, maxSize: 1024 };
    void latest.current.read<Preview>(operation, args).then((value) => {
      if (generation === canvasEpoch.current) setPreview(value);
    }).catch((cause) => { if (generation === canvasEpoch.current) setError(String(cause)); })
      .finally(() => { if (generation === canvasEpoch.current) setCanvasLoading(false); });
    return () => { canvasEpoch.current++; };
  }, [image?.id, revision, open, busy, target, channel, projection, timeIndex, plane, slice, validSelection]);

  const load = async (id: string) => {
    if (!id || !image) { fresh(); return; }
    const generation = ++epoch.current; setLoading(true); setError("");
    try {
      const value = await read<{ annotation: AnnotationRecord }>("annotation.get", { imageId: image.id, annotationId: id });
      if (generation !== epoch.current) return;
      const record = value.annotation;
      setAnnotationId(id); setLoadedGeometryRevision(record.geometryRevision); setName(record.name); setNotes(record.notes); setKind(record.geometry.type);
      setPoints(record.geometry.points); setVertex(-1); setTarget(record.target);
      setChannel(record.selection.sourceParameters?.channel ?? record.selection.channel ?? 0);
      setMeasurementChannel(record.selection.sourceParameters?.channel ?? record.selection.channel ?? 0);
      setProjection(record.selection.sourceParameters?.zProjection ?? "max");
      setTimeIndex(record.selection.timeIndex ?? 0); setPlane(record.selection.plane ?? "xy"); setSlice(record.selection.index ?? 0);
      setResult(undefined); setDirty(false);
    } catch (cause) { if (generation === epoch.current) setError(String(cause)); }
    finally { if (generation === epoch.current) setLoading(false); }
  };
  const acceptSaved = (record: AnnotationRecord) => {
    epoch.current++; setResult(undefined); setError(""); setDirty(false); setLoading(false);
    setAnnotationId(record.id ?? ""); setLoadedGeometryRevision(record.geometryRevision); setName(record.name); setNotes(record.notes);
    setKind(record.geometry.type); setPoints(record.geometry.points); setVertex(-1);
    setTarget(record.target); setChannel(record.selection.sourceParameters?.channel ?? record.selection.channel ?? 0);
    setProjection(record.selection.sourceParameters?.zProjection ?? "max");
    setTimeIndex(record.selection.timeIndex ?? 0); setPlane(record.selection.plane ?? "xy"); setSlice(record.selection.index ?? 0);
  };
  const measure = async () => {
    if (!image) return;
    const generation = ++epoch.current; setLoading(true); setError("");
    try {
      const value = await read<AnnotationMeasurement>("annotation.measure", { imageId: image.id,
        ...(annotationId && !dirty ? { annotationId } : { draft: { ...(name.trim() ? { name: name.trim() } : {}), geometry, ...selection } }),
        measurementChannel, ...(hasProfile ? { profileSamples } : {}) });
      if (generation === epoch.current) setResult(value);
    } catch (cause) { if (generation === epoch.current) setError(String(cause)); }
    finally { if (generation === epoch.current) setLoading(false); }
  };
  const add = (point: AnnotationPoint) => {
    if (kind === "point") { changePoints([point]); setVertex(0); }
    else if (kind === "line" && points.length >= 2) { changePoints([point]); setVertex(0); }
    else if (points.length < 2048) { changePoints([...points, point]); setVertex(points.length); }
    setCoordinate(point);
  };
  const changeSelection = (action: () => void) => { invalidate(); action(); };
  const locked = busy || loading;
  return <div className="workbench-automation"><details onToggle={(event) => setOpen(event.currentTarget.open)}>
    <summary>Annotations and intensity profiles</summary>
    <p>Draw points, lines and polygons over the source image. Annotations keep their geometry separately from object masks.</p>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    <fieldset disabled={locked || !image}>
      <div className="workbench-editor-grid">
        <label>Saved annotation<select value={annotationId} onChange={(event) => void load(event.target.value)}>
          <option value="">New annotation</option>
          {annotations.map((item) => <option key={item.id} value={item.id ?? ""}>
            {item.name} · {item.geometry.type}{item.deleted ? " · deleted" : ""}</option>)}
        </select></label>
        <label>Name<input value={name} maxLength={200} onChange={(event) => { invalidate(); setName(event.target.value); }} /></label>
        <label>Shape<select value={kind} onChange={(event) => {
          invalidate(); setKind(event.target.value as AnnotationKind); setPoints([]); setVertex(-1);
        }}><option value="point">Point</option><option value="line">Line</option>
          <option value="polyline">Polyline</option><option value="polygon">Polygon</option></select></label>
        <label>View<select value={target} onChange={(event) => changeSelection(() => {
          setTarget(event.target.value as "plane" | "volume"); setPoints([]); setVertex(-1);
        })}><option value="plane" disabled={(image?.timeCount ?? 1) > 1}>2D projection</option><option value="volume">Volume slice</option></select></label>
        <label>Display channel<select value={channel} onChange={(event) => changeSelection(() => setChannel(Number(event.target.value)))}>
          {Array.from({ length: image?.channels ?? 1 }, (_, i) => <option key={i} value={i}>Channel {i + 1}</option>)}
        </select></label>
        {target === "plane" ? <label>Z selection<select value={projection} onChange={(event) => changeSelection(() => setProjection(event.target.value as typeof projection))}>
          <option value="max">Maximum projection</option><option value="mean">Mean projection</option><option value="middle">Middle plane</option>
        </select></label> : <>
          <label>Time point<input type="number" min={1} max={image?.timeCount ?? 1} value={timeIndex + 1}
            onChange={(event) => changeSelection(() => setTimeIndex(Number(event.target.value) - 1))} /></label>
          <label>Slice orientation<select value={plane} onChange={(event) => changeSelection(() => {
            setPlane(event.target.value as VolumePlane); setSlice(0); setPoints([]); setVertex(-1);
          })}><option value="xy">XY</option><option value="xz">XZ</option><option value="yz">YZ</option></select></label>
          <label>Slice<input type="number" min={1} max={sliceCount} value={slice + 1}
            onChange={(event) => changeSelection(() => setSlice(Number(event.target.value) - 1))} /></label>
        </>}
      </div>
      <div className="workbench-annotation-canvas">
        {preview ? <svg viewBox={`0 0 ${preview.width} ${preview.height}`} tabIndex={0}
          aria-label={`${image?.name}, annotation drawing canvas`} onClick={(event) => {
            if (locked) return;
            event.currentTarget.focus();
            const matrix = event.currentTarget.getScreenCTM();
            if (!matrix) return;
            const point = new DOMPoint(event.clientX, event.clientY).matrixTransform(matrix.inverse());
            if (point.x >= 0 && point.x <= preview.width && point.y >= 0 && point.y <= preview.height) add([point.x, point.y]);
          }} onKeyDown={(event) => {
            if (locked) return;
            if (event.key === "Escape") { event.preventDefault(); changePoints([]); setVertex(-1); }
            else if ((event.key === "Backspace" || event.key === "Delete") && points.length) {
              event.preventDefault(); changePoints(points.slice(0, -1)); setVertex(-1);
            }
          }}>
          <image href={preview.dataUrl} width={preview.width} height={preview.height} />
          {points.length > 1 ? kind === "polygon" ? <polygon points={points.map((p) => p.join(",")).join(" ")}
            fill="#ffcd3822" stroke="#ffcd38" strokeWidth={2} vectorEffect="non-scaling-stroke" />
            : <polyline points={points.map((p) => p.join(",")).join(" ")} fill="none" stroke="#ffcd38" strokeWidth={2} vectorEffect="non-scaling-stroke" /> : null}
          {points.map((point, i) => <circle key={i} cx={point[0]} cy={point[1]} r={Math.max(preview.width, preview.height) / 220}
            fill={vertex === i ? "#ffcd38" : "#fff"} stroke="#171a1e" strokeWidth={1} vectorEffect="non-scaling-stroke"
            onClick={(event) => { event.stopPropagation(); setVertex(i); setCoordinate(point); }} />)}
        </svg> : <p>{canvasLoading ? "Loading source image…" : "Choose a valid source selection."}</p>}
      </div>
      <p>Click to add vertices; click an existing vertex to edit its coordinates. Escape clears the draft; Delete removes the last vertex.</p>
      <div className="workbench-editor-grid">
        <label>Horizontal coordinate (pixel edges)<input type="number" step="any" value={coordinate[0]} min={0} max={preview?.width}
          onChange={(event) => setCoordinate([Number(event.target.value), coordinate[1]])} /></label>
        <label>Vertical coordinate (pixel edges)<input type="number" step="any" value={coordinate[1]} min={0} max={preview?.height}
          onChange={(event) => setCoordinate([coordinate[0], Number(event.target.value)])} /></label>
        <label>Notes<input value={notes} maxLength={2000} onChange={(event) => { invalidate(); setNotes(event.target.value); }} /></label>
      </div>
      <div className="workbench-actions">
        <button className="cc-btn" disabled={!coordinatesValid || points.length >= 2048} onClick={() => add(coordinate)}>Add point</button>
        <button className="cc-btn" disabled={!coordinatesValid || vertex < 0 || vertex >= points.length}
          onClick={() => changePoints(points.map((point, i) => i === vertex ? coordinate : point))}>Update vertex {vertex < 0 ? "" : vertex + 1}</button>
        <button className="cc-btn" disabled={!points.length} onClick={() => { changePoints(points.slice(0, -1)); setVertex(-1); }}>Remove last point</button>
        <button className="cc-btn" onClick={fresh}>New annotation</button>
      </div>
      <div className="workbench-editor-grid">
        <label>Measurement channel<select value={measurementChannel} onChange={(event) => {
          epoch.current++; setResult(undefined); setMeasurementChannel(Number(event.target.value));
        }}>{Array.from({ length: image?.channels ?? 1 }, (_, i) => <option key={i} value={i}>Channel {i + 1}</option>)}</select></label>
        {hasProfile ? <label>Profile samples<input type="number" min={2} max={4096} step={1} value={profileSamples}
          onChange={(event) => { epoch.current++; setResult(undefined); setProfileSamples(Number(event.target.value)); }} /></label> : null}
      </div>
      <div className="workbench-actions">
        <button className="cc-btn" disabled={!canMeasure || saved?.deleted} onClick={() => void measure()}>
          {annotationId && !dirty ? "Measure saved annotation" : "Measure draft"}</button>
        <button className="cc-btn" disabled={!validGeometry || !validSelection || !name.trim() || saved?.deleted} onClick={() => void act("annotation.save", {
          imageId: image?.id, ...(annotationId ? { annotationId } : {}), name: name.trim(), notes, geometry, ...selection,
        }, acceptSaved)}>{annotationId ? "Save annotation changes" : "Save annotation"}</button>
        <button className="cc-btn" disabled={!saved || saved.deleted} onClick={() => void act("annotation.delete", {
          imageId: image?.id, annotationId, reason: "Deleted in the desktop annotation editor",
        }, acceptSaved)}>Delete saved annotation</button>
        <button className="cc-btn" disabled={!saved?.undoAvailable} onClick={() => void act("annotation.undo", {
          imageId: image?.id, annotationId,
        }, acceptSaved)}>Undo saved annotation change</button>
      </div>
      <section aria-label="Export saved annotation">
        <h3>Export saved annotation</h3>
        {exportCatalogueError ? <p className="workbench-error" role="alert">{exportCatalogueError}{" "}
          <button type="button" className="cc-btn" onClick={() => setExportCatalogueAttempt((value) => value + 1)}>Retry export formats</button></p> : null}
        <label>File contents<select value={exportFormats.length ? exportFormatId : ""}
          onChange={(event) => setExportFormatId(event.target.value as AnnotationExportFormatId)}>
          {!exportFormats.length ? <option value="">Loading annotation export formats…</option> : null}
          {exportFormats.map((item) => <option key={item.id} value={item.id}
            disabled={item.id === "profile-csv" && !hasProfile}>{item.name}</option>)}
        </select></label>
        {exportFormat ? <p>{exportFormat.description}</p> : null}
        {exportFormat && exportFormat.id !== "geometry-json" ? <p>
          Uses measurement channel {measurementChannel + 1}{hasProfile ? ` and ${profileSamples} profile samples` : ""}.
        </p> : null}
        {!annotationId ? <p>Save an annotation before exporting it.</p> : dirty
          ? <p>Save the pending annotation changes before exporting.</p>
          : saved?.deleted ? <p>This annotation is deleted. Undo its deletion before exporting.</p>
          : saved && !savedGeometryMatches ? <p>The saved annotation changed. Reload it before exporting.</p> : null}
        {exportFormat?.id === "profile-csv" && !hasProfile ? <p>Profile CSV is available for lines and polylines.</p> : null}
        <button type="button" className="cc-btn" disabled={!canExport} onClick={() => {
          if (!canExport || !exportFormat || !image) return;
          void exportAnnotation(exportFormat, {
            imageId: image.id, annotationId, format: exportFormat.id,
            ...(exportFormat.id !== "geometry-json" ? { measurementChannel, ...(hasProfile ? { profileSamples } : {}) } : {}),
          }, saved?.name ?? name);
        }}>Save annotation export…</button>
        <p>Exports retain the saved geometry revision and provenance. Choose a new file name; existing files are preserved.</p>
      </section>
    </fieldset>
    <WorkbenchAnnotationImport image={image} revision={revision} busy={locked} dirty={dirty || importBlocked} read={read}
      chooseFile={chooseImportFile} commit={(args, accepted) => act("annotation.import.run", { ...args }, accepted)}
      onImported={acceptSaved} />
    {dirty ? <p>Unsaved annotation changes. Measurements below describe the draft until it is saved.</p> : null}
    {result ? <section aria-label="Annotation measurements">
      <h3>{result.annotation.name} · {result.annotation.id ? `saved geometry revision ${result.annotation.geometryRevision}` : "draft geometry"}</h3>
      <ScientificOutput output={{ summary: result.measurement.geometry, pixelSpacingUm: result.measurement.pixelSpacingUm }} />
      <ScientificOutput output={{ summary: result.measurement.intensity, validSupport: result.measurement.validSupport, notes: result.measurement.notes }} />
      {result.measurement.profile ? <IntensityProfile key={`${result.measurement.sourceRevision}:${result.measurement.geometryRevision}:${result.measurement.measurementChannel}:${profileSamples}`}
        profile={result.measurement.profile} units={result.measurement.intensity.units} /> : null}
    </section> : null}
  </details></div>;
}
