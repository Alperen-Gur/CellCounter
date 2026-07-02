import SwiftUI

struct AnalysisPanel: View {
    @Bindable var state: AppState
    @Binding var profileMode: Bool

    @Environment(AppTheme.self) private var theme

    private var currentImage: ImageRecord? { state.currentImage }

    var body: some View {
        VStack(spacing: 0) {
            // ── ANALYZE header ────────────────────────────────────────────
            SectionHeader(title: "ANALYZE")

            Divider().overlay(Tokens.divider)

            // ── Intensity histogram ───────────────────────────────────────
            VStack(alignment: .leading, spacing: 10) {
                Text("Intensity histogram")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Tokens.textSecondary)

                if let img = currentImage {
                    IntensityHistogram(image: img)
                } else {
                    // Placeholder when no image is loaded
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                        .fill(Tokens.bgSunken)
                        .frame(height: 80)
                        .overlay(
                            Text("No image loaded")
                                .font(.system(size: 11))
                                .foregroundStyle(Tokens.textTertiary)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                                .strokeBorder(Tokens.border, lineWidth: 0.5)
                        )
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            Divider().overlay(Tokens.divider)

            // ── Line profile ──────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 10) {
                Text("Line profile")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Tokens.textSecondary)

                Button {
                    withAnimation(Tokens.Motion.easeFast) {
                        profileMode.toggle()
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: profileMode ? "xmark" : "line.diagonal")
                            .font(.system(size: 12))
                        Text(profileMode ? "Cancel profile" : "Draw a line on the image")
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .appButton(profileMode ? .danger : .standard, size: .sm)
                .animation(Tokens.Motion.easeFast, value: profileMode)

                if profileMode {
                    Text("Tap the image once to set the start, again to set the end. A third tap resets.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Tokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
    }
}
