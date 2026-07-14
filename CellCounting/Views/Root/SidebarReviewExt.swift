import SwiftUI

/// Sidebar entry for the Review queue, provided without touching Sidebar.swift.
///
/// Integration note (for the Sidebar owner):
///   Splice `ReviewNavItem(state: state)` into `AppSidebar.body` right after the
///   existing "Queue" NavItemView, i.e. between:
///       NavItemView(icon: "queue", label: "Queue", count: 6, isActive: …) { … }
///   and the `SidebarSectionLabel(text: "Library")` block.
///
/// Routes to `state.view = .reviewQueue`. The badge count reads from
/// `state.reviewQueueCount` — an @Observable mirror on `AppState` that's
/// refreshed by `refreshLibraryStats()` on app launch, after each detection
/// import, after `recordCorrection`, and on `ccCorrectionsChanged` /
/// `ccLibraryChanged` notifications. No local cache, no sync repo call in body.
///
/// `reviewQueueCount` traces back to `Repositories.uncorrectedCellCount(below:)`,
/// which now walks the identical `allBatches() → batch.images → image.detection
/// → detection.cells` path (and the identical confidence/corrected-exclusion
/// predicates) that `ReviewQueueView.rebuild()` uses to build the on-screen
/// cards — so this number and the queue's card count are guaranteed to agree.
/// `count == 0 ? nil : count` below only hides the numeral when the badge is
/// zero; it never re-derives the value, so keep the two counting functions in
/// lockstep if either one's membership rule ever changes.
struct ReviewNavItem: View {
    @Bindable var state: AppState

    var body: some View {
        let count = state.reviewQueueCount
        ReviewNavRow(
            label: "Review queue",
            count: count == 0 ? nil : count,
            isActive: state.view == .reviewQueue
        ) {
            state.view = .reviewQueue
        }
    }
}

/// Visual twin of `NavItemView` but with the literal "checklist" SF Symbol
/// (which isn't in the project's Icon name map). Kept private so it doesn't
/// leak as a general-purpose alternative.
private struct ReviewNavRow: View {
    let label: String
    var count: Int? = nil
    let isActive: Bool
    let action: () -> Void

    @Environment(AppTheme.self) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "checklist")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(isActive ? theme.accentColor : Tokens.textSecondary)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? theme.accentColor : Tokens.text)
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(isActive ? theme.accentColor.opacity(0.85) : Tokens.textTertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .fill(isActive ? theme.accentSoftAdaptive(for: scheme) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
