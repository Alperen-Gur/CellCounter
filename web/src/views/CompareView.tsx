import { BarChart3 } from "lucide-react";
import { useMemo } from "react";
import type { WorkspaceImage } from "../app/types";
import { filterCellsByRois } from "../app/roi";
import { compareCellGroups as compareBatches } from "../domain/analysis";

export function CompareView({ images, onLibrary }: { images: WorkspaceImage[]; onLibrary: () => void }) {
  const comparison = useMemo(() => {
    const grouped = new Map<string, { imageIds: Set<string>; cells: { diameterUm: number; areaUm2: number }[] }>();
    images.forEach((image) => {
      const condition = image.condition || "Unassigned";
      const group = grouped.get(condition) ?? { imageIds: new Set<string>(), cells: [] };
      group.imageIds.add(image.id);
      group.cells.push(...filterCellsByRois(image).map((cell) => ({
        diameterUm: cell.diameterUm,
        areaUm2: cell.areaUm2 ?? Math.PI * (cell.diameterUm / 2) ** 2,
      })));
      grouped.set(condition, group);
    });
    return compareBatches(Array.from(grouped, ([condition, group]) => ({ id: `condition:${condition}`, condition, imageCount: group.imageIds.size, cells: group.cells })), [20, 30]);
  }, [images]);
  const max = Math.max(1, ...comparison.groups.map((group) => group.cellCount));
  return (
    <main className="page-view compare-view">
      <header className="page-heading"><div><span className="eyebrow">Across conditions</span><h1>Batch comparison</h1><p>Compare object counts and physical measurements without moving data off-device.</p></div></header>
      {comparison.groups.length > 1 && comparison.groups.some((group) => group.cellCount) ? (
        <div className="comparison-layout">
          <section className="comparison-plot">
            <div className="plot-heading"><div><span>Object count</span><strong>Distribution by condition</strong></div><em>{comparison.groups.reduce((sum, group) => sum + group.imageCount, 0)} fields</em></div>
            <div className="bar-chart">
              {comparison.groups.map((group, index) => <div className="bar-row" key={group.condition}><span>{group.condition}</span><div><i style={{ width: `${Math.max(2, group.cellCount / max * 100)}%`, "--delay": `${index * 60}ms` } as React.CSSProperties} /></div><strong>{group.cellCount}</strong></div>)}
            </div>
            {comparison.mannWhitney && <p className="test-summary">Mann–Whitney U {comparison.mannWhitney.u.toFixed(1)} · p {comparison.mannWhitney.pValue < .001 ? "< 0.001" : `= ${comparison.mannWhitney.pValue.toFixed(3)}`} · median Δ {comparison.mannWhitney.medianDifferenceUm.toFixed(1)} µm</p>}
          </section>
          <section className="comparison-table">
            <div className="comparison-header"><span>Condition</span><span>Images</span><span>Mean ø</span><span>Spread</span></div>
            {comparison.groups.map((group) => <div className="comparison-row" key={group.condition}><strong>{group.condition}</strong><span>{group.imageCount}</span><span>{group.meanDiameterUm ? `${group.meanDiameterUm.toFixed(1)} µm` : "—"}</span><span>{group.standardDeviationUm ? `${group.standardDeviationUm.toFixed(1)} µm SD` : "—"}</span></div>)}
          </section>
        </div>
      ) : (
        <div className="page-empty"><BarChart3 size={28} /><h2>Assign at least two conditions</h2><p>Use the library to label images—for example, “Control” and “Treatment”.</p><button className="secondary-button" onClick={onLibrary}>Open library</button></div>
      )}
    </main>
  );
}
