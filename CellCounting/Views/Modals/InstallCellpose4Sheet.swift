import SwiftUI

// MARK: - InstallCellpose4Sheet
//
// Pass-16 (C3): install sheet variant for the Cellpose-SAM (cellpose 4.x)
// family. Lives alongside `InstallCellposeSheet` rather than refactoring the
// 3.x sheet — the visual structure is similar but the copy, disk estimate, and
// the second-stage "weights download lazily on first detection" warning are
// distinct enough that interleaving the two branches in one View would obscure
// both. The 3.x sheet stays bit-for-bit identical.
//
// Talks to `CellposeSAMInstaller` (shipped by C2). The installer drives
// `scripts/install_python_cp4.sh`, builds a SEPARATE venv at
// `python/venv4/`, and streams stderr lines the same way the 3.x installer
// does. After pip install succeeds, the sheet does NOT eagerly download the
// CPSAM weights — cellpose 4.x downloads them lazily on first
// `CellposeModel()` construction. Triggering that here would couple us to a
// private cellpose API; we surface a second-stage warning instead.

/// Pre-install state mirror — distinct from the 3.x sheet's enum so the cases
/// can diverge without breaking the 3.x flow.
private enum CP4PreInstallState {
    case freshInstall
    case broken(reason: String)
    case alreadyInstalled
}

struct InstallCellpose4Sheet: View {
    let onClose: () -> Void
    let onInstalled: () -> Void

    @StateObject private var installer = CellposeSAMInstaller()
    @State private var appeared = false
    @State private var preInstallState: CP4PreInstallState = .freshInstall
    @Environment(AppTheme.self) private var theme

    private func resolvePreInstallState() -> CP4PreInstallState {
        if let reason = Cellpose4BrokenProbe.reason() {
            return .broken(reason: reason)
        }
        if case .available = Cellpose4Availability.detect() {
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
                    if !installer.isRunning { onClose() }
                }

            VStack(spacing: 0) {
                CP4Header(
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
                        CP4RunningBody(installer: installer, theme: theme)
                    } else if case .alreadyInstalled = preInstallState {
                        CP4AlreadyDoneBody()
                    } else {
                        CP4IdleBody(preInstallState: preInstallState)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)

                CP4Footer(
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
                        // Wipe the partial venv4 so the user lands in a clean
                        // "needs install" state, not "broken".
                        try? FileManager.default.removeItem(
                            at: FileStore.shared.pythonVenv4Dir)
                        NotificationCenter.default.post(name: .ccVenv4Changed, object: nil)
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
        .onKeyPress(.escape) {
            guard !installer.isRunning else { return .ignored }
            onClose()
            return .handled
        }
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

private struct CP4Header: View {
    let theme: AppTheme
    let onClose: () -> Void
    let disableClose: Bool
    let preInstallState: CP4PreInstallState

    private var title: String {
        switch preInstallState {
        case .broken: return "Reinstall Cellpose-SAM"
        case .alreadyInstalled: return "Cellpose-SAM is installed"
        case .freshInstall: return "Install Cellpose-SAM"
        }
    }

    private var subtitle: String {
        switch preInstallState {
        case .broken:
            return "Your previous Cellpose-SAM install was interrupted. Reinstalling will delete the partial environment and start fresh."
        case .alreadyInstalled:
            return "Cellpose-SAM is already set up. You can close this sheet."
        case .freshInstall:
            return "Cellpose-SAM (cellpose 4.x) runs in a SEPARATE Python environment from Cellpose 3.x — both can coexist. This is a one-time setup."
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

// MARK: — Already-done body

private struct CP4AlreadyDoneBody: View {
    @Environment(AppTheme.self) private var theme
    var body: some View {
        HStack(spacing: 10) {
            Icon("check", size: 14)
                .foregroundStyle(Tokens.success)
            Text("Cellpose-SAM is installed and ready to use. You can close this sheet.")
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

// MARK: — Idle body (pre-install)

private struct CP4IdleBody: View {
    let preInstallState: CP4PreInstallState
    @Environment(AppTheme.self) private var theme

    private let packages: [(name: String, desc: String)] = [
        ("cellpose>=4",  "Cellpose-SAM (CPSAM transformer)"),
        ("torch",        "deep-learning runtime (~700 MB)"),
        ("scikit-image", "image post-processing"),
        ("numpy, pillow","array + image I/O"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Prominent disk-usage warning. Different shape from the 3.x sheet
            // — CPSAM downloads ~1.15 GB of transformer weights on first
            // detection, on top of the ~2 GB of Python dependencies.
            HStack(alignment: .top, spacing: 10) {
                Icon("info", size: 14)
                    .foregroundStyle(theme.accentColor)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Disk usage: ~3.5 GB on first run")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                    Text("~1.15 GB weights + ~2 GB Python deps. The weights download lazily on your first detection run, not now.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .fill(theme.accentSofter)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .strokeBorder(theme.accentSoft, lineWidth: 0.5)
            )

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
                Text("Separate from your Cellpose 3.x install — both can be kept. ~5–8 minutes on most Macs.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
    }
}

// MARK: — Running / done / error body

private struct CP4RunningBody: View {
    @ObservedObject var installer: CellposeSAMInstaller
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
                        Text("Cellpose-SAM installed.")
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

            // Second-stage warning, shown ONLY after pip install completes.
            // The CPSAM weights are not downloaded here on purpose — cellpose
            // 4 fetches them lazily on first `CellposeModel()` construction.
            if installer.done {
                HStack(alignment: .top, spacing: 8) {
                    Icon("info", size: 12)
                        .foregroundStyle(theme.accentColor)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Weights will download on first detection")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Tokens.text)
                        Text("~1.15 GB of model weights download the first time you press Detect on an image.")
                            .font(.system(size: 11))
                            .foregroundStyle(Tokens.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                        .fill(theme.accentSofter)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                        .strokeBorder(theme.accentSoft, lineWidth: 0.5)
                )
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

private struct CP4Footer: View {
    @ObservedObject var installer: CellposeSAMInstaller
    let preInstallState: CP4PreInstallState
    let theme: AppTheme
    let onStart: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onDone: () -> Void
    let onClose: () -> Void

    private var primaryLabel: String {
        if case .broken = preInstallState { return "Reinstall" }
        return "Install Cellpose-SAM"
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

// MARK: — Cellpose4BrokenProbe shim
//
// Mirror of `CellposeBrokenProbe.reason()` but for the venv4 directory + the
// `cc-cellpose4-importable` cache key. C2 may ship a richer probe inside
// `Cellpose4Availability` — when it lands we can drop this shim. Lives here so
// the sheet compiles independently of C2.

enum Cellpose4BrokenProbe {
    static func reason() -> String? {
        let fm = FileManager.default
        // Mirror of CellposeBrokenProbe — the cp4 install sentinel beats every
        // filesystem heuristic. C2 owns the sentinel writes; we only read.
        if fm.fileExists(atPath: FileStore.shared.cellpose4InstallIncompleteSentinel.path) {
            return "the previous Cellpose-SAM install was cancelled or crashed mid-flight."
        }
        let venv4 = FileStore.shared.pythonVenv4Dir
        guard fm.fileExists(atPath: venv4.path) else { return nil }
        let pip = venv4.appendingPathComponent("bin/pip")
        let python = venv4.appendingPathComponent("bin/python3")
        if !fm.fileExists(atPath: pip.path) {
            return "pip is missing — the previous Cellpose-SAM install was interrupted."
        }
        if !fm.isExecutableFile(atPath: python.path) {
            return "the python interpreter in venv4 is missing or not executable."
        }
        if let cached = UserDefaults.standard.object(forKey: "cc-cellpose4-importable") as? Bool,
           cached == false {
            return "the cellpose 4 package is not importable from venv4."
        }
        return nil
    }
}

// MARK: — Notification namespace

extension Notification.Name {
    /// Posted whenever the cellpose-4 venv directory is created or removed
    /// out-of-band (Settings → Reset, CellposeSAMInstaller, the user wiping
    /// it via Finder). Separate from `ccVenvChanged` so 3.x ↔ 4.x state
    /// changes don't trip each other's UI.
    static let ccVenv4Changed = Notification.Name("ccVenv4Changed")

    /// Pass-16: emitted by CellposeSAMInstaller when an install completes
    /// successfully. Mirror of `cellpose-install-completed` (3.x). Models
    /// view + AppState observe this to flip CPSAM rows from "Get" to
    /// "Activate" without a manual refresh.
    static let ccCellposeSAMInstallCompleted = Notification.Name("cellpose-sam-install-completed")
}
