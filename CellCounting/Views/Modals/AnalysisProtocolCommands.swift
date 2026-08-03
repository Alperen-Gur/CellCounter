import SwiftUI

/// Menu commands for analysis protocols + GeoJSON export.
///
/// NOT YET WIRED UP: `Commands` groups only take effect when attached to a
/// `Scene` via the `.commands { }` modifier, which lives in
/// `CellCountingApp.swift` (outside this agent's ownership for this pass —
/// see the task's file-ownership list). To wire this in, add one line to
/// that file's existing `.commands { }` block:
/// ```swift
/// .commands {
///     CommandGroup(replacing: .appInfo) { ... }
///     CommandGroup(replacing: .newItem) { ... }
///     CommandMenu("Analysis") { ... }
///     AnalysisProtocolCommands(state: state)   // <- add this line
///     CommandGroup(after: .help) { ... }
/// }
/// ```
/// Until then, `Views/Modals/AnalysisProtocolSheet.swift` and
/// `Views/Results/GeoJSONExportPanel.swift` remain reachable as plain
/// SwiftUI views (e.g. for manual testing / preview) even though no menu
/// item or toolbar button opens them yet.
struct AnalysisProtocolCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandMenu("Protocols") {
            Button("Analysis Protocols\u{2026}") {
                state.showAnalysisProtocols = true
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

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
            .disabled(state.currentImage?.detection == nil)
        }
    }
}
