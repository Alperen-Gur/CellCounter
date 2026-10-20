import type { ParameterSpec, ParameterValue, WorkbenchPlugin } from "../../../../shared/workbench/extensionProtocol";

/** One declarative form for execution and paired-model comparison. */
export default function PluginParameters({ plugin, schema, values, onChange }: {
  plugin?: WorkbenchPlugin; values: Record<string, ParameterValue>;
  schema?: { properties: Record<string, ParameterSpec>; required: string[] };
  onChange: (values: Record<string, ParameterValue>) => void;
}) {
  const definition = schema ?? plugin?.manifest.parameters;
  return <>{Object.entries(definition?.properties ?? {}).map(([name, spec]) => {
    const value = values[name] ?? spec.default;
    const set = (next: ParameterValue) => onChange({ ...values, [name]: next });
    return <label key={name}>{spec.title ?? name}
      {spec.enum ? <select value={value === undefined ? "" : String(spec.enum.indexOf(value))} onChange={(event) => set(spec.enum![Number(event.target.value)])}>
        {value === undefined ? <option value="" disabled>Choose a value</option> : null}
        {spec.enum.map((option, index) => <option key={index} value={index}>{String(option)}</option>)}
      </select> : spec.type === "boolean" ? <input type="checkbox" checked={value === true}
        onChange={(event) => set(event.target.checked)} /> : <input
        type={spec.type === "string" ? "text" : "number"} value={value === undefined ? "" : String(value)}
        min={spec.minimum} max={spec.maximum} step={spec.type === "integer" ? 1 : "any"} maxLength={spec.maxLength}
        required={definition?.required.includes(name)}
        onChange={(event) => {
          if (event.target.value === "" && spec.type !== "string") {
            const next = { ...values }; delete next[name]; onChange(next);
          } else set(spec.type === "string" ? event.target.value : Number(event.target.value));
        }} />}
      {spec.description ? <small>{spec.description}</small> : null}
    </label>;
  })}</>;
}
