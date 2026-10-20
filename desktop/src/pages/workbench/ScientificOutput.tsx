import { useState } from "react";

const record = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" && !Array.isArray(value);
const format = (value: unknown) => value == null ? "—" : typeof value === "number"
  ? value.toLocaleString(undefined, { maximumFractionDigits: 4 })
  : typeof value === "object" ? JSON.stringify(value) : String(value);

export default function ScientificOutput({ output }: { output: unknown }) {
  const [page, setPage] = useState(0);
  const [rawVisible, setRawVisible] = useState(false);
  if (!record(output)) return <p>{format(output)}</p>;
  const source = [output.measurements, output.per_cell, output.cells, output.spots].find(Array.isArray);
  const rows: Record<string, unknown>[] = (source ?? []).filter(record).map((row) => {
    if (record(row.values)) { const { values, ...rest } = row; return { ...rest, ...values as Record<string, unknown> }; }
    return row;
  });
  const columns = [...new Set(rows.slice(0, 100).flatMap(Object.keys))];
  const actualPage = Math.min(page, Math.max(0, Math.ceil(rows.length / 100) - 1));
  const summary = record(output.summary) ? output.summary : record(output.image) ? output.image
    : Object.fromEntries(Object.entries(output).filter(([, value]) => value == null || ["string", "number", "boolean"].includes(typeof value)));
  return <div>
    <dl className="workbench-metric-grid">{Object.entries(summary).map(([key, value]) => <div key={key}>
      <dt>{key.replaceAll("_", " ")}</dt><dd>{format(value)}</dd>
    </div>)}</dl>
    {output.units ? <p>Units: {format(output.units)}</p> : null}
    {Array.isArray(output.notes) ? <p>{output.notes.join(" ")}</p> : null}
    {rows.length ? <><div className="workbench-table"><table>
      <caption>{rows.length.toLocaleString()} observations</caption>
      <thead><tr>{columns.map((column) => <th key={column}>{column.replaceAll("_", " ")}</th>)}</tr></thead>
      <tbody>{rows.slice(actualPage * 100, (actualPage + 1) * 100).map((row, index) => <tr key={index}>
        {columns.map((column) => <td key={column}>{format(row[column])}</td>)}
      </tr>)}</tbody>
    </table></div>
      <div className="workbench-actions"><button className="cc-btn" disabled={!actualPage} onClick={() => setPage(actualPage - 1)}>Previous 100</button>
        <span>Page {actualPage + 1}</span><button className="cc-btn" disabled={(actualPage + 1) * 100 >= rows.length}
          onClick={() => setPage(actualPage + 1)}>Next 100</button></div>
    </> : null}
    <details onToggle={(event) => setRawVisible(event.currentTarget.open)}><summary>Complete values</summary>
      {rawVisible ? <pre className="workbench-plugin-output">{JSON.stringify(output, null, 2)}</pre> : null}</details>
  </div>;
}
