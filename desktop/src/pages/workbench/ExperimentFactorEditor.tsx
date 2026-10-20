import type { StatisticalFactor } from "../../../../shared/workbench/statisticsProtocol";

export type FactorDraft = StatisticalFactor & { levelsText: string };
export const factorLevels = (factor: FactorDraft) => factor.levelsText.split("\n").map(value => value.trim()).filter(Boolean);
export const factorDrafts = (factors: StatisticalFactor[]): FactorDraft[] => factors.map(factor => ({ ...factor, levelsText: factor.levels?.join("\n") ?? "" }));
export const factorDefinitions = (factors: FactorDraft[]): StatisticalFactor[] => factors.map(factor => ({ id: factor.id, name: factor.name.trim(), kind: factor.kind,
  ...(factor.kind === "categorical" ? { levels: factorLevels(factor), referenceLevel: factor.referenceLevel || factorLevels(factor)[0] }
    : factor.unit?.trim() ? { unit: factor.unit.trim() } : {}) }));
export const invalidFactors = (factors: FactorDraft[]) => factors.length === 0 || factors.some(factor => !factor.name.trim() || factor.kind === "categorical" &&
  (factorLevels(factor).length < 2 || factorLevels(factor).length > 32 || new Set(factorLevels(factor)).size !== factorLevels(factor).length ||
    !!factor.referenceLevel && !factorLevels(factor).includes(factor.referenceLevel)));

/** The same factor definition editor is used by saved layouts and statistical designs. */
export default function ExperimentFactorEditor({ factors, onChange }: { factors: FactorDraft[]; onChange: (values: FactorDraft[]) => void }) {
  const edit = (id: string, changes: Partial<FactorDraft>) => onChange(factors.map(factor => factor.id === id ? { ...factor, ...changes } : factor));
  return <>{factors.map(factor => <fieldset key={factor.id}><legend>{factor.name || "New factor"}</legend><div className="workbench-editor-grid">
    <label>Factor name<input value={factor.name} maxLength={200} onChange={event => edit(factor.id, { name: event.target.value })} /></label>
    <label>Factor type<select value={factor.kind} onChange={event => edit(factor.id, { kind: event.target.value as StatisticalFactor["kind"] })}><option value="categorical">Categorical</option><option value="numeric">Numeric</option></select></label>
    {factor.kind === "categorical" ? <><label>Levels (one per line)<textarea rows={3} value={factor.levelsText} onChange={event => edit(factor.id, { levelsText: event.target.value })} /></label>
      <label>Reference level<select value={factor.referenceLevel ?? ""} onChange={event => edit(factor.id, { referenceLevel: event.target.value })}><option value="">First declared level</option>{[...new Set(factorLevels(factor))].map(value => <option key={value} value={value}>{value}</option>)}</select></label></>
      : <label>Unit (optional)<input value={factor.unit ?? ""} maxLength={200} onChange={event => edit(factor.id, { unit: event.target.value })} /></label>}
    </div><button className="cc-btn" onClick={() => onChange(factors.filter(value => value.id !== factor.id))}>Remove factor</button></fieldset>)}
    <button className="cc-btn" disabled={factors.length >= 16} onClick={() => onChange([...factors, { id: `factor_${crypto.randomUUID().replaceAll("-", "").slice(0, 12)}`,
      name: "New factor", kind: "categorical", levelsText: "Control\nTreatment", referenceLevel: "Control" }])}>Add factor</button></>;
}
