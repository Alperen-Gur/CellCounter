import { useState } from "react";
import type { PreprocessingCatalogue, PreprocessingDraftStep } from "../../../../shared/workbench/preprocessingProtocol";
import { recipeStepIssues } from "../../../../shared/workbench/preprocessingProtocol";
import PluginParameters from "./PluginParameters";

/** Presentational editor shared by one-image processing and saved workflows. */
export default function PreprocessingRecipeEditor({ catalogue, steps, dimension, disabled = false, onChange }: {
  catalogue?: PreprocessingCatalogue;
  steps: PreprocessingDraftStep[];
  dimension: 2 | 3;
  disabled?: boolean;
  onChange: (steps: PreprocessingDraftStep[]) => void;
}) {
  const [preferredMethod, setPreferredMethod] = useState("gaussian");
  const available = catalogue?.filters.filter((item) => item.dimensions.includes(dimension)) ?? [];
  const method = available.some((item) => item.method === preferredMethod) ? preferredMethod : available[0]?.method ?? "";
  const selected = available.find((item) => item.method === method);
  const move = (index: number, direction: -1 | 1) => {
    const next = [...steps]; [next[index], next[index + direction]] = [next[index + direction], next[index]]; onChange(next);
  };
  return <fieldset disabled={disabled || !catalogue} className="workbench-recipe-editor">
    <legend>Preprocessing recipe · {dimension}D</legend>
    {!catalogue ? <p role="status">Loading available filters…</p> : null}
    <label>Add filter<select value={method} onChange={(event) => setPreferredMethod(event.target.value)}>
      {!available.length ? <option value="">No available filters</option> : null}
      {available.map((item) => <option key={item.method} value={item.method}>{item.name ?? item.method}</option>)}
    </select></label>
    <button type="button" className="cc-btn" disabled={!selected || steps.length >= (catalogue?.recipeSchema.maxItems ?? 8)}
      onClick={() => {
        if (selected) onChange([...steps, { key: crypto.randomUUID(), method, values: { ...selected.defaults } }]);
      }}>Add step</button>
    {!steps.length ? <p>Add a filter to define the recipe.</p> : null}
    <ol className="workbench-recipe">{steps.map((step, index) => {
      const filter = catalogue?.filters.find((item) => item.method === step.method);
      const title = filter?.name ?? step.method;
      const issues = catalogue ? recipeStepIssues(step, catalogue, dimension) : [];
      const schema = { required: [], properties: Object.fromEntries(Object.entries(filter?.defaults ?? {}).map(([key, value]) => [
        key, { ...catalogue!.recipeSchema.items.properties[key], default: value,
          description: filter?.parameterUnits?.[key]?.replaceAll("-", " ") },
      ])) };
      return <li key={step.key}>
        <h4>{index + 1}. {title}</h4>
        {issues.map((issue) => <p key={issue} className="workbench-error" role="alert">{issue}</p>)}
        <PluginParameters schema={schema} values={step.values}
          onChange={(values) => onChange(steps.map((item) => item.key === step.key ? { ...item, values } : item))} />
        {filter?.intensityEffect ? <small>{filter.intensityEffect.replaceAll("-", " ")}</small> : null}
        {filter?.notes?.length ? <p>{filter.notes.join(" ")}</p> : null}
        <div className="workbench-actions">
          <button type="button" className="cc-btn" disabled={index === 0} aria-label={`Move ${title} step ${index + 1} earlier`}
            onClick={() => move(index, -1)}>Move earlier</button>
          <button type="button" className="cc-btn" disabled={index === steps.length - 1} aria-label={`Move ${title} step ${index + 1} later`}
            onClick={() => move(index, 1)}>Move later</button>
          <button type="button" className="cc-btn" disabled={!filter} aria-label={`Reset ${title} step ${index + 1} to defaults`}
            onClick={() => filter && onChange(steps.map((item) => item.key === step.key ? { ...item, values: { ...filter.defaults } } : item))}>Reset defaults</button>
          <button type="button" className="cc-btn" aria-label={`Remove ${title} step ${index + 1}`}
            onClick={() => onChange(steps.filter((item) => item.key !== step.key))}>Remove</button>
        </div>
      </li>;
    })}</ol>
    {catalogue?.notes.length ? <p>{catalogue.notes.join(" ")}</p> : null}
  </fieldset>;
}
