import SwiftUI

struct RootView: View {
    @Bindable var state: AppState
    @Binding var showShortcuts: Bool
    @Environment(AppTheme.self) private var theme
    @Environment(\.colorScheme) private var scheme

    /// Pass-15: full-screen edit mode for the Results viewer. When true, the
    /// left sidebar, top AppToolbar, and right ResultsSidebar all collapse so
    /// the image canvas fills the window. Toggled from the viewer toolbar,
    /// Esc, or ⌘⇧F (handled inside ResultsView).
    @State private var fullScreenEdit: Bool = false

    /// Full-screen edit only applies when we're actually on the Results view.
    private var isFullScreen: Bool { fullScreenEdit && state.view == .results }

    var body: some View {
        ZStack {
            // Wallpaper-ish backdrop visible behind the window's rounded corners
            backdrop.ignoresSafeArea()

            // The "app window" — but since we host inside a real macOS window already,
            // we draw the window-internal shell only (titlebar provided natively).
            HStack(spacing: 0) {
                if !isFullScreen {
                    AppSidebar(state: state)
                }
                VStack(spacing: 0) {
                    if !isFullScreen {
                        AppToolbar(state: state)
                    }
                    contentBody
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Tokens.bg)
                }
            }
            .background(Tokens.bg)
            .preferredColorScheme(theme.colorScheme)
            .tint(theme.accentColor)

            if state.showCalibration {
                CalibrationSheet(
                    current: state.pxPerUm,
                    // Bug #11: pass current image URL so "Draw on scale bar" tab can show the real image
                    imageURL: state.currentImage?.storedURL,
                    // Pass-13: hand the repo through so the "Use preset" tab
                    // can list user-saved presets and create new ones inline.
                    repos: state.repos,
                    onClose: { state.showCalibration = false },
                    onSave: { state.pxPerUm = $0 })
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(50)
            }
            if state.showOnboarding {
                OnboardingSheet(onClose: { state.completeOnboarding() })
                    .transition(.opacity)
                    .zIndex(60)
            }
            if state.showInstallCellpose {
                InstallCellposeSheet(
                    onClose: { state.showInstallCellpose = false },
                    onInstalled: { state.refreshDetector() })
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(55)
            }
            // Pass-16: Cellpose-SAM (cellpose 4.x) install sheet. Distinct from
            // the 3.x sheet — both can theoretically be presented in sequence
            // (user installs 3.x, then comes back to install 4.x) but they're
            // mutually exclusive at any given moment.
            if state.showInstallCellpose4 {
                InstallCellpose4Sheet(
                    onClose: { state.showInstallCellpose4 = false },
                    onInstalled: { state.refreshDetector() })
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(55)
            }
            if showShortcuts {
                KeyboardShortcutsSheet(onClose: { showShortcuts = false })
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(70)
            }
            // Pass-17: duplicate import prompt
            if state.showDuplicateImportSheet, let session = state.pendingDuplicateSession {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    DuplicateImportSheet(state: state, session: session)
                        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
                }
                .transition(.opacity)
                .zIndex(80)
            }
        }
        .animation(.easeOut(duration: 0.24), value: state.showCalibration)
        .animation(.easeOut(duration: 0.24), value: state.showOnboarding)
        .animation(.easeOut(duration: 0.24), value: state.showInstallCellpose)
        .animation(.easeOut(duration: 0.24), value: state.showInstallCellpose4)
        .animation(.easeOut(duration: 0.24), value: showShortcuts)
        .animation(.easeOut(duration: 0.20), value: state.showDuplicateImportSheet)
        .animation(.easeInOut(duration: 0.24), value: state.view)
        .animation(.easeInOut(duration: 0.18), value: fullScreenEdit)
        .onChange(of: state.view) { _, newView in
            // Leaving Results always exits full-screen so the user doesn't get
            // stranded in a chrome-less window on a non-Results screen.
            if newView != .results { fullScreenEdit = false }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        switch state.view {
        case .home:       HomeView(state: state)
        case .processing: ProcessingView(state: state)
        case .results:    ResultsView(state: state, fullScreenEdit: $fullScreenEdit)
        case .batch:      BatchView(state: state)
        case .models:     ModelsView(state: state)
        case .fineTune:   FineTuneView(state: state)
        case .settings:   SettingsView(state: state)
        case .queue:          QueueEmpty(state: state)
        case .reviewQueue:    ReviewQueueView(state: state)
        case .compare:        CompareView(state: state)
        case .imagesLibrary:  ImagesLibraryView(state: state)
        }
    }

    private var backdrop: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(OKLCH(0.25, 0.04, 50)), Color(OKLCH(0.18, 0.06, 285))]
                : [Color(OKLCH(0.78, 0.06, 50)), Color(OKLCH(0.55, 0.10, 285))],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
