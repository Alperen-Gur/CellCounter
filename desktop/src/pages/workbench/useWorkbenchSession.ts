import { useCallback, useEffect, useRef, useState } from "react";
import { request } from "../../kernel/workbench/client";
import type { ProjectChanges, SessionNavigation, SessionSelection, WorkbenchSession } from "../../../../shared/workbench/sessionProtocol";
import { activeJobWorker, type JobWorker } from "../../../../shared/workbench/workerProtocol";
import type { TrainingJob } from "../../../../shared/workbench/modelProtocol";

type State = { path: string; projectId?: string; revision?: number; selection: SessionSelection; busy: boolean; blockedReason?: string; workers: JobWorker[]; trainingActive: boolean };
type NavigationDecision = { outcome: "applied" | "deferred" | "refused"; reason?: string; commit?: () => void };
type Props = {
  state: () => State;
  enqueue: (action: () => Promise<void>) => Promise<void>;
  observe: (changes: ProjectChanges, startedAt: number) => Promise<boolean>;
  workers: (workers: JobWorker[]) => void;
  activity: (value: { activeJobWorkers: JobWorker[]; activeTrainingJobs: TrainingJob[]; activeWorkerCount: number; activeTrainingJobCount: number }) => void;
  navigate: (navigation: SessionNavigation) => Promise<NavigationDecision>;
};
const selectionIdentity = (selection: SessionSelection) => JSON.stringify(Object.entries(selection).sort(([a], [b]) => a.localeCompare(b)));

/** One host observation loop for committed changes, workers and view sessions. */
export default function useWorkbenchSession(props: Props) {
  const latest = useRef(props); latest.current = props;
  const record = useRef<{ path: string; projectId: string; value: WorkbenchSession } | undefined>(undefined);
  const alive = useRef(true), inFlight = useRef(false);
  const [session, setSession] = useState<WorkbenchSession>();
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");
  const state = props.state();
  const remember = (path: string, projectId: string, value: WorkbenchSession) => {
    record.current = { path, projectId, value };
    if (alive.current) setSession(value);
  };
  const observe = useCallback(async () => {
    const initial = latest.current.state();
    if (inFlight.current || initial.busy || !initial.path || initial.revision === undefined || !initial.projectId) return;
    inFlight.current = true;
    try {
      await latest.current.enqueue(async () => {
        try {
          let active = latest.current.state();
          if (!alive.current || active.path !== initial.path || active.projectId !== initial.projectId || active.revision === undefined) return;
          const startedAt = performance.now();
          const changes = await request<ProjectChanges>(active.path, "project.changes", { afterRevision: active.revision, limit: 500 });
          if (!alive.current || latest.current.state().path !== active.path) return;
          if (changes.projectRevision !== active.revision || changes.resetRequired) {
            const adopted = await latest.current.observe(changes, startedAt);
            if (!alive.current) return;
            setNotice(adopted ? "" : `Saved project revision ${changes.projectRevision} is available. ${latest.current.state().blockedReason || "The current display will refresh when its active work settles."}`);
          } else setNotice("");
          active = latest.current.state();
          if (active.path !== initial.path || active.projectId !== initial.projectId || active.revision === undefined) return;
          if (active.workers.some(activeJobWorker) || active.trainingActive || changes.projectRevision !== initial.revision || changes.events.length) {
            const response = await request<Parameters<Props["activity"]>[0]>(active.path, "project.activity");
            if (alive.current && latest.current.state().path === active.path) latest.current.activity(response);
          }
          if (record.current && (record.current.path !== active.path || record.current.projectId !== active.projectId)) {
            const old = record.current;
            record.current = undefined;
            // Closing is coordination metadata only. A competing session edit
            // can prevent this best-effort close without changing any science.
            try { await request(old.path, "session.close", { sessionId: old.value.id, expectedSessionRevision: old.value.sessionRevision }); } catch { /* closed/stale records remain explicitly self-declared */ }
          }
          let value: WorkbenchSession;
          if (!record.current || record.current.value.closed) {
            value = (await request<{ session: WorkbenchSession }>(active.path, "session.open", { name: "CellCounter Windows workbench", clientKind: "desktop" })).session;
          } else {
            value = (await request<{ session: WorkbenchSession }>(active.path, "session.get", { sessionId: record.current.value.id })).session;
          }
          if (!alive.current || latest.current.state().path !== active.path) return;
          remember(active.path, active.projectId!, value);
          const navigation = value.navigation;
          if (navigation && ["pending", "deferred"].includes(navigation.status)) {
            const now = latest.current.state();
            const projectRevision = value.projectRevision ?? changes.projectRevision;
            let outcome: NavigationDecision;
            const taskOnly = Boolean(navigation.selection.task) && Object.keys(navigation.selection).every(key => key === "task");
            if ((!taskOnly && now.blockedReason) || now.revision !== projectRevision) {
              outcome = { outcome: "deferred", reason: now.blockedReason || "Waiting for the current saved project revision before applying navigation." };
            } else if (navigation.observedProjectRevision !== projectRevision) {
              outcome = { outcome: "refused", reason: "The project changed after this navigation request. Inspect the current project and request navigation again." };
            } else outcome = await latest.current.navigate(navigation);
            if (outcome.outcome !== "deferred" || navigation.status !== "deferred" || navigation.reason !== outcome.reason) {
              const { commit, ...acknowledgement } = outcome;
              value = (await request<{ session: WorkbenchSession }>(active.path, "session.navigation.ack", {
                sessionId: value.id, expectedSessionRevision: value.sessionRevision, navigationId: navigation.id,
                observedProjectRevision: projectRevision, ...acknowledgement,
              })).session;
              if (alive.current && latest.current.state().path === active.path) {
                remember(active.path, active.projectId!, value);
                if (value.navigation?.id === navigation.id && value.navigation.status === "applied") commit?.();
              }
            }
            setError("");
            return; // React applies selection state before the next publication.
          }
          const now = latest.current.state();
          if (now.revision === (value.projectRevision ?? changes.projectRevision) &&
            (value.observedProjectRevision !== now.revision || selectionIdentity(value.selection) !== selectionIdentity(now.selection))) {
            value = (await request<{ session: WorkbenchSession }>(active.path, "session.update", {
              sessionId: value.id, expectedSessionRevision: value.sessionRevision,
              observedProjectRevision: now.revision, selection: now.selection,
            })).session;
            if (alive.current && latest.current.state().path === active.path) remember(active.path, active.projectId!, value);
          }
          if (alive.current) setError("");
        } catch (cause) {
          if (alive.current) setError(cause instanceof Error ? cause.message : String(cause));
        }
      });
    } finally { inFlight.current = false; }
  }, []);
  useEffect(() => {
    alive.current = true;
    let active = true;
    let timer: ReturnType<typeof setTimeout>;
    const poll = async () => {
      await observe();
      if (active) timer = setTimeout(() => void poll(), 5000);
    };
    const focus = () => { void observe(); };
    void poll();
    window.addEventListener("focus", focus);
    return () => { active = false; clearTimeout(timer); window.removeEventListener("focus", focus); };
  }, [state.path, state.projectId, observe]);
  useEffect(() => () => {
    alive.current = false;
    const old = record.current;
    if (old) void request(old.path, "session.close", { sessionId: old.value.id, expectedSessionRevision: old.value.sessionRevision }).catch(() => undefined);
  }, []);
  return { session: record.current?.projectId === state.projectId ? session : undefined, notice, error, observe };
}
