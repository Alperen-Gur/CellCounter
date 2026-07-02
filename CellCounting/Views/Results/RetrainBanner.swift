import SwiftUI

/// Surfaces a "your corrections are worth retraining on" affordance.
///
/// Integration note (for the Image-pipeline owner of ResultsView.swift):
///   Inject `RetrainBanner(state: state, onTrain: { state.view = .fineTune })`
///   into the Results sidebar between the total-count block and the bins panel.
///   The view is `EmptyView()` when there are fewer than 10 total corrections, so
///   it self-hides and is safe to always render.
///
/// Behavior:
/// - Counts every CorrectionRecord across all batches' images' detections.
/// - When count >= 10, shows accent-soft banner with sparkle icon, copy, and a
///   primary "Improve model" CTA. Estimated minutes = max(2, N / 5).
/// - The close button (×) writes a UserDefaults flag keyed to the exact count,
///   so the banner doesn't reappear at the same N (but re-emerges when more
///   corrections accumulate).
struct RetrainBanner: View {
    @Bindable var state: AppState
    var onTrain: () -> Void

    @Environment(AppTheme.self) private var theme
    @State private var dismissedAtCount: Int = -1
    /// Cached total — recomputed in `.onAppear` and on `ccCorrectionsChanged` rather than
    /// every SwiftUI body invocation (the underlying walk decodes every detection's JSON).
    @State private var cachedTotal: Int = 0

    private var totalCorrections: Int { cachedTotal }

    private func recomputeTotal() {
        cachedTotal = state.repos.allBatches()
            .flatMap { $0.images }
            .compactMap { $0.detection }
            .flatMap { $0.corrections }
            .count
    }

    private var estimatedMinutes: Int {
        max(2, totalCorrections / 5)
    }

    private var shouldShow: Bool {
        totalCorrections >= 10 && dismissedAtCount != totalCorrections
    }

    var body: some View {
        Group {
            if shouldShow {
                content
            } else {
                EmptyView()
            }
        }
        .onAppear {
            recomputeTotal()
            hydrateDismissal()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ccCorrectionsChanged"))) { _ in
            recomputeTotal()
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.accentSoft)
                    .frame(width: 28, height: 28)
                Icon("sparkles", size: 14)
                    .foregroundStyle(theme.accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("You've corrected \(totalCorrections) images.")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                Text("Improving the model from these takes about ~\(estimatedMinutes) minutes.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                Button(action: dismiss) {
                    Icon("x", size: 11)
                        .foregroundStyle(Tokens.textTertiary)
                }
                .appButton(.ghost, size: .sm)

                Button(action: onTrain) {
                    Text("Improve model")
                }
                .appButton(.primary, size: .sm)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .fill(theme.accentSofter)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .strokeBorder(theme.accentSoft, lineWidth: 0.5)
        )
    }

    private func hydrateDismissal() {
        // Walk recent counts looking for any dismissed key — keeps banner hidden
        // for the most recent dismissed count.
        let current = totalCorrections
        for n in stride(from: current, through: max(10, current - 200), by: -1) {
            if UserDefaults.standard.bool(forKey: dismissalKey(for: n)) {
                dismissedAtCount = n
                return
            }
        }
        dismissedAtCount = -1
    }

    private func dismiss() {
        let n = totalCorrections
        UserDefaults.standard.set(true, forKey: dismissalKey(for: n))
        dismissedAtCount = n
    }

    private func dismissalKey(for n: Int) -> String {
        "cc-retrain-banner-dismissed-at-count-\(n)"
    }
}
