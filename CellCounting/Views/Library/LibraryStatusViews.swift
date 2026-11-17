import AppKit
import SwiftUI

/// Banners above the main content: the persistent "changes will not be
/// saved" warning when the store could not be opened from disk, the one-time
/// notice after the database was copied before an upgrade, and the launch
/// notice when the remembered library was unavailable.
struct LibraryStatusBanners: View {
    let state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let error = state.repos.diskStoreError {
                LibraryBanner(
                    tint: Tokens.danger,
                    icon: "exclamationmark.octagon.fill",
                    title: "Changes will not be saved",
                    message: "CellCounter could not open the library database at \(state.libraries.libraryRoot.path) and is working from temporary memory. Everything you import or edit in this session is lost when you quit. (\(error))",
                    actions: {
                        Button("Show in Finder") { state.libraries.showLibraryInFinder() }
                            .appButton(.standard, size: .sm)
                        Button("Open Library…") { state.libraries.presentOpenLibrary(state: state) }
                            .appButton(.standard, size: .sm)
                            .disabled(state.libraries.isSwitching || state.libraries.switchingUnavailableReason != nil)
                    })
            }
            if let backup = state.libraries.upgradeBackupURL {
                LibraryBanner(
                    tint: Tokens.warning,
                    icon: "externaldrive.badge.checkmark",
                    title: "Library upgraded · safety copy saved",
                    message: LibraryStoreBackup.notice(for: backup),
                    actions: {
                        Button("Show Copy in Finder") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
                            .appButton(.standard, size: .sm)
                        Button("Dismiss") { state.libraries.upgradeBackupURL = nil }
                            .appButton(.standard, size: .sm)
                    })
            }
            if let notice = state.libraries.startupNotice {
                LibraryBanner(
                    tint: Tokens.warning,
                    icon: "externaldrive.badge.exclamationmark",
                    title: "Library not available",
                    message: notice,
                    actions: {
                        Button("Dismiss") { state.libraries.startupNotice = nil }
                            .appButton(.standard, size: .sm)
                    })
            }
        }
    }
}

private struct LibraryBanner<Actions: View>: View {
    let tint: Color
    let icon: String
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { actions() }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(tint.opacity(0.35)).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
    }
}

/// "Keratinocytes 2026 · 212 images" with the library's location. Used at the
/// top of the library overview (Home).
struct LibraryHeader: View {
    let state: AppState

    var body: some View {
        let libraries = state.libraries
        HStack(spacing: 10) {
            Image(systemName: libraries.isArchive ? "archivebox" : "books.vertical")
                .font(.system(size: 15))
                .foregroundStyle(Tokens.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(libraries.kindLabel.uppercased())
                    .tracking(0.04 * 10.5)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Tokens.textTertiary)
                Text(libraries.summary(imageCount: state.libraryImageCount))
                    .font(.system(size: 14, weight: .semibold))
            }
            Spacer(minLength: 8)
            Button("Show in Finder") { libraries.showLibraryInFinder() }
                .appButton(.ghost, size: .sm)
        }
        .help(libraries.libraryRoot.path)
    }
}

/// Covers the window while the app saves and relaunches into another library.
struct LibrarySwitchingOverlay: View {
    let name: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.regular)
                Text("Opening “\(name)”…").font(.system(size: 13, weight: .semibold))
                Text("CellCounter saves your work and restarts with the other library.")
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.textSecondary)
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous).fill(Tokens.bgElevated))
        }
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}
