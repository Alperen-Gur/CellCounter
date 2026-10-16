import { useRef, useState, useSyncExternalStore } from "react";
import { buildLocalDiagnostics, diagnosticExportAllowed, DIAGNOSTICS_FILENAME, type DiagnosticSnapshot } from "../../../../shared/diagnostics/report";
import "../../../../shared/diagnostics/panel.css";
import { startLocalPerformance, stopLocalPerformance, clearLocalPerformance, localPerformanceActive, subscribeLocalPerformance, localPerformanceReport } from "../../../../shared/diagnostics/performance";
import packageInfo from "../../../package.json";

export function LocalDiagnosticsPanel({ readSnapshot }: { readSnapshot(): DiagnosticSnapshot }) {
  const active = useSyncExternalStore(subscribeLocalPerformance, localPerformanceActive);
  const [sessionMinutes, setSessionMinutes] = useState(30);
  const [includePerformance, setIncludePerformance] = useState(false);
  const [includeState, setIncludeState] = useState(false);
  const [draft, setDraft] = useState<string>();
  const [reviewed, setReviewed] = useState(false);
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState("");
  const savingRef = useRef(false);
  const generate = () => {
    if (savingRef.current) return;
    try {
      setDraft(buildLocalDiagnostics("windows", packageInfo.version, includeState ? readSnapshot() : undefined) + (includePerformance ? "\n" + localPerformanceReport() + "\n" : ""));
      setReviewed(false); setMessage("");
    } catch { setMessage("Could not prepare the snapshot. Try again with optional state disabled."); }
  };
  const save = async () => {
    if (savingRef.current || !reviewed || draft === undefined || !diagnosticExportAllowed(draft)) return;
    const text = draft; // Export exactly the reviewed text, never regenerate after the picker.
    savingRef.current = true; setSaving(true); setMessage("");
    try {
      const { save: chooseFile } = await import("@tauri-apps/plugin-dialog");
      const destination = await chooseFile({ defaultPath: DIAGNOSTICS_FILENAME, filters: [{ name: "Plain text", extensions: ["txt"] }] });
      if (!destination) { setMessage("Export cancelled. Nothing was saved."); return; }
      const { writeTextFile } = await import("@tauri-apps/plugin-fs");
      await writeTextFile(destination, text);
      setMessage("Reviewed text saved. Nothing was uploaded.");
    } catch { setMessage("Could not save the report. The editable draft is still available; choose a writable destination and retry."); }
    finally { savingRef.current = false; setSaving(false); }
  };
  return <section className="local-diagnostics" aria-labelledby="diagnostics-title">
    <h2 id="diagnostics-title">Local diagnostics</h2>
    <p>Prepare a report only when you choose. Performance recording requires a separate opt-in; nothing is uploaded. The basic report contains only the app version and platform. Images, measurements, names, paths, identifiers, logs and crash dumps are excluded.</p>
    <h3>Benchmark real workflows</h3>
    <p>Start a session, then use your real images and normal analysis, queue, review and export controls. Return here to stop and prepare a report. Only fixed operation categories and aggregate timings are recorded, in memory, for the session limit you choose. A crash or app exit loses unsaved results.</p>
    <p role="status">{active ? "Real-workflow timing is recording." : "Timing is stopped. No new timings are collected."}</p>
    <label>Session limit <select value={sessionMinutes} disabled={active || saving} onChange={event => setSessionMinutes(Number(event.target.value))}><option value={10}>10 minutes</option><option value={30}>30 minutes</option><option value={120}>2 hours</option></select></label>
    <button type="button" disabled={active || saving} onClick={() => startLocalPerformance(sessionMinutes)}>Start real-workflow benchmark</button>
    <button type="button" disabled={!active || saving} onClick={stopLocalPerformance}>Stop recording</button>
    <button type="button" disabled={saving} onClick={() => { clearLocalPerformance(); setDraft(undefined); setReviewed(false); setMessage("Recorded timings and draft erased."); }}>Erase timings and draft</button>
    <p>No synthetic data or automatic reruns are used. Normal analysis still uses your chosen settings and may save normal results. Timing summaries can reveal workload characteristics; inspect them before sharing. Prepared reports are snapshots and do not update automatically.</p>
    {draft === undefined ? <>
      <label><input type="checkbox" checked={includeState} onChange={event => setIncludeState(event.target.checked)} />Include optional state summary (approximate counts and status flags)</label>
      <label><input type="checkbox" checked={includePerformance} onChange={event => setIncludePerformance(event.target.checked)} />Include recorded real-workflow timings</label>
      <button type="button" onClick={generate}>Prepare preview</button>
    </> : <>
      <p>Remove any lines or edit the text below. Only this text will be exported. Anything you add may contain personal information; review it before sharing. Counts describe cached state, not a crash trace.</p>
      <label htmlFor="diagnostics-draft">Report preview — editable and redactable</label>
      <textarea id="diagnostics-draft" value={draft} maxLength={65536} disabled={saving} spellCheck={false} autoComplete="off" autoCorrect="off" autoCapitalize="off" onChange={event => { setDraft(event.target.value); setReviewed(false); setMessage(""); }} />
      {!diagnosticExportAllowed(draft) && <p role="alert">The report must contain text and fit within 64 KiB.</p>}
      <label><input type="checkbox" checked={reviewed} disabled={saving} onChange={event => setReviewed(event.target.checked)} />I have inspected this text and removed anything I do not want to share.</label>
      <button type="button" disabled={saving || !reviewed || !diagnosticExportAllowed(draft)} onClick={() => void save()}>{saving ? "Saving…" : "Export reviewed text…"}</button>
      <button type="button" disabled={saving} onClick={() => { setDraft(undefined); setReviewed(false); setMessage(""); }}>Discard draft</button>
      <p>The editable draft is kept only in memory until you export. Sharing is a separate choice after export; your chosen destination or browser download folder may be synced by other software.</p>
    </>}
    {message && <p role="status">{message}</p>}
  </section>;
}

export function LocalTimingIndicator() {
  const active = useSyncExternalStore(subscribeLocalPerformance, localPerformanceActive);
  return active ? <button type="button" className="local-timing-indicator" onClick={stopLocalPerformance}>Local timing is recording · Stop</button> : null;
}
