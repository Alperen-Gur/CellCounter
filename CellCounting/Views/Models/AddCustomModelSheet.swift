import SwiftUI
import AppKit

/// Sheet for registering a bring-your-own model, and for choosing the two
/// members of the ensemble "second opinion".
///
/// Both live here because they are the same job from the user's side —
/// "configure a model that isn't just a download" — and because both need the
/// same live validation feedback before the OK button becomes meaningful.
struct AddCustomModelSheet: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(AppTheme.self) private var theme

    enum Tab: String, CaseIterable, Identifiable {
        case custom = "Your own model"
        case ensemble = "Second opinion"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .custom

    // Custom-model form state
    @State private var kind: CustomModelEntry.Kind = .cellpose
    @State private var runtime: CustomModelEntry.Runtime = .base
    @State private var path: String = ""
    @State private var displayName: String = ""
    @State private var validationError: String? = nil
    @State private var didPick: Bool = false

    // Ensemble form state
    @State private var primaryId: String = EnsembleDownloader.primaryId()
    @State private var secondaryId: String = EnsembleDownloader.secondaryId()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Tokens.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .custom:   customForm
                    case .ensemble: ensembleForm
                    }
                }
                .padding(20)
            }
            Divider().overlay(Tokens.divider)
            footer
        }
        .frame(width: 560, height: 520)
        .background(Tokens.bg)
    }

    // MARK: — Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a model")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Tokens.text)
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            if tab == .custom, !registered.isEmpty {
                Text("\(registered.count) registered")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .appButton(.ghost, size: .sm)
            Button(tab == .custom ? "Add model" : "Save pair") {
                if tab == .custom { addCustom() } else { saveEnsemble() }
            }
            .appButton(.primary, size: .sm)
            .disabled(!canSubmit)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: — Custom model form

    @ViewBuilder
    private var customForm: some View {
        Text("Point CellCounter at a model you already trained. It runs through the same "
             + "measurement and export path as the built-in models, so the numbers are "
             + "directly comparable.")
            .font(.system(size: 12))
            .foregroundStyle(Tokens.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

        FieldLabel("Framework")
        Picker("", selection: $kind) {
            ForEach(CustomModelEntry.Kind.allCases, id: \.self) { k in
                Text(k.displayName).tag(k)
            }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        .onChange(of: kind) { _, _ in
            // The two kinds want different things on disk, so a path chosen for
            // one is almost never valid for the other.
            path = ""
            didPick = false
            validationError = nil
            if kind == .stardist { runtime = .base }
        }

        Text(kind == .cellpose
             ? "A single checkpoint file — the artefact Cellpose training writes into its models/ folder."
             : "The model FOLDER — the one containing config.json and weights_best.h5.")
            .font(.system(size: 11.5))
            .foregroundStyle(Tokens.textTertiary)

        FieldLabel(kind.wantsDirectory ? "Model folder" : "Checkpoint file")
        HStack(spacing: 8) {
            Text(path.isEmpty ? "No \(kind.wantsDirectory ? "folder" : "file") chosen" : path)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(path.isEmpty ? Tokens.textTertiary : Tokens.text)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .fill(Tokens.bgSunken))
            Button("Choose…") { choosePath() }
                .appButton(.standard, size: .sm)
        }

        if let validationError {
            CalloutRow(icon: "info", text: validationError, tint: Tokens.danger)
        } else if didPick && !path.isEmpty {
            CalloutRow(icon: "check",
                       text: "Looks like a valid \(kind == .cellpose ? "Cellpose checkpoint" : "StarDist model folder").",
                       tint: theme.accentColor)
        }

        if kind == .cellpose {
            FieldLabel("Runs in")
            Picker("", selection: $runtime) {
                Text(CustomModelEntry.Runtime.base.displayName)
                    .tag(CustomModelEntry.Runtime.base)
                Text(CustomModelEntry.Runtime.cellpose4.displayName)
                    .tag(CustomModelEntry.Runtime.cellpose4)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text("A checkpoint fine-tuned from Cellpose 3.x won't load under Cellpose-SAM, "
                 + "and vice versa. Pick whichever version you trained from.")
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        FieldLabel("Name in the models list")
        TextField("e.g. HeLa fine-tune v3", text: $displayName)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12.5))

        if !registered.isEmpty {
            Divider().overlay(Tokens.divider).padding(.vertical, 4)
            FieldLabel("Already registered")
            VStack(spacing: 6) {
                ForEach(registered) { entry in
                    HStack(spacing: 8) {
                        Icon("sparkles", size: 12).foregroundStyle(Tokens.textSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Tokens.text)
                            Text(entry.path)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Tokens.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer()
                        Button {
                            CustomModelStore.remove(id: entry.id)
                            refreshCatalog()
                        } label: {
                            Icon("trash", size: 12).foregroundStyle(Tokens.textTertiary)
                        }
                        .appButton(.ghost, size: .sm)
                        .help("Remove from CellCounter. Your model file is not deleted.")
                    }
                }
            }
        }
    }

    // MARK: — Ensemble form

    @ViewBuilder
    private var ensembleForm: some View {
        Text("Run two models on every image and flag only the cells they disagree about. "
             + "Instead of checking every detection, you check the handful the two models "
             + "couldn't agree on.")
            .font(.system(size: 12))
            .foregroundStyle(Tokens.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

        FieldLabel("First model")
        memberPicker(selection: $primaryId, excluding: secondaryId)

        FieldLabel("Second model")
        memberPicker(selection: $secondaryId, excluding: primaryId)

        if primaryId == secondaryId {
            CalloutRow(icon: "info",
                       text: "Pick two different models — a model always agrees with itself.",
                       tint: Tokens.danger)
        } else {
            CalloutRow(
                icon: "info",
                text: "Disagreements are reported at confidence 0.60: visible and counted, "
                    + "but queued for review. Agreements land at 0.80 or above. Agreement "
                    + "and disagreement counts are saved with the image.",
                tint: theme.accentColor)
        }

        Text("A neural model paired with the classical threshold detector is the cheapest "
             + "useful pairing — the classical side needs no download and adds under a second "
             + "per image.")
            .font(.system(size: 11.5))
            .foregroundStyle(Tokens.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func memberPicker(selection: Binding<String>, excluding other: String) -> some View {
        Picker("", selection: selection) {
            ForEach(eligible, id: \.id) { model in
                Text("\(model.name)  ·  \(model.family.rawValue)").tag(model.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    // MARK: — Data

    private var registered: [CustomModelEntry] { CustomModelStore.all() }

    private var eligible: [DetectionModelInfo] {
        EnsembleDownloader.eligibleMembers(from: state.models)
    }

    private var canSubmit: Bool {
        switch tab {
        case .custom:
            return !path.isEmpty && validationError == nil && !displayName.trimmed.isEmpty
        case .ensemble:
            return primaryId != secondaryId
        }
    }

    // MARK: — Actions

    private func choosePath() {
        presentOpenPanel(allowedExtensions: [],
                         allowFolders: kind.wantsDirectory,
                         allowMultiple: false) { urls in
            guard let url = urls.first else { return }
            path = url.path
            didPick = true
            validationError = CustomModelStore.validationMessage(path: url.path, kind: kind)
            if displayName.trimmed.isEmpty {
                displayName = url.deletingPathExtension().lastPathComponent
            }
        }
    }

    private func addCustom() {
        // Re-validate at submit: the picker's answer could be seconds stale.
        if let problem = CustomModelStore.validationMessage(path: path, kind: kind) {
            validationError = problem
            return
        }
        let entry = CustomModelEntry(name: displayName.trimmed,
                                     path: path,
                                     kind: kind,
                                     runtime: kind == .stardist ? .base : runtime)
        guard CustomModelStore.add(entry) else {
            validationError = "Couldn't save the model. Try again."
            return
        }
        refreshCatalog()
        dismiss()
    }

    private func saveEnsemble() {
        guard EnsembleDownloader.setMembers(primary: primaryId, secondary: secondaryId) else {
            return
        }
        state.installStateCache.refresh(modelId: EnsembleDownloader.modelId,
                                        registry: state.detectorRegistry,
                                        models: state.models)
        dismiss()
    }

    /// Re-read the catalog so a newly registered model appears immediately, and
    /// re-probe so its row resolves to Activate rather than "Checking…".
    private func refreshCatalog() {
        state.models = ModelCatalog.all
        state.installStateCache.refresh(for: state.models, registry: state.detectorRegistry)
    }
}

// MARK: — Small shared bits

private struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.06 * 10.5)
            .foregroundStyle(Tokens.textTertiary)
    }
}

private struct CalloutRow: View {
    let icon: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Icon(icon, size: 12).foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
            .fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
            .strokeBorder(tint.opacity(0.28), lineWidth: 0.5))
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
