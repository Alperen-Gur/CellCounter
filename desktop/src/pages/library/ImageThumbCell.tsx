/**
 * pages/library/ImageThumbCell.tsx — one card in the Images Library grid.
 *
 * Read-only presentation of an image (port of the Swift `ImageThumbCell`):
 *   - thumbnail via `convertFileSrc(thumbPath)` (guarded for a plain browser
 *     preview, where Tauri IPC is absent),
 *   - a "N cells" badge when a detection exists,
 *   - a 5-bin size mini-distribution bar,
 *   - a "duplicate" marker when this image shares a SHA-256 with others,
 *   - a multi-select checkbox (in select mode) and a hover delete affordance
 *     (out of select mode).
 *
 * All interaction is delegated up via callbacks — this component owns no data
 * access. Feature-owned by feat-library-dedup.
 */

import { useMemo } from "react";
import { convertFileSrc } from "@tauri-apps/api/core";

import type { ImageDTO } from "../../kernel/types";
import type { ImageStats } from "./useLibraryData";

/** Size-bin palette (shell tokens), cycled for any bins beyond the first 3. */
const BIN_COLORS = [
  "var(--cc-bin-small)",
  "var(--cc-bin-mid)",
  "var(--cc-bin-large)",
];

function binColor(i: number): string {
  return BIN_COLORS[i % BIN_COLORS.length];
}

/** convertFileSrc, guarded so a browser preview doesn't throw. */
function safeConvert(path: string): string | undefined {
  try {
    return convertFileSrc(path);
  } catch {
    return undefined;
  }
}

export interface ImageThumbCellProps {
  image: ImageDTO;
  displayName: string;
  stats: ImageStats | undefined;
  /** This image shares a fileHash with ≥1 other image. */
  isDuplicate: boolean;
  isSelected: boolean;
  multiSelectMode: boolean;
  /** Tap: toggles selection in select mode, else opens in Results. */
  onTap: () => void;
  /** Hover trash (single-delete, out of select mode). */
  onDelete: () => void;
}

export function ImageThumbCell({
  image,
  displayName,
  stats,
  isDuplicate,
  isSelected,
  multiSelectMode,
  onTap,
  onDelete,
}: ImageThumbCellProps) {
  const thumbSrc = useMemo(
    () => (image.thumbPath ? safeConvert(image.thumbPath) : undefined),
    [image.thumbPath],
  );

  const distNorm = stats?.distNorm ?? null;

  const ariaLabel = `${displayName}${
    stats?.hasDetection ? `, ${stats.cellCount} cells` : ""
  }${isDuplicate ? ", duplicate" : ""}`;

  return (
    <div
      className={
        "cc-lib__cell" +
        (isSelected ? " cc-lib__cell--selected" : "") +
        (multiSelectMode ? " cc-lib__cell--selecting" : "")
      }
    >
      <button
        type="button"
        className="cc-lib__cell-btn"
        onClick={onTap}
        aria-label={ariaLabel}
        aria-pressed={multiSelectMode ? isSelected : undefined}
      >
        <div className="cc-lib__thumb">
          {thumbSrc ? (
            <img
              className="cc-lib__thumb-img"
              src={thumbSrc}
              alt=""
              draggable={false}
              loading="lazy"
            />
          ) : (
            <div className="cc-lib__thumb-fallback" aria-hidden="true">
              🖼️
            </div>
          )}

          {stats?.hasDetection && (
            <span className="cc-lib__count-badge">{stats.cellCount} cells</span>
          )}

          {isDuplicate && (
            <span className="cc-lib__dupe-badge" title="Shares content with another image">
              duplicate
            </span>
          )}

          {image.notes && image.notes.trim() !== "" && (
            <span
              className="cc-lib__notes-badge"
              title={notesTooltip(image.notes)}
              aria-hidden="true"
            >
              ℹ
            </span>
          )}
        </div>

        <div className="cc-lib__meta">
          <span className="cc-lib__name" title={displayName}>
            {displayName}
          </span>

          {distNorm && (
            <div
              className="cc-lib__dist"
              role="img"
              aria-label="Size distribution"
            >
              {distNorm.map((h, i) => (
                <span
                  key={i}
                  className="cc-lib__dist-seg"
                  style={{
                    height: `${Math.max(3, h * 20)}px`,
                    background: binColor(i),
                  }}
                />
              ))}
            </div>
          )}
        </div>
      </button>

      {multiSelectMode ? (
        <span
          className={
            "cc-lib__check" + (isSelected ? " cc-lib__check--on" : "")
          }
          aria-hidden="true"
        >
          {isSelected ? "✓" : ""}
        </span>
      ) : (
        <button
          type="button"
          className="cc-lib__delete"
          onClick={(e) => {
            e.stopPropagation();
            onDelete();
          }}
          aria-label={`Delete ${displayName}`}
          title="Delete image"
        >
          🗑
        </button>
      )}
    </div>
  );
}

/** Trim notes to ~80 chars for the thumbnail hover tooltip (Swift parity). */
function notesTooltip(notes: string): string {
  const trimmed = notes.trim();
  return trimmed.length <= 80 ? trimmed : trimmed.slice(0, 80) + "…";
}
