/** Bounded, durable cell triage with keyboard and button actions. */

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
    cursor,
    totalPending,
    skipped,
    current,
    next,
    loading,
    saving,
    error,
    pageError,
    notice,
    canUndo,
    undo,
    contextError,
    retryContext,
    retryPage,
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
    { enabled: !loading && !saving && current !== null },
  );

  // Enter-to-save while editing (Enter isn't part of the frozen review scope).
  useEffect(() => {
    if (editing === null || saving) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Enter") {
        e.preventDefault();
        commitEditing();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [editing, saving, commitEditing]);

  // Local Undo shortcut also works on the completed/next-page screens. Leave
  // native text-input undo alone while a diameter field has keyboard focus.
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const target = event.target;
      if (target instanceof HTMLElement && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName))) return;
      if ((event.ctrlKey || event.metaKey) && !event.shiftKey && !event.altKey && event.key.toLowerCase() === "z" && canUndo && !loading && !saving) {
        event.preventDefault();
        void undo();
      }
    };
    window.addEventListener("keydown",onKey);
    return () => window.removeEventListener("keydown",onKey);
  }, [canUndo, loading, saving, undo]);

  const remainingLabel = `${totalPending} pending${skipped > 0 ? ` · ${skipped} skipped this visit` : ""}`;
  const finished = !loading && !pageError && current === null;

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
            Inspect uncertain detections. Keep, remove, or correct their diameter.
          </p>
        </div>
        {totalPending > 0 && !finished && (
          <span className="cc-review__remaining">{remainingLabel}</span>
        )}
        <button type="button" className="cc-btn" onClick={() => void undo()} disabled={!canUndo || loading || saving} title="Undo last decision (Ctrl+Z)">
          Undo <kbd className="cc-review__kbd">Ctrl+Z</kbd>
        </button>
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
        {notice && <p className="cc-review__empty-sub" role="status">{notice}</p>}
        {error && !pageError && (
          <div className="cc-review__error" role="alert"><Icon name="alert" size={15} /><span>{error}</span></div>
        )}
        {loading ? (
          <div className="cc-review__loading">Building review queue…</div>
        ) : pageError && !current ? (
          <div className="cc-review__empty" role="alert">
            <div className="cc-review__empty-title">Couldn’t load the next cells</div>
            <p className="cc-review__empty-sub">{error}</p>
            <button type="button" className="cc-btn" onClick={() => void retryPage()}>Retry</button>
          </div>
        ) : finished ? (
          <div className="cc-review__empty">
            <div className="cc-review__empty-glyph" aria-hidden="true">
              <Icon name="checkCircle" size={28} />
            </div>
            <div className="cc-review__empty-title">
              {skipped > 0 ? "Finished this visit" : "Done — nothing to review"}
            </div>
            <p className="cc-review__empty-sub">
              {skipped > 0
                ? `${skipped} skipped cell${skipped === 1 ? " will" : "s will"} appear when you reopen Review.`
                : "All cells in this visit have been reviewed. Your decisions are saved."}
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

            {contextError && (
              <div className="cc-review__error" role="alert">
                <span>Couldn’t load cell outlines. {contextError}</span>
                <button type="button" className="cc-btn" onClick={retryContext}>Retry outlines</button>
              </div>
            )}
            {current.contextLimited && (
              <p className="cc-review__empty-sub">Preview shows up to 96 nearby cells; very large outlines use circles. Saved contours are unchanged.</p>
            )}

            <div className="cc-review__actions">
              <button
                type="button"
                className="cc-btn cc-review__btn cc-review__btn--danger"
                onClick={() => void reject()}
                disabled={saving}
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
                disabled={saving}
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
                  disabled={saving}
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
                    disabled={saving}
                  >
                    Cancel
                  </button>
                  <button
                    type="button"
                    className="cc-btn cc-btn--primary cc-review__btn"
                    onClick={commitEditing}
                    disabled={saving}
                    title="Save edit (Return)"
                  >
                    <Icon name="check" size={16} />
                    Save edit
                  </button>
                </>
              )}
              <button type="button" className="cc-btn cc-review__btn" onClick={skip} disabled={saving} title="Skip (→)">
                Skip <kbd className="cc-review__kbd">→</kbd>
              </button>
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
