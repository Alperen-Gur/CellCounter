import SwiftUI
import SwiftData

@main
struct CellCountingApp: App {
    @State private var theme = AppTheme()
    @State private var state: AppState
    @State private var showShortcuts: Bool = false

    @MainActor init() {
        // Pass-11: run one-time data wipe BEFORE opening the SwiftData store.
        // If we built `Repositories` first, SwiftData would open the old DB
        // file (with mock-detector rows / orphan image refs) under the new
        // schema and either crash or surface ghost data again.
        FileStore.runMigrationsIfNeeded()

        // Pass-13: kill any orphaned cellpose_detect.py / install_python.sh
        // processes that survived a prior CellCounter death (PPID=1) and wire
        // the willTerminate hook so this session's children don't outlive us.
        // Otherwise stale subprocesses pin the CPU and the next detection
        // looks like it's "stuck at 0%" — that was the actual cause of the
        // hang the user saw.
        ChildProcessTracker.shared.installLifecycle()

        // Pass-13: re-stage bundled python sidecar files into the FileStore
        // python dir on every launch so script updates (bug fixes in
        // cellpose_detect.py etc.) ship with the binary instead of being
        // pinned to whatever was staged at first install. The .py helpers
        // overwrite cleanly; install_python.sh missing is swallowed here
        // (the installer path surfaces the proper StagingError when needed).
        try? PythonRuntime.stageScripts()

        // Build repositories first, then AppState that wraps them.
        let repos = Repositories()
        self._state = State(initialValue: AppState(repos: repos))
    }

    var body: some Scene {
        Window("CellCounter", id: "main") {
            RootView(state: state, showShortcuts: $showShortcuts)
                .environment(theme)
                .frame(minWidth: 1080, minHeight: 720)
                .modelContainer(state.repos.container)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About CellCounter") { state.view = .settings }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Images…") {
                    presentOpenPanel(allowedExtensions: Array(ImageLoader.supported), allowFolders: false, allowMultiple: true) { urls in
                        state.importAndAnalyze(urls: urls)
                    }
                }
                .keyboardShortcut("o", modifiers: [.command])
                Button("Open Folder…") {
                    presentOpenPanel(allowedExtensions: Array(ImageLoader.supported), allowFolders: true, allowMultiple: false) { urls in
                        guard let folder = urls.first else { return }
                        let files = enumerateImages(in: folder)
                        if !files.isEmpty { state.importAndAnalyze(urls: files) }
                    }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Analysis") {
                // Calibration shortcut uses ⌘⇧K rather than ⌘K — bare ⌘K is
                // reserved across macOS (Finder "Connect to Server", Mail "Mark",
                // Terminal "Clear Buffer", browsers focus the address bar). Users
                // hitting ⌘K expect one of those, not a modal sheet.
                Button("Calibrate scale…") { state.showCalibration = true }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Settings") { state.view = .settings }
                    .keyboardShortcut(",", modifiers: [.command])
                Button("Cancel") {
                    state.showCalibration = false
                    state.showInstallCellpose = false
                }
                .keyboardShortcut(".", modifiers: [.command])
            }
            CommandGroup(after: .help) {
                Button("Keyboard Shortcuts") { showShortcuts = true }
                    .keyboardShortcut("/", modifiers: [.command])
            }
        }
    }
}

private func enumerateImages(in folder: URL) -> [URL] {
    guard let it = FileManager.default.enumerator(at: folder,
                                                  includingPropertiesForKeys: [.isRegularFileKey],
                                                  options: [.skipsHiddenFiles]) else { return [] }
    var out: [URL] = []
    for case let url as URL in it {
        if ImageLoader.supported.contains(url.pathExtension.lowercased()) { out.append(url) }
    }
    return out
}
