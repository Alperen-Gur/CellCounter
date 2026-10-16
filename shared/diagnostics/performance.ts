/** Opt-in timings of real application work. No arguments, output, errors or IDs are retained. */
export const OPERATIONS = ["image.import", "image.decode", "image.source", "storage.read", "storage.write", "queue.load", "queue.save", "queue.process", "analysis.inference", "analysis.assay", "review.load", "review.save", "workspace.compute", "export.prepare", "ui.render", "ui.frame", "ui.event-loop"] as const;
export type LocalOperation = typeof OPERATIONS[number];
interface Metric { count: number; dropped: number; failures: number; total: number; min: number; max: number; samples: number[] }
const metrics = new Map<LocalOperation, Metric>();
const inFlight = new Map<LocalOperation, number>();
const listeners = new Set<() => void>();
let generation = 0, active = false, started = 0, elapsed = 0, limitMs = 1_800_000;
let cleanup: (() => void) | undefined;
const now = () => performance.now();
const emit = () => { for (const listener of listeners) listener(); };
export const subscribeLocalPerformance = (listener: () => void) => { listeners.add(listener); return () => { listeners.delete(listener); }; };
export const localPerformanceActive = () => active;

export function stopLocalPerformance(): void {
  if (!active) return;
  elapsed = Math.min(limitMs, Math.max(0, now() - started)); active = false;
  cleanup?.(); cleanup = undefined; emit();
}
export function clearLocalPerformance(): void {
  stopLocalPerformance(); generation++; metrics.clear(); inFlight.clear(); elapsed = 0; emit();
}
export function startLocalPerformance(minutes = 30): void {
  limitMs = ([10, 30, 120].includes(minutes) ? minutes : 30) * 60_000;
  clearLocalPerformance(); active = true; started = now(); emit();
  let previousFrame: number | undefined, frame = 0, expected = now() + 250;
  const token = generation;
  const record = (operation: LocalOperation, ms: number) => add(operation, ms, true, token);
  const tick = (time: number) => {
    if (!active || token !== generation) return;
    if (document.visibilityState === "visible") {
      if (previousFrame !== undefined) record("ui.frame", time - previousFrame);
      previousFrame = time;
    } else previousFrame = undefined;
    if (active && token === generation) frame = requestAnimationFrame(tick);
  };
  frame = requestAnimationFrame(tick);
  const interval = window.setInterval(() => {
    const current = now();
    if (document.visibilityState === "visible") record("ui.event-loop", Math.max(0, current - expected));
    expected = current + 250;
  }, 250);
  const visibility = () => { previousFrame = undefined; expected = now() + 250; };
  document.addEventListener("visibilitychange", visibility);
  const timeout = window.setTimeout(stopLocalPerformance, limitMs);
  cleanup = () => { cancelAnimationFrame(frame); clearInterval(interval); clearTimeout(timeout); document.removeEventListener("visibilitychange", visibility); };
}
function add(operation: LocalOperation, ms: number, success: boolean, token: number): void {
  if (!active || token !== generation || !OPERATIONS.includes(operation) || !Number.isFinite(ms) || ms < 0) return;
  if (now() - started > limitMs) { stopLocalPerformance(); return; }
  const value = Math.min(ms, limitMs), metric = metrics.get(operation) ?? { count: 0, dropped: 0, failures: 0, total: 0, min: Infinity, max: 0, samples: [] };
  if (metric.count >= 100_000) { metric.dropped++; return; }
  metric.count++; if (!success) metric.failures++; metric.total += value;
  metric.min = Math.min(metric.min, value); metric.max = Math.max(metric.max, value);
  // Bounded recent window for the approximate p95; full-session mean/min/max.
  metric.samples[(metric.count - 1) % 256] = value; metrics.set(operation, metric);
}
export function beginLocalTiming(operation: LocalOperation): (success?: boolean) => void {
  if (!active || !OPERATIONS.includes(operation)) return () => {};
  const token = generation, start = now(); let ended = false;
  inFlight.set(operation, (inFlight.get(operation) ?? 0) + 1);
  return (success = true) => { if (!ended) { ended = true;
    if (active && token === generation) inFlight.set(operation, Math.max(0, (inFlight.get(operation) ?? 1) - 1));
    add(operation, now() - start, success, token);
  } };
}
export async function timeLocalOperation<T>(operation: LocalOperation, work: () => Promise<T>): Promise<T> {
  if (!active) return work();
  const end = beginLocalTiming(operation);
  try { const value = await work(); end(true); return value; }
  catch (error) { end(false); throw error; }
}
export function localPerformanceReport(): string {
  if (active && now() - started >= limitMs) stopLocalPerformance();
  const duration = active ? Math.max(0, now() - started) : elapsed;
  const lines = ["Optional real-workflow timing session · format 1", `Session: ${active ? "running (snapshot only)" : "stopped"}`, `Observed duration, seconds: ${Math.round(Math.min(limitMs, duration) / 1000)}`,
    "Real operations only; no synthetic workloads or automatic reanalysis.",
    "Timings include scheduling, waiting and cache effects. Nested operations overlap; totals must not be added.",
    "Failures include rejected or cancelled operations. Inputs and settings may differ between observations.",
    "At most 100,000 completed observations per category are retained; omitted observations are counted explicitly.",
    "Recording adds overhead. ui.frame measures foreground animation-callback spacing; ui.render measures composition, not GPU kernel time.",
    "p95 uses at most 256 recent retained observations; other statistics cover all retained observations.",
    "No timestamps, event order, image data, names, paths, IDs, hardware identifiers or error text are recorded.",
    "Unobserved operations are listed explicitly. A missing sample is not a zero-time measurement.", "", "operation | retained completed | omitted | failures | unfinished at snapshot/stop | mean ms | min ms | max ms | recent p95 ms"];
  for (const operation of OPERATIONS) {
    const metric = metrics.get(operation);
    if (!metric) { lines.push(`${operation} | not completed | unfinished: ${inFlight.get(operation) ?? 0}`); continue; }
    const sorted = [...metric.samples].sort((a, b) => a - b);
    const p95 = sorted[Math.max(0, Math.ceil(sorted.length * .95) - 1)];
    lines.push(`${operation} | ${metric.count} | ${metric.dropped} | ${metric.failures} | ${inFlight.get(operation) ?? 0} | ${(metric.total / metric.count).toFixed(1)} | ${metric.min.toFixed(1)} | ${metric.max.toFixed(1)} | ${p95.toFixed(1)}`);
  }
  const ranked = [...metrics.entries()].filter(([operation, metric]) => !operation.startsWith("ui.") && metric.count > 0).sort((a, b) => b[1].total / b[1].count - a[1].total / a[1].count).slice(0, 3);
  lines.push("", "Highest observed mean latency (overlapping categories, not a causal diagnosis):");
  if (!ranked.length) lines.push("No completed real operations were observed.");
  for (const [operation, metric] of ranked) lines.push(`${operation}: ${(metric.total / metric.count).toFixed(1)} ms mean across ${metric.count} operations`);
  const inference = metrics.get("analysis.inference");
  if (inference && !inference.dropped && duration > 0) lines.push(`Successful inference operations per session minute (includes idle time): ${((inference.count - inference.failures) / (duration / 60_000)).toFixed(2)}`);
  const loop = metrics.get("ui.event-loop");
  if (loop && loop.max > 100) lines.push("Main-loop delays exceeded 100 ms while foregrounded; correlate with real work before drawing conclusions.");
  lines.push("", "A crash ends the session; unsaved diagnostics are not recoverable. Timings measure performance, not segmentation accuracy.");
  return lines.join("\n");
}
