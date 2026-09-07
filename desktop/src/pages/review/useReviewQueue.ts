import { useCallback, useEffect, useMemo, useState, useSyncExternalStore } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useAppStore } from "../../kernel/store/store";
import { ReviewSession, type ReviewAction, type ReviewContext, type ReviewItem, type ReviewPage, type ReviewDecisionOutcome } from "./reviewSession";

export type { ReviewItem } from "./reviewSession";

export function useReviewQueue() {
  const refreshLibraryStats = useAppStore((s) => s.refreshLibraryStats);
  const session = useMemo(() => new ReviewSession({
    page: (after) => invoke<ReviewPage>("review_page", { after, limit: 64 }),
    decide: (item, action, diameterUm) => invoke<ReviewDecisionOutcome>("review_decision", {
      detectionId: item.detectionId, cellId: item.cell.id, action, diameterUm: diameterUm ?? null,
    }),
    undo: (token) => invoke<void>("review_undo", { token }),
  }), []);
  const state = useSyncExternalStore(session.subscribe, session.getSnapshot);
  const [contexts, setContexts] = useState<Record<string, ReviewContext>>({});
  const [contextError, setContextError] = useState<string | null>(null);
  const [contextAttempt, setContextAttempt] = useState(0);
  const current = state.restored ?? state.items[state.index] ?? null;
  const next = state.items[state.index + (state.restored ? 0 : 1)] ?? null;

  useEffect(() => {
    void session.start();
    return () => session.dispose();
  }, [session]);

  // Geometry belongs only to the current/peek cards, never to the whole page.
  // Cancelled effects cannot resurrect contours after navigation or unmount.
  useEffect(() => {
    let alive = true;
    setContextError(null);
    setContexts({});
    const visible = [current, next].filter((item): item is ReviewItem => item !== null);
    void Promise.all(visible.map(async (item) => {
      const context = await invoke<ReviewContext | null>("review_context", {
        detectionId: item.detectionId, cellId: item.cell.id,
      });
      return [item.key, context] as const;
    })).then((entries) => {
      if (alive) setContexts(Object.fromEntries(entries.filter((entry) => entry[1] !== null)) as Record<string, ReviewContext>);
    }).catch((error: unknown) => {
      if (alive) setContextError(String(error));
    });
    return () => { alive = false; };
  }, [current, next, contextAttempt]);

  const hydrated = (item: ReviewItem | null): ReviewItem | null => {
    if (!item) return null;
    const context = contexts[item.key];
    return context ? { ...item, cell: context.cell, neighbors: context.neighbors, contextLimited: context.limited } : item;
  };
  const decide = useCallback(async (action: ReviewAction, diameterUm?: number) => {
    if (await session.decide(action, diameterUm)) await refreshLibraryStats().catch(() => {});
  }, [session, refreshLibraryStats]);
  const undo = useCallback(async () => {
    if (await session.undo()) await refreshLibraryStats().catch(() => {});
  }, [session, refreshLibraryStats]);

  return {
    current: hydrated(current), next: hydrated(next),
    cursor: state.visited,
    totalPending: state.totalPending,
    skipped: state.skipped,
    loading: state.loading,
    saving: state.saving,
    error: state.error,
    pageError: state.pageError,
    notice: state.notice,
    canUndo: state.undo !== null,
    undo,
    contextError,
    retryContext: () => setContextAttempt((attempt) => attempt + 1),
    retryPage: session.retryPage,
    reject: () => decide("reject"),
    keep: () => decide("keep"),
    editDiameter: (diameterUm: number) => decide("resize", diameterUm),
    skip: () => { void session.skip(); },
  };
}
