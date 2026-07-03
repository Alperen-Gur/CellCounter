import SwiftUI
import AppKit

// MARK: - SupportSheet

struct SupportSheet: View {
    let onClose: () -> Void
    @Environment(AppTheme.self) private var theme

    private let appVersion: String = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "142"
        return "\(v) (build \(b))"
    }()

    private let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    var body: some View {
        ZStack {
            Tokens.bgOverlay
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Support")
                            .font(.system(size: 18, weight: .bold))
                            .tracking(-0.02 * 18)
                            .foregroundStyle(Tokens.text)
                        Text("Version \(appVersion) · \(osVersion)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Tokens.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Button(action: onClose) {
                        Icon("x", size: 14)
                            .foregroundStyle(Tokens.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Tokens.bgElevated)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Tokens.borderStrong, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 20)

                Rectangle().fill(Tokens.divider).frame(height: 0.5)

                // Body
                VStack(alignment: .leading, spacing: 16) {
                    // Info card
                    VStack(spacing: 0) {
                        SupportInfoRow(label: "App version", value: appVersion)
                        SupportInfoRow(label: "macOS", value: osVersion)
                        SupportInfoRow(label: "Contact", value: "support@cellcounter.local")
                    }
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                            .strokeBorder(Tokens.border, lineWidth: 0.5)
                    )

                    // Quick actions
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Quick actions".uppercased())
                            .tracking(0.04 * 11)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Tokens.textTertiary)

                        HStack(spacing: 8) {
                            Button {
                                NSWorkspace.shared.open(
                                    URL(string: "mailto:support@cellcounter.local?subject=CellCounter%20support%20request&body=App%20version%3A%20\(appVersion)%0AmacOS%3A%20\(osVersion)")!
                                )
                            } label: {
                                HStack(spacing: 6) {
                                    Icon("mail", size: 13)
                                    Text("Email support")
                                }
                            }
                            .appButton(.primary, size: .sm)

                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([FileStore.shared.root])
                            } label: {
                                HStack(spacing: 6) {
                                    Icon("folder", size: 13)
                                    Text("Reveal logs in Finder")
                                }
                            }
                            .appButton(.standard, size: .sm)
                        }
                    }

                    // Helpful hints
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Common questions".uppercased())
                            .tracking(0.04 * 11)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Tokens.textTertiary)

                        VStack(spacing: 0) {
                            SupportHintRow(
                                question: "Where is my data stored?",
                                answer: "~/Library/Containers/alguer.CellCounting/Data/Library/Application Support/CellCounter/ — all images, thumbnails and the SQLite database live here."
                            )
                            SupportHintRow(
                                question: "Is anything uploaded?",
                                answer: "No. Everything runs locally on your Mac. Model weights are downloaded once from public sources (Cellpose, Hugging Face) and then cached on disk."
                            )
                            SupportHintRow(
                                question: "Fine-tuned models",
                                answer: "Custom models stay on your Mac unless you manually export them via File › Export Model."
                            )
                        }
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                                .strokeBorder(Tokens.border, lineWidth: 0.5)
                        )
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 520)
            .background(Tokens.bg)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous)
                    .strokeBorder(Tokens.border, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 32, y: 8)
        }
    }
}

// MARK: - SupportInfoRow

private struct SupportInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Tokens.text)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Tokens.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.divider).frame(height: 0.5) }
    }
}

// MARK: - SupportHintRow

private struct SupportHintRow: View {
    let question: String
    let answer: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Tokens.Motion.easeFast) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Text(question)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Tokens.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Icon("chevron", size: 11)
                        .foregroundStyle(Tokens.textTertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(answer)
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.divider).frame(height: 0.5) }
    }
}
