import SwiftUI
import AppKit
import SwiftData

// MARK: - Root

struct SettingsView: View {
    @Bindable var state: AppState
    @State private var section: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $section)
            Rectangle().fill(Tokens.divider).frame(width: 0.5)
            SettingsBody(section: section, state: state)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.bg)
    }
}

// MARK: - Section enum

enum SettingsSection: String, CaseIterable {
    case general, appearance, bins, conditions, calibration, models, output, shortcuts, about

    var label: String {
        switch self {
        case .general:     return "General"
        case .appearance:  return "Appearance"
        case .bins:        return "Default bins"
        case .conditions:  return "Conditions"
        case .calibration: return "Calibration presets"
        case .models:      return "Models"
        case .output:      return "Output folder"
        case .shortcuts:   return "Shortcuts"
        case .about:       return "About"
        }
    }

    var icon: String {
        switch self {
        case .general:     return "settings"
        case .appearance:  return "image"
        case .bins:        return "layers"
        case .conditions:  return "compare"
        case .calibration: return "ruler"
        case .models:      return "cpu"
        case .output:      return "folder"
        case .shortcuts:   return "cmd"
        case .about:       return "help"
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(SettingsSection.allCases, id: \.self) { sec in
                NavItemView(icon: sec.icon, label: sec.label,
                            isActive: selection == sec) {
                    selection = sec
                }
            }
            Spacer()
        }
        .padding(8)
        .frame(width: 200)
        .background(Tokens.bgSunken)
    }
}

// MARK: - Body container

private struct SettingsBody: View {
    let section: SettingsSection
    @Bindable var state: AppState

    var body: some View {
        ScrollView {
            Group {
                switch section {
                case .general:     GeneralSection(state: state)
                case .appearance:  AppearanceSection()
                case .bins:        BinsSection(state: state)
                case .conditions:  ConditionsSection(state: state)
                case .calibration: CalibrationSection(state: state)
                case .models:      ModelsSection(state: state)
                case .output:      OutputSection()
                case .shortcuts:   ShortcutsSection()
                case .about:       AboutSection(state: state)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - SetRow

struct SetRow<Content: View>: View {
    let label: String
    var desc: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Tokens.text)
                if let desc {
                    Text(desc)
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.textTertiary)
                }
            }
            Spacer(minLength: 0)
            content()
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.divider).frame(height: 0.5) }
    }
}

// MARK: - SelectPill

private struct SelectPill: View {
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
            Icon("chevron", size: 12)
        }
        .foregroundStyle(Tokens.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Tokens.bgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Tokens.borderStrong, lineWidth: 0.5)
        )
    }
}

// MARK: - SectionHeading

private struct SectionHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.02 * 20)
                .foregroundStyle(Tokens.text)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Tokens.textTertiary)
        }
        .padding(.bottom, 18)
    }
}

// MARK: - General

private struct GeneralSection: View {
    @Bindable var state: AppState

    // bg-subtract, rolling-ball, watershed, watershed-min-distance-um,
    // max-parallel are AppState-owned; UI binds directly via `$state.*`.
    // cc-default-model is the first-launch fallback for cc-active-model.
    @AppStorage("cc-default-model") private var defaultModel = "cp-cyto3"

    private let allModels: [DetectionModelInfo] = ModelCatalog.all
    private let parallelOptions: [(value: Int, label: String)] = [
        (1, "1"), (2, "2"), (4, "4"), (8, "8")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(title: "General",
                           subtitle: "Defaults applied to every new analysis.")
            SetRow(label: "Default model",
                   desc: "Used at first launch when no model has been activated yet") {
                Menu {
                    ForEach(allModels) { m in
                        Button(m.name) { defaultModel = m.id }
                    }
                } label: {
                    SelectPill(label: allModels.first(where: { $0.id == defaultModel })?.name ?? defaultModel)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            SetRow(label: "Max parallel images",
                   desc: "Higher uses more memory, finishes batches faster") {
                Menu {
                    ForEach(parallelOptions, id: \.value) { opt in
                        Button(opt.label) { state.maxParallel = opt.value }
                    }
                } label: {
                    SelectPill(label: "\(state.maxParallel)")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            SetRow(label: "Subtract background before detection",
                   desc: "Rolling-ball subtraction — improves accuracy on phase-contrast images with uneven illumination") {
                CustomToggle(isOn: $state.backgroundSubtract)
            }
            SetRow(label: "Rolling-ball radius",
                   desc: "Larger radius removes broader illumination gradients (10–200 px)") {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { Double(state.rollingBallRadius) },
                        set: { state.rollingBallRadius = Int($0) }
                    ), in: 10...200, step: 1)
                    .frame(width: 120)
                    Text("\(state.rollingBallRadius) px")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Tokens.textSecondary)
                        .frame(width: 52, alignment: .trailing)
                }
            }
            SetRow(label: "Split touching cells",
                   desc: "Apply distance-transform watershed automatically on every new analysis") {
                CustomToggle(isOn: $state.watershedSplit)
            }
            SetRow(label: "Watershed min distance",
                   desc: "Minimum separation between cell centres (4–24 µm); smaller splits more aggressively") {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { Double(state.watershedMinDistanceUm) },
                        set: { state.watershedMinDistanceUm = Int($0) }
                    ), in: 4...24, step: 1)
                    .frame(width: 120)
                    Text("\(state.watershedMinDistanceUm) µm")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Tokens.textSecondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceSection: View {
    @Environment(AppTheme.self) private var theme

    private let accentChoices = AccentChoice.all
    private let themeModes: [(value: ThemeMode, label: String)] = [
        (.system, "System"), (.light, "Light"), (.dark, "Dark")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(title: "Appearance",
                           subtitle: "How the app looks.")

            SetRow(label: "Theme",
                   desc: "Match system, or force light/dark") {
                @Bindable var th = theme
                SegmentedPicker(value: $th.mode, options: themeModes)
            }

            SetRow(label: "Accent color",
                   desc: "Used for primary buttons and active states") {
                HStack(spacing: 8) {
                    ForEach(accentChoices) { choice in
                        AccentSwatch(choice: choice,
                                     isSelected: theme.accent == choice)
                    }
                }
            }
        }
    }
}

private struct AccentSwatch: View {
    let choice: AccentChoice
    let isSelected: Bool
    @Environment(AppTheme.self) private var theme

    var body: some View {
        Button {
            theme.accent = choice
        } label: {
            Circle()
                .fill(Color(OKLCH(0.685, 0.155, choice.hue)))
                .frame(width: 22, height: 22)
                .overlay(
                    Circle()
                        .strokeBorder(isSelected ? Tokens.text : Tokens.border,
                                      lineWidth: isSelected ? 2 : 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Default Bins

private struct BinsSection: View {
    @Bindable var state: AppState
    @AppStorage("cc-use-specimen-defaults") private var specimenAware = true

    // Thresholds are owned by AppState (`cc-thresholds`); bind straight to
    // `state.thresholds` — no local @State mirror, no `cc-default-thresholds`.
    @State private var binPresets: [BinPresetRecord] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(title: "Default bins",
                           subtitle: "New images start with these size thresholds. You can always override per-image in the results sidebar.")

            VStack(alignment: .leading, spacing: 0) {
                // Guard against the stale-index ForEach binding pattern so a
                // row being removed can't crash on `state.thresholds[i]` for
                // one render after the array shrinks.
                ForEach(Array(state.thresholds.enumerated()), id: \.offset) { pair in
                    let i = pair.offset
                    ThresholdRow(
                        binIndex: i + 2,
                        value: Binding(
                            get: { state.thresholds.indices.contains(i) ? state.thresholds[i] : 0 },
                            set: {
                                guard state.thresholds.indices.contains(i) else { return }
                                state.thresholds[i] = $0
                            }
                        ),
                        canDelete: state.thresholds.count > 1,
                        onRemove: {
                            guard state.thresholds.indices.contains(i),
                                  state.thresholds.count > 1 else { return }
                            state.thresholds.remove(at: i)
                        }
                    )
                }
                Button {
                    // No fixed cap on the number of thresholds — append above the
                    // current max so the array stays sorted and the bins stay
                    // valid for any N.
                    state.thresholds.append((state.thresholds.max() ?? 30) + 10)
                } label: {
                    HStack(spacing: 6) {
                        Icon("plus", size: 12)
                        Text("Add threshold")
                            .font(.system(size: 12.5))
                    }
                    .foregroundStyle(Tokens.textSecondary)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 10)
            }
            .padding(.bottom, 4)

            SetRow(label: "Use specimen-aware defaults",
                   desc: "Switch to your saved presets based on the active calibration (e.g. 'keratinocytes 20×')") {
                CustomToggle(isOn: $specimenAware)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("Saved presets".uppercased())
                    .tracking(0.04 * 13)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.textSecondary)
                    .padding(.top, 22)
                    .padding(.bottom, 10)

                VStack(spacing: 0) {
                    ForEach(binPresets) { preset in
                        BinPresetRow(
                            preset: preset,
                            onApply: {
                                state.thresholds = preset.thresholds
                            },
                            onDelete: {
                                state.repos.context.delete(preset)
                                try? state.repos.context.save()
                                refreshPresets()
                            }
                        )
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                        .strokeBorder(Tokens.border, lineWidth: 0.5)
                )
            }
        }
        .onAppear { refreshPresets() }
    }

    private func refreshPresets() {
        binPresets = state.repos.binPresets()
    }
}

private struct ThresholdRow: View {
    let binIndex: Int
    @Binding var value: Double
    var canDelete: Bool = true
    let onRemove: () -> Void

    @State private var text: String = ""

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Tokens.binColor(binIndex - 1))
                .frame(width: 12, height: 12)
            TextField("", text: $text)
                .font(.system(size: 12.5, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                        .fill(Tokens.bgElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                        .strokeBorder(Tokens.borderStrong, lineWidth: 0.5)
                )
                .onAppear { text = String(format: "%.0f", value) }
                .onChange(of: text) { _, new in
                    if let d = Double(new) { value = d }
                }
            Text("µm")
                .font(.system(size: 12))
                .foregroundStyle(Tokens.textTertiary)
            if canDelete {
                Button(action: onRemove) {
                    Icon("minus", size: 12)
                        .foregroundStyle(Tokens.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Tokens.bgElevated)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Tokens.borderStrong, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 22, height: 22)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct BinPresetRow: View {
    let preset: BinPresetRecord
    let onApply: () -> Void
    let onDelete: () -> Void

    private var thresholdLabel: String {
        let t = preset.thresholds
        guard !t.isEmpty else { return "—" }
        var parts: [String] = []
        parts.append("< \(Int(t[0])) µm")
        for i in 0..<(t.count - 1) {
            parts.append("\(Int(t[i]))–\(Int(t[i+1])) µm")
        }
        parts.append("> \(Int(t[t.count - 1])) µm")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Tokens.text)
                Text(thresholdLabel)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Tokens.textTertiary)
            }
            Spacer(minLength: 0)
            Button("Apply", action: onApply)
                .appButton(.ghost, size: .sm)
            Button(action: onDelete) { Icon("trash", size: 12) }
                .appButton(.ghost, size: .sm)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.divider).frame(height: 0.5) }
    }
}

// MARK: - Conditions (pass 6)

private struct ConditionsSection: View {
    @Bindable var state: AppState
    @State private var items: [ConditionRecord] = []
    @State private var filter: String = ""
    @State private var showingNew = false
    @State private var newName: String = ""
    @State private var newColor: String = "#7b88e0"
    @State private var renamingID: UUID? = nil
    @State private var renameBuffer: String = ""

    /// Curated swatch palette — same family as the conditions seed.
    private let palette: [String] = [
        "#4db3a8", "#d97757", "#7b88e0", "#c074b8",
        "#e0b04d", "#5fa8d3", "#9bc466", "#d35a72"
    ]

    private var filtered: [ConditionRecord] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(title: "Conditions",
                           subtitle: "Inhibitor / treatment tags. Applied per-batch, then pooled in the Compare view.")

            // Filter
            HStack(spacing: 8) {
                Icon("search", size: 12).foregroundStyle(Tokens.textTertiary)
                TextField("Filter conditions…", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .fill(Tokens.bgElevated))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .strokeBorder(Tokens.borderStrong, lineWidth: 0.5))
            .padding(.bottom, 10)

            VStack(spacing: 0) {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, cond in
                    ConditionRow(
                        condition: cond,
                        isRenaming: renamingID == cond.id,
                        renameBuffer: $renameBuffer,
                        canMoveUp: idx > 0,
                        canMoveDown: idx < filtered.count - 1,
                        onStartRename: {
                            renamingID = cond.id
                            renameBuffer = cond.name
                        },
                        onCommitRename: {
                            let trimmed = renameBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                state.repos.renameCondition(cond, to: trimmed)
                            }
                            renamingID = nil
                            refresh()
                        },
                        onCancelRename: { renamingID = nil },
                        onDelete: {
                            state.repos.deleteCondition(cond)
                            refresh()
                        },
                        onMoveUp: { move(cond, by: -1) },
                        onMoveDown: { move(cond, by: +1) },
                        onPickColor: { hex in
                            cond.color = hex
                            try? state.repos.context.save()
                            refresh()
                        },
                        palette: palette
                    )
                }
                if filtered.isEmpty {
                    Text(filter.isEmpty ? "No conditions yet." : "No matches.")
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.textTertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .strokeBorder(Tokens.border, lineWidth: 0.5))

            if showingNew {
                HStack(spacing: 10) {
                    TextField("Condition name", text: $newName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                                .fill(Tokens.bgElevated))
                        .overlay(
                            RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                                .strokeBorder(Tokens.borderStrong, lineWidth: 0.5))
                    HStack(spacing: 4) {
                        ForEach(palette, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex) ?? .gray)
                                .frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(
                                    newColor == hex ? Tokens.text : Tokens.border,
                                    lineWidth: newColor == hex ? 2 : 0.5))
                                .onTapGesture { newColor = hex }
                        }
                    }
                    Button("Save") {
                        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        state.repos.createCondition(name: trimmed, color: newColor)
                        newName = ""
                        showingNew = false
                        refresh()
                    }
                    .appButton(.primary, size: .sm)
                    Button("Cancel") { showingNew = false; newName = "" }
                        .appButton(.ghost, size: .sm)
                }
                .padding(.top, 14)
            } else {
                Button {
                    newName = ""
                    newColor = palette[items.count % palette.count]
                    showingNew = true
                } label: {
                    HStack(spacing: 6) {
                        Icon("plus", size: 12)
                        Text("New condition…")
                    }
                }
                .appButton(.standard, size: .sm)
                .padding(.top, 14)
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        items = state.repos.conditions()
    }

    private func move(_ cond: ConditionRecord, by delta: Int) {
        var ordered = items
        guard let i = ordered.firstIndex(where: { $0.id == cond.id }) else { return }
        let j = i + delta
        guard ordered.indices.contains(j) else { return }
        ordered.swapAt(i, j)
        state.repos.reorderConditions(ordered)
        refresh()
    }
}

private struct ConditionRow: View {
    let condition: ConditionRecord
    let isRenaming: Bool
    @Binding var renameBuffer: String
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onStartRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onPickColor: (String) -> Void
    let palette: [String]

    @State private var showingColorPicker = false

    var body: some View {
        HStack(spacing: 12) {
            // Color swatch (click to open palette popover-ish row).
            Button { showingColorPicker.toggle() } label: {
                Circle()
                    .fill(Color(hex: condition.color) ?? .gray)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(Tokens.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            // Name / rename input
            if isRenaming {
                TextField("Name", text: $renameBuffer, onCommit: onCommitRename)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Save", action: onCommitRename).appButton(.primary, size: .sm)
                Button("Cancel", action: onCancelRename).appButton(.ghost, size: .sm)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(condition.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Tokens.text)
                    Text(condition.color)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Tokens.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Reorder
                Button(action: onMoveUp) { Icon("chevron", size: 10).rotationEffect(.degrees(180)) }
                    .appButton(.ghost, size: .sm)
                    .disabled(!canMoveUp)
                    .opacity(canMoveUp ? 1 : 0.35)
                Button(action: onMoveDown) { Icon("chevron", size: 10) }
                    .appButton(.ghost, size: .sm)
                    .disabled(!canMoveDown)
                    .opacity(canMoveDown ? 1 : 0.35)

                Button("Rename", action: onStartRename)
                    .appButton(.ghost, size: .sm)
                Button(action: onDelete) { Icon("trash", size: 12) }
                    .appButton(.ghost, size: .sm)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                if showingColorPicker {
                    HStack(spacing: 6) {
                        ForEach(palette, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex) ?? .gray)
                                .frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(
                                    condition.color == hex ? Tokens.text : Tokens.border,
                                    lineWidth: condition.color == hex ? 2 : 0.5))
                                .onTapGesture {
                                    onPickColor(hex)
                                    showingColorPicker = false
                                }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
                Rectangle().fill(Tokens.divider).frame(height: 0.5)
            }
        }
    }
}

// MARK: - Calibration presets

private struct CalibrationSection: View {
    @Bindable var state: AppState
    @State private var presets: [CalibrationPresetRecord] = []
    @State private var showingEditor = false
    @State private var editingPreset: CalibrationPresetRecord? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(title: "Calibration presets",
                           subtitle: "Reusable scale settings, one per microscope + objective.")

            VStack(spacing: 0) {
                ForEach(presets) { preset in
                    CalibrationRow(
                        preset: preset,
                        onEdit: {
                            editingPreset = preset
                            showingEditor = true
                        },
                        onDelete: {
                            state.repos.deleteCalibrationPreset(preset)
                            refreshPresets()
                        }
                    )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .strokeBorder(Tokens.border, lineWidth: 0.5)
            )

            if showingEditor {
                CalibrationPresetEditor(
                    existing: editingPreset,
                    onSave: { name, pxPerUm in
                        if let existing = editingPreset {
                            existing.name = name
                            existing.pxPerUm = pxPerUm
                            try? state.repos.context.save()
                        } else {
                            let rec = CalibrationPresetRecord(name: name, pxPerUm: pxPerUm)
                            state.repos.upsertCalibrationPreset(rec)
                        }
                        showingEditor = false
                        editingPreset = nil
                        refreshPresets()
                    },
                    onCancel: {
                        showingEditor = false
                        editingPreset = nil
                    }
                )
                .padding(.top, 14)
            } else {
                Button {
                    editingPreset = nil
                    showingEditor = true
                } label: {
                    HStack(spacing: 6) {
                        Icon("plus", size: 12)
                        Text("New preset…")
                    }
                }
                .appButton(.standard, size: .sm)
                .padding(.top, 14)
            }
        }
        .onAppear { refreshPresets() }
    }

    private func refreshPresets() {
        presets = state.repos.calibrationPresets()
    }
}

private struct CalibrationPresetEditor: View {
    let existing: CalibrationPresetRecord?
    let onSave: (String, Double) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var pxPerUmText: String = ""

    var body: some View {
        HStack(spacing: 10) {
            TextField("Preset name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                        .fill(Tokens.bgElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                        .strokeBorder(Tokens.borderStrong, lineWidth: 0.5)
                )
            HStack(spacing: 4) {
                TextField("0.0", text: $pxPerUmText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                            .fill(Tokens.bgElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                            .strokeBorder(Tokens.borderStrong, lineWidth: 0.5)
                    )
                Text("px/µm")
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.textTertiary)
            }
            Button("Save") {
                guard !name.isEmpty, let px = Double(pxPerUmText), px > 0 else { return }
                onSave(name, px)
            }
            .appButton(.primary, size: .sm)
            Button("Cancel", action: onCancel)
                .appButton(.ghost, size: .sm)
        }
        .onAppear {
            name = existing?.name ?? ""
            pxPerUmText = existing.map { String(format: "%.2f", $0.pxPerUm) } ?? ""
        }
    }
}

private struct CalibrationRow: View {
    let preset: CalibrationPresetRecord
    let onEdit: () -> Void
    let onDelete: () -> Void
    @Environment(AppTheme.self) private var theme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Tokens.text)
                Text(String(format: "%.1f px / µm", preset.pxPerUm))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Tokens.textTertiary)
            }
            Spacer(minLength: 0)
            if preset.isDefault {
                Text("Default")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.accentColor)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(theme.accentSoft))
            }
            Button("Edit", action: onEdit)
                .appButton(.ghost, size: .sm)
            Button(action: onDelete) { Icon("trash", size: 12) }
                .appButton(.ghost, size: .sm)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.divider).frame(height: 0.5) }
    }
}

// MARK: - Models

private struct ModelsSection: View {
    @Bindable var state: AppState
    // cc-verify-checksums and cc-use-gpu are AppState-owned; bind via `$state.*`.

    /// Bumps to force a re-read of disk usage after Remove.
    @State private var storageTick: Int = 0

    private var installedModels: [DetectionModelInfo] {
        _ = storageTick
        return state.models.filter {
            state.detectorRegistry.isInstalled($0.id, models: state.models)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(title: "Models",
                           subtitle: "Storage and behavior of downloaded models. To browse or activate, open the Models tab in the sidebar.")
            SetRow(label: "Download location",
                   desc: FileStore.shared.modelsDir.path) {
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([FileStore.shared.modelsDir])
                }
                .appButton(.standard, size: .sm)
            }
            SetRow(label: "Verify checksums on download",
                   desc: "Slower but catches corrupted files") {
                CustomToggle(isOn: $state.verifyChecksums)
            }
            SetRow(label: "Use GPU when available",
                   desc: "Apple Neural Engine + Metal where supported") {
                CustomToggle(isOn: $state.useGPU)
            }

            // Storage breakdown
            Text("Storage".uppercased())
                .tracking(0.04 * 13)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)
                .padding(.top, 22)
                .padding(.bottom, 10)

            let installed = installedModels
            if installed.isEmpty {
                Text("Nothing installed yet — pick a model on the Models tab.")
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.textTertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                            .strokeBorder(Tokens.border, lineWidth: 0.5)
                    )
            } else {
                VStack(spacing: 0) {
                    ForEach(installed) { m in
                        StorageRow(
                            model: m,
                            sizeBytes: state.detectorRegistry.diskUsageBytes(m.id, models: state.models),
                            onRemove: {
                                try? state.detectorRegistry.uninstall(m.id, models: state.models)
                                if let i = state.models.firstIndex(where: { $0.id == m.id }) {
                                    if state.models[i].state != .off {
                                        state.models[i].state = .off
                                    }
                                }
                                storageTick &+= 1
                            }
                        )
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                        .strokeBorder(Tokens.border, lineWidth: 0.5)
                )
            }
        }
    }
}

private struct StorageRow: View {
    let model: DetectionModelInfo
    let sizeBytes: Int64
    let onRemove: () -> Void
    @Environment(AppTheme.self) private var theme

    private var iconName: String {
        if model.custom { return "sparkles" }
        switch model.family {
        case .cellpose:  return "cpu"
        // Pass-16: Cellpose-SAM (4.x). See ModelsView for the same case.
        case .cellpose4: return "flame"
        case .stardist:  return "star"
        case .sam:       return "flask"
        case .custom:    return "sparkles"
        case .all:       return "cpu"
        }
    }

    private var sizeLabel: String {
        if sizeBytes <= 0 { return model.sizeLabel }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB, .useKB]
        f.countStyle = .file
        return f.string(fromByteCount: sizeBytes)
    }

    var body: some View {
        HStack(spacing: 12) {
            Icon(iconName, size: 13)
                .foregroundStyle(Tokens.textSecondary)
                .frame(width: 16)
            Text(model.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Tokens.text)
            Spacer(minLength: 0)
            Text(sizeLabel)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Tokens.textTertiary)
            Button("Remove", action: onRemove)
                .appButton(.ghost, size: .sm)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.divider).frame(height: 0.5) }
    }
}

// MARK: - Output folder

private struct OutputSection: View {
    @AppStorage("cc-export-folder")           private var exportFolder = ""
    @AppStorage("cc-export-organize-by-batch") private var organizeByBatch = true
    @AppStorage("cc-export-timestamp")        private var appendTimestamp = true
    @AppStorage("cc-export-csv-sep")          private var csvSep = ","

    private var displayFolder: String {
        exportFolder.isEmpty ? FileStore.shared.defaultUserExports.path : exportFolder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(title: "Output folder",
                           subtitle: "Where exported annotated images and CSVs land.")

            HStack(spacing: 8) {
                Text(displayFolder)
                    .font(.system(size: 13))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    presentOpenPanel(allowedExtensions: [], allowFolders: true, allowMultiple: false) { urls in
                        if let url = urls.first {
                            // Persist as a security-scoped bookmark so the sandboxed
                            // app keeps write access across launches. Path is mirrored
                            // for display only.
                            SecurityBookmarks.save(url, key: "cc-export-folder-bookmark")
                            exportFolder = url.path
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Icon("folder", size: 12)
                        Text("Browse…")
                    }
                }
                .appButton(.standard, size: .sm)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .fill(Tokens.bgElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .strokeBorder(Tokens.borderStrong, lineWidth: 0.5)
            )
            .padding(.bottom, 4)

            SetRow(label: "Organize by batch name",
                   desc: "Each batch gets its own subfolder") {
                CustomToggle(isOn: $organizeByBatch)
            }
            SetRow(label: "Append timestamp",
                   desc: "Avoids overwriting earlier exports") {
                CustomToggle(isOn: $appendTimestamp)
            }
            SetRow(label: "CSV separator",
                   desc: "Pick comma or semicolon") {
                Menu {
                    Button("Comma (,)")  { csvSep = "," }
                    Button("Semicolon (;)") { csvSep = ";" }
                } label: {
                    SelectPill(label: csvSep == ";" ? "Semicolon (;)" : "Comma (,)")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsSection: View {
    private let shortcuts: [(key: String, label: String)] = [
        ("⌘O",      "Open files…"),
        ("⌘⇧O",    "Open folder…"),
        ("⌘R",      "Re-analyze current image"),
        ("⌘E",      "Export current"),
        ("⌘⇧E",    "Export batch"),
        ("⌘1 / ⌘2","Switch image bin overlay (bbox / outline)"),
        ("Space",    "Toggle overlay"),
        ("⌘+ / ⌘−", "Zoom"),
        ("⌘0",      "Fit to view"),
        ("⌘,",      "Settings"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(title: "Keyboard shortcuts",
                           subtitle: "Click any binding to remap it.")

            VStack(spacing: 0) {
                ForEach(shortcuts.indices, id: \.self) { i in
                    ShortcutRow(label: shortcuts[i].label, key: shortcuts[i].key)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .strokeBorder(Tokens.border, lineWidth: 0.5)
            )
        }
    }
}

private struct ShortcutRow: View {
    let label: String
    let key: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Tokens.text)
            Spacer(minLength: 0)
            Text(key)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Tokens.text)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Tokens.bgElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Tokens.borderStrong, lineWidth: 0.5)
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.divider).frame(height: 0.5) }
    }
}

// MARK: - About

private struct AboutSection: View {
    @Bindable var state: AppState
    @Environment(AppTheme.self) private var theme
    @State private var showAcknowledgements = false
    @State private var showPrivacy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(theme.accentSoft)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Tokens.border, lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                    AppMark(size: 44)
                }
                .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 4) {
                    Text("CellCounter")
                        .font(.system(size: 22, weight: .bold))
                        .tracking(-0.02 * 22)
                        .foregroundStyle(Tokens.text)
                    Text("Version 1.0 (build 142) · macOS 14+")
                        .font(.system(size: 13))
                        .foregroundStyle(Tokens.textTertiary)
                    Text("Counts and size-bins cells in microscope images. Local-only — your data never leaves this Mac.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Tokens.textTertiary)
                }
            }
            .padding(.bottom, 22)

            VStack(spacing: 0) {
                // Replay onboarding
                AboutRow(label: "Replay onboarding", trailing: .replay, isExpanded: false) {
                    state.showOnboarding = true
                }

                // Acknowledgements expandable row
                VStack(alignment: .leading, spacing: 0) {
                    AboutRow(
                        label: "Acknowledgements",
                        trailing: .chevron,
                        isExpanded: showAcknowledgements
                    ) {
                        withAnimation(Tokens.Motion.easeFast) {
                            showAcknowledgements.toggle()
                            if showAcknowledgements { showPrivacy = false }
                        }
                    }
                    if showAcknowledgements {
                        AcknowledgementsContent()
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                // Privacy expandable row
                VStack(alignment: .leading, spacing: 0) {
                    AboutRow(
                        label: "Privacy & data handling",
                        trailing: .chevron,
                        isExpanded: showPrivacy
                    ) {
                        withAnimation(Tokens.Motion.easeFast) {
                            showPrivacy.toggle()
                            if showPrivacy { showAcknowledgements = false }
                        }
                    }
                    if showPrivacy {
                        PrivacyContent()
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                AboutRow(label: "Reset all settings", trailing: .reset, isExpanded: false) {
                    confirmReset(state: state)
                }

                // Destructive data wipe — nukes imported images, detections,
                // batches, and corrections (distinct from "Reset all settings").
                AboutRow(label: "Reset all data…", trailing: .reset, isExpanded: false) {
                    confirmResetAllData(state: state)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .strokeBorder(Tokens.border, lineWidth: 0.5)
            )
        }
    }

    private func confirmResetAllData(state: AppState) {
        let alert = NSAlert()
        alert.messageText = "Delete all imported data?"
        alert.informativeText =
            "This permanently removes all imported images, detections, " +
            "batches, and corrections.\n\n" +
            "Your conditions, calibration presets, bin presets, the Python " +
            "environment, and the Exports folder are preserved.\n\n" +
            "This cannot be undone."
        alert.alertStyle = .critical
        let deleteButton = alert.addButton(withTitle: "Delete everything")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        do {
            try state.repos.wipeAllUserData()
            NotificationCenter.default.post(name: Notification.Name("ccLibraryChanged"), object: nil)
        } catch {
            let failed = NSAlert()
            failed.messageText = "Couldn't fully reset data."
            failed.informativeText = "The on-disk image directory may not have been recreated. Restart CellCounter and try again. Error: \(error.localizedDescription)"
            failed.alertStyle = .warning
            failed.addButton(withTitle: "OK")
            failed.runModal()
            return
        }

        // Pass-16: explicit cleanup hook for the Cellpose-SAM (4.x) install
        // state. `wipeAllUserData()` intentionally preserves the cellpose 3.x
        // venv (`python/venv/`) — for parity, the cp4 venv (`python/venv4/`)
        // is also preserved on a data wipe. We DO invalidate the cached
        // `cc-cellpose4-importable` flag so the cache re-probes on the next
        // Models view appear (the venv on disk should still be importable;
        // re-probing is cheap and prevents stale-cache reads after a reset).
        // Post `ccVenv4Changed` so the InstallStateCache picks the change up.
        UserDefaults.standard.removeObject(forKey: "cc-cellpose4-importable")
        NotificationCenter.default.post(name: .ccVenv4Changed, object: nil)

        // Reset in-memory state that points at now-deleted batches/images so
        // the UI doesn't keep stale selections alive.
        state.currentBatchId = nil
        state.refreshFromDefaults()

        // The SwiftData container is still live and now empty. Surface a
        // short confirmation rather than trying to hot-reload the container
        // (which would require tearing down the entire view tree).
        let done = NSAlert()
        done.messageText = "Data cleared."
        done.informativeText = "All imported images, detections, batches, and corrections have been removed. Quit and reopen CellCounter for the cleanest state."
        done.alertStyle = .informational
        done.addButton(withTitle: "OK")
        done.runModal()
    }

    private func confirmReset(state: AppState) {
        let alert = NSAlert()
        alert.messageText = "Reset all settings?"
        alert.informativeText = "This will clear all CellCounter preferences and restart the onboarding flow. Your batches and images are not affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        // Keys that are actually written and read somewhere. `cc-onboarded`
        // IS cleared here so "Reset all settings" replays onboarding. The
        // separate "Reset all data" path does not touch onboarding/settings.
        let ccKeys = [
            "cc-default-model", "cc-max-parallel",
            "cc-theme", "cc-accent",
            "cc-use-specimen-defaults",
            "cc-verify-checksums", "cc-use-gpu",
            "cc-channels-cyto", "cc-bg-subtract", "cc-rolling-ball",
            "cc-watershed", "cc-watershed-min-distance-um",
            "cc-export-folder", "cc-export-organize-by-batch",
            "cc-export-timestamp", "cc-export-csv-sep",
            "cc-export-folder-bookmark",
            "cc-thresholds", "cc-pxperum", "cc-confidence", "cc-expected-diameter",
            "cc-active-model",
            "cc-model-filter", "cc-onboarded", "cc-current-batch",
            "cc-models-banner-dismissed", "cc-install-banner-dismissed",
            "cc-manual-diameter", "cc-cellpose-importable",
            // Pass-16: cp4 importable flag pairs with `cc-cellpose-importable`.
            "cc-cellpose4-importable",
            "cc-seeded-conditions-v1",
        ]
        let ud = UserDefaults.standard
        ccKeys.forEach { ud.removeObject(forKey: $0) }

        // Reset live in-memory state so the UI reflects cleared defaults immediately.
        state.thresholds = [20, 30]
        state.expectedDiameterUm = 0   // back to Auto (bin-derived size prior)
        state.activeModelId = "cp-cyto3"
        state.modelFilter = .all
        state.showOnboarding = true
        state.refreshFromDefaults()
    }
}

private enum AboutTrailing { case chevron, reset, replay }

private struct AboutRow: View {
    let label: String
    let trailing: AboutTrailing
    var isExpanded: Bool = false
    let action: () -> Void
    @Environment(AppTheme.self) private var theme

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(trailing == .reset ? Tokens.danger : Tokens.text)
                Spacer(minLength: 0)
                switch trailing {
                case .chevron:
                    Icon("chevron", size: 12)
                        .foregroundStyle(Tokens.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                case .reset:
                    Text("Reset")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Tokens.danger)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .overlay(
                            Capsule().strokeBorder(Tokens.danger.opacity(0.35), lineWidth: 0.5)
                        )
                case .replay:
                    Text("Replay")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Tokens.textSecondary)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .overlay(
                            Capsule().strokeBorder(Tokens.borderStrong, lineWidth: 0.5)
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(Tokens.divider).frame(height: 0.5) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AcknowledgementsContent

private struct AckEntry: Identifiable {
    let id = UUID()
    let name: String
    let year: String
    let authors: String
    let license: String
    let description: String
    let paper: String?
}

private struct AcknowledgementsContent: View {
    private let entries: [AckEntry] = [
        AckEntry(
            name: "Cellpose 3",
            year: "2024",
            authors: "Stringer & Pachitariu",
            license: "BSD-3",
            description: "Generalist cell segmentation via flow fields and transformer priors.",
            paper: "https://doi.org/10.1038/s41592-024-02282-3"
        ),
        AckEntry(
            name: "StarDist",
            year: "2018",
            authors: "Schmidt et al.",
            license: "BSD-3",
            description: "Star-convex polygon detection for fluorescence microscopy nuclei.",
            paper: "https://doi.org/10.1007/978-3-030-00934-2_30"
        ),
        AckEntry(
            name: "Segment Anything for Microscopy (micro_sam)",
            year: "2024",
            authors: "Archit et al.",
            license: "MIT",
            description: "Fine-tuned SAM models for interactive microscopy segmentation.",
            paper: "https://doi.org/10.1038/s41592-024-02580-8"
        ),
        AckEntry(
            name: "MobileSAM",
            year: "2023",
            authors: "Zhang et al.",
            license: "Apache-2.0",
            description: "Lightweight Segment Anything variant optimised for edge devices.",
            paper: "https://arxiv.org/abs/2306.14289"
        ),
        AckEntry(
            name: "scikit-image / scipy / numpy",
            year: "—",
            authors: "Open-source community",
            license: "BSD-3",
            description: "Image processing, scientific computing and array operations.",
            paper: nil
        ),
        AckEntry(
            name: "PyTorch",
            year: "—",
            authors: "Meta AI",
            license: "BSD-3",
            description: "Deep-learning framework powering all model inference.",
            paper: nil
        ),
        AckEntry(
            name: "SwiftUI / Apple frameworks",
            year: "—",
            authors: "Apple Inc.",
            license: "Proprietary",
            description: "macOS UI, concurrency, and system integration.",
            paper: nil
        ),
        AckEntry(
            name: "Lucide icons",
            year: "—",
            authors: "Lucide contributors",
            license: "ISC",
            description: "Icon design language (adapted to SF Symbols in this app).",
            paper: "https://lucide.dev"
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(entries) { e in
                    AckCard(entry: e)
                }
            }
            .padding(14)
        }
        .frame(maxHeight: 340)
        .background(Tokens.bgSunken)
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.divider).frame(height: 0.5) }
    }
}

private struct AckCard: View {
    let entry: AckEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                Text(entry.year)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
                Spacer(minLength: 0)
                Text(entry.license)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Tokens.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Tokens.bgElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Tokens.borderStrong, lineWidth: 0.5)
                    )
            }
            Text(entry.authors)
                .font(.system(size: 12))
                .foregroundStyle(Tokens.textSecondary)
            Text(entry.description)
                .font(.system(size: 12))
                .foregroundStyle(Tokens.textTertiary)
            if let url = entry.paper, let link = URL(string: url) {
                Link(url, destination: link)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                .fill(Tokens.bgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                .strokeBorder(Tokens.borderStrong, lineWidth: 0.5)
        )
    }
}

// MARK: - PrivacyContent

private struct PrivacyContent: View {
    private let storagePath = "~/Library/Containers/alguer.CellCounting/Data/Library/Application Support/CellCounter/"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Everything runs locally on your Mac. No images, measurements, or detection results are ever transmitted anywhere. " +
                "CellCounter has no telemetry; if we ever add optional analytics they will be strictly opt-in.\n\n" +
                "Python runs in an isolated virtual environment on your machine. Model weights are downloaded from public sources " +
                "(Cellpose model hub, Hugging Face) only when you tap \"Get\" on a model card — never automatically. " +
                "Fine-tuned models stay on your Mac unless you manually export them."
            )
            .font(.system(size: 12.5))
            .foregroundStyle(Tokens.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Persistent storage location")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Tokens.textTertiary)
                Text(storagePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.textSecondary)
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                    .fill(Tokens.bgSunken)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                    .strokeBorder(Tokens.borderStrong, lineWidth: 0.5)
            )
        }
        .padding(14)
        .background(Tokens.bgSunken)
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.divider).frame(height: 0.5) }
    }
}
