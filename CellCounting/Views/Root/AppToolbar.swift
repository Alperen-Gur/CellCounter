import SwiftUI

// MARK: — Not-installed indicator pill (pass-8)
//
// Shown next to the Model pill when the active model id isn't installed yet.
// Replaces the pass-7 "Mock results" pill — there are no mocks anymore, so the
// user needs an unambiguous signal that detection will fail.

private struct ModelNotInstalledPill: View {
    /// Tap action — pass-12 makes the pill the primary install entry-point from
    /// anywhere in the app. Tapping it opens InstallCellposeSheet directly.
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                Text("Not installed")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.red)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.red.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Color.red.opacity(0.30), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("The active model isn't installed. Click to install it.")
    }
}

struct AppToolbar: View {
    @Bindable var state: AppState
    @Environment(AppTheme.self) private var theme

    /// Pass-16: family of the active model. Used to pick the correct install
    /// route and the distinct "Cellpose-SAM" pill subtitle when CPSAM is
    /// active.
    private var activeFamily: ModelFamily {
        state.models.first(where: { $0.id == state.activeModelId })?.family ?? .cellpose
    }

    /// Route the "Not installed" pill to whichever install sheet matches the
    /// active model's family — 3.x to the original sheet, 4.x to the new one.
    private func openInstallSheetForActive() {
        if activeFamily == .cellpose4 {
            state.showInstallCellpose4 = true
        } else {
            state.showInstallCellpose = true
        }
    }

    private var title: String {
        switch state.view {
        case .home:       return "Home"
        case .processing: return "Processing"
        case .results:    return state.currentBatch?.displayName ?? "Results"
        case .batch:      return "Batches"
        case .models:     return "Models"
        case .fineTune:   return "Fine-tune"
        case .settings:   return "Settings"
        case .queue:          return "Queue"
        case .reviewQueue:    return "Review queue"
        case .compare:        return "Compare conditions"
        case .imagesLibrary:  return "Images"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.01 * 15)
            Spacer()
            trailingActions
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(Tokens.bgToolbar)
        .background(.regularMaterial.opacity(0.4))
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.border).frame(height: 0.5) }
    }

    @ViewBuilder
    private var trailingActions: some View {
        switch state.view {
        case .home:
            ModelToolbarPill(state: state, family: activeFamily)
            if !state.canRunDetection {
                ModelNotInstalledPill { openInstallSheetForActive() }
            }
            Button { state.showCalibration = true } label: {
                HStack(spacing: 6) { Icon("ruler"); Text("Calibrate") }
            }.appButton()
            Button { state.view = .settings } label: { Icon("settings") }
                .appButton(.ghost)
                .frame(width: 28, height: 28)
        case .results:
            ModelToolbarPill(state: state, family: activeFamily)
            if !state.canRunDetection {
                ModelNotInstalledPill { openInstallSheetForActive() }
            }
            Button { state.showCalibration = true } label: {
                HStack(spacing: 6) { Icon("ruler"); Text(String(format: "%.1f px/µm", state.pxPerUm)) }
            }.appButton()
            Button { state.view = .home } label: { Icon("x") }
                .appButton(.ghost).frame(width: 28, height: 28)
        case .batch:
            EmptyView()
        case .fineTune:
            Button { state.view = .home } label: { Icon("x") }
                .appButton(.ghost).frame(width: 28, height: 28)
        case .queue:
            EmptyView()
        case .compare, .imagesLibrary, .models:
            ModelToolbarPill(state: state, family: activeFamily)
            if !state.canRunDetection {
                ModelNotInstalledPill { openInstallSheetForActive() }
            }
        case .processing, .settings, .reviewQueue:
            EmptyView()
        }
    }
}

// MARK: — Model pill with family-aware "v4" badge
//
// Pass-16: when the active model is in the Cellpose-SAM (cellpose 4.x) family
// the pill carries a small accent-tinted "v4" chip so the user can tell at a
// glance which Cellpose runtime is in play. 3.x models render the existing
// pill unchanged.

private struct ModelToolbarPill: View {
    @Bindable var state: AppState
    let family: ModelFamily
    @Environment(AppTheme.self) private var theme

    var body: some View {
        if family == .cellpose4 {
            Button { state.view = .models } label: {
                HStack(spacing: 6) {
                    Text("Model")
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.textTertiary)
                    Text(state.activeModelName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Tokens.text)
                    Text("v4")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(theme.accentSoft))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Tokens.bgElevated))
                .overlay(Capsule().strokeBorder(theme.accentSoft, lineWidth: 0.75))
            }
            .buttonStyle(.plain)
            .help("Active model: \(state.activeModelName) (Cellpose-SAM). Click to manage models.")
        } else {
            ToolbarPill(label: "Model", value: state.activeModelName) { state.view = .models }
        }
    }
}
