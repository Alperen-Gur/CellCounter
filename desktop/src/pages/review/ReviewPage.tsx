/**
 * pages/review/ReviewPage.tsx — the Review Queue screen (feat-review-queue).
 *
 * Card-stack triage of every low-confidence (`confidence < 0.65`), un-triaged
 * detected cell across all batches. Each card offers Reject (R) / Keep (K) /
 * Edit-diameter (E) / Skip (→); Esc returns Home. The queue + all persistence
 * live in `useReviewQueue`; this file is the layout + keyboard wiring + the
 * edit-diameter local UI state.
 *
 * Correction kinds written (via `PersistencePort.recordCorrection`, in the
 * hook): Reject → "remove" (+ drops the cell), Keep → "accept", Edit → "resize"
 * (+ updates the diameter). The badge count the Sidebar shows
 * (`store.reviewQueueCount`, from `uncorrectedCellCount(0.65)`) stays in sync —
 * the hook refreshes library stats after every write.
 *
 * Boundaries (docs/tasks.json feat-review-queue):
 *   - owns `pages/review/` only; never imports a sibling page. Routing uses the
 *     shell's dependency-free `navigate`.
 *   - the 0.65 cutoff is canonical (`REVIEW_QUEUE_CONFIDENCE_CUTOFF`) and
 *     independent of the confidence slider — enforced in the hook.
 *   - does NOT alter the store's slice shape (only reads
 *     `refreshLibraryStats` / `thresholds`, calls existing setters via nav).
 *
 * Uses ONLY its `uses` set: kernel-persistence + kernel-store + kernel-types
 * (all data through the frozen `PersistencePort`), plus the shell's `useKeymap`
 * (bound to the frozen `review` scope) and hash `navigate`.
 */

import { useCallback, useEffect, useState } from "react";

import { useAppStore } from "../../kernel/store/store";
import { navigate as shellNavigate } from "../../components/useHashRoute";
import type { RouteId } from "../../components/routes";
import { useKeymap } from "../../components/useKeymap";
import { Icon } from "../../components/Icon";

import { useReviewQueue } from "./useReviewQueue";
import { ReviewCard } from "./ReviewCard";

import "./review.css";

export default function ReviewPage() {
  const thresholds = useAppStore((s) => s.thresholds);
  const {
    queue,
    cursor,
    current,
    next,
    loading,
    error,
    reject,
    keep,
    editDiameter,
    skip,
  } = useReviewQueue();

  // Live diameter (µm) while the current card is in edit mode; null otherwise.
  const [editing, setEditing] = useState<number | null>(null);

  // Any cursor move (advance from an action, or Skip) exits edit mode so the
  // slider never leaks onto the next card (mirrors the Swift `advance()`).
  useEffect(() => {
    setEditing(null);
  }, [cursor]);

  const goHome = useCallback(() => {
    shellNavigate("home" as RouteId);
  }, []);

  const startEditing = useCallback(() => {
    if (!current) return;
    setEditing(current.cell.diameterUm);
  }, [current]);

  const cancelEditing = useCallback(() => {
    setEditing(null);
  }, []);

  const commitEditing = useCallback(() => {
    if (!current || editing === null) return;
    void editDiameter(editing);
    // `editing` is cleared by the cursor-change effect once the queue advances.
  }, [current, editing, editDiameter]);

  // ── keyboard: the frozen `review` scope (R / K / E / → / Esc) ─────────────
  // While editing, R/K/E are suspended (the user is dialing a number); Enter
  // saves, Esc cancels the edit. Otherwise the normal triage chords apply and
  // Esc exits to Home. `useKeymap` already ignores events from text inputs.
  useKeymap(
    "review",
    editing !== null
      ? {
          // Save edit — Enter isn't in the frozen `review` scope, so bind it via
          // a tiny local listener below; here we only need to keep Esc→cancel.
          exit: cancelEditing,
        }
      : {
          reject: () => void reject(),
          keep: () => void keep(),
          editDiameter: startEditing,
          skip: skip,
          exit: goHome,
        },
    { enabled: !loading && current !== null },
  );

  // Enter-to-save while editing (Enter isn't part of the frozen review scope).
  useEffect(() => {
    if (editing === null) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Enter") {
        e.preventDefault();
        commitEditing();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [editing, commitEditing]);

  const total = queue.length;
  const remainingLabel =
    total > 0 ? `${Math.min(cursor + 1, total)} of ${total} remaining` : "";
  const finished = !loading && (total === 0 || cursor >= total);

  return (
    <div className="cc-review">
      <header className="cc-review__header">
        <div className="cc-review__title-group">
          <span className="cc-review__eyebrow">
            <Icon name="queue" size={14} />
            Queue
          </span>
          <h1 className="cc-review__title">Review queue</h1>
          <p className="cc-review__subtitle">
            Sort uncertain detections. Each correction nudges the model toward
            your imaging.
          </p>
        </div>
        {total > 0 && !finished && (
          <span className="cc-review__remaining">{remainingLabel}</span>
        )}
        <button
          type="button"
          className="cc-review__close"
          onClick={goHome}
          aria-label="Close review queue (Esc)"
          title="Close review queue (Esc)"
        >
          <Icon name="close" size={16} />
        </button>
      </header>

      <div className="cc-review__body">
        {loading ? (
          <div className="cc-review__loading">Building review queue…</div>
        ) : finished ? (
          <div className="cc-review__empty">
            <div className="cc-review__empty-glyph" aria-hidden="true">
              <Icon name="checkCircle" size={28} />
            </div>
            <div className="cc-review__empty-title">
              Done — nothing to review
            </div>
            <p className="cc-review__empty-sub">
              {total === 0
                ? "All low-confidence detections have been triaged. Drop in another batch to keep training the model."
                : `You triaged ${total} cell${total === 1 ? "" : "s"}. Improvements will show up after the next fine-tune.`}
            </p>
            <button
              type="button"
              className="cc-btn cc-review__empty-btn"
              onClick={goHome}
            >
              <Icon name="arrowLeft" size={16} />
              Back to home
            </button>
          </div>
        ) : current ? (
          <div className="cc-review__stack-wrap">
            <div className="cc-review__stack">
              {next && (
                <div className="cc-review__peek">
                  <ReviewCard
                    key={next.key}
                    item={next}
                    thresholds={thresholds}
                    editingDiameter={null}
                    peek
                  />
                </div>
              )}
              <ReviewCard
                key={current.key}
                item={current}
                thresholds={thresholds}
                editingDiameter={editing}
                onEditChange={setEditing}
              />
            </div>

            {error && (
              <div className="cc-review__error" role="alert">
                <Icon name="alert" size={15} />
                <span>Couldn't save — retry.</span>
              </div>
            )}

            <div className="cc-review__actions">
              <button
                type="button"
                className="cc-btn cc-review__btn cc-review__btn--danger"
                onClick={() => void reject()}
                title="Reject (R)"
              >
                <Icon name="xCircle" size={16} />
                Reject
                <kbd className="cc-review__kbd">R</kbd>
              </button>
              <button
                type="button"
                className="cc-btn cc-review__btn"
                onClick={() => void keep()}
                title="Keep (K)"
              >
                <Icon name="check" size={16} />
                Keep
                <kbd className="cc-review__kbd">K</kbd>
              </button>

              <span className="cc-review__actions-spacer" />

              {editing === null ? (
                <button
                  type="button"
                  className="cc-btn cc-review__btn"
                  onClick={startEditing}
                  title="Edit diameter (E)"
                >
                  <Icon name="edit" size={16} />
                  Edit diameter
                  <kbd className="cc-review__kbd">E</kbd>
                </button>
              ) : (
                <>
                  <button
                    type="button"
                    className="cc-btn cc-btn--ghost cc-review__btn"
                    onClick={cancelEditing}
                  >
                    Cancel
                  </button>
                  <button
                    type="button"
                    className="cc-btn cc-btn--primary cc-review__btn"
                    onClick={commitEditing}
                    title="Save edit (Return)"
                  >
                    <Icon name="check" size={16} />
                    Save edit
                  </button>
                </>
              )}
            </div>

            <button
              type="button"
              className="cc-review__done-link"
              onClick={goHome}
            >
              <Icon name="arrowLeft" size={14} />
              Done — back to home
            </button>
          </div>
        ) : null}
      </div>
    </div>
  );
}
