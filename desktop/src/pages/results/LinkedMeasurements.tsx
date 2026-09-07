import { useEffect, useMemo, useRef, useState } from "react";
import type { CellDTO } from "../../kernel/types";
import { useAppStore } from "../../kernel/store/store";
import { MEASUREMENT_METRICS, MEASUREMENT_PAGE_SIZE, SCATTER_DRAW_LIMIT, measurementPoints, pointRange, scatterSample, selectMeasurementPage, selectMeasurementRange, type MeasurementMetric } from "./reviewMath";

const WIDTH = 600, HEIGHT = 180, PAD = 18;
const format = (n: number | undefined) => n == null || !Number.isFinite(n) ? "—" : n.toLocaleString(undefined, { maximumFractionDigits: 2 });

export function LinkedMeasurements({ cells }: { cells: CellDTO[] }) {
  const selected = useAppStore(s => s.selectedCellIds);
  const setSelected = useAppStore(s => s.setSelectedCellIds);
  const [page, setPage] = useState(0);
  const [selectedOnly, setSelectedOnly] = useState(false);
  const [xMetric, setXMetric] = useState<MeasurementMetric>("diameterUm");
  const [yMetric, setYMetric] = useState<MeasurementMetric>("confidence");
  const [brush, setBrush] = useState<{ x: number; y: number; endX: number; endY: number } | null>(null);
  const brushRef = useRef<typeof brush>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const points = useMemo(() => measurementPoints(cells, xMetric, yMetric), [cells, xMetric, yMetric]);
  const xRange = useMemo(() => pointRange(points, "x"), [points]);
  const yRange = useMemo(() => pointRange(points, "y"), [points]);
  const rows = useMemo(() => selectedOnly ? cells.filter(cell => selected.has(cell.id)) : cells, [cells, selected, selectedOnly]);
  const pages = Math.max(1, Math.ceil(rows.length / MEASUREMENT_PAGE_SIZE));
  const shownPage = Math.min(page, pages - 1);
  const visibleRows = selectMeasurementPage(rows, shownPage);

  useEffect(() => {
    const valid = new Set(cells.map(cell => cell.id));
    const old = useAppStore.getState().selectedCellIds;
    const next = new Set([...old].filter(id => valid.has(id)));
    if (next.size !== old.size) setSelected(next);
  }, [cells, setSelected]);

  useEffect(() => {
    const context = canvas.current?.getContext("2d");
    if (!context) return;
    const projectX = (x: number) => PAD + (x - xRange[0]) / (xRange[1] - xRange[0]) * (WIDTH - 2 * PAD);
    const projectY = (y: number) => HEIGHT - PAD - (y - yRange[0]) / (yRange[1] - yRange[0]) * (HEIGHT - 2 * PAD);
    context.clearRect(0, 0, WIDTH, HEIGHT);
    context.strokeStyle = "#98a3b3";
    context.strokeRect(PAD, PAD, WIDTH - 2 * PAD, HEIGHT - 2 * PAD);
    for (const point of scatterSample(points, selected)) {
      const active = selected.has(point.id);
      context.fillStyle = active ? "#e37c1c" : "#387ba8";
      context.globalAlpha = active ? 1 : .55;
      context.beginPath(); context.arc(projectX(point.x), projectY(point.y), active ? 3.5 : 2, 0, Math.PI * 2); context.fill();
    }
    context.globalAlpha = 1;
    if (brush) {
      context.fillStyle = "#3183b526";
      context.strokeStyle = "#3183b5";
      context.fillRect(brush.x, brush.y, brush.endX - brush.x, brush.endY - brush.y);
      context.strokeRect(brush.x, brush.y, brush.endX - brush.x, brush.endY - brush.y);
    }
  }, [points, selected, xRange, yRange, brush]);

  const location = (event: React.PointerEvent<HTMLCanvasElement>) => {
    const rect = event.currentTarget.getBoundingClientRect();
    return { x: (event.clientX - rect.left) / rect.width * WIDTH, y: (event.clientY - rect.top) / rect.height * HEIGHT };
  };
  const select = (ids: Set<string>, extend: boolean) => setSelected(extend ? new Set([...useAppStore.getState().selectedCellIds, ...ids]) : ids);

  return <section className="rv-linked" aria-label="Linked measurements and scatter plot">
    <div className="rv-review-row">
      <strong>Measurements</strong><span>{cells.length.toLocaleString()} included · {selected.size.toLocaleString()} selected</span>
      <label><input type="checkbox" checked={selectedOnly} onChange={e => { setSelectedOnly(e.target.checked); setPage(0); }} /> Selected only</label>
      <button onClick={() => setSelected(new Set(cells.map(cell => cell.id)))}>Select all included</button>
      <button onClick={() => setSelected(new Set())} disabled={!selected.size}>Clear selection</button>
    </div>
    <div className="rv-linked__body">
      <div>
        <div className="rv-review-row">
          <label>X <select value={xMetric} onChange={e => setXMetric(e.target.value as MeasurementMetric)}>{MEASUREMENT_METRICS.map(metric => <option key={metric.id} value={metric.id}>{metric.label}</option>)}</select></label>
          <label>Y <select value={yMetric} onChange={e => setYMetric(e.target.value as MeasurementMetric)}>{MEASUREMENT_METRICS.map(metric => <option key={metric.id} value={metric.id}>{metric.label}</option>)}</select></label>
        </div>
        <canvas ref={canvas} width={WIDTH} height={HEIGHT} className="rv-scatter" aria-label="Scatter plot; drag a rectangle to select cells, or use the measurement table"
          onPointerDown={e => { const p = location(e); brushRef.current = { ...p, endX: p.x, endY: p.y }; setBrush(brushRef.current); e.currentTarget.setPointerCapture(e.pointerId); }}
          onPointerMove={e => { if (!brushRef.current) return; const p = location(e); brushRef.current = { ...brushRef.current, endX: p.x, endY: p.y }; setBrush(brushRef.current); }}
          onPointerCancel={() => { brushRef.current = null; setBrush(null); }}
          onPointerUp={e => {
            const region = brushRef.current; if (!region) return;
            const end = location(e); brushRef.current = null; setBrush(null);
            const sourceX = (x: number) => xRange[0] + (x - PAD) / (WIDTH - 2 * PAD) * (xRange[1] - xRange[0]);
            const sourceY = (y: number) => yRange[0] + (HEIGHT - PAD - y) / (HEIGHT - 2 * PAD) * (yRange[1] - yRange[0]);
            const small = Math.hypot(end.x - region.x, end.y - region.y) < 5;
            const found = selectMeasurementRange(points,
              [sourceX(small ? end.x - 7 : region.x), sourceX(small ? end.x + 7 : end.x)],
              [sourceY(small ? end.y - 7 : region.y), sourceY(small ? end.y + 7 : end.y)]);
            select(found, e.shiftKey || e.ctrlKey || e.metaKey);
          }} />
        <p className="rv-review-help">Drag to select; Shift adds to selection. {points.length > SCATTER_DRAW_LIMIT ? "The plot samples large sets; selection checks every measured cell. " : ""}{cells.length - points.length} cells lack one of these measurements.</p>
        <p className="rv-review-help">X: {format(xRange[0])}–{format(xRange[1])} · Y: {format(yRange[0])}–{format(yRange[1])}</p>
      </div>
      <div>
        <div className="rv-measure-table"><table><thead><tr><th>Select</th><th>Cell</th><th>Ø µm</th><th>Area µm²</th><th>Intensity</th><th>Confidence</th></tr></thead>
          <tbody>{visibleRows.map((cell, i) => <tr key={cell.id} className={selected.has(cell.id) ? "rv-measure-selected" : ""} onClick={e => { if ((e.target as HTMLElement).tagName !== "INPUT") select(new Set([cell.id]), e.shiftKey || e.ctrlKey || e.metaKey); }}>
            <td><input type="checkbox" aria-label={`Select cell ${shownPage * MEASUREMENT_PAGE_SIZE + i + 1}`} checked={selected.has(cell.id)} onChange={e => { const next = new Set(selected); if (e.target.checked) next.add(cell.id); else next.delete(cell.id); setSelected(next); }} /></td>
            <td title={cell.id}>{shownPage * MEASUREMENT_PAGE_SIZE + i + 1}</td><td>{format(cell.diameterUm)}</td><td>{format(cell.areaUm2)}</td><td>{format(cell.meanIntensity)}</td><td>{format(cell.confidence)}</td>
          </tr>)}</tbody></table></div>
        <div className="rv-review-row"><button disabled={shownPage === 0} onClick={() => setPage(shownPage - 1)}>Previous</button><span>Page {shownPage + 1} / {pages}</span><button disabled={shownPage + 1 >= pages} onClick={() => setPage(shownPage + 1)}>Next</button></div>
      </div>
    </div>
  </section>;
}
