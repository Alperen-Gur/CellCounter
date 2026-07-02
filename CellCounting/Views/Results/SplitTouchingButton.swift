import SwiftUI

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
/// - Re-uses the *current* `activeModelId` + calibration; does NOT mutate
///   `state.watershedSplit` (the persistent UI toggle) — this is one-shot.
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
        let priorCount = image.detection?.cells.count ?? 0
        isRunning = true
        confirmation = nil
        confirmationTask?.cancel()

        Task {
            defer { isRunning = false }
            guard let svc = state.detector else {
                showConfirmation("No detector installed")
                return
            }
            do {
                let input = DetectionInput(
                    imageURL: image.storedURL,
                    modelId: state.activeModelId,
                    pxPerUm: state.pxPerUm,
                    confidenceThreshold: state.confidence,
                    channels: state.channels.asArray,
                    backgroundSubtract: state.backgroundSubtract,
                    rollingBallRadius: state.rollingBallRadius,
                    watershedSplit: true,
                    watershedMinDistance: 8
                )
                let result = try await svc.detect(input)
                state.repos.saveDetection(
                    result.cells,
                    detectorId: "\(type(of: svc))/\(state.activeModelId)+watershed",
                    for: image
                )
                NotificationCenter.default.post(
                    name: Notification.Name("ccCorrectionsChanged"),
                    object: nil
                )
                let delta = max(0, result.cells.count - priorCount)
                showConfirmation("Split \(delta) new cell\(delta == 1 ? "" : "s")")
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
