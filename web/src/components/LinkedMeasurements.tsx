import { useMemo, useState } from "react";
import type { WorkspaceCell } from "../app/types";

const PAGE_SIZE = 50;
const PLOT_LIMIT = 600;
export function LinkedMeasurements({ cells, selectedId, onSelect, hasLearnedConfidence = true, calibrationVerified = true }: { calibrationVerified?: boolean; hasLearnedConfidence?: boolean; cells: readonly WorkspaceCell[]; selectedId?: string; onSelect(id: string): void }) {
  const [page, setPage] = useState(0);
  const [minimum, setMinimum] = useState(0);
  const [maximum, setMaximum] = useState(1000);
  const filtered = useMemo(() => cells.filter((cell) => cell.diameterUm >= minimum && cell.diameterUm <= maximum), [cells, minimum, maximum]);
  const selectedIndex = filtered.findIndex((cell) => cell.id === selectedId);
  const selectedPage = selectedIndex >= 0 ? Math.floor(selectedIndex / PAGE_SIZE) : Math.min(page, Math.max(0, Math.ceil(filtered.length / PAGE_SIZE) - 1));
  const [followSelection, setFollowSelection] = useState(true);
  const currentPage = followSelection ? selectedPage : Math.min(page, Math.max(0, Math.ceil(filtered.length / PAGE_SIZE) - 1));
  const plot = useMemo(() => { const stride = Math.max(1, Math.ceil(filtered.length / PLOT_LIMIT)); return filtered.filter((_, index) => index % stride === 0); }, [filtered]);
  const maxDiameter = Math.max(1, ...plot.map((cell) => cell.diameterUm));
  return <details className="linked-measurements"><summary>Measurements <span>{filtered.length} objects{selectedId ? " · 1 selected" : ""}{!calibrationVerified ? " · scale unverified" : ""}</span></summary>
    <div className="processing-actions"><label>Diameter from <input aria-label="Minimum plot diameter" type="number" min="0" value={minimum} onChange={(event) => { setMinimum(Number(event.target.value)); setPage(0); }} /></label><label>to <input aria-label="Maximum plot diameter" type="number" min="0" value={maximum} onChange={(event) => { setMaximum(Number(event.target.value)); setPage(0); }} /> µm</label><button disabled={!selectedId} onClick={() => setFollowSelection(true)}>Show selected row</button></div>
    <svg className="measurement-plot" viewBox="0 0 600 130" role="group" aria-label="Diameter versus confidence. Select a point to link to the image and table.">{plot.map((cell) => <circle key={cell.id} cx={15 + cell.diameterUm / maxDiameter * 570} cy={115 - cell.confidence * 100} r={cell.id === selectedId ? 5 : 3} fill={cell.id === selectedId ? "#b98016" : "#168b79"} tabIndex={0} role="button" aria-label={`Select ${cell.id}, ${cell.diameterUm.toFixed(1)} micrometres`} onClick={() => { onSelect(cell.id); setFollowSelection(true); }} onKeyDown={(event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); onSelect(cell.id); setFollowSelection(true); } }} />)}</svg>
    <p>Diameter → · {hasLearnedConfidence ? "confidence ↑" : "classical threshold has no learned confidence"} · {plot.length} plotted; diameter filtering evaluates all {cells.length} included objects.</p>
    <div className="measurement-table"><table><thead><tr><th>Object</th><th>Diameter µm</th><th>Area µm²</th><th>Confidence</th></tr></thead><tbody>{filtered.slice(currentPage * PAGE_SIZE, (currentPage + 1) * PAGE_SIZE).map((cell) => <tr key={cell.id} aria-selected={selectedId === cell.id}><td><button onClick={() => { onSelect(cell.id); setFollowSelection(true); }}>{cell.id}</button></td><td>{cell.diameterUm.toFixed(2)}</td><td>{cell.areaUm2?.toFixed(2) ?? "—"}</td><td>{hasLearnedConfidence ? `${(cell.confidence * 100).toFixed(0)}%` : "Not estimated"}</td></tr>)}</tbody></table></div>
    <div className="processing-actions"><button disabled={currentPage === 0} onClick={() => { setPage(currentPage - 1); setFollowSelection(false); }}>Previous</button><span>Page {currentPage + 1} of {Math.max(1, Math.ceil(filtered.length / PAGE_SIZE))}</span><button disabled={(currentPage + 1) * PAGE_SIZE >= filtered.length} onClick={() => { setPage(currentPage + 1); setFollowSelection(false); }}>Next</button></div>
  </details>;
}
