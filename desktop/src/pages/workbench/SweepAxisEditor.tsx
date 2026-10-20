import { useState } from "react";
import { sweepAddressLabel, type SweepAddress, type SweepAxis, type SweepParameter, type SweepScalar } from "../../../../shared/workbench/sweepProtocol";

export type SweepDraftAxis = SweepAddress & { key: string; path: string; text: string; nodeName?: string };
export const sweepParameterKey = (item: { stepIndex?: number; nodeId?: string; path: string }) =>
  JSON.stringify(item.nodeId ? ["node", item.nodeId, item.path] : ["step", item.stepIndex, item.path]);

export function parseSweepAxis(axis: SweepDraftAxis, parameter: SweepParameter | undefined, maxValues: number): { axis?: SweepAxis; error?: string } {
  if (!parameter) return { error: "This parameter is unavailable in the selected workflow." };
  let parsed: unknown;
  try { parsed = JSON.parse(axis.text); } catch { return { error: "Enter a JSON list, for example [10, 20, 30] or [\"auto\", \"cpu\"]." }; }
  if (!Array.isArray(parsed) || parsed.length < 1 || parsed.length > maxValues) return { error: `Enter between 1 and ${maxValues} values.` };
  const seen = new Set<string>();
  for (const value of parsed) {
    if (value !== null && !["string", "number", "boolean"].includes(typeof value)) return { error: "Each value must be a number, string, boolean, or allowed null." };
    const encoded = JSON.stringify(value);
    if (encoded === undefined) return { error: "Every list item must be a JSON scalar." };
    if (seen.has(encoded)) return { error: "Remove duplicate values from this parameter." };
    seen.add(encoded);
    if (value === null) {
      if (!parameter.canOmit) return { error: "This parameter cannot be omitted; null is not allowed." };
      continue;
    }
    const schema = parameter.schema;
    if ((schema.type === "string" && typeof value !== "string") || (schema.type === "boolean" && typeof value !== "boolean") ||
      ((schema.type === "integer" || schema.type === "number") && (typeof value !== "number" || !Number.isFinite(value) ||
        (schema.type === "integer" && !Number.isInteger(value))))) return { error: `Values must match the ${schema.type} parameter type.` };
    if (schema.enum && !schema.enum.includes(value)) return { error: `Choose values from ${JSON.stringify(schema.enum)}.` };
    if (typeof value === "number" && ((schema.minimum !== undefined && value < schema.minimum) ||
      (schema.maximum !== undefined && value > schema.maximum) || (schema.exclusiveMinimum !== undefined && value <= schema.exclusiveMinimum))) {
      return { error: "A value is outside the parameter's allowed range." };
    }
    if (typeof value === "string" && (value.includes("\0") || (schema.maxLength !== undefined && value.length > schema.maxLength))) {
      return { error: "A string exceeds the parameter bounds or contains an invalid character." };
    }
  }
  if (axis.nodeId !== undefined) return { axis: { nodeId: axis.nodeId, path: axis.path, values: parsed as SweepScalar[] } };
  return { axis: { stepIndex: axis.stepIndex, path: axis.path, values: parsed as SweepScalar[] } };
}

/** Uses canonical candidate schemas instead of duplicating detector controls. */
export default function SweepAxisEditor({ parameters, axes, disabled, maxAxes, maxValues, onChange }: {
  parameters: SweepParameter[]; axes: SweepDraftAxis[]; disabled: boolean; maxAxes: number; maxValues: number;
  onChange: (axes: SweepDraftAxis[]) => void;
}) {
  const [preferred, setPreferred] = useState("");
  const available = parameters.filter((parameter) => !axes.some((axis) => sweepParameterKey(axis) === sweepParameterKey(parameter)));
  const candidate = available.find((item) => sweepParameterKey(item) === preferred) ?? available[0];
  return <fieldset disabled={disabled}>
    <legend>Parameters to vary</legend>
    <label>Add parameter<select value={candidate ? sweepParameterKey(candidate) : ""} onChange={(event) => setPreferred(event.target.value)}>
      {!available.length ? <option value="">No additional parameters</option> : null}
      {available.map((item) => <option key={sweepParameterKey(item)} value={sweepParameterKey(item)}>
        {sweepAddressLabel(item)} · {item.label || item.path}
      </option>)}
    </select></label>
    <button type="button" className="cc-btn" disabled={!candidate || axes.length >= maxAxes} onClick={() => {
      if (!candidate) return;
      const initial = candidate.present ? candidate.currentValue : candidate.schema.default ?? (candidate.canOmit ? null :
        candidate.schema.enum?.[0] ?? (candidate.schema.type === "boolean" ? false : candidate.schema.type === "string" ? "" :
          candidate.schema.minimum ?? (candidate.schema.exclusiveMinimum !== undefined ? candidate.schema.exclusiveMinimum + 1 : 0)));
      const address: SweepAddress = candidate.nodeId !== undefined ? { nodeId: candidate.nodeId } : { stepIndex: candidate.stepIndex };
      onChange([...axes, { key: crypto.randomUUID(), ...address, nodeName: candidate.nodeName, path: candidate.path,
        text: JSON.stringify([initial ?? null]) }]);
    }}>Add parameter axis</button>
    <ol className="workbench-recipe">{axes.map((axis) => {
      const parameter = parameters.find((item) => sweepParameterKey(item) === sweepParameterKey(axis));
      const parsed = parseSweepAxis(axis, parameter, maxValues);
      return <li key={axis.key}>
        <label>{sweepAddressLabel(parameter ?? axis)} · {parameter?.label ?? axis.path}
          <textarea rows={2} value={axis.text} maxLength={8192} spellCheck={false}
            onChange={(event) => onChange(axes.map((item) => item.key === axis.key ? { ...item, text: event.target.value } : item))} />
        </label>
        {parameter?.schema.description ? <p>{parameter.schema.description}</p> : null}
        <small>{parameter?.schema.type} values in a JSON list{parameter?.schema.enum ? ` · allowed: ${JSON.stringify(parameter.schema.enum)}` : ""}.
          {parameter?.canOmit ? " Use null to omit this field and use the backend's default behavior." : ""}</small>
        {parsed.error ? <p className="workbench-error" role="alert">{parsed.error}</p> : null}
        <button type="button" className="cc-btn" onClick={() => onChange(axes.filter((item) => item.key !== axis.key))}
          aria-label={`Remove parameter ${parameter?.label ?? axis.path}`}>Remove axis</button>
      </li>;
    })}</ol>
  </fieldset>;
}
