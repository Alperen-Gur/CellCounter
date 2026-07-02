/**
 * pages/home/HomePage.tsx — the Home screen (feat-home-import).
 *
 * The app's entry point: a drag-and-drop target with "Choose images…" /
 * "Choose folder…" CTAs and a Recent list. Dropping or choosing images kicks off
 * the import → dedup → detect pipeline in `importFlow`, which drives the store's
 * ProcessingSlice and routes to /results.
 *
 * This component owns gestures + layout only; all orchestration lives in
 * `importFlow.ts` and all data reads go through the frozen ports. It routes via
 * the shell's dependency-free `navigate` (never importing a sibling page).
 *
 * Boundaries (docs/tasks.json feat-home-import): owns pages/home/ only; does not
 * render the Processing screen, the batch table, or export.
 */

import { useCallback, useEffect, useRef, useState } from "react";

import { useAppStore } from "../../kernel/store/store";
import { navigate as shellNavigate } from "../../components/useHashRoute";
import type { RouteId } from "../../components/routes";
import { Icon } from "../../components/Icon";

import {
  importAndAnalyze,
  isImporting,
  type DuplicateSession,
  type DuplicateDecision,
  type ImportFlowHooks,
} from "./importFlow";
import {
  subscribeFileDrop,
  chooseImages,
  chooseFolder,
  isPickerAvailable,
  isTauri,
} from "./fileSources";
import { useRecents, relativeDate, type RecentRow } from "./useRecents";
import { DuplicatePrompt } from "./DuplicatePrompt";

import "./home.css";

// A pending duplicate prompt: the session + the promise resolver the flow waits
// on. Resolving with a decision map proceeds; resolving with null cancels.
interface PendingDuplicate {
  session: DuplicateSession;
  resolve: (
    decisions: Record<string, DuplicateDecision> | null,
  ) => void;
}

export default function HomePage() {
  const activeModelId = useAppStore((s) => s.activeModelId);
  const showDetectionError = useAppStore((s) => s.showDetectionError);
  const lastDetectionError = useAppStore((s) => s.lastDetectionError);
  const dismissDetectionError = useAppStore((s) => s.dismissDetectionError);

  const [isOver, setIsOver] = useState(false);
  const [busy, setBusy] = useState(false);
  const [pickerAvailable, setPickerAvailable] = useState<boolean | null>(null);
  const [pending, setPending] = useState<PendingDuplicate | null>(null);

  const { rows } = useRecents();

  // `navigate` accepts our narrowed route ids; widen to RouteId for the shell.
  const go = useCallback(
    (id: "processing" | "results" | "home") => {
      shellNavigate(id as RouteId);
    },
    [],
  );

  // The flow's hooks: routing + the duplicate handshake (a promise the prompt
  // resolves). Kept in a ref so the drop subscription always sees the latest.
  const hooksRef = useRef<ImportFlowHooks>({
    navigate: go,
    onDuplicates: () => Promise.resolve({}),
    onImportError: (path, message) =>
      console.warn(`[home] import failed for ${path}: ${message}`),
  });
  hooksRef.current = {
    navigate: go,
    onDuplicates: (session) =>
      new Promise<Record<string, DuplicateDecision> | null>((resolve) => {
        setPending({ session, resolve });
      }),
    onImportError: (path, message) =>
      console.warn(`[home] import failed for ${path}: ${message}`),
  };

  // Probe once whether the native picker is available (plugin-dialog present).
  useEffect(() => {
    let alive = true;
    void isPickerAvailable().then((ok) => {
      if (alive) setPickerAvailable(ok);
    });
    return () => {
      alive = false;
    };
  }, []);

  // Synchronous in-flight guard covering the WHOLE flow (import + duplicate
  // prompt + detect). `isImporting()` only turns true once detection starts, so
  // it wouldn't stop a second drop landing while the duplicate prompt is open;
  // this ref closes that window.
  const inFlightRef = useRef(false);

  const runImport = useCallback(async (paths: string[]) => {
    if (paths.length === 0) return;
    if (inFlightRef.current || isImporting()) return; // one run at a time
    inFlightRef.current = true;
    setBusy(true);
    try {
      await importAndAnalyze(paths, hooksRef.current, useAppStore);
    } finally {
      inFlightRef.current = false;
      setBusy(false);
    }
  }, []);

  // Subscribe to native file drops for the lifetime of the page.
  useEffect(() => {
    const unsub = subscribeFileDrop({
      onEnter: () => setIsOver(true),
      onLeave: () => setIsOver(false),
      onDrop: (paths) => {
        setIsOver(false);
        void runImport(paths);
      },
    });
    return unsub;
  }, [runImport]);

  const onChooseImages = useCallback(async () => {
    const paths = await chooseImages();
    if (paths === null) {
      // No picker in this build — nudge toward drag-and-drop.
      useAppStore
        .getState()
        .setDetectionError(
          "The file picker isn't available in this build yet — drag images onto the drop zone instead.",
        );
      return;
    }
    await runImport(paths);
  }, [runImport]);

  const onChooseFolder = useCallback(async () => {
    const paths = await chooseFolder();
    if (paths === null) {
      useAppStore
        .getState()
        .setDetectionError(
          "The folder picker isn't available in this build yet — drag a folder onto the drop zone instead.",
        );
      return;
    }
    await runImport(paths);
  }, [runImport]);

  const openRecent = useCallback((row: RecentRow) => {
    if (row.imageCount === 0) return;
    useAppStore.getState().openBatch(row.batch.id);
    shellNavigate("results" as RouteId);
  }, []);

  const resolvePending = useCallback(
    (decisions: Record<string, DuplicateDecision> | null) => {
      pending?.resolve(decisions);
      setPending(null);
    },
    [pending],
  );

  const ctaDisabled = busy || pickerAvailable === false;

  return (
    <div className="home">
      <section
        className={"home-drop" + (isOver ? " home-drop--over" : "")}
        aria-label="Drop microscope images to analyze"
      >
        <div className="home-drop__art" aria-hidden="true">
          <PetriDish over={isOver} />
        </div>

        <h1 className="home-drop__title">Drop microscope images here</h1>
        <p className="home-drop__sub">
          One image, a folder, or a whole batch — we&apos;ll detect and size
          every cell.
        </p>

        <div className="home-drop__cta">
          <button
            type="button"
            className="cc-btn home-btn--primary home-btn--lg"
            onClick={() => void onChooseImages()}
            disabled={ctaDisabled}
            title={
              pickerAvailable === false
                ? "File picker unavailable — drag images onto the drop zone."
                : "Pick one or more images to analyze."
            }
          >
            {busy ? "Working…" : "Choose images…"}
          </button>
          <button
            type="button"
            className="cc-btn home-btn--lg"
            onClick={() => void onChooseFolder()}
            disabled={ctaDisabled}
            title={
              pickerAvailable === false
                ? "Folder picker unavailable — drag a folder onto the drop zone."
                : "Pick a folder of images to analyze."
            }
          >
            Choose folder…
          </button>
        </div>

        {!isTauri() && (
          <div className="home-drop__hint">
            Running in preview — drag-and-drop and detection are available inside
            the desktop app.
          </div>
        )}
      </section>

      <section className="home-actions" aria-label="Quick actions">
        <button type="button" className="home-card" onClick={() => shellNavigate("onboarding" as RouteId)}>
          <span className="home-card__icon"><Icon name="calibrate" size={20} /></span>
          <span className="home-card__title">Calibrate scale</span>
          <span className="home-card__sub">px · µm</span>
        </button>
        <button type="button" className="home-card" onClick={() => shellNavigate("models" as RouteId)}>
          <span className="home-card__icon"><Icon name="models" size={20} /></span>
          <span className="home-card__title">
            {activeModelId === "cp-cyto3" ? "Cellpose cyto3" : activeModelId}
          </span>
          <span className="home-card__sub">Active model</span>
        </button>
        <button type="button" className="home-card" onClick={() => shellNavigate("finetune" as RouteId)}>
          <span className="home-card__icon"><Icon name="finetune" size={20} /></span>
          <span className="home-card__title">Fine-tune…</span>
          <span className="home-card__sub">Train on your cells</span>
        </button>
        <button type="button" className="home-card" onClick={() => shellNavigate("settings" as RouteId)}>
          <span className="home-card__icon"><Icon name="settings" size={20} /></span>
          <span className="home-card__title">Settings</span>
          <span className="home-card__sub">Bins, palette, paths</span>
        </button>
      </section>

      <section className="home-recent" aria-label="Recent analyses">
        <div className="home-recent__head">
          <span className="home-recent__title">RECENT</span>
          {rows.length > 0 && (
            <button
              type="button"
              className="home-recent__all"
              onClick={() => shellNavigate("library" as RouteId)}
            >
              Show all
            </button>
          )}
        </div>

        {rows.length === 0 ? (
          <div className="home-recent__empty">
            <div className="home-recent__empty-title">No analyses yet</div>
            <div className="home-recent__empty-sub">
              Drop an image or folder above to get started.
            </div>
          </div>
        ) : (
          <ul className="home-recent__list">
            {rows.map((row) => (
              <li key={row.batch.id}>
                <button
                  type="button"
                  className="home-recent__row"
                  onClick={() => openRecent(row)}
                >
                  <span className="home-recent__thumb">
                    {row.thumbSrc ? (
                      <img src={row.thumbSrc} alt="" />
                    ) : (
                      <span
                        className="home-recent__thumb-fallback"
                        aria-hidden="true"
                      >
                        <Icon name="scope" size={20} />
                      </span>
                    )}
                  </span>
                  <span className="home-recent__body">
                    <span className="home-recent__name">
                      {row.batch.displayName}
                    </span>
                    <span className="home-recent__meta">
                      {row.cellCount} cells · {row.imageCount}{" "}
                      {row.imageCount === 1 ? "image" : "images"}
                    </span>
                  </span>
                  <span className="home-recent__count">{row.cellCount}</span>
                  <span className="home-recent__when">
                    {relativeDate(row.batch.createdAt)}
                  </span>
                </button>
              </li>
            ))}
          </ul>
        )}
      </section>

      {pending && (
        <DuplicatePrompt
          session={pending.session}
          onConfirm={(decisions) => resolvePending(decisions)}
          onCancel={() => resolvePending(null)}
        />
      )}

      {showDetectionError && (
        <div
          className="home-error"
          role="alertdialog"
          aria-label="Detection failed"
        >
          <div className="home-error__card">
            <div className="home-error__title">Something went wrong</div>
            <div className="home-error__msg">
              {lastDetectionError ?? "Unknown error."}
            </div>
            <div className="home-error__foot">
              <button
                type="button"
                className="cc-btn home-btn--primary"
                onClick={() => dismissDetectionError()}
              >
                OK
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Petri-dish illustration (SVG port of HomeView.PetriDishIllustration)
// ---------------------------------------------------------------------------

function PetriDish({ over }: { over: boolean }) {
  const dots: Array<[number, number, number, number]> = [
    [0.32, 0.24, 6, 0.7],
    [0.58, 0.38, 4, 0.5],
    [0.28, 0.55, 5, 0.6],
    [0.62, 0.62, 6, 0.65],
    [0.48, 0.45, 7, 0.55],
    [0.72, 0.3, 4, 0.45],
  ];
  const size = 110;
  const fill = over ? "var(--cc-bin-large)" : "var(--cc-bin-small)";
  return (
    <svg
      width={size}
      height={size}
      viewBox={`0 0 ${size} ${size}`}
      role="img"
      aria-hidden="true"
    >
      <circle
        cx={size / 2}
        cy={size / 2}
        r={size / 2 - 1}
        fill="none"
        stroke="var(--cc-text-tertiary)"
        strokeWidth={1.5}
      />
      <circle
        cx={size / 2}
        cy={size / 2}
        r={size / 2 - 10}
        fill="none"
        stroke="var(--cc-text-tertiary)"
        strokeOpacity={0.5}
        strokeWidth={1}
        strokeDasharray="4 3"
      />
      <circle
        cx={size / 2}
        cy={size / 2}
        r={size / 2 - 22}
        fill="none"
        stroke="var(--cc-text-tertiary)"
        strokeOpacity={0.35}
        strokeWidth={1}
        strokeDasharray="4 3"
      />
      {dots.map(([x, y, r, opacity], i) => (
        <circle
          key={i}
          cx={x * size}
          cy={y * size}
          r={r / 2 + 1}
          fill={fill}
          fillOpacity={opacity}
        />
      ))}
    </svg>
  );
}
