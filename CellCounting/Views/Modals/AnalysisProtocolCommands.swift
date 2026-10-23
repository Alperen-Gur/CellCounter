import SwiftUI

/// Scene-attached protocol actions shared by menus and the shortcuts reference.
struct AnalysisProtocolCommands: Commands {
    let state: AppState
    var shortcutsPresented = false

    var body: some Commands {
        CommandMenu("Workflows") {
            Button("Project Workflows") {
                state.workbenchSession.task = .workflows
                state.view = .workbench
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(shortcutsPresented || KeyboardShortcutContext.hasOverlay(state) || KeyboardShortcutContext.hasNativeSheet)

            Button("Existing Library Analysis Protocols\u{2026}") {
                state.showAnalysisProtocols = true
            }
            .disabled(state.view == .workbench || state.view == .settings || shortcutsPresented || KeyboardShortcutContext.hasOverlay(state) || KeyboardShortcutContext.hasNativeSheet)

            Divider()

            Button("Export GeoJSON\u{2026}") {
                presentGeoJSONExport(state: state) { result in
                    switch result {
                    case .success(let url):
                        state.flashExport("Saved \(url.lastPathComponent)", isError: false)
                    case .failure(let error):
                        state.flashExport(error.localizedDescription, isError: true)
                    }
                }
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(state.currentImage?.detection == nil || ![AppView.results, .batch].contains(state.view)
                      || shortcutsPresented || KeyboardShortcutContext.hasOverlay(state) || KeyboardShortcutContext.hasNativeSheet)
        }
    }
}
