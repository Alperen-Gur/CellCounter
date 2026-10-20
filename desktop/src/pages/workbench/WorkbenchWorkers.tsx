import { useEffect, useRef, useState } from "react";
import type { ProjectSnapshot } from "../../../../shared/workbench/protocol";
import { activeJobWorker, workerTargetId, workerTargetKind, type JobWorker } from "../../../../shared/workbench/workerProtocol";
import ScientificOutput from "./ScientificOutput";
import { useCataloguePins } from "./WorkbenchCatalogueBrowser";
import type { CataloguePage } from "../../../../shared/workbench/catalogueProtocol";

type Props = { snapshot: ProjectSnapshot; busy: boolean;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  act: (operation: string, args: Record<string, unknown>) => Promise<void>;
  stop: (workerId: string) => Promise<void>;
  onProgress: (workers: JobWorker[]) => void };

export default function WorkbenchWorkers({ snapshot, busy, read, act, stop, onProgress }: Props) {
  const [workers, setWorkers] = useState<JobWorker[]>(snapshot.jobWorkers ?? []);
  const [jobId, setJobId] = useState("");
  const [error, setError] = useState("");
  const [stopping, setStopping] = useState("");
  const [refreshing, setRefreshing] = useState(false);
  const pinError = useCataloguePins([{ catalogue: "jobs", entryId: jobId }]);
  const epoch = useRef(0);
  const readInFlight = useRef(false);
  const latest = useRef({ read, onProgress, busy });
  latest.current = { read, onProgress, busy };
  const jobs = (snapshot.jobs ?? []).filter((job) => ["pending", "running"].includes(job.status));
  const running = workers.some(activeJobWorker);
  useEffect(() => {
    epoch.current++;
    setRefreshing(false); setStopping("");
    setWorkers(snapshot.jobWorkers ?? []);
    setJobId((id) => id || jobs[0]?.id || "");
    return () => { epoch.current++; };
  }, [snapshot.project.revision, snapshot.jobWorkers]);
  const load = async () => {
    if (readInFlight.current) return;
    readInFlight.current = true; setRefreshing(true);
    const generation = epoch.current;
    try {
      const activity = await latest.current.read<{ activeJobWorkers: JobWorker[] }>("project.activity");
      const result = await latest.current.read<CataloguePage<JobWorker>>("project.catalogue", { catalogue: "jobWorkers", limit: 25 });
      if (epoch.current === generation) {
        const values = [...new Map([...result.entries, ...activity.activeJobWorkers].map(item => [item.workerId, item])).values()];
        setWorkers(values); setError(""); latest.current.onProgress(values);
      }
    } catch (cause) { if (epoch.current === generation) setError(String(cause)); }
    finally { readInFlight.current = false; if (epoch.current === generation) setRefreshing(false); }
  };
  // The host's single project/session observation loop supplies worker updates.
  // Manual refresh and stop keep using this same canonical read operation.
  const requestStop = async (workerId: string) => {
    const generation = epoch.current; setStopping(workerId); setError("");
    try {
      await stop(workerId);
      if (generation === epoch.current) await load();
    } catch (cause) { if (generation === epoch.current) setError(String(cause)); }
    finally { if (generation === epoch.current) setStopping(""); }
  };
  return <section aria-label="Background execution">
    <h3>Background execution</h3>
    <p>A local worker advances saved checkpoints while the app is closed. One worker owns a project at a time.
      Stop requests pause after the current step; completed work stays saved.</p>
    <p>Start a whole parameter sweep from its sweep card, a result refresh from Measurements, or tiled processing from Images &amp; preparation. Individual saved batches use the selector below.</p>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    {pinError ? <p className="workbench-error" role="alert">{pinError}</p> : null}
    <fieldset disabled={busy}>
      <label>Saved batch<select value={jobId} onChange={(event) => setJobId(event.target.value)}>
        {!jobs.length ? <option value="">Create or resume a batch first</option> : null}
        {jobs.map((job) => <option key={job.id} value={job.id}>{job.name || job.workflow.name}</option>)}
      </select></label>
      <div className="workbench-actions">
        <button className="cc-btn" disabled={running || !jobs.some(job => job.id === jobId)} onClick={() => void act("job.worker.start", { jobId })}>Run batch in background</button>
        <button className="cc-btn" disabled={refreshing} onClick={() => void load()}>Refresh worker progress</button>
      </div>
    </fieldset>
    {running ? <p role="status">A worker is active. Saved scientific views refresh after it finishes; progress updates every five seconds.</p> : null}
    <ul className="workbench-jobs">{workers.slice(-30).reverse().map((worker) => {
      const kind = workerTargetKind(worker);
      const id = workerTargetId(worker);
      const name = (kind === "tiled-analysis" ? snapshot.tiledAnalyses?.find((analysis) => analysis.id === id)?.name : kind === "sweep" ? snapshot.sweeps?.find((sweep) => sweep.id === id)?.name
        : kind === "refresh" ? snapshot.refreshJobs?.find((job) => job.id === id)?.name : snapshot.jobs?.find((job) => job.id === id)?.name) || id;
      const targetStatus = worker.targetStatus ?? worker.analysisStatus ?? worker.refreshStatus ?? worker.sweepStatus ?? worker.jobStatus;
      const targetLabel = kind === "tiled-analysis" ? "Tiled analysis" : kind === "sweep" ? "Whole sweep" : kind === "refresh" ? "Result refresh" : "Batch";
      return <li key={worker.workerId}>
      <strong>{targetLabel} · {name}</strong>
      <span>{worker.status}{worker.lastRevision == null ? "" : ` · revision ${worker.lastRevision}`}</span>
      {targetStatus ? <small>{targetLabel} status: {targetStatus}</small> : null}
      {worker.progress ? <div>
        <p>{worker.progress.completed.toLocaleString()} / {worker.progress.total.toLocaleString()} saved checkpoints</p>
        <progress aria-label={`${name} background progress`} value={worker.progress.completed} max={worker.progress.total || 1} />
      </div> : null}
      {worker.heartbeatAt ? <small>Last heartbeat: {worker.heartbeatAt}</small> : null}
      {worker.reason ? <p>{worker.reason}</p> : null}
      {worker.error ? <p className="workbench-error">{worker.error.message}</p> : null}
      {worker.lastUnit ? <ScientificOutput output={worker.lastUnit} /> : null}
      {activeJobWorker(worker) ? <button className="cc-btn" disabled={Boolean(stopping) || worker.stopRequested}
        onClick={() => void requestStop(worker.workerId)}>{worker.stopRequested || stopping === worker.workerId ? "Stop requested" : "Stop after current step"}</button> : null}
    </li>; })}</ul>
  </section>;
}
