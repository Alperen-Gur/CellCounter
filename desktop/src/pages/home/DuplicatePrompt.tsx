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
        <header className="home-dup__head">
          <div className="home-dup__glyph" aria-hidden="true">
            🗂️
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
                      🖼️
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
            <span aria-hidden="true">✓</span> {newCount} new file
            {newCount === 1 ? "" : "s"} will always be imported.
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
            className="cc-btn home-btn--primary"
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
