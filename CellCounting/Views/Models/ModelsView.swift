import SwiftUI

// MARK: — Main screen

struct ModelsView: View {
    @Bindable var state: AppState
    @State private var searchText: String = ""
    @State private var presentingLineageFor: String? = nil
    @FocusState private var searchFocused: Bool
    @Environment(AppTheme.self) private var theme

    private var allModels: [DetectionModelInfo] { state.models }

    private var filteredModels: [DetectionModelInfo] {
        let base: [DetectionModelInfo]
        if state.modelFilter == .all {
            base = allModels
        } else {
            base = allModels.filter { $0.family == state.modelFilter }
        }
        guard !searchText.isEmpty else { return base }
        let q = searchText.lowercased()
        return base.filter {
            $0.name.lowercased().contains(q)
            || $0.desc.lowercased().contains(q)
            || $0.tags.joined(separator: " ").lowercased().contains(q)
        }
    }

    /// True when a cellpose-family model is currently active but the venv is
    /// entirely missing. Drives the "Active model is not installed" banner —
    /// distinct from the broken-venv banner that fires for half-built venvs.
    /// Reads both the @Observable mirror (for SwiftUI re-renders after
    /// `ccVenvChanged`) and the filesystem (to survive stale-cache races on
    /// first render before the observer fires).
    private var isActiveCellposeMissing: Bool {
        guard let info = state.models.first(where: { $0.id == state.activeModelId }),
              info.family == .cellpose else { return false }
        // Touch the observable so SwiftUI re-renders on mirror changes.
        let mirror = state.activeModelInstallState
        if case .installed = mirror { return false }
        let venv = FileStore.shared.pythonVenvDir
        return !FileManager.default.fileExists(atPath: venv.path)
    }

    /// Pass-16: same as `isActiveCellposeMissing` but for the cellpose 4.x
    /// (CPSAM) family. Drives the same banner shape — but the CTA opens the
    /// 4.x install sheet (`showInstallCellpose4`) instead of the 3.x one.
    private var isActiveCellpose4Missing: Bool {
        guard let info = state.models.first(where: { $0.id == state.activeModelId }),
              info.family == .cellpose4 else { return false }
        let mirror = state.activeModelInstallState
        if case .installed = mirror { return false }
        return !FileManager.default.fileExists(atPath: FileStore.shared.pythonVenv4Dir.path)
    }

    /// Reads the cache, NOT the registry — avoids subprocess on the main
    /// thread during render. Cache is populated on `.onAppear` below.
    private var downloadedCount: Int {
        allModels.filter { state.installStateCache.get($0.id) == .installed }.count
    }
    private var diskMB: Int {
        allModels
            .filter { state.installStateCache.get($0.id) == .installed }
            .reduce(0) { $0 + $1.sizeMB }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ModelsHeaderRow(
                    searchText: $searchText,
                    searchFocused: $searchFocused,
                    isRefreshing: state.installStateCache.isRefreshing,
                    onRefresh: {
                        state.installStateCache.refresh(for: state.models, registry: state.detectorRegistry)
                    }
                )
                .padding(.bottom, 16)

                if !state.modelsBannerDismissed {
                    ModelsBanner(count: allModels.count, onDismiss: { state.dismissModelsBanner() })
                        .padding(.bottom, 16)
                }

                // Broken / missing-venv banner. Two trigger paths:
                //   1. The venv exists but is partially built (pip/python/
                //      cellpose-import missing). Always show, regardless of
                //      active model.
                //   2. The venv is entirely missing AND the user's active
                //      model is in the cellpose family — surfaces an install
                //      affordance even though no partial install exists.
                if let reason = CellposeBrokenProbe.reason() {
                    BrokenVenvBanner(
                        title: "Cellpose install is broken — \(reason)",
                        subtitle: "Reinstalling will delete the partial environment and start over.",
                        cta: "Reinstall…",
                        onTap: { state.showInstallCellpose = true }
                    )
                    .padding(.bottom, 16)
                } else if isActiveCellposeMissing {
                    let activeName = state.models
                        .first(where: { $0.id == state.activeModelId })?.name
                        ?? state.activeModelName
                    BrokenVenvBanner(
                        title: "Active model '\(activeName)' is not installed",
                        subtitle: "Detection is disabled until Cellpose is installed.",
                        cta: "Install Cellpose…",
                        onTap: { state.showInstallCellpose = true }
                    )
                    .padding(.bottom, 16)
                } else if isActiveCellpose4Missing {
                    // Pass-16: the active model is CPSAM but venv4 isn't on
                    // disk. Route to the new install sheet rather than the
                    // 3.x one — the two flows install to different venvs and
                    // share nothing.
                    let activeName = state.models
                        .first(where: { $0.id == state.activeModelId })?.name
                        ?? state.activeModelName
                    BrokenVenvBanner(
                        title: "Active model '\(activeName)' is not installed",
                        subtitle: "Detection is disabled until Cellpose-SAM is installed.",
                        cta: "Install Cellpose-SAM…",
                        onTap: { state.showInstallCellpose4 = true }
                    )
                    .padding(.bottom, 16)
                }

                InstallCellposeBanner(state: state)
                    .padding(.bottom, 16)

                ModelsFilterChips(
                    filter: state.modelFilter,
                    allModels: allModels,
                    onSelect: { state.setFilter($0) }
                )
                .padding(.bottom, 16)

                ModelsSections(
                    filtered: filteredModels,
                    allModels: allModels,
                    filter: state.modelFilter,
                    state: state,
                    presentingLineageFor: $presentingLineageFor,
                    onActivate: { state.activate($0) },
                    onDownload: { state.download($0) }
                )

                ModelsDiskFooter(downloaded: downloadedCount, total: allModels.count, diskMB: diskMB, onManageStorage: { state.view = .settings })
                    .padding(.top, 12)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        // ⌘F — focus search field
        .overlay(
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: [.command])
                .hidden()
                .allowsHitTesting(false)
        )
        .onAppear {
            // Pass-16: refresh if ANY model is still .unknown (not "all" — the
            // active model's single-id probe populates only its own cache
            // entry at launch, which used to leave the others stuck at
            // "Checking…"). The explicit Refresh button and
            // `ccVenvChanged` / `cellpose-install-completed` notifications
            // handle subsequent syncs.
            let hasUnknown = state.models.contains {
                if case .unknown = state.installStateCache.get($0.id) { return true }
                return false
            }
            if hasUnknown {
                state.installStateCache.refresh(for: state.models, registry: state.detectorRegistry)
                state.refreshActiveModelInstallState()
                state.refreshDetector()
            }
        }
        // After the install sheet closes, re-check availability so rows flip
        // from "Get" to "Activate" without a manual refresh.
        .onChange(of: state.showInstallCellpose) { _, isShowing in
            if !isShowing {
                state.installStateCache.refresh(for: state.models, registry: state.detectorRegistry)
            }
        }
        // CellposeInstaller posts this when an install completes successfully.
        // K2 will hook the same notification on its real cache. The
        // `cellpose-install-completed` name is matched in CellposeInstaller.swift.
        .onReceive(NotificationCenter.default.publisher(for: .init("cellpose-install-completed"))) { _ in
            state.installStateCache.refresh(for: state.models, registry: state.detectorRegistry)
        }
    }
}

// MARK: — Broken venv banner

private struct BrokenVenvBanner: View {
    let title: String
    let subtitle: String
    let cta: String
    let onTap: () -> Void
    @Environment(AppTheme.self) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Icon("info", size: 15)
                .foregroundStyle(Tokens.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
            }
            Spacer(minLength: 12)
            Button(cta, action: onTap)
                .appButton(.primary, size: .sm)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .fill(Tokens.danger.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .strokeBorder(Tokens.danger.opacity(0.32), lineWidth: 0.5)
        )
    }
}

// MARK: — Header row

private struct ModelsHeaderRow: View {
    @Binding var searchText: String
    var searchFocused: FocusState<Bool>.Binding
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Models")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.02 * 22)
                    .foregroundStyle(Tokens.text)
                Text("Cell detection and segmentation. Try different ones to find what works for your imaging.")
                    .font(.system(size: 13))
                    .foregroundStyle(Tokens.textTertiary)
            }
            Spacer()
            HStack(spacing: 8) {
                Button(action: onRefresh) {
                    HStack(spacing: 4) {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Icon("refresh", size: 12)
                        }
                        Text(isRefreshing ? "Checking…" : "Refresh")
                    }
                }
                .appButton(.ghost, size: .sm)
                .disabled(isRefreshing)
                .help("Re-check which models are installed.")

                HStack(spacing: 6) {
                    Icon("search", size: 12)
                        .foregroundStyle(Tokens.textTertiary)
                    TextField("Search models…", text: $searchText)
                        .font(.system(size: 12.5))
                        .textFieldStyle(.plain)
                        .focused(searchFocused)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(width: 180)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                        .fill(Tokens.bgElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                        .strokeBorder(Tokens.borderStrong, lineWidth: 0.5)
                )

            }
        }
    }
}

// MARK: — Banner

private struct ModelsBanner: View {
    let count: Int
    let onDismiss: () -> Void
    @Environment(AppTheme.self) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Icon("info", size: 15)
                .foregroundStyle(theme.accentColor)
            HStack(spacing: 0) {
                Text("\(count) cell-counting models available.")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(" Try different ones to find what works best for your imaging setup.")
                    .font(.system(size: 12.5))
            }
            .foregroundStyle(Tokens.text)
            Spacer()
            Button(action: onDismiss) {
                Icon("x", size: 13)
                    .foregroundStyle(Tokens.textSecondary)
            }
            .appButton(.ghost, size: .sm)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .fill(theme.accentSofter)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .strokeBorder(theme.accentSoft, lineWidth: 0.5)
        )
    }
}

// MARK: — Filter chips row

private struct ModelsFilterChips: View {
    let filter: ModelFamily
    let allModels: [DetectionModelInfo]
    let onSelect: (ModelFamily) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ModelFamily.allCases) { family in
                let isActive = filter == family
                let title: String = {
                    if isActive && family != .all {
                        let n = allModels.filter { $0.family == family }.count
                        return "\(family.rawValue) · \(n)"
                    }
                    return family.rawValue
                }()
                Chip(title: title, active: isActive) {
                    onSelect(family)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: — Sections container

private struct ModelsSections: View {
    let filtered: [DetectionModelInfo]
    let allModels: [DetectionModelInfo]
    let filter: ModelFamily
    @Bindable var state: AppState
    @Binding var presentingLineageFor: String?
    let onActivate: (String) -> Void
    let onDownload: (String) -> Void

    private let familyOrder: [ModelFamily] = [.cellpose, .cellpose4, .stardist, .sam, .custom]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if filter == .all {
                let builtIns = filtered.filter { $0.builtIn }
                if !builtIns.isEmpty {
                    ModelsSectionBlock(
                        title: "Built-in",
                        models: builtIns,
                        state: state,
                        presentingLineageFor: $presentingLineageFor,
                        onActivate: onActivate,
                        onDownload: onDownload
                    )
                }
                ForEach(familyOrder, id: \.self) { family in
                    let list = filtered.filter { $0.family == family && !$0.builtIn }
                    if !list.isEmpty {
                        ModelsSectionBlock(
                            title: family.rawValue,
                            models: list,
                            state: state,
                            presentingLineageFor: $presentingLineageFor,
                            onActivate: onActivate,
                            onDownload: onDownload
                        )
                    }
                }
            } else {
                if !filtered.isEmpty {
                    ModelsSectionBlock(
                        title: filter.rawValue,
                        models: filtered,
                        state: state,
                        presentingLineageFor: $presentingLineageFor,
                        onActivate: onActivate,
                        onDownload: onDownload
                    )
                }
            }

        }
    }
}

// MARK: — Single section

private struct ModelsSectionBlock: View {
    let title: String
    let models: [DetectionModelInfo]
    @Bindable var state: AppState
    @Binding var presentingLineageFor: String?
    let onActivate: (String) -> Void
    let onDownload: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.06 * 11)
                .foregroundStyle(Tokens.textTertiary)
                .padding(.leading, 4)

            ModelListCard(
                models: models,
                state: state,
                presentingLineageFor: $presentingLineageFor,
                onActivate: onActivate,
                onDownload: onDownload
            )
        }
    }
}

// MARK: — Model list card

private struct ModelListCard: View {
    let models: [DetectionModelInfo]
    @Bindable var state: AppState
    @Binding var presentingLineageFor: String?
    let onActivate: (String) -> Void
    let onDownload: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(models.enumerated()), id: \.element.id) { idx, model in
                if idx > 0 {
                    Divider()
                        .overlay(Tokens.divider)
                        .frame(height: 0.5)
                }
                ModelRow(
                    model: model,
                    state: state,
                    presentingLineageFor: $presentingLineageFor,
                    onActivate: { onActivate(model.id) },
                    onDownload: { onDownload(model.id) }
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .fill(Tokens.bgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .strokeBorder(Tokens.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
    }
}

// MARK: — Model row

private struct ModelRow: View {
    let model: DetectionModelInfo
    @Bindable var state: AppState
    @Binding var presentingLineageFor: String?
    let onActivate: () -> Void
    let onDownload: () -> Void

    @State private var showPopover = false
    @Environment(AppTheme.self) private var theme

    private var iconName: String {
        if model.custom { return "sparkles" }
        switch model.family {
        case .cellpose: return "cpu"
        // Pass-16: Cellpose-SAM uses a flame to visually distinguish from
        // the 3.x cpu glyph. UX may refine in a follow-up; case must be
        // present here for the switch to remain exhaustive.
        case .cellpose4: return "flame"
        case .stardist: return "star"
        case .sam: return "flask"
        case .custom: return "sparkles"
        case .all: return "cpu"
        }
    }

    /// Latest fine-tune record for this model — drives the inline lineage chip.
    private var latestVersion: ModelVersionRecord? {
        guard model.custom else { return nil }
        return state.repos.modelVersions(for: model.id).first
    }

    private func relativeDate(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    /// Tint the icon as "active" only when the row is BOTH the active model id
    /// AND actually installed — same coupling rule as the Active chip. Lets a
    /// stale active id (e.g. user rm-rf'd the venv) read as inactive visually.
    private var isActiveAndInstalled: Bool {
        guard state.activeModelId == model.id else { return false }
        if case .installed = state.installStateCache.get(model.id) { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Icon column (28pt)
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActiveAndInstalled ? theme.accentSoft : Tokens.bgSunken)
                    .frame(width: 28, height: 28)
                Icon(iconName, size: 14)
                    .foregroundStyle(isActiveAndInstalled ? theme.accentColor : Tokens.textSecondary)
            }
            .frame(width: 28, height: 28)

            // Center content (1fr)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(model.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                    if model.recommended {
                        TagLabel(text: "Recommended for phase-contrast", style: .accent)
                    } else if model.custom {
                        TagLabel(text: "Yours", style: .accent)
                    }
                }
                Text(model.desc)
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.textTertiary)
                    .lineLimit(2)

                // Pass-16: prominent disk-size warning for CPSAM only. The row
                // description stays short (catalog-owned by C2); this line is
                // an accent-tinted callout the user can't miss before they
                // accidentally trigger a 3.5 GB install.
                if model.family == .cellpose4 {
                    HStack(spacing: 4) {
                        Icon("info", size: 11)
                            .foregroundStyle(theme.accentColor)
                        Text("~1.15 GB weights + ~2 GB Python deps. ~3.5 GB on first run.")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.accentColor)
                    }
                    .padding(.top, 2)
                }

                if let v = latestVersion {
                    Text("v\(v.version) · \(v.trainedOnImages) imgs · \(v.trainedOnCorrections) corrections · \(relativeDate(v.createdAt))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Tokens.textTertiary)
                }

                HStack(spacing: 6) {
                    ForEach(model.tags, id: \.self) { tag in
                        TagLabel(text: tag, style: .neutral)
                    }
                    switch model.speed {
                    case .fast:
                        TagLabel(text: "Fast", style: .fast)
                    case .med:
                        TagLabel(text: "Medium", style: .neutral)
                    case .slow:
                        TagLabel(text: "Slow", style: .neutral)
                    }
                    if model.accuracy == .high {
                        TagLabel(text: "High accuracy", style: .acc)
                    }
                    if model.license == "nc" {
                        TagLabel(text: "Non-commercial", style: .licNc)
                    }
                    if let note = model.note {
                        TagLabel(text: note, style: .neutral)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Size column
            Text(model.sizeLabel)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Tokens.textTertiary)

            // Action column
            HStack(spacing: 6) {
                // Versions button — custom models only
                if model.custom {
                    Button {
                        presentingLineageFor = model.id
                    } label: {
                        HStack(spacing: 4) {
                            Icon("layers", size: 12)
                            Text("Versions")
                        }
                    }
                    .appButton(.ghost, size: .sm)
                    .popover(
                        isPresented: Binding(
                            get: { presentingLineageFor == model.id },
                            set: { if !$0 { presentingLineageFor = nil } }
                        ),
                        arrowEdge: .trailing
                    ) {
                        ModelLineagePopover(modelId: model.id, state: state)
                    }
                }

                // Info button
                Button {
                    showPopover = true
                } label: {
                    Icon("info", size: 13)
                        .foregroundStyle(Tokens.textTertiary)
                }
                .appButton(.ghost, size: .sm)
                .popover(isPresented: $showPopover) {
                    ModelInfoPopover(model: model)
                }

                // State / install action — progress-aware
                ModelRowActions(model: model, state: state)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: — Action cluster (progress-aware)

/// Right-aligned action area for a model row. Reads the optional
/// `ModelInstallProgress` from `state.detectorRegistry.installs[model.id]` and
/// renders the right control (Get / progress bar / installing tail / Activate /
/// Active chip / Retry). Width is roughly stable so rows don't shift on state
/// transitions.
private struct ModelRowActions: View {
    let model: DetectionModelInfo
    @Bindable var state: AppState
    @Environment(AppTheme.self) private var theme

    var body: some View {
        // Observe the registry directly so a fresh `installs[id]` entry forces a
        // redraw. The nested observed view then re-subscribes to the individual
        // progress object's @Published fields.
        RegistryObserver(registry: state.detectorRegistry) {
            if let progress = state.detectorRegistry.installs[model.id] {
                ModelRowActionsObserved(model: model, state: state, progress: progress)
            } else {
                ModelRowActionsStatic(model: model, state: state)
            }
        }
    }
}

/// Thin wrapper that subscribes to the DetectorRegistry's `objectWillChange`
/// publisher. Used so the row redraws when an install task is registered.
private struct RegistryObserver<Content: View>: View {
    @ObservedObject var registry: DetectorRegistry
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
    }
}

private struct ModelRowActionsObserved: View {
    let model: DetectionModelInfo
    @Bindable var state: AppState
    @ObservedObject var progress: ModelInstallProgress
    @Environment(AppTheme.self) private var theme

    var body: some View {
        switch progress.stage {
        case .checkingDependencies:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
            }
            .frame(minWidth: 140, alignment: .trailing)

        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Verifying…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
            }
            .frame(minWidth: 140, alignment: .trailing)

        case .downloading(let p, let rate):
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: max(0, min(1, p)))
                        .progressViewStyle(.linear)
                        .frame(width: 110)
                    HStack(spacing: 6) {
                        Text("\(Int(p * 100))%")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Tokens.textTertiary)
                        if let rate {
                            Text(Self.formatRate(rate))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Tokens.textTertiary)
                        }
                    }
                }
                Button {
                    state.detectorRegistry.installs[model.id] = nil
                } label: {
                    Icon("x", size: 11)
                        .foregroundStyle(Tokens.textSecondary)
                }
                .appButton(.ghost, size: .sm)
                .help("Cancel download")
            }
            .frame(minWidth: 160, alignment: .trailing)

        case .installingDependencies(let line):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(Self.tail(line, max: 32))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Tokens.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(width: 140, alignment: .trailing)
            }
            .frame(minWidth: 160, alignment: .trailing)

        case .ready:
            // Installed — show Active chip or Activate button based on registry + activeModelId.
            installedAction
                .frame(minWidth: 80, alignment: .trailing)

        case .failed(let msg):
            HStack(spacing: 6) {
                Text(Self.tail(msg, max: 24))
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.danger)
                    .lineLimit(1)
                Button("Retry") {
                    state.detectorRegistry.installs[model.id] = nil
                    state.detectorRegistry.install(model.id, models: state.models)
                }
                .appButton(.standard, size: .sm)
            }
            .frame(minWidth: 140, alignment: .trailing)

        case .notStarted:
            // Shouldn't really land here while a progress exists, but stay safe.
            ModelRowActionsStatic(model: model, state: state)
        }
    }

    @ViewBuilder
    private var installedAction: some View {
        // Pass-12: `.ready` means the install just completed, so showing the
        // Active chip here is safe (we know it IS installed). No need for an
        // extra cache check.
        if state.activeModelId == model.id {
            ActiveChip()
        } else {
            Button("Activate") {
                state.activate(model.id)
            }
            .appButton(.primary, size: .sm)
        }
    }

    private static func tail(_ s: String, max n: Int) -> String {
        if s.count <= n { return s }
        return "…" + s.suffix(n - 1)
    }

    private static func formatRate(_ bps: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .file
        return "\(f.string(fromByteCount: bps))/s"
    }
}

private struct ModelRowActionsStatic: View {
    let model: DetectionModelInfo
    @Bindable var state: AppState
    @Environment(AppTheme.self) private var theme

    private var isActive: Bool { state.activeModelId == model.id }

    var body: some View {
        // Pass-19: Coming-soon models are visible in the catalog so the user
        // sees what's planned, but get neither install affordance nor
        // activation. They're not wired or verified end-to-end yet.
        if model.comingSoon {
            ComingSoonChip()
        } else {
        // Read from the cache, NOT the registry directly — the registry's
        // `isInstalled` can fork a Python subprocess which would freeze the
        // view on every render. The cache is refreshed by `.onAppear` / the
        // Refresh button / post-install notifications.
        //
        // The matrix couples Active to Installed: the "Active" chip only
        // renders when the cache also reports `.installed`, so a stale
        // active id (user wiped the venv out-of-band) reads as not-installed.
        let cached = state.installStateCache.get(model.id)
        switch cached {
        case .installed:
            if isActive {
                ActiveChip()
            } else {
                Button("Activate") {
                    state.activate(model.id)
                }
                .appButton(.primary, size: .sm)
            }

        case .notInstalled:
            if isActive {
                // Active model but no install on disk — emphasize the
                // mismatch with a danger chip + reinstall affordance so the
                // user can't miss it. Pass-16: route to the right sheet
                // based on the row's family so CPSAM doesn't fall into the
                // 3.x installer.
                HStack(spacing: 6) {
                    NotInstalledChip()
                    Button {
                        if model.family == .cellpose4 {
                            state.showInstallCellpose4 = true
                        } else {
                            state.showInstallCellpose = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Icon("refresh", size: 11)
                            Text("Reinstall")
                        }
                    }
                    .appButton(.primary, size: .sm)
                    .help("This model is marked Active but isn't installed. Reinstall to recover.")
                }
            } else {
                Button {
                    state.detectorRegistry.install(model.id, models: state.models)
                } label: {
                    HStack(spacing: 4) {
                        Icon("download", size: 11)
                        Text("Get")
                    }
                }
                .appButton(.standard, size: .sm)
            }

        case .unknown:
            // First render before the cache has resolved — show a placeholder
            // instead of either "Get" (false negative) or hanging on a probe.
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
            }

        case .installing:
            // An install is in-flight. The ModelRowActions wrapper renders the
            // detailed progress chip from `installs[modelId]`; here we just
            // show a generic spinner so the static path doesn't read "Get".
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
            }

        case .broken(let reason):
            // Half-installed venv (or weights). Surface a Reinstall CTA so the
            // user has a recovery path instead of a hung spinner. Pass-16:
            // route to the right sheet based on the row's family.
            let openSheet: () -> Void = {
                if model.family == .cellpose4 {
                    state.showInstallCellpose4 = true
                } else {
                    state.showInstallCellpose = true
                }
            }
            if isActive {
                HStack(spacing: 6) {
                    NotInstalledChip()
                    Button(action: openSheet) {
                        HStack(spacing: 4) {
                            Icon("refresh", size: 11)
                            Text("Reinstall")
                        }
                    }
                    .appButton(.primary, size: .sm)
                    .help(reason)
                }
            } else {
                Button(action: openSheet) {
                    HStack(spacing: 4) {
                        Icon("refresh", size: 11)
                        Text("Reinstall")
                    }
                }
                .appButton(.standard, size: .sm)
                .help(reason)
            }
        }
        } // end !comingSoon branch
    }
}

// MARK: — Row state chips (pass 12)

/// Visual chip for "Active" — only rendered when the model is also installed.
private struct ActiveChip: View {
    @Environment(AppTheme.self) private var theme
    var body: some View {
        Text("Active")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(theme.accentColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.accentSoft))
    }
}

/// Pass-19: chip for catalog entries that aren't verified yet — the model is
/// visible to communicate "this is on the roadmap" but the user can't install
/// or activate it.
private struct ComingSoonChip: View {
    var body: some View {
        Text("Coming soon")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Tokens.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(Tokens.bgSunken))
            .overlay(Capsule().strokeBorder(Tokens.border, lineWidth: 0.5))
    }
}

/// Danger-tinted chip for "Active model is not installed on disk". Used in the
/// row's action column next to a Reinstall button.
private struct NotInstalledChip: View {
    var body: some View {
        Text("Not installed")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Tokens.danger)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(Tokens.danger.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Tokens.danger.opacity(0.32), lineWidth: 0.5))
    }
}


// MARK: — Info popover

private struct ModelInfoPopover: View {
    let model: DetectionModelInfo
    @Environment(AppTheme.self) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.text)

            VStack(alignment: .leading, spacing: 8) {
                InfoRow(label: "Architecture", value: model.architecture)
                InfoRow(label: "Training data", value: model.trainingData)
                InfoRow(label: "Output", value: model.outputType)
                InfoRow(label: "License", value: model.license == "nc" ? "Non-commercial" : "Open")

                VStack(alignment: .leading, spacing: 2) {
                    Text("Paper")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Tokens.textTertiary)
                    Text(model.paper)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.text)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Tokens.textTertiary)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.text)
        }
    }
}

// MARK: — Disk footer

private struct ModelsDiskFooter: View {
    let downloaded: Int
    let total: Int
    let diskMB: Int
    let onManageStorage: () -> Void
    @Environment(AppTheme.self) private var theme

    var body: some View {
        HStack {
            Text("\(downloaded) of \(total) models downloaded · \(diskMB) MB on disk")
                .font(.system(size: 12))
                .foregroundStyle(Tokens.textTertiary)
            Spacer()
            Button("Manage storage…", action: onManageStorage)
                .font(.system(size: 12))
                .foregroundStyle(theme.accentColor)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }
}
