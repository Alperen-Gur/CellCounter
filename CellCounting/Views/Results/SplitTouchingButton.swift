import SwiftUI
import SwiftData

// MARK: — Splice point (for main-thread integration)
//
// `SplitTouchingButton` is a one-shot action button intended to live in the
// Results view's TOP-RIGHT controls cluster — specifically immediately to the
// LEFT of the zoom/fit controls inside `ViewerControlsRight` in
// `Views/Results/ResultsView.swift`. Rendered example:
//
//     HStack(spacing: 8) {
//         SplitTouchingButton(state: state)
//         // existing zoom HStack here
//     }
//
// It does NOT add a new EditorMode (those belong to A4/A5/A6). It runs
// detection once with `watershedSplit = true` and replaces the existing
// DetectionRecord on the current image, then shows a confirmation overlay
// for ~2.4 s reporting how many new cells were produced.

/// One-shot Results-view toolbar button that re-runs detection on the current
/// image with the watershed-split flag enabled and replaces the existing
/// DetectionRecord. Designed to recover work when a model has merged touching
/// cells into a single blob.
///
/// Behaviour:
/// - Disabled while a previous split run is in flight, or when no current image.
/// - Re-uses saved settings when the active model matches the original run;
///   otherwise captures the current settings. Does not mutate the default
///   watershed toggle.
/// - On success, replaces `currentImage.detection` via `Repositories.saveDetection`
///   and posts a `Notification.Name("ccCorrectionsChanged")` so any observing
///   sidebars/charts refresh.
/// - Shows a transient "Split N new cells" confirmation overlay anchored to
///   the button's bottom edge.
struct SplitTouchingButton: View {
    @Bindable var state: AppState

    @State private var isRunning = false
    @State private var confirmation: String? = nil
    @State private var confirmationTask: Task<Void, Never>? = nil

    private var hasImage: Bool { state.currentImage != nil }

    var body: some View {
        Button(action: runSplit) {
            HStack(spacing: 6) {
                if isRunning {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .frame(width: 14, height: 14)
                } else {
                    Icon("layers", size: 13)
                }
                Text("Split touching")
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .appButton(.standard, size: .sm)
        .disabled(isRunning || !hasImage)
        .help("Re-run detection on this image with watershed splitting enabled")
        .overlay(alignment: .top) {
            if let msg = confirmation {
                ConfirmationPill(text: msg)
                    .offset(y: 34)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Tokens.Motion.ease, value: confirmation)
    }

    // MARK: — Action

    private func runSplit() {
        guard !isRunning, let image = state.currentImage else { return }
        let imageId = image.id
        isRunning = true
        confirmation = nil
        confirmationTask?.cancel()

        Task {
            defer { isRunning = false }
            do {
                if let detection = image.detection { try await state.finishPendingCellEdits(for: detection) }
                guard !image.isDeleted, image.modelContext != nil, image.id == imageId else {
                    throw CancellationError()
                }
                let detectionId = image.detection?.id
                let detectionRevision = image.detection?.cellsRevision
                let priorCount = image.detection?.summaryCellCount ?? 0
                let savedSettings = image.detection?.runSettings
                var settings = savedSettings?.modelId == state.activeModelId
                    ? (savedSettings ?? AnalysisRunSettings.capture(state: state))
                    : AnalysisRunSettings.capture(state: state)
                if savedSettings?.modelId != state.activeModelId {
                    settings.pxPerUm = image.batch?.pxPerUm ?? state.pxPerUm
                }
                settings.watershedSplit = true
                if let error = settings.validationError {
                    throw DetectionError.sidecarFailed(exitCode: -1, stderr: error)
                }
                let svc = try state.detectionService(for: settings)
                let input = settings.detectionInput(imageURL: settings.sourceURL(for: image))
                let result = try await svc.detectWithLocalTiming(input)
                try Task.checkCancellation()
                guard !image.isDeleted, image.modelContext != nil,
                      image.id == imageId, image.detection?.id == detectionId else {
                    throw CancellationError()
                }
                if let detection = image.detection { try await state.finishPendingCellEdits(for: detection) }
                guard !image.isDeleted, image.modelContext != nil,
                      image.id == imageId, image.detection?.id == detectionId,
                      image.detection?.cellsRevision == detectionRevision else {
                    throw CancellationError()
                }
                state.repos.saveDetection(
                    state.cellsAtBatchScale(result.cells, for: image, measuredAt: settings.pxPerUm),
                    detectorId: "\(type(of: svc))/\(settings.modelId)+watershed",
                    for: image,
                    imageStats: result.imageStats,
                    runSettings: settings
                )
                NotificationCenter.default.post(
                    name: Notification.Name("ccCorrectionsChanged"),
                    object: nil
                )
                let delta = max(0, result.cells.count - priorCount)
                showConfirmation("Split \(delta) new cell\(delta == 1 ? "" : "s")")
            } catch is CancellationError {
                showConfirmation("Split cancelled; image or masks changed")
            } catch DetectionError.modelNotInstalled(_) {
                showConfirmation("No detector installed")
            } catch {
                NSLog("CellCounter: SplitTouchingButton detect failed: %@",
                      error.localizedDescription)
                showConfirmation("Split failed")
            }
        }
    }

    private func showConfirmation(_ text: String) {
        confirmation = text
        confirmationTask?.cancel()
        confirmationTask = Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if !Task.isCancelled {
                confirmation = nil
            }
        }
    }
}

// MARK: — Confirmation pill

private struct ConfirmationPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Tokens.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Tokens.bgToolbar)
                    .overlay(Capsule().strokeBorder(Tokens.border, lineWidth: 0.5))
            )
            .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
            .fixedSize()
    }
}
