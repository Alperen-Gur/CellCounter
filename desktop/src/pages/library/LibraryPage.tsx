/**
 * pages/library/LibraryPage.tsx — the Images Library screen (feat-library-dedup).
 *
 * A grid of every imported image with thumbnails, per-image cell counts, and a
 * size mini-distribution; surfaces SHA-256 duplicate groups (same `fileHash`),
 * and lets the user open an image in Results or delete it. Multi-select mode +
 * ⌘A select-all, Return-to-open, Delete-to-remove (with confirm) mirror the
 * Swift `ImagesLibraryView`.
 *
 * Boundaries (docs/tasks.json feat-library-dedup):
 *   - owns `pages/library/` only; never imports a sibling page.
 *   - routes via the shell's dependency-free `navigate` (store drives Results).
 *   - hashing happens in the Rust importer (kernel-persistence) — this page
 *     only reads `duplicateGroups()`; it never re-hashes.
 *   - no export here.
 *
 * Uses ONLY its `uses` set: kernel-persistence (`getPort`), kernel-store
 * (`useAppStore`), kernel-types. All data crosses the frozen `PersistencePort`.
 */

import { useCallback, useEffect, useMemo, useState } from "react";

import type { ImageDTO } from "../../kernel/types";
import { getPort } from "../../kernel/persistence";
import { useAppStore } from "../../kernel/store/store";
import { navigate as shellNavigate } from "../../components/useHashRoute";
import type { RouteId } from "../../components/routes";
import { Icon } from "../../components/Icon";

import { useLibraryData } from "./useLibraryData";
import { LibraryGrid } from "./LibraryGrid";

import "./library.css";

/** Is a typing target focused? Suppresses global keyboard actions. */
function isTypingTarget(target: EventTarget | null): boolean {
  const el = target as HTMLElement | null;
  return (
    !!el &&
    (el.tagName === "INPUT" ||
      el.tagName === "TEXTAREA" ||
      el.isContentEditable)
  );
}

export default function LibraryPage() {
  const {
    images,
    duplicateGroups,
    statsById,
    displayNames,
    duplicateIds,
    loading,
    reload,
  } = useLibraryData();

  const [multiSelectMode, setMultiSelectMode] = useState(false);
  const [selectedIds, setSelectedIds] = useState<Set<string>>(
    () => new Set(),
  );

  // ── keep selection valid + reflect count on the sidebar badge ──────────
  // The Sidebar's "library" badge reads store.libraryImageCount; refresh it so
  // deletions there stay in sync (it's derived, mirroring refreshLibraryStats).
  const refreshLibraryStats = useAppStore((s) => s.refreshLibraryStats);

  // Prune any selected ids that no longer exist after a reload.
  useEffect(() => {
    setSelectedIds((prev) => {
      if (prev.size === 0) return prev;
      const live = new Set(images.map((im) => im.id));
      let changed = false;
      const next = new Set<string>();
      for (const id of prev) {
        if (live.has(id)) next.add(id);
        else changed = true;
      }
      return changed ? next : prev;
    });
  }, [images]);

  // Leaving select mode clears the selection (Swift onChange behaviour).
  const setSelectMode = useCallback((on: boolean) => {
    setMultiSelectMode(on);
    if (!on) setSelectedIds(new Set());
  }, []);

  const selectAll = useCallback(() => {
    setMultiSelectMode(true);
    setSelectedIds(new Set(images.map((im) => im.id)));
  }, [images]);

  const toggleSelected = useCallback((id: string) => {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }, []);

  // ── open an image in Results ───────────────────────────────────────────
  // Find the batch owning the image and focus it at the right index. The index
  // MUST be computed in `owner.imageIds` order — the exact order Results reads
  // (useResultsData resolves images by batch.imageIds and warns that any other
  // ordering opens a different image than the one clicked). Sorting by
  // importedAt here would hand off an index that resolves to the wrong image
  // whenever imageIds order differs from import-timestamp order.
  const openInResults = useCallback(async (image: ImageDTO) => {
    const port = getPort();
    const batches = await port.allBatches();
    const owner = batches.find((b) => b.imageIds.includes(image.id));
    if (!owner) return;

    const idx = owner.imageIds.indexOf(image.id);

    const store = useAppStore.getState();
    store.openBatch(owner.id);
    if (idx >= 0) store.setCurrentImageIdx(idx);
    shellNavigate("results" as RouteId);
  }, []);

  // ── tap a card: toggle in select mode, else open ───────────────────────
  const handleTap = useCallback(
    (image: ImageDTO) => {
      if (multiSelectMode) {
        toggleSelected(image.id);
        return;
      }
      void openInResults(image);
    },
    [multiSelectMode, toggleSelected, openInResults],
  );

  // ── delete (with confirm) ──────────────────────────────────────────────
  const deleteImages = useCallback(
    async (ids: string[]) => {
      if (ids.length === 0) return;
      const port = getPort();
      await Promise.all(
        ids.map((id) =>
          port.deleteImage(id).catch(() => {
            /* best-effort: keep deleting the rest */
          }),
        ),
      );
      setSelectedIds(new Set());
      await reload();
      // Keep the sidebar's image/review counts in sync after a mutation.
      await refreshLibraryStats().catch(() => {});
    },
    [reload, refreshLibraryStats],
  );

  const confirmDeleteSingle = useCallback(
    (image: ImageDTO) => {
      const name = displayNames.get(image.id) ?? image.fileName;
      const ok =
        typeof window === "undefined" ||
        window.confirm(
          `Delete "${name}"?\n\nThis removes the image and its detection. This cannot be undone.`,
        );
      if (ok) void deleteImages([image.id]);
    },
    [displayNames, deleteImages],
  );

  const confirmDeleteSelected = useCallback(() => {
    const ids = Array.from(selectedIds);
    if (ids.length === 0) return;
    const ok =
      typeof window === "undefined" ||
      window.confirm(
        `Delete ${ids.length} image${ids.length === 1 ? "" : "s"}?\n\n` +
          `This removes the images and their detections. This cannot be undone.`,
      );
    if (ok) void deleteImages(ids);
  }, [selectedIds, deleteImages]);

  // ── global keyboard: ⌘A select-all · Return open · Delete remove ───────
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (isTypingTarget(e.target)) return;

      // ⌘A / Ctrl+A — select all (enters select mode).
      if ((e.metaKey || e.ctrlKey) && (e.key === "a" || e.key === "A")) {
        if (images.length === 0) return;
        e.preventDefault();
        selectAll();
        return;
      }

      // Return — open the first selected image (else the first image).
      if (e.key === "Enter") {
        const target =
          images.find((im) => selectedIds.has(im.id)) ?? images[0];
        if (!target) return;
        e.preventDefault();
        void openInResults(target);
        return;
      }

      // Delete / Backspace — remove the SELECTED images only. With nothing
      // selected the key is a no-op: deleting an arbitrary first image on a
      // reflexive Backspace (with no clear target the user chose) is surprising
      // and risky, even behind a confirm.
      if (e.key === "Delete" || e.key === "Backspace") {
        if (selectedIds.size === 0) return;
        e.preventDefault();
        confirmDeleteSelected();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [
    images,
    selectedIds,
    selectAll,
    openInResults,
    confirmDeleteSelected,
    confirmDeleteSingle,
  ]);

  // Number of real duplicate clusters (each ≥2 images sharing a hash).
  const dupeGroupCount = useMemo(
    () => duplicateGroups.filter((g) => g.length >= 2).length,
    [duplicateGroups],
  );

  // ── render ─────────────────────────────────────────────────────────────
  if (loading && images.length === 0) {
    return (
      <div className="cc-lib">
        <div className="cc-lib__loading">Loading library…</div>
      </div>
    );
  }

  if (images.length === 0) {
    return (
      <div className="cc-lib">
        <div className="cc-lib__empty">
          <span className="cc-lib__empty-glyph" aria-hidden="true">
            <Icon name="images" size={26} />
          </span>
          <div className="cc-lib__empty-title">No images yet</div>
          <p className="cc-lib__empty-sub">
            Drop microscope images on Home to get started.
          </p>
        </div>
      </div>
    );
  }

  return (
    <div className="cc-lib">
      <div className="cc-lib__toolbar">
        <div className="cc-lib__toolbar-info">
          <span className="cc-lib__stat">
            {images.length} image{images.length === 1 ? "" : "s"}
          </span>
          {dupeGroupCount > 0 && (
            <span
              className="cc-lib__stat cc-lib__stat--dupe"
              title="Groups of images with identical content (same SHA-256)"
            >
              {dupeGroupCount} duplicate group{dupeGroupCount === 1 ? "" : "s"}
            </span>
          )}
        </div>

        <span className="cc-lib__toolbar-spacer" />

        {multiSelectMode && selectedIds.size > 0 && (
          <button
            type="button"
            className="cc-btn cc-lib__btn--danger"
            onClick={confirmDeleteSelected}
          >
            <Icon name="trash" size={15} />
            Delete {selectedIds.size}
          </button>
        )}

        <button
          type="button"
          className={
            "cc-btn" + (multiSelectMode ? " cc-lib__btn--active" : "")
          }
          aria-pressed={multiSelectMode}
          onClick={() => setSelectMode(!multiSelectMode)}
        >
          <Icon name={multiSelectMode ? "check" : "grid"} size={15} />
          {multiSelectMode ? "Done" : "Select"}
        </button>
      </div>

      {/* Windowed grid: only visible cells (+ overscan) mount, so a library of
          100s of images stays light. Selection / open / delete behaviour and
          the data hook are unchanged — LibraryGrid only owns the mounting. */}
      <LibraryGrid
        images={images}
        displayNames={displayNames}
        statsById={statsById}
        duplicateIds={duplicateIds}
        selectedIds={selectedIds}
        multiSelectMode={multiSelectMode}
        onTap={handleTap}
        onDelete={confirmDeleteSingle}
      />
    </div>
  );
}
