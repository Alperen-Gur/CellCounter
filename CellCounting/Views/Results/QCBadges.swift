import SwiftUI

// MARK: — QCBadges
//
// A small horizontal pill row displaying per-image focus and illumination quality
// scores computed by the Python sidecars (C3, pass 6).
//
// Splice point: insert `QCBadges(stats: state.currentImage?.detection?.imageStats)`
// inside `ViewerControlsLeft` in ResultsView, below the segmented-control / eye row.
//
// Traffic-light thresholds:
//   Focus (higher = sharper):
//     green  ≥ 0.5   — acceptable; most in-focus images score 0.5–1.0
//     amber  0.2–0.5 — borderline blur; results may be less accurate
//     red    < 0.2   — likely out-of-focus; consider re-imaging
//   Illumination residual (lower = flatter field):
//     green  < 0.1   — uniform illumination
//     amber  0.1–0.2 — moderate gradient; background subtraction recommended
//     red    > 0.2   — strong gradient; may bias cell boundaries

struct QCBadges: View {
    /// Pass `state.currentImage?.detection?.imageStats`.
    /// View renders nothing when stats is nil (legacy/mock detections).
    let stats: [String: Double]?

    var body: some View {
        if let stats,
           let focus = stats["focus_score"] {
            HStack(spacing: 4) {
                QCBadge(
                    label: "Focus",
                    value: focus,
                    format: "%.2f",
                    color: focusColor(focus)
                )
                if let illum = stats["illumination_residual"] {
                    QCBadge(
                        label: "Illum residual",
                        value: illum,
                        format: "%.2f",
                        color: illuminationColor(illum)
                    )
                }
            }
        }
    }

    // MARK: — Traffic-light helpers

    private func focusColor(_ v: Double) -> Color {
        if v >= 0.5 { return Tokens.success }
        if v >= 0.2 { return Tokens.warning }
        return Tokens.danger
    }

    private func illuminationColor(_ v: Double) -> Color {
        if v < 0.1  { return Tokens.success }
        if v < 0.2  { return Tokens.warning }
        return Tokens.danger
    }
}

// MARK: — Single badge pill

private struct QCBadge: View {
    let label: String
    let value: Double
    let format: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(label): \(String(format: format, value))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.text)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Tokens.bgToolbar)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Tokens.border, lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
    }
}
