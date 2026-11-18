import SwiftUI

/// Model resource use wherever a run is set up or visible: a compact
/// "Resource use: Balanced ▾" menu. Choosing a preset applies to a running
/// analysis at once (see `AppState.modelResourcesDidChange`).
struct ModelResourceMenu: View {
    @Bindable var state: AppState
    /// Off inside sheets, where opening Settings would leave the sheet open.
    var showsSettingsLink = true

    private var presetBinding: Binding<ModelResourcePreset> {
        Binding(get: { state.modelResourcePreset },
                set: { state.selectModelResourcePreset($0) })
    }

    var body: some View {
        let limits = state.modelResourceLimits
        Menu {
            Picker("Resource use", selection: presetBinding) {
                ForEach(ModelResourcePreset.allCases, id: \.self) { preset in
                    Text(preset.menuTitle).tag(preset)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if showsSettingsLink {
                Divider()
                Button("Resource Use Settings…") { state.openModelResourceSettings() }
            }
        } label: {
            Label("Resource use: \(state.modelResourcePreset.label)", systemImage: "speedometer")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("\(state.modelResourcePreset.purpose). \(limits.summary). You can switch while an analysis runs.")
    }
}

/// One line for the analysis setup sheet: the menu plus what it means.
struct ModelResourceInlineRow: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            ModelResourceMenu(state: state, showsSettingsLink: false)
            Text(state.modelResourceLimits.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }
}

/// App menu ▸ Model Resource Use, available at any time.
struct ModelResourceCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Picker("Model Resource Use", selection: Binding(
                get: { state.modelResourcePreset },
                set: { state.selectModelResourcePreset($0) })) {
                ForEach(ModelResourcePreset.allCases, id: \.self) { preset in
                    Text(preset.menuTitle).tag(preset)
                }
            }
            Button("Model Resource Use Settings…") { state.openModelResourceSettings() }
        }
    }
}
