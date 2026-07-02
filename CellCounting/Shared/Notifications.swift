import Foundation

// MARK: — Central registry of CellCounter NotificationCenter names.
//
// Pass-18 (Lane K3): every `Notification.Name` posted or observed inside
// CellCounter is now indexed here, even when the underlying `static let`
// declaration still lives next to a sibling type. The goal is one searchable
// file you can `cmd-click` to that documents every cross-cutting signal in
// the app, what it carries, who posts it, and who observes it.
//
// HARD RULE: the underlying raw string values MUST NOT change. Existing
// observers and posts all match by the literal string. Renaming the raw
// value silently breaks observation.
//
// Where the declarations physically live (kept where they are to avoid the
// invasive Views/Detection/Services churn that would be required to move
// them — moving the file location does not improve the call sites):
//
//   • Detection/InstallStateCache.swift:
//       - `ccVenvChanged`             — 3.x venv created/removed.
//       - `ccDetectionStage`          — detector stderr line (userInfo["line"]).
//
//   • Views/Modals/InstallCellpose4Sheet.swift:
//       - `ccVenv4Changed`            — 4.x (CPSAM) venv created/removed.
//       - `ccCellposeSAMInstallCompleted` — raw "cellpose-sam-install-completed".
//
//   • Detection/AnnotationMatcher.swift:
//       - `ccAnnotationsChanged`      — GroundTruthAnnotation added/removed.
//
// New typed declarations introduced by Pass-18 (replacing previous raw-string
// posts at the call sites we own — see AppState.swift, Repositories.swift):

extension Notification.Name {
    /// Posted whenever a `CorrectionRecord` is added or a detection's cells
    /// change (re-run, split-touching). Observers: AppState (refreshes the
    /// Review-queue badge), ReviewQueueView, BatchView, ResultsView,
    /// RetrainBanner — all of which reload their caches.
    ///
    /// Raw value preserved verbatim from the string-form posts that predate
    /// this file ("ccCorrectionsChanged"); existing string-form observers
    /// continue to match.
    static let ccCorrectionsChanged = Notification.Name("ccCorrectionsChanged")

    /// Posted on any change to the on-disk library — image imported/deleted,
    /// batch created/deleted, file hashes back-filled. Observers: AppState
    /// (refreshes `libraryImageCount` / `libraryBatchCount` / `recentBatchIds`),
    /// library views (reload). Raw value preserved verbatim ("ccLibraryChanged").
    static let ccLibraryChanged = Notification.Name("ccLibraryChanged")

    /// Posted by `CellposeInstaller` after a successful 3.x install. Observers:
    /// AppState (refreshes detector + install-state mirror), ModelsView (flips
    /// rows from "Get" to "Activate" without a manual refresh).
    ///
    /// Raw value preserved verbatim from the string-form post in
    /// `Services/CellposeInstaller.swift` ("cellpose-install-completed").
    static let ccCellposeInstallCompleted = Notification.Name("cellpose-install-completed")
}
