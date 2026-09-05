import SwiftUI

// MARK: - InstallCellposeBanner
//
// Top banner for the Models view header, prompting the user to install Cellpose
// when `CellposeAvailability.detect()` is anything other than `.available`.
// Self-hides when Cellpose is already available or when the user has dismissed
// it once (persisted under `cc-install-banner-dismissed`).

struct InstallCellposeBanner: View {
    @Bindable var state: AppState
    @Environment(AppTheme.self) private var theme
    @State private var dismissed: Bool = UserDefaults.standard.bool(forKey: "cc-install-banner-dismissed")
    private var shouldShow: Bool {
        !dismissed && state.models.contains {
            $0.family == .cellpose && state.installStateCache.get($0.id) == .notInstalled
        }
    }

    var body: some View {
        Group {
            if shouldShow {
                HStack(alignment: .center, spacing: 12) {
                    Icon("sparkles", size: 15)
                        .foregroundStyle(theme.accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Install Cellpose to use its cell segmentation models.")
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

    }

    private func dismiss() {
        dismissed = true
        UserDefaults.standard.set(true, forKey: "cc-install-banner-dismissed")
    }

}
