import { useCataloguePins } from "./WorkbenchCatalogueBrowser";
import { useEffect, useRef, useState, type PointerEvent } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import type { ProjectSnapshot } from "../../../../shared/workbench/protocol";
import type { SourceOverview } from "../../../../shared/workbench/sourceProtocol";

type Props = { snapshot: ProjectSnapshot; busy: boolean;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  act: (operation: string, args: Record<string, unknown>) => Promise<void> };
type Region = { x: number; y: number; width: number; height: number };

export default function WorkbenchSources({ snapshot, busy, read, act }: Props) {
  const sources = snapshot.largeSources ?? [];
  const [sourceId, setSourceId] = useState("");
  const [pageIndex, setPageIndex] = useState(0);
  const [channel, setChannel] = useState(0);
  const [region, setRegion] = useState<Region>({ x: 0, y: 0, width: 1024, height: 1024 });
  const [name, setName] = useState("");
  const [overview, setOverview] = useState<SourceOverview>();
  const [loading, setLoading] = useState(false);
  const [expanded, setExpanded] = useState(false);
  const [error, setError] = useState("");
  const epoch = useRef(0);
  const drag = useRef<{ x: number; y: number } | undefined>(undefined);
  const latestRead = useRef(read); latestRead.current = read;
  const pinError = useCataloguePins([{ catalogue: "largeSources", entryId: sourceId }]);
  const source = sources.find((item) => item.id === sourceId);
  const valid = source && source.access !== "unsupported" && Object.values(region).every(Number.isInteger)
    && region.x >= 0 && region.y >= 0 && region.width > 0 && region.height > 0
    && region.x + region.width <= source.width && region.y + region.height <= source.height
    && region.width * region.height <= source.limits.roiPixels;

  useEffect(() => {
    setSourceId((id) => id || sources[0]?.id || "");
  }, [snapshot.project.revision]);
  useEffect(() => {
    setPageIndex(0); setChannel(0); setName(""); setOverview(undefined);
    setRegion({ x: 0, y: 0, width: Math.min(1024, source?.width ?? 1024), height: Math.min(1024, source?.height ?? 1024) });
    drag.current = undefined;
  }, [sourceId]);
  useEffect(() => {
    const generation = ++epoch.current;
    setOverview(undefined); setLoading(false); setError(""); drag.current = undefined;
    if (!expanded || !source || source.access === "unsupported" || busy) return;
    setLoading(true);
    void latestRead.current<SourceOverview>("source.overview", { sourceId, pageIndex, channel, maxSize: 1024 }).then((result) => {
      if (epoch.current === generation) setOverview(result);
    }).catch((cause) => { if (epoch.current === generation) setError(String(cause)); })
      .finally(() => { if (epoch.current === generation) setLoading(false); });
    return () => { epoch.current++; };
  }, [expanded, sourceId, pageIndex, channel, snapshot.project.revision, busy]);
  const importSources = async () => {
    const generation = epoch.current;
    try {
      const paths = await open({ title: "Open large TIFF sources", multiple: true,
        filters: [{ name: "TIFF source", extensions: ["tif", "tiff"] }] });
      if (paths && generation === epoch.current) await act("source.import", { paths: Array.isArray(paths) ? paths : [paths] });
    } catch (cause) { if (generation === epoch.current) setError(String(cause)); }
  };
  const point = (event: PointerEvent<SVGSVGElement>) => {
    const matrix = event.currentTarget.getScreenCTM();
    if (!matrix || !source) return;
    const value = new DOMPoint(event.clientX, event.clientY).matrixTransform(matrix.inverse());
    return { x: Math.min(source.width, Math.max(0, value.x)), y: Math.min(source.height, Math.max(0, value.y)) };
  };
  const move = (event: PointerEvent<SVGSVGElement>) => {
    if (!drag.current || !source) return;
    const current = point(event);
    if (!current) return;
    const x = Math.min(source.width - 1, Math.floor(Math.min(drag.current.x, current.x)));
    const y = Math.min(source.height - 1, Math.floor(Math.min(drag.current.y, current.y)));
    const right = Math.min(source.width, Math.max(x + 1, Math.ceil(Math.max(drag.current.x, current.x))));
    const bottom = Math.min(source.height, Math.max(y + 1, Math.ceil(Math.max(drag.current.y, current.y))));
    setRegion({ x, y, width: right - x, height: bottom - y });
  };
  return <div className="workbench-automation"><details onToggle={(event) => setExpanded(event.currentTarget.open)}>
    <summary>Large TIFF sources and regions</summary>
    <p>Open a large source, select a stored page and channel, then extract a region for analysis.
      The overview is reduced for display; extracted pixels retain their original resolution and intensity values.</p>
    {pinError ? <p className="workbench-error" role="alert">{pinError}</p> : null}
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    <button className="cc-btn" disabled={busy || loading} onClick={() => void importSources()}>Open large TIFF sources</button>
    <div className="workbench-editor-grid">
      <fieldset disabled={busy || loading}>
        <label>Source<select value={sourceId} onChange={(event) => setSourceId(event.target.value)}>
          {!sources.length ? <option value="">Open a TIFF source first</option> : null}
          {sources.map((item) => <option key={item.id} value={item.id}>{item.name} · {item.width} × {item.height}</option>)}
        </select></label>
        {source ? <>
          <p>{source.dtype} · {source.pageCount} stored pages · {source.channels} channels · {(source.sourceBytes / 1024 ** 2).toFixed(1)} MiB</p>
          <label>Stored page<input type="number" min={1} max={source.pageCount} step={1} value={pageIndex + 1}
            onChange={(event) => {
              const value = Number(event.target.value);
              if (Number.isInteger(value) && value >= 1 && value <= source.pageCount) setPageIndex(value - 1);
            }} /></label>
          <label>Channel<select value={channel} onChange={(event) => setChannel(Number(event.target.value))}>
            {Array.from({ length: source.channels }, (_, index) => <option key={index} value={index}>Channel {index + 1}</option>)}
          </select></label>
          <p>Page numbers are stored-file positions. Z and time coordinates are not inferred.</p>
        </> : null}
      </fieldset>
      <fieldset disabled={busy || loading || !source}>
        <h3>Region in original pixels</h3>
        {(["x", "y", "width", "height"] as const).map((key) => <label key={key}>
          {key === "x" || key === "y" ? `${key.toUpperCase()} origin (starting at 0)` : key}
          <input type="number" min={key === "x" || key === "y" ? 0 : 1} step={1} value={region[key]}
            onChange={(event) => setRegion((old) => ({ ...old, [key]: Number(event.target.value) }))} />
        </label>)}
        <p>{(region.width * region.height / 1_000_000).toFixed(2)} megapixels · limit {((source?.limits.roiPixels ?? 16_000_000) / 1_000_000).toFixed(0)}</p>
        {!valid && source ? <p>Choose a positive rectangle within the source and pixel limit.</p> : null}
        <label>Extracted image name<input value={name} maxLength={200} placeholder="Use source name and region coordinates"
          onChange={(event) => setName(event.target.value)} /></label>
        <button className="cc-btn" disabled={!valid} onClick={() => void act("source.extract", {
          sourceId, pageIndex, channel, ...region, ...(name.trim() ? { name: name.trim() } : {}),
        })}>Extract source-resolution image</button>
      </fieldset>
    </div>
    {loading ? <p role="status">Reading bounded source overview…</p> : null}
    {source?.access === "unsupported" ? <p className="workbench-error">This TIFF's compressed segments exceed the access budget. Convert it to a tiled or uncompressed TIFF before extraction.</p> : null}
    {overview && source ? <div className="workbench-source-overview">
      <p>Drag a rectangle or enter exact coordinates above.</p>
      <svg viewBox={`0 0 ${source.width} ${source.height}`} aria-label="Large source overview and selected extraction region"
        onPointerDown={(event) => {
          if (busy || loading) return;
          const position = point(event);
          if (position) { drag.current = position; event.currentTarget.setPointerCapture(event.pointerId); move(event); }
        }} onPointerMove={move}
        onPointerUp={(event) => { move(event); drag.current = undefined; if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId); }}
        onPointerCancel={() => { drag.current = undefined; }}>
        <image href={overview.dataUrl} width={source.width} height={source.height} />
        <rect x={region.x} y={region.y} width={region.width} height={region.height}
          fill="rgba(79,180,255,.12)" stroke="#4fb4ff" strokeWidth={2} vectorEffect="non-scaling-stroke" />
      </svg>
    </div> : null}
    {source ? <details><summary>Source access and lineage</summary>
      <p className="workbench-project-path">SHA-256: {source.sourceHash}</p>
      <ul>{source.limitations.map((note, index) => <li key={index}>{note}</li>)}</ul>
    </details> : null}
  </details></div>;
}
