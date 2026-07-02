/**
 * pages/home/DuplicatePrompt.tsx — the duplicate-import decision sheet.
 *
 * Port of `Views/Modals/DuplicateImportSheet.swift`. Shown when a drop/pick
 * contains files whose whole-file SHA-256 already exists in the library. The
 * user decides per file — "Open existing" (skip) or "Import anyway" — with bulk
 * shortcuts. Resolving returns the decision map to `importFlow`, which then
 * deletes the skipped freshly-imported rows and proceeds with the rest.
 *
 * Purely presentational + local state; it reaches no port and no sibling page.
 */

import { useMemo, useState } from "react";
import { convertFileSrc } from "@tauri-apps/api/core";

import { Icon } from "../../components/Icon";
import type {
  DuplicateSession,
  DuplicateDecision,
} from "./importFlow";

interface DuplicatePromptProps {
  session: DuplicateSession;
  /** Confirm with per-imported-id decisions. */
  onConfirm: (decisions: Record<string, DuplicateDecision>) => void;
  /** Cancel the whole import (rolls back the freshly-imported rows). */
  onCancel: () => void;
}

export function DuplicatePrompt({
  session,
  onConfirm,
  onCancel,
}: DuplicatePromptProps) {
  const { duplicates } = session;

  // Default every duplicate to "skip" (use the existing record).
  const [decisions, setDecisions] = useState<
    Record<string, DuplicateDecision>
  >(() => {
    const init: Record<string, DuplicateDecision> = {};
    for (const d of duplicates) init[d.imported.id] = "skip";
    return init;
  });

  const newCount = useMemo(() => {
    const dupIds = new Set(duplicates.map((d) => d.imported.id));
    return session.imported.filter((p) => !dupIds.has(p.image.id)).length;
  }, [duplicates, session.imported]);

  const setAll = (decision: DuplicateDecision) => {
    const next: Record<string, DuplicateDecision> = {};
    for (const d of duplicates) next[d.imported.id] = decision;
    setDecisions(next);
  };

  const setOne = (id: string, decision: DuplicateDecision) => {
    setDecisions((prev) => ({ ...prev, [id]: decision }));
  };

  const title =
    duplicates.length === 1
      ? "This file is already imported"
      : `${duplicates.length} files are already imported`;

  return (
    <div
      className="home-dup-backdrop"
      role="dialog"
      aria-modal="true"
      aria-label="Duplicate import"
      onClick={(e) => {
        if (e.target === e.currentTarget) onCancel();
      }}
    >
      <div className="home-dup">
        <style>{DUP_STYLES}</style>
        <header className="home-dup__head">
          <div className="home-dup__glyph" aria-hidden="true">
            <Icon name="batches" size={20} />
          </div>
          <div className="home-dup__title">{title}</div>
          <div className="home-dup__sub">
            Choose what to do for each duplicate below.
          </div>
        </header>

        <div className="home-dup__list">
          {duplicates.map((d) => {
            const decision = decisions[d.imported.id] ?? "skip";
            const thumb = safeConvert(d.existing.thumbPath);
            return (
              <div className="home-dup__row" key={d.imported.id}>
                <div className="home-dup__thumb">
                  {thumb ? (
                    <img src={thumb} alt="" />
                  ) : (
                    <div className="home-dup__thumb-fallback" aria-hidden="true">
                      <Icon name="image" size={20} />
                    </div>
                  )}
                </div>

                <div className="home-dup__info">
                  <div className="home-dup__name" title={d.imported.fileName}>
                    {d.imported.fileName}
                  </div>
                  <div className="home-dup__meta">
                    Already in library
                    {d.existing.importedAt
                      ? ` · imported ${shortDate(d.existing.importedAt)}`
                      : ""}
                  </div>
                </div>

                <div
                  className="home-dup__choice"
                  role="radiogroup"
                  aria-label={`Decision for ${d.imported.fileName}`}
                >
                  <button
                    type="button"
                    role="radio"
                    aria-checked={decision === "skip"}
                    className={
                      "home-dup__opt" +
                      (decision === "skip" ? " home-dup__opt--on" : "")
                    }
                    onClick={() => setOne(d.imported.id, "skip")}
                  >
                    Open existing
                  </button>
                  <button
                    type="button"
                    role="radio"
                    aria-checked={decision === "importAnyway"}
                    className={
                      "home-dup__opt" +
                      (decision === "importAnyway" ? " home-dup__opt--on" : "")
                    }
                    onClick={() => setOne(d.imported.id, "importAnyway")}
                  >
                    Import anyway
                  </button>
                </div>
              </div>
            );
          })}
        </div>

        {newCount > 0 && (
          <div className="home-dup__newnote">
            <Icon name="checkCircle" size={16} />
            <span>
              {newCount} new file{newCount === 1 ? "" : "s"} will always be
              imported.
            </span>
          </div>
        )}

        <footer className="home-dup__foot">
          <button
            type="button"
            className="cc-btn"
            onClick={() => setAll("skip")}
          >
            Skip all duplicates
          </button>
          <button
            type="button"
            className="cc-btn"
            onClick={() => setAll("importAnyway")}
          >
            Import all anyway
          </button>
          <span className="home-dup__foot-spacer" />
          <button type="button" className="cc-btn" onClick={onCancel}>
            Cancel
          </button>
          <button
            type="button"
            className="cc-btn cc-btn--primary"
            onClick={() => onConfirm(decisions)}
          >
            Confirm
          </button>
        </footer>
      </div>
    </div>
  );
}

function safeConvert(path: string): string | undefined {
  try {
    return convertFileSrc(path);
  } catch {
    return undefined;
  }
}

function shortDate(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const months = [
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
  ];
  return `${months[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()}`;
}

// ---------------------------------------------------------------------------
// Scoped styles (design tokens from styles/theme.css; self-contained)
// ---------------------------------------------------------------------------

const DUP_STYLES = `
.home-dup-backdrop {
  position: fixed;
  inset: 0;
  z-index: 55;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: var(--cc-space-5);
  background: rgba(24, 24, 27, 0.28);
}
.home-dup {
  display: flex;
  flex-direction: column;
  width: min(560px, 100%);
  max-height: min(720px, calc(100vh - 48px));
  background: var(--cc-bg-elevated);
  border: 1px solid var(--cc-border);
  border-radius: var(--cc-radius-lg);
  box-shadow: var(--cc-shadow-3);
  overflow: hidden;
}
.home-dup__head {
  display: flex;
  flex-direction: column;
  gap: 3px;
  padding: var(--cc-space-5) var(--cc-space-5) var(--cc-space-4);
}
.home-dup__glyph {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 40px;
  height: 40px;
  margin-bottom: var(--cc-space-2);
  border-radius: var(--cc-radius-md);
  background: var(--cc-bg-subtle);
  border: 1px solid var(--cc-border);
  color: var(--cc-text-secondary);
}
.home-dup__title {
  font-family: var(--cc-font-display);
  font-size: var(--cc-text-lg);
  font-weight: 650;
  letter-spacing: -0.01em;
  color: var(--cc-text);
}
.home-dup__sub {
  font-size: var(--cc-text-sm);
  color: var(--cc-text-secondary);
}
.home-dup__list {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  padding: 0 var(--cc-space-5);
  display: flex;
  flex-direction: column;
  border-top: 1px solid var(--cc-border);
  border-bottom: 1px solid var(--cc-border);
}
.home-dup__row {
  display: flex;
  align-items: center;
  gap: var(--cc-space-3);
  padding: var(--cc-space-3) 0;
}
.home-dup__row + .home-dup__row {
  border-top: 1px solid var(--cc-border);
}
.home-dup__thumb {
  flex: 0 0 auto;
  width: 46px;
  height: 46px;
  border-radius: var(--cc-radius-md);
  overflow: hidden;
  background: var(--cc-bg-subtle);
  border: 1px solid var(--cc-border);
  display: inline-flex;
  align-items: center;
  justify-content: center;
}
.home-dup__thumb img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}
.home-dup__thumb-fallback {
  display: inline-flex;
  color: var(--cc-text-tertiary);
}
.home-dup__info {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.home-dup__name {
  font-weight: 600;
  color: var(--cc-text);
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
}
.home-dup__meta {
  font-size: var(--cc-text-sm);
  color: var(--cc-text-tertiary);
}
.home-dup__choice {
  flex: 0 0 auto;
  display: inline-flex;
  padding: 2px;
  gap: 2px;
  border-radius: var(--cc-radius-md);
  background: var(--cc-bg-subtle);
  border: 1px solid var(--cc-border);
}
.home-dup__opt {
  padding: 5px 11px;
  border: none;
  border-radius: var(--cc-radius-sm);
  background: transparent;
  color: var(--cc-text-secondary);
  font-size: var(--cc-text-sm);
  font-weight: 550;
  cursor: pointer;
  white-space: nowrap;
  transition: background 0.12s ease, color 0.12s ease, box-shadow 0.12s ease;
}
.home-dup__opt:hover {
  color: var(--cc-text);
}
.home-dup__opt--on {
  background: var(--cc-bg-elevated);
  color: var(--cc-text);
  box-shadow: var(--cc-shadow-1);
}
.home-dup__newnote {
  display: flex;
  align-items: center;
  gap: var(--cc-space-2);
  margin: var(--cc-space-4) var(--cc-space-5) 0;
  padding: var(--cc-space-3);
  border-radius: var(--cc-radius-md);
  background: var(--cc-bg-subtle);
  border: 1px solid var(--cc-border);
  font-size: var(--cc-text-sm);
  color: var(--cc-text-secondary);
}
.home-dup__newnote .cc-icon {
  flex: 0 0 auto;
  color: var(--cc-success);
}
.home-dup__foot {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  gap: var(--cc-space-2);
  padding: var(--cc-space-4) var(--cc-space-5);
  background: var(--cc-bg-sidebar);
  border-top: 1px solid var(--cc-border);
}
.home-dup__foot-spacer {
  flex: 1 1 auto;
}
`;
