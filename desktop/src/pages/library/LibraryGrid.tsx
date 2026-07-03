/**
 * pages/library/LibraryGrid.tsx — windowed thumbnail grid (feat-library-dedup).
 *
 * Replaces the plain CSS-grid `images.map(...)` with a react-window
 * `FixedSizeGrid`, so a library of 100s of images only mounts the visible cells
 * (+ a small overscan) instead of every `ImageThumbCell` at once. This also
 * keeps the per-image `getDetection` cost bounded to what the hook already
 * fetched — nothing extra fetches here.
 *
 * The visual language is unchanged: it reproduces the previous
 * `repeat(auto-fill, minmax(180px, 1fr))` behavior by deriving the column count
 * from the measured pane width and letting each column stretch to fill the row.
 * Selection / open / delete all still flow through the same callbacks; only the
 * MOUNTING strategy changed, not the data hook or the cell.
 *
 * Owned by this page directory; imports only the shell's kernel/components and
 * its own siblings.
 */

import { useMemo } from "react";
import { FixedSizeGrid, type GridChildComponentProps } from "react-window";

import type { ImageDTO } from "../../kernel/types";
import { ImageThumbCell } from "./ImageThumbCell";
import type { ImageStats } from "./useLibraryData";
import { useMeasuredSize } from "../../kernel/viewport/useMeasuredSize";

/**
 * Layout constants mirroring the old `.cc-lib__grid` CSS so the windowed grid
 * looks identical to the static one it replaces:
 *   - MIN_COL_WIDTH  ≙ `minmax(180px, …)`
 *   - GRID_GAP       ≙ `gap: var(--cc-space-4)` (16px)
 *   - ROW_HEIGHT     = thumbnail (4:3 of the column) + meta block. It is a
 *     FIXED estimate; see the file/PR risks note. A card is: a 4:3 thumbnail
 *     plus a ~72px meta area (name line + 20px mini-distribution + padding).
 *     We size rows tall enough for the widest column so nothing clips.
 */
const MIN_COL_WIDTH = 180;
const GRID_GAP = 16;
/** Meta block under the thumbnail: name row + 20px dist bar + 12px padding×2. */
const META_HEIGHT = 72;
/** A little overscan keeps scrolling smooth without mounting everything. */
const OVERSCAN_ROWS = 2;

export interface LibraryGridProps {
  images: ImageDTO[];
  displayNames: Map<string, string>;
  statsById: Map<string, ImageStats>;
  duplicateIds: Set<string>;
  selectedIds: Set<string>;
  multiSelectMode: boolean;
  /** Tap a card: toggle selection (select mode) or open in Results. */
  onTap: (image: ImageDTO) => void;
  /** Single-delete (hover trash, out of select mode). */
  onDelete: (image: ImageDTO) => void;
}

export function LibraryGrid({
  images,
  displayNames,
  statsById,
  duplicateIds,
  selectedIds,
  multiSelectMode,
  onTap,
  onDelete,
}: LibraryGridProps) {
  // Measure the flex-grow wrapper; the grid fills it and owns its own scroll.
  const { ref, size } = useMeasuredSize<HTMLDivElement>();

  // Derive the responsive column count the same way `auto-fill, minmax(180px,
  // 1fr)` would: as many 180px columns (with 16px gaps) as fit, ≥1.
  const columnCount = useMemo(() => {
    if (size.width <= 0) return 1;
    const cols = Math.floor(
      (size.width + GRID_GAP) / (MIN_COL_WIDTH + GRID_GAP),
    );
    return Math.max(1, cols);
  }, [size.width]);

  const rowCount = Math.ceil(images.length / columnCount);

  // Column width stretches to fill the pane (the `1fr` half of the minmax);
  // rows are the stretched-column thumbnail (4:3) plus the meta block.
  const columnWidth = useMemo(() => {
    if (columnCount <= 0 || size.width <= 0) return MIN_COL_WIDTH + GRID_GAP;
    // Distribute the pane width across columns, each carrying one trailing gap.
    return Math.floor(size.width / columnCount);
  }, [columnCount, size.width]);

  // Cell content width (minus the gap we reserve on the right of each cell).
  const cellContentWidth = Math.max(0, columnWidth - GRID_GAP);
  // Thumbnail is 4:3 of the card's inner width; add the meta block + one gap.
  const rowHeight = Math.round((cellContentWidth * 3) / 4) + META_HEIGHT + GRID_GAP;

  const Cell = ({ columnIndex, rowIndex, style }: GridChildComponentProps) => {
    const index = rowIndex * columnCount + columnIndex;
    if (index >= images.length) return null;
    const image = images[index];
    // `style` positions the cell absolutely; we inset by the gap to reproduce
    // the CSS grid's inter-cell spacing (right + bottom gutters).
    return (
      <div
        style={{
          ...style,
          paddingRight: GRID_GAP,
          paddingBottom: GRID_GAP,
          boxSizing: "border-box",
        }}
      >
        <ImageThumbCell
          image={image}
          displayName={displayNames.get(image.id) ?? image.fileName}
          stats={statsById.get(image.id)}
          isDuplicate={duplicateIds.has(image.id)}
          isSelected={selectedIds.has(image.id)}
          multiSelectMode={multiSelectMode}
          onTap={() => onTap(image)}
          onDelete={() => onDelete(image)}
        />
      </div>
    );
  };

  return (
    <div ref={ref} className="cc-lib__grid-viewport">
      {size.height > 0 && size.width > 0 && rowCount > 0 ? (
        <FixedSizeGrid
          className="cc-lib__grid-inner"
          columnCount={columnCount}
          columnWidth={columnWidth}
          rowCount={rowCount}
          rowHeight={rowHeight}
          width={size.width}
          height={size.height}
          overscanRowCount={OVERSCAN_ROWS}
        >
          {Cell}
        </FixedSizeGrid>
      ) : null}
    </div>
  );
}
