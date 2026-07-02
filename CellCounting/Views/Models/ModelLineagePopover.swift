import SwiftUI

/// Vertical timeline of fine-tune versions for a given model.
///
/// Integration note (for the Models view owner):
///   Attach as a `.popover` to the existing `ModelRow` when a custom model is
///   shown — most naturally, swap (or duplicate) the existing info button so a
///   custom model shows a "Versions" affordance that toggles
///   `ModelLineagePopover(modelId: model.id, state: state)`.
///
/// Each row shows: version number, relative date, trained-on counts, AP @ 0.5
/// and Δ vs. previous. "Roll back" is a no-op stub — wire later.
struct ModelLineagePopover: View {
    let modelId: String
    @Bindable var state: AppState
    @Environment(AppTheme.self) private var theme

    private var versions: [ModelVersionRecord] { state.repos.modelVersions(for: modelId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Version history")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                Spacer()
                Text("\(versions.count) version\(versions.count == 1 ? "" : "s")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14).padding(.bottom, 10)

            Divider().overlay(Tokens.divider).frame(height: 0.5)

            if versions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(versions.enumerated()), id: \.element.id) { idx, v in
                            let prev: ModelVersionRecord? = idx + 1 < versions.count ? versions[idx + 1] : nil
                            VersionRowView(
                                version: v,
                                previous: prev,
                                isLatest: idx == 0,
                                onRollback: { RollbackService.rollback(to: v, in: state) }
                            )
                            if idx < versions.count - 1 {
                                Rectangle().fill(Tokens.divider).frame(height: 0.5)
                                    .padding(.leading, 44)
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 340)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Icon("sparkles", size: 22)
                .foregroundStyle(Tokens.textQuaternary)
            Text("No versions yet.")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)
            Text("Fine-tune to create one.")
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.textTertiary)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }
}

// MARK: — Single version row

private struct VersionRowView: View {
    let version: ModelVersionRecord
    let previous: ModelVersionRecord?
    let isLatest: Bool
    let onRollback: () -> Void

    @Environment(AppTheme.self) private var theme

    private var ap50: Double? { version.metrics["ap50"] ?? version.metrics["AP@0.5"] }
    private var prevAp50: Double? { previous?.metrics["ap50"] ?? previous?.metrics["AP@0.5"] }

    private var delta: Double? {
        guard let a = ap50, let b = prevAp50 else { return nil }
        return a - b
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // timeline dot column
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(isLatest ? theme.accentColor : Tokens.borderStrong)
                        .frame(width: 10, height: 10)
                    if isLatest {
                        Circle().strokeBorder(theme.accentSoft, lineWidth: 4)
                            .frame(width: 18, height: 18)
                    }
                }
                .frame(width: 20, height: 20)
                Rectangle().fill(Tokens.divider).frame(width: 0.5)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 20)
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("v\(version.version)")
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Tokens.text)
                    if isLatest {
                        TagLabel(text: "Latest", style: .accent)
                    }
                    Spacer()
                    Text(relativeDate(version.createdAt))
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.textTertiary)
                }

                HStack(spacing: 10) {
                    metricLabel("Images", "\(version.trainedOnImages)")
                    metricLabel("Corrections", "\(version.trainedOnCorrections)")
                }

                HStack(spacing: 10) {
                    if let ap = ap50 {
                        metricLabel("AP @ 0.5", String(format: "%.3f", ap))
                    } else {
                        metricLabel("AP @ 0.5", "—")
                    }
                    if let d = delta {
                        deltaPill(d)
                    }
                }

                HStack {
                    Spacer()
                    Button("Roll back", action: onRollback)
                        .appButton(.ghost, size: .sm)
                        .disabled(isLatest)
                }
                .padding(.top, 2)
            }
            .padding(.trailing, 16)
            .padding(.vertical, 12)
        }
        .padding(.leading, 12)
    }

    private func metricLabel(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .tracking(0.04 * 9)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Tokens.textTertiary)
            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Tokens.text)
        }
    }

    private func deltaPill(_ d: Double) -> some View {
        let positive = d >= 0
        let color: Color = positive ? Tokens.success : Tokens.danger
        let arrow = positive ? "▲" : "▼"
        let mag = String(format: "%.3f", abs(d))
        return Text("\(arrow) \(mag)")
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.12)))
            .foregroundStyle(color)
    }

    private func relativeDate(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}
