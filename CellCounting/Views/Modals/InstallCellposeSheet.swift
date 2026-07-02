import SwiftUI

// MARK: - InstallCellposeSheet
//
// Visual language matches CalibrationSheet: backdrop + 560pt centered card,
// header / body / footer, soft drop-in animation. The user can:
//   • read what will be installed
//   • kick off the install (live log streams in)
//   • cancel, retry on error, or close on success.
//
// On a successful install we invoke `onInstalled` so RootView/AppState can
// resolve `state.detector` for the active model id without an app restart.

/// Pre-install detected state. Drives header copy + button labels.
private enum PreInstallState {
    case freshInstall          // missingVenv / missingScripts / missingInstaller
    case broken(reason: String) // venv exists but partial
    case alreadyInstalled      // sheet shouldn't have been opened
}

struct InstallCellposeSheet: View {
    let onClose: () -> Void
    let onInstalled: () -> Void

    @StateObject private var installer = CellposeInstaller()
    @State private var appeared = false
    @State private var preInstallState: PreInstallState = .freshInstall
    @Environment(AppTheme.self) private var theme

    private func resolvePreInstallState() -> PreInstallState {
        // K2 will replace this with `if case .venvBroken(let r) = ...`. Until
        // then we ask the shim probe, which only flags obvious broken shapes
        // (venv dir exists but pip is missing, etc.).
        if let reason = CellposeBrokenProbe.reason() {
            return .broken(reason: reason)
        }
        if case .available = CellposeAvailability.detect() {
            return .alreadyInstalled
        }
        return .freshInstall
    }

    var body: some View {
        ZStack {
            Tokens.bgOverlay
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture {
                    // Don't dismiss while a long install is running — too easy to nuke by accident.
                    if !installer.isRunning { onClose() }
                }

            VStack(spacing: 0) {
                InstallHeader(
                    theme: theme,
                    onClose: onClose,
                    disableClose: installer.isRunning,
                    preInstallState: preInstallState
                )
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

                Group {
                    if installer.isRunning || !installer.output.isEmpty || installer.done || installer.error != nil {
                        InstallRunningBody(installer: installer, theme: theme)
                    } else if case .alreadyInstalled = preInstallState {
                        InstallAlreadyDoneBody()
                    } else {
                        InstallIdleBody(preInstallState: preInstallState)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)

                InstallFooter(
                    installer: installer,
                    preInstallState: preInstallState,
                    theme: theme,
                    onStart: {
                        if case .broken = preInstallState {
                            installer.reinstall()
                        } else {
                            installer.start()
                        }
                    },
                    onCancel: {
                        installer.cancel()
                        // Clean up the partial venv so we don't end up in the
                        // exact broken-state the user is trying to escape. K2's
                        // probe will treat the absence of the venv as a clean
                        // "needs install" state.
                        try? FileManager.default.removeItem(at: FileStore.shared.pythonVenvDir)
                        // Cache + AppState mirror must re-probe after wipe.
                        NotificationCenter.default.post(name: .ccVenvChanged, object: nil)
                    },
                    onRetry: { installer.start() },
                    onDone: {
                        onInstalled()
                        onClose()
                    },
                    onClose: onClose
                )
            }
            .frame(width: 560)
            .background(Tokens.bg)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 60, y: 24)
            .offset(y: appeared ? 0 : -12)
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.98)
        }
        .onAppear {
            preInstallState = resolvePreInstallState()
            withAnimation(Tokens.Motion.easeSlow) { appeared = true }
        }
        // Esc — close (when not running)
        .onKeyPress(.escape) {
            guard !installer.isRunning else { return .ignored }
            onClose()
            return .handled
        }
        // Enter — Install / Reinstall / Retry / Done
        .onKeyPress(.return) {
            if installer.done {
                onInstalled(); onClose()
            } else if installer.error != nil {
                installer.start()
            } else if !installer.isRunning {
                if case .broken = preInstallState {
                    installer.reinstall()
                } else if case .alreadyInstalled = preInstallState {
                    onClose()
                } else {
                    installer.start()
                }
            }
            return .handled
        }
    }
}

// MARK: — Header

private struct InstallHeader: View {
    let theme: AppTheme
    let onClose: () -> Void
    let disableClose: Bool
    let preInstallState: PreInstallState

    private var title: String {
        switch preInstallState {
        case .broken: return "Reinstall Cellpose"
        case .alreadyInstalled: return "Cellpose is installed"
        case .freshInstall: return "Install Cellpose"
        }
    }

    private var subtitle: String {
        switch preInstallState {
        case .broken:
            return "Your previous Cellpose install was interrupted. Reinstalling will delete the partial environment and start fresh (~2 GB)."
        case .alreadyInstalled:
            return "Cellpose is already set up. You can close this sheet."
        case .freshInstall:
            return "CellCounter needs the Cellpose Python package to run real cell detection. This sets up a local virtual environment under the app's Resources folder (≈2 GB)."
        }
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .tracking(-0.01 * 18)
                    .foregroundStyle(Tokens.text)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: { if !disableClose { onClose() } }) {
                Icon("x", size: 14)
                    .foregroundStyle(disableClose ? Tokens.textQuaternary : Tokens.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous).fill(Tokens.bgSunken))
            }
            .buttonStyle(.plain)
            .disabled(disableClose)
        }
    }
}

// MARK: — Idle body (pre-install)

private struct InstallAlreadyDoneBody: View {
    @Environment(AppTheme.self) private var theme
    var body: some View {
        HStack(spacing: 10) {
            Icon("check", size: 14)
                .foregroundStyle(Tokens.success)
            Text("Cellpose is installed and ready to use. You can close this sheet.")
                .font(.system(size: 12.5))
                .foregroundStyle(Tokens.text)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .fill(Tokens.bgSunken)
        )
    }
}

private struct InstallIdleBody: View {
    let preInstallState: PreInstallState
    @Environment(AppTheme.self) private var theme

    private let packages: [(name: String, desc: String)] = [
        ("cellpose",      "the segmentation model"),
        ("torch",         "deep-learning runtime (~700 MB)"),
        ("scikit-image",  "image post-processing"),
        ("numpy, pillow", "array + image I/O"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(packages, id: \.name) { pkg in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(theme.accentColor)
                            .frame(width: 5, height: 5)
                            .padding(.top, 5)
                        HStack(spacing: 6) {
                            Text(pkg.name)
                                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Tokens.text)
                            Text("— \(pkg.desc)")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Tokens.textTertiary)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .fill(Tokens.bgSunken)
            )

            HStack(spacing: 6) {
                Icon("info", size: 12)
                    .foregroundStyle(Tokens.textTertiary)
                Text("About 2 GB on disk · 3–5 minutes on most Macs · one-time setup.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
    }
}

// MARK: — Running / done / error body

private struct InstallRunningBody: View {
    @ObservedObject var installer: CellposeInstaller
    let theme: AppTheme

    private var tail: [String] {
        let last = installer.output.suffix(12)
        return Array(last)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if installer.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                } else if installer.done {
                    HStack(spacing: 6) {
                        Icon("check", size: 12)
                            .foregroundStyle(Tokens.success)
                        Text("Cellpose installed.")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Tokens.text)
                    }
                } else if installer.error != nil {
                    HStack(spacing: 6) {
                        Icon("info", size: 12)
                            .foregroundStyle(Tokens.danger)
                        Text("Install failed.")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Tokens.danger)
                    }
                }
            }

            if !installer.progressHint.isEmpty {
                Text(installer.progressHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textSecondary)
            }

            // Live tail
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(tail.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Tokens.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                        Color.clear.frame(height: 1).id("tail-bottom")
                    }
                    .padding(10)
                }
                .frame(height: 168)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                        .fill(Tokens.bgSunken)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                        .strokeBorder(Tokens.border, lineWidth: 0.5)
                )
                .onChange(of: installer.output.count) { _, _ in
                    withAnimation(Tokens.Motion.easeFast) {
                        proxy.scrollTo("tail-bottom", anchor: .bottom)
                    }
                }
            }

            if let err = installer.error {
                Text(err)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Tokens.danger)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: — Footer

private struct InstallFooter: View {
    @ObservedObject var installer: CellposeInstaller
    let preInstallState: PreInstallState
    let theme: AppTheme
    let onStart: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onDone: () -> Void
    let onClose: () -> Void

    private var primaryLabel: String {
        if case .broken = preInstallState { return "Reinstall" }
        return "Install Cellpose"
    }

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            if installer.done {
                Button("Done", action: onDone)
                    .appButton(.primary)
            } else if installer.error != nil {
                Button("Close", action: onClose)
                    .appButton(.standard)
                Button("Retry", action: onRetry)
                    .appButton(.primary)
            } else if installer.isRunning {
                // Cancel now also wipes the partial venv (see onCancel in parent).
                // The button copy still reads "Cancel" — the cleanup is silent.
                Button("Cancel", action: onCancel)
                    .appButton(.danger)
            } else if case .alreadyInstalled = preInstallState {
                Button("Close", action: onClose)
                    .appButton(.primary)
            } else {
                Button("Not now", action: onClose)
                    .appButton(.standard)
                Button(primaryLabel, action: onStart)
                    .appButton(.primary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Tokens.bgSunken)
        .overlay(
            Divider().frame(maxWidth: .infinity, maxHeight: 0.5), alignment: .top
        )
    }
}
