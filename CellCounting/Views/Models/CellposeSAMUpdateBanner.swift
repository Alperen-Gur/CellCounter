import SwiftUI

// MARK: - CellposeSAMUpdateBanner
//
// Shown in Models when venv4 has a working Cellpose other than the version
// CellCounter pins (`CellposeSAMRuntime.pinnedCellposeVersion`). Nothing
// updates by itself: analyses keep using the installed Cellpose until the
// user clicks the button, which opens the Cellpose-SAM sheet and starts the
// update there, with its log in view.

struct CellposeSAMUpdateBanner: View {
    @Bindable var state: AppState
    @Environment(AppTheme.self) private var theme

    private var status: CellposeSAMRuntime.Status {
        // Re-evaluated whenever the install cache publishes; its probe stores
        // the version before it publishes the verdict.
        _ = state.installStateCache.generation
        return CellposeSAMRuntime.cachedStatus()
    }

    /// The update replaces packages a running analysis may be using.
    private var analysisRunning: Bool { state.jobScheduler.activeCount > 0 }

    private var pinned: String { CellposeSAMRuntime.pinnedCellposeVersion }

    var body: some View {
        if case .updateAvailable(let installed) = status {
            let old = installed.map { "Cellpose \($0)" } ?? "an older Cellpose"
            HStack(alignment: .center, spacing: 12) {
                Icon("refresh", size: 15)
                    .foregroundStyle(theme.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cellpose-SAM can be updated to Cellpose \(pinned)")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                    Text("This Mac has \(old). Until you update, analyses keep using it. "
                         + "Results can differ slightly from runs made with the old version; "
                         + "the version is recorded with every result. Cellpose-SAM v2 needs the update.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Update Cellpose-SAM to \(pinned)") {
                    state.cellpose4UpdateRequested = true
                    state.showInstallCellpose4 = true
                }
                .appButton(.primary, size: .sm)
                .disabled(analysisRunning)
                .help(analysisRunning
                      ? "Pause or finish the running analyses first: the update replaces packages they use."
                      : "Installs the tested package set into the Cellpose-SAM environment. Takes a few minutes.")
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
            .padding(.bottom, 16)
        }
    }
}
