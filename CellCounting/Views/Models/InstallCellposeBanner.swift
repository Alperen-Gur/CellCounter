import SwiftUI

// MARK: - InstallCellposeBanner
//
// Top banner for the Models view header, prompting the user to install Cellpose
// when `CellposeAvailability.detect()` is anything other than `.available`.
//
// SPLICE POINT: Drop `InstallCellposeBanner(state: state)` inside
// `ModelsView.body`'s VStack just above the `ModelsFilterChips` row — i.e. right
// below the existing `ModelsBanner` block:
//
//   if !state.modelsBannerDismissed { ModelsBanner(...) }
//   InstallCellposeBanner(state: state)        // ← here
//       .padding(.bottom, 16)
//   ModelsFilterChips(...)
//
// The banner self-hides when Cellpose is already available or when the user has
// dismissed it once (persisted under `cc-install-banner-dismissed`).

struct InstallCellposeBanner: View {
    @Bindable var state: AppState
    @Environment(AppTheme.self) private var theme
    @State private var dismissed: Bool = UserDefaults.standard.bool(forKey: "cc-install-banner-dismissed")
    @State private var available: Bool = {
        if case .available = CellposeAvailability.detect() { return true }
        return false
    }()

    private var shouldShow: Bool { !dismissed && !available }

    var body: some View {
        Group {
            if shouldShow {
                HStack(alignment: .center, spacing: 12) {
                    Icon("sparkles", size: 15)
                        .foregroundStyle(theme.accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cellpose isn't installed yet — detection is disabled until you install it.")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Tokens.text)
                        Text("~2 GB, one-time setup. Takes about 4 minutes.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Tokens.textTertiary)
                    }

                    Spacer()

                    Button("Install Cellpose…") {
                        state.showInstallCellpose = true
                    }
                    .appButton(.primary, size: .sm)

                    Button(action: dismiss) {
                        Icon("x", size: 13)
                            .foregroundStyle(Tokens.textSecondary)
                    }
                    .appButton(.ghost, size: .sm)
                }
                .padding(.horizontal, 16)
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
        }
        .onChange(of: state.showInstallCellpose) { _, isShowing in
            // When the install sheet closes, re-check availability so the banner
            // disappears after a successful install without needing a navigation roundtrip.
            if !isShowing { refreshAvailability() }
        }
    }

    private func dismiss() {
        dismissed = true
        UserDefaults.standard.set(true, forKey: "cc-install-banner-dismissed")
    }

    private func refreshAvailability() {
        if case .available = CellposeAvailability.detect() {
            available = true
        }
    }
}
