import SwiftUI

/// Scene-attached protocol actions shared by menus and the shortcuts reference.
struct AnalysisProtocolCommands: Commands {
    let state: AppState
    var shortcutsPresented = false

    var body: some Commands {
        CommandMenu("Protocols") {
            Button("Analysis Protocols\u{2026}") {
                state.showAnalysisProtocols = true
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(shortcutsPresented || shortcutsPresented || KeyboardShortcutContext.hasOverlay(state) || KeyboardShortcutContext.hasNativeSheet)

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
