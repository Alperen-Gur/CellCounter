import AppKit
import Combine
import SwiftUI

struct WorkbenchView: View {
    @Bindable var session: WorkbenchSession
    var onLibraryMigration: (() -> Void)?
    var isActive = true
    @State private var visitedTasks: Set<WorkbenchTask> = []
    @State private var newName = "Microscopy project"
    @State private var showingExperiment = false
    @State private var showingPackage = false
    @State private var showingSavedRecords = false
    @State private var showingPlugins = false
    @State private var showingAdaptation = false
    @State private var showingModels = false
    @State private var showingAssays = false
    @State private var showingResultFreshness = false
    @State private var showingPreprocessing = false
    @State private var showingVariant = false
    @State private var showingSources = false
    @State private var showingRegistration = false
    @State private var showingImageExport = false
    @State private var showingLabelImport = false
    @State private var showingMaskComparison = false
    @State private var showingAnnotations = false
    @State private var showingProjectDetails = false
    @State private var showingAgentAccess = false
    @State private var showingLayeredWorkspace = false
    @State private var showingLibrary = false
    @State private var showingStatistics = false
    @State private var showingTiledStorage = false
    @State private var tiledStorageScope: WorkbenchStorageScope = .segmentation
    @State private var variantName = ""
    @State private var copyVariantAnalysis = false
    @FocusState private var imageFocused: Bool
    private let workerTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            projectBar
            Divider()
            taskBar
            Divider()
            if let error = session.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle")
                    VStack(alignment: .leading, spacing: 4) {
                        if let action = session.errorContext { Text(action).fontWeight(.semibold) }
                        Text(error).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Dismiss") { session.error = nil }
                }
                .font(.callout).foregroundStyle(.red)
                .padding(12).background(Color.red.opacity(0.06))
                .accessibilityElement(children: .combine)
            }
            if session.sharedSession.pendingRevision != nil || session.sharedSession.hasPendingNavigation {
                HStack {
                    Text(session.sharedSession.notice).font(.callout).foregroundStyle(.orange)
                    Spacer()
                    if session.sharedSession.hasPendingNavigation {
                        Button("Apply navigation") { session.resolveRequestedNavigation(apply: true) }
                            .disabled(session.busy || ((!session.canRefreshWithoutDiscardingEdits || session.hasActiveWorkers) &&
                                !session.isTaskOnlyNavigation(session.sharedSession.navigation["selection"])))
                        Button("Refuse") { session.resolveRequestedNavigation(apply: false) }.disabled(session.busy)
                    } else {
                        Button("Refresh") { session.refreshProjectActivity() }.disabled(!session.canRefreshWithoutDiscardingEdits)
                    }
                }.padding(10)
            }
            if session.task != .segmentation, hasSegmentationDraft {
                HStack {
                    Text("Your unfinished segmentation is preserved. Return to Segmentation to finish the preview or correction.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Segmentation") { session.task = .segmentation }
                }.padding(.horizontal, 14).padding(.vertical, 8)
            }
            taskContent
            HStack(spacing: 8) {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary)
                if session.hasActiveWorkers && !session.busy && !session.canRefreshWithoutDiscardingEdits {
                    Text("Progress refresh paused while editing.").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                if let revision = session.revision { Text("Revision \(revision)").font(.caption.monospacedDigit()) }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .background(Tokens.bg)
        .focusedSceneValue(\.cellCounterShortcuts, isActive ? shortcutActions : nil)
        .task {
            session.sharedSession.visible = isActive
            visitedTasks.insert(session.task)
            await session.loadNavigationCatalog()
            if !session.hasProject && !session.projectPath.isEmpty { session.refresh() }
            else { session.refreshProjectActivity() }
            openRequestedLayeredWorkspace()
        }
        .onChange(of: isActive) { _, active in
            session.sharedSession.visible = active
            if active { session.refreshProjectActivity() }
        }
        .onChange(of: session.task) { _, task in
            visitedTasks.insert(task)
            if task == .export, session.hasProject, !session.busy { session.summarize() }
        }
        .onChange(of: session.projectPath) { _, _ in visitedTasks = [session.task] }
        .onDisappear {
            session.sharedSession.visible = false
            Task { await session.closeViewSession() }
        }
        .onChange(of: session.sharedSession.presentWorkspace) { _, requested in
            if requested { openRequestedLayeredWorkspace() }
        }
        .onChange(of: session.hasProject) { _, _ in openRequestedLayeredWorkspace() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if isActive, session.hasProject { session.refreshProjectActivity() }
        }
        .onReceive(workerTimer) { _ in if isActive { session.refreshBackgroundProgress() } }
        .sheet(isPresented: $showingAgentAccess) { WorkbenchAgentAccessView(session: session) }
        .sheet(isPresented: $showingLayeredWorkspace) { WorkbenchWorkspaceView(session: session, workspace: session.layeredWorkspace) }
        .sheet(isPresented: $showingLibrary) { WorkbenchLibraryView(session: session, library: session.library) }
        .sheet(isPresented: $showingTiledStorage) {
            WorkbenchStorageView(session: session, storage: session.storage, scope: tiledStorageScope)
        }
        .sheet(isPresented: $showingStatistics) { WorkbenchStatisticsView(session: session, statistics: session.statistics) }
        .sheet(isPresented: $showingExperiment) { WorkbenchExperimentView(session: session) }
        .sheet(isPresented: $showingPackage) { WorkbenchPackageView(session: session) }
        .sheet(isPresented: $showingPlugins) { WorkbenchPluginsView(session: session, extensions: session.extensions) }
        .sheet(isPresented: $showingAdaptation) { WorkbenchAdaptationView(session: session, extensions: session.extensions) }
        .sheet(isPresented: $showingModels) { WorkbenchModelsView(session: session, models: session.models) }
        .sheet(isPresented: $showingAssays) { WorkbenchAssaysView(session: session, assays: session.assays) }
        .sheet(isPresented: $showingResultFreshness) {
            WorkbenchResultRefreshView(session: session, refresh: session.resultRefresh)
        }
        .sheet(isPresented: $showingPreprocessing) {
            WorkbenchPreprocessingView(session: session, preprocessing: session.preprocessing)
        }
        .sheet(isPresented: $showingSources) {
            WorkbenchSourcesView(session: session, sources: session.sources)
        }
        .sheet(isPresented: $showingRegistration) {
            WorkbenchRegistrationView(session: session, registration: session.registration)
        }
        .sheet(isPresented: $showingImageExport) {
            WorkbenchImageExportView(session: session, exports: session.imageExports)
        }
        .sheet(isPresented: $showingLabelImport) {
            WorkbenchLabelImportView(session: session, labelImport: session.labelImport)
        }
        .sheet(isPresented: $showingMaskComparison) {
            WorkbenchMaskComparisonView(session: session, comparison: session.comparison)
        }
        .sheet(isPresented: $showingAnnotations) {
            WorkbenchAnnotationsView(session: session, annotations: session.annotations)
        }
        .sheet(isPresented: $showingVariant) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Independent mask variant").font(.title2)
                Text("Create a separate analysis identity for the same acquired pixels and calibration. Use it for a second segmentation, such as nuclear masks alongside cell masks.")
                    .foregroundStyle(.secondary)
                TextField("Variant name", text: $variantName).textFieldStyle(.roundedBorder)
                Toggle("Copy current saved masks", isOn: $copyVariantAnalysis)
                Text("The new variant has independent corrections. Reference approvals and tracks belong to the original analysis.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { showingVariant = false }
                    Button("Create variant") {
                        session.duplicateImage(name: variantName, copyAnalysis: copyVariantAnalysis)
                        showingVariant = false
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 500).disabled(session.busy)
        }
    }

    private var hasSegmentationDraft: Bool {
        session.viewingVolume
            ? session.volume.parametersChanged || session.volume.isPreview || !session.volume.polygon.isEmpty || session.volume.editMode != "select"
            : session.parametersChanged || session.isPreview || !session.polygon.isEmpty || session.drawingPolygon
    }

    private var shortcutActions: ScreenShortcutActions {
        var actions = ScreenShortcutActions()
        if session.hasProject, !session.busy {
            if !session.hasActiveWorkers { actions.export = { session.presentExportProject() } }
            if session.task == .segmentation, session.selectedImage != nil {
                actions.run = { if session.viewingVolume { session.analyzeVolume(previewOnly: false) } else { session.analyze(previewOnly: false) } }
                actions.preview = { if session.viewingVolume { session.analyzeVolume(previewOnly: true) } else { session.analyze(previewOnly: true) } }
                if !session.viewingVolume, !session.isPreview { actions.undo = session.undo }
            }
        }
        return actions
    }

    private var projectBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.hasProject ? session.projectName : "Microscopy project").font(.headline)
                Text(session.hasProject ? imageContext : "Import, analyze, correct, measure and export in one project.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if session.hasProject {
                Button { showingProjectDetails = true } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).help("Project location and revision")
                    .accessibilityLabel("Project details")
                    .popover(isPresented: $showingProjectDetails) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Project details").font(.headline)
                            Text(session.projectName).font(.callout)
                            Text(session.projectPath).font(.caption).textSelection(.enabled)
                            if let revision = session.revision {
                                Text("Saved revision \(revision)").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.projectPath)])
                                }
                                Button("Copy path") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(session.projectPath, forType: .string)
                                }
                            }
                        }.padding(16).frame(width: 390)
                    }
            }
            Menu("Project") {
                Button("New project…", action: { session.presentCreateProject(name: newName) })
                    .disabled(!session.canRefreshWithoutDiscardingEdits || session.hasActiveWorkers)
                Button("Open project…", action: session.presentOpenProject)
                    .disabled(!session.canRefreshWithoutDiscardingEdits || session.hasActiveWorkers)
                if !session.hasProject {
                    Button("Restore analysis package…") { showingPackage = true }
                }
                Button("Browse saved records…") { showingSavedRecords = true }.disabled(!session.hasProject)
                if let onLibraryMigration {
                    Button("Copy existing library into a project…", action: onLibraryMigration)
                        .disabled(!session.canRefreshWithoutDiscardingEdits || session.hasActiveWorkers)
                }
                Divider()
                Button("AI agent and command-line access…") { showingAgentAccess = true }
                Button("Refresh project", action: session.refresh)
                    .disabled(!session.hasProject || !session.canRefreshWithoutDiscardingEdits)
            }.fixedSize()
        }
        .padding(14).disabled(session.busy)
        .sheet(isPresented: $showingSavedRecords) { WorkbenchCatalogueBrowser(session: session, catalogues: []) }
    }

    private func openRequestedLayeredWorkspace() {
        guard session.sharedSession.presentWorkspace else { return }
        guard session.hasProject else {
            session.reportStatus("Create or open a shared project to add layers or import an existing workspace document.")
            return
        }
        guard session.canRefreshWithoutDiscardingEdits, !session.hasActiveWorkers else { return }
        showingLayeredWorkspace = true; session.sharedSession.presentWorkspace = false
    }

    private var imageContext: String {
        guard let image = session.selectedImage else { return "\(session.imageCount) images · Select or import an image" }
        if session.viewingVolume {
            return "\(image.name) · Volume · Time \(session.volume.timeIndex + 1) · Channel \(session.volume.channel + 1)"
        }
        return "\(image.name) · 2D projection · Channel \(session.channel + 1)"
    }

    private var taskBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(WorkbenchTask.allCases) { task in
                    Button { session.task = task } label: {
                        Text(task.title).font(.callout.weight(session.task == task ? .semibold : .regular))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(session.task == task ? Color.accentColor.opacity(0.12) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(session.task == task ? .isSelected : [])
                    .help(session.navigationCatalog["tasks"].array.first { $0["id"].string == task.rawValue }?["description"].string ?? task.detail)
                }
            }.padding(.horizontal, 10).padding(.vertical, 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workbench tasks")
    }

    private var taskContent: some View {
        VStack(spacing: 0) {
            if session.hasProject {
                taskTools
                Divider()
            }
            ZStack {
                imageAnalysisContent
                    .opacity(isImageTask || !session.hasProject ? 1 : 0)
                    .allowsHitTesting(isImageTask || !session.hasProject)
                    .accessibilityHidden(!isImageTask && session.hasProject)
                if session.hasProject, visitedTasks.contains(.review) || session.task == .review {
                    WorkbenchReviewView(session: session, review: session.review, embedded: true)
                        .id("review-" + session.projectPath)
                        .opacity(session.task == .review ? 1 : 0)
                        .allowsHitTesting(session.task == .review)
                        .accessibilityHidden(session.task != .review)
                }
                if session.hasProject, visitedTasks.contains(.workflows) || session.task == .workflows {
                    WorkbenchWorkflowView(session: session, embedded: true)
                        .id("workflows-" + session.projectPath)
                        .opacity(session.task == .workflows ? 1 : 0)
                        .allowsHitTesting(session.task == .workflows)
                        .accessibilityHidden(session.task != .workflows)
                }
            }
        }
    }

    private var isImageTask: Bool { ![WorkbenchTask.review, .workflows].contains(session.task) }

    private var imageAnalysisContent: some View {
        HSplitView {
            inspector.frame(minWidth: 240, idealWidth: 270, maxWidth: 340)
            VStack(spacing: 0) {
                if session.task == .export, session.hasProject {
                    resultSummary
                } else if session.viewingVolume, session.selectedImage != nil {
                    WorkbenchVolumeStage(session: session, volume: session.volume).frame(minHeight: 300)
                    if session.task == .segmentation {
                        WorkbenchVolumeCorrectionBar(session: session, volume: session.volume)
                    }
                    if session.task == .measurements {
                        Divider()
                        WorkbenchVolumeMeasurements(session: session, volume: session.volume)
                            .frame(minHeight: 150, idealHeight: 220, maxHeight: 300)
                    }
                } else {
                    imageStage.frame(minHeight: 220)
                    if session.task == .segmentation { correctionBar }
                    if session.task == .measurements {
                        Divider()
                        measurements.frame(minHeight: 200, idealHeight: 300)
                    }
                }
            }.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var taskTools: some View {
        HStack(spacing: 10) {
            switch session.task {
            case .preparation:
                Button("Import images…", action: session.presentImportImages)
                    .disabled(!session.canRefreshWithoutDiscardingEdits || session.hasActiveWorkers)
                Menu("Prepare") {
                    Button("Import image folder…", action: session.presentImportFolder)
                    Button("Sources and regions…") { showingSources = true }
                    Button("Image metadata and collections…") { showingLibrary = true }
                    Button("Layered workspace…") { showingLayeredWorkspace = true }
                    Divider()
                    Button("Preprocess image…") { showingPreprocessing = true }.disabled(session.selectedImageID == nil)
                    Button("Register images…") { showingRegistration = true }.disabled(session.imageCount < 2)
                }.disabled(!session.canRefreshWithoutDiscardingEdits)
            case .segmentation:
                Button("Models…") { showingModels = true }
                Button("Tiled analysis…") { tiledStorageScope = .segmentation; showingTiledStorage = true }
                Menu("Masks") {
                    Button("Create mask variant…") {
                        variantName = "\(session.selectedImage?.name ?? "Image") · variant"
                        copyVariantAnalysis = false; showingVariant = true
                    }.disabled(session.selectedImageID == nil || session.hasActiveWorkers)
                    Button("Import label masks…") { showingLabelImport = true }.disabled(session.selectedImageID == nil)
                }
                Button("Training and adaptation…") { showingAdaptation = true }
            case .measurements:
                Button("Assays…") { showingAssays = true }.disabled(session.selectedImageID == nil)
                Button("Tiled measurements…") { tiledStorageScope = .measurements; showingTiledStorage = true }
                Button("Annotations and profiles…") { showingAnnotations = true }.disabled(session.selectedImageID == nil)
                Button("Biological statistics…") { showingStatistics = true }.disabled(!session.canRefreshWithoutDiscardingEdits)
                if !(session.viewingVolume ? session.volume.selectedLabels : session.selectedLabels).isEmpty {
                    Button("Clear selection") {
                        if session.viewingVolume { session.volume.selectedLabels = [] }
                        else { session.selectedLabels = [] }
                    }
                }
            case .review:
                Button("Compare saved masks…") { showingMaskComparison = true }.disabled(session.selectedImageID == nil)
                Text("Saved reviews retain their own image selection.").font(.caption).foregroundStyle(.secondary)
            case .workflows:
                Button("Experiments and specimens…") { showingExperiment = true }
                Button("Result freshness…") { showingResultFreshness = true }
                Button("Plugins…") { showingPlugins = true }
            case .export:
                Button("Refresh summary", action: session.summarize)
                Button("Tiled results…") { tiledStorageScope = .export; showingTiledStorage = true }
                Button("Scientific image data…") { showingImageExport = true }.disabled(session.selectedImageID == nil)
                Button("Export package…", action: session.presentExportProject).disabled(session.hasActiveWorkers)
                Button("Storage and restore…") { showingPackage = true }
            }
            Spacer(minLength: 0)
        }
        .font(.callout).controlSize(.small).padding(.horizontal, 14).padding(.vertical, 8)
        .disabled(session.busy)
    }

    private var resultSummary: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Project summary").font(.title2)
                if let summary = session.summary {
                    Text("\(summary.cellCount) 2D objects across \(summary.analyzedImageCount) analyzed images")
                        .font(.headline)
                    Text("\(summary.imageCount) imported images · Revision \(summary.revision)")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if !summary.volumes["frames"].array.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("3D analysis").font(.headline)
                                    Text("\(summary.volumes["cellCount"].integer ?? 0) objects across \(summary.volumes["frameCount"].integer ?? 0) analyzed volumes")
                                    ForEach(Array(summary.volumes["frames"].array.enumerated()), id: \.offset) { _, frame in
                                        Text("\(frame["name"].string ?? "Image") · T\((frame["timeIndex"].integer ?? 0) + 1), C\((frame["channel"].integer ?? 0) + 1): \(frame["cellCount"].integer ?? 0) objects · \(frame["voxelCount"].integer ?? 0) voxels · \(formatted(frame["volumeUm3"].number)) µm³")
                                    }
                                    Text("Time points are not biological replicates.").font(.caption).foregroundStyle(.secondary)
                                }
                                Divider()
                            }
                            ForEach(summary.images) { image in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(image.name).font(.headline)
                                    if let count = image.cellCount {
                                        Text("\(count) objects · Total area \(formatted(image.totalAreaPx)) px²")
                                        if image.totalAreaUm2 != nil {
                                            Text("Total area \(formatted(image.totalAreaUm2)) µm² · Mean diameter \(formatted(image.meanDiameterUm)) µm")
                                        }
                                        Text("Mean object intensity \(formatted(image.meanCellIntensity))")
                                    } else {
                                        Text("Not analyzed").foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.font(.callout).textSelection(.enabled)
                    }
                    Text("Descriptive image summaries. Images are not treated as independent biological replicates.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if session.busy {
                    ProgressView("Computing summary…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(session.error ?? "No summary is available.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.padding(16)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !session.hasProject {
                    Text("One project, shared operations").font(.headline)
                    Text("Import images, preview segmentation, correct objects, inspect measurements and export a portable analysis package.")
                        .font(.callout).foregroundStyle(.secondary)
                    TextField("New project name", text: $newName)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("New project name")
                    Button("New project…", action: { session.presentCreateProject(name: newName) })
                    Button("Open project…", action: session.presentOpenProject)
                }
                Text("Images").font(.headline)
                if session.hasProject { WorkbenchImageBrowserControls(session: session, page: session.imagePage) }
                if session.imageCount == 0 {
                    Text("No images imported.").font(.callout).foregroundStyle(.secondary)
                    if session.hasProject {
                        Button("Import images…", action: session.presentImportImages)
                            .buttonStyle(.borderedProminent).disabled(session.hasActiveWorkers)
                    }
                }
                if let selected = session.selectedImage, !session.imagePage.images.contains(where: { $0.id == selected.id }) {
                    Text("Selected off this page: \(selected.name)").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(session.imagePage.images) { image in
                    Button { session.select(image.id) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(image.name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            if image.archived { Text("Archived · selected image").font(.caption).foregroundStyle(.secondary) }
                            Text("\(image.width) × \(image.height) · \(image.cellCount.map { "\($0) 2D objects" } ?? (image.volumeFrameCount > 0 ? "\(image.volumeFrameCount) analyzed volumes" : image.status))")
                                .font(.caption).foregroundStyle(.secondary)
                            if image.cellCount != nil, image.volumeFrameCount > 0 {
                                Text("\(image.volumeFrameCount) analyzed volumes").font(.caption).foregroundStyle(.secondary)
                            }
                            if image.variantOf != nil {
                                Text("Independent mask variant").font(.caption).foregroundStyle(.secondary)
                            }
                            if !image.lineages.isEmpty {
                                let divisions = image.lineages.reduce(0) { $0 + ($1["divisionCount"].integer ?? 0) }
                                Text("\(divisions) lineage divisions\(image.lineages.contains { $0["status"].string == "stale" } ? " · Lineage out of date" : "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if image.registration["registered"].bool == true {
                                Text(image.registration["parentInputsCurrent"].bool == false
                                    ? "Registered image · Parent inputs changed" : "Registered image")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .background(session.selectedImageID == image.id ? Color.accentColor.opacity(0.12) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
                if let image = session.selectedImage {
                    Divider()
                    if session.task != .export {
                        WorkbenchCompositeControls(session: session, composite: session.composite)
                    }
                    Divider()
                    if image.supportsVolume {
                        Picker("Analysis view", selection: Binding(
                            get: { session.viewingVolume }, set: { session.setVolumeMode($0) })) {
                            Text("Volume and time").tag(true)
                            Text("2D projection (first time point)").tag(false)
                        }
                    }
                    if session.viewingVolume, session.task != .export {
                        WorkbenchVolumeControls(session: session, volume: session.volume)
                    } else if !session.viewingVolume {
                    if session.task == .segmentation {
                    Text("Segmentation").font(.headline)
                    Picker("Method", selection: $session.method) {
                        ForEach(WorkbenchClassicalMethod.names, id: \.id) { value in Text(value.title).tag(value.id) }
                    }
                    Picker("Foreground", selection: $session.polarity) {
                        Text("Bright objects").tag("bright")
                        Text("Dark objects").tag("dark")
                        Text("Automatic (median background)").tag("auto")
                    }
                    if session.method == "manual" {
                        numberField("Raw intensity threshold", value: $session.threshold)
                    }
                    if session.method == "adaptive" {
                        integerField("Neighbourhood (odd pixels, 3–501)", value: $session.adaptiveBlockSize)
                        Picker("Adaptive offset", selection: $session.adaptiveOffsetMode) {
                            Text("Automatic (local residual)").tag("auto")
                            Text("Manual").tag("manual")
                        }
                        if session.adaptiveOffsetMode == "manual" { numberField("Offset (source intensity)", value: $session.adaptiveOffset) }
                        Text("Local Gaussian background with reflecting edges. Automatic offset is half the residual standard deviation in the source intensity scale. Requires rectangular acquired support.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Fill enclosed holes", isOn: Binding(get: { session.fillHoles }, set: { session.fillHoles = $0; session.fillHolesExplicit = true }))
                    integerField("Minimum area (pixels²)", value: $session.minAreaPx)
                    integerField("Split distance (pixels)", value: $session.minDistancePx)
                    Picker("Channel", selection: $session.channel) {
                        ForEach(0..<image.channels, id: \.self) { channel in
                            Text("Channel \(channel + 1)").tag(channel)
                        }
                    }
                    Picker("Z projection", selection: $session.projection) {
                        Text("Maximum").tag("max")
                        Text("Mean").tag("mean")
                        Text("Middle plane").tag("middle")
                    }
                    HStack {
                        Button("Preview") { session.analyze(previewOnly: true) }
                        Button("Run analysis") { session.analyze(previewOnly: false) }.buttonStyle(.borderedProminent)
                    }
                    Text("Threshold and watershed settings. Choose Models for registered model inference, or Workflows for reusable analyses.")
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    if session.task == .preparation {
                    Divider()
                    Text("Calibration").font(.headline)
                    numberField("Pixels per micrometre", value: $session.calibration)
                    Button("Apply calibration", action: session.applyCalibration)
                        .disabled(!session.calibration.isFinite || session.calibration <= 0)
                    if image.pxPerUm == nil {
                        Text("Physical measurements need calibration. Pixel measurements remain available.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    }
                    }
                }
            }
            .padding(14)
        }
        .disabled(session.busy)
    }

    private var imageStage: some View {
        GeometryReader { geometry in
            let rect = fittedRect(in: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.88)
                if let image = session.displayedComposite ?? session.preview {
                    Image(nsImage: image).resizable().interpolation(.none)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    if !session.parametersChanged, !session.isPreview, let overlay = session.measurementPage.maskOverlay {
                        Image(nsImage: overlay).resizable().interpolation(.none)
                            .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                            .allowsHitTesting(false)
                    }
                    Canvas { context, _ in
                        guard let source = session.selectedImage else { return }
                        let scale = rect.width / Double(source.width)
                        for cell in session.parametersChanged ? [] : (session.isPreview ? session.cells : session.measurementPage.selectedCells) {
                            let selected = session.selectedLabels.contains(cell.id)
                            let path = objectPath(cell, rect: rect, scale: scale)
                            context.stroke(path, with: .color(selected ? .yellow : .cyan.opacity(0.85)),
                                           lineWidth: selected ? 2.5 : 1)
                        }
                        if !session.polygon.isEmpty {
                            let path = contourPath(session.polygon, rect: rect, scale: scale, closed: false)
                            context.stroke(path, with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                            for point in session.polygon {
                                context.fill(Path(ellipseIn: CGRect(
                                    x: rect.minX + point[0] * scale - 3, y: rect.minY + point[1] * scale - 3,
                                    width: 6, height: 6)), with: .color(.orange))
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { location in imageFocused = true; select(at: location, rect: rect) }
                    .accessibilityLabel("Image and segmentation overlay. Select objects in the measurements table, or click outlines.")
                    if session.parametersChanged {
                        Text("Settings changed. Preview or run to update the image and results.")
                            .font(.caption.weight(.semibold)).padding(7)
                            .background(.black.opacity(0.7)).foregroundStyle(.yellow).padding(10)
                    } else if session.isPreview {
                        Text("Unsaved preview").font(.caption.weight(.semibold)).padding(7)
                            .background(.black.opacity(0.7)).foregroundStyle(.yellow).padding(10)
                    } else if session.displayedComposite != nil {
                        Text(session.composite.hasDraftChanges ? "Composite display · Changes pending" : "Composite display")
                            .font(.caption.weight(.semibold)).padding(7)
                            .background(.black.opacity(0.7)).foregroundStyle(.white).padding(10)
                    } else if session.composite.enabled {
                        Text("Source display · Preview composite for this selection")
                            .font(.caption.weight(.semibold)).padding(7)
                            .background(.black.opacity(0.7)).foregroundStyle(.white).padding(10)
                    }
                } else {
                    ContentUnavailableView(session.hasActiveWorkers ? "Background analysis running" : "Image preview",
                        systemImage: session.hasActiveWorkers ? "gearshape.2" : "photo",
                        description: Text(session.hasActiveWorkers ?
                            (session.jobWorkers.contains { $0.active && $0.targetKind == "tiled-analysis" }
                                ? "Open Segmentation → Tiled analysis for progress and stop controls. The image reloads when the worker stops."
                                : session.jobWorkers.contains { $0.active && $0.targetKind == "refresh" }
                                ? "Open Measurements → Saved result freshness for checkpoint progress and stop controls. The image reloads when the worker stops."
                                : "Open Workflows for checkpoint progress and stop controls. The image reloads when the worker stops.") :
                            session.hasProject ? "Import or select an image." : "Create or open a project."))
                        .foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .focusable().focused($imageFocused)
        .onKeyPress(keys: [.delete, .deleteForward, .escape, .return, .init("z")]) { press in
            guard session.task == .segmentation else { return .ignored }
            guard !session.busy, !KeyboardShortcutContext.isEditingText,
                  !KeyboardShortcutContext.hasNativeSheet else { return .ignored }
            if press.key == .escape, press.modifiers.isEmpty {
                session.polygon = []; session.drawingPolygon = false; session.selectedLabels = []
                return .handled
            }
            guard !session.isPreview, !session.parametersChanged, session.preview != nil else { return .ignored }
            if press.key == .init("z"), press.modifiers == .command { session.undo(); return .handled }
            guard press.modifiers.isEmpty else { return .ignored }
            if press.key == .return, session.drawingPolygon, session.polygon.count >= 3 {
                session.edit("polygon"); return .handled
            }
            if press.key == .delete || press.key == .deleteForward {
                if session.drawingPolygon, !session.polygon.isEmpty { session.polygon.removeLast(); return .handled }
                if !session.drawingPolygon, !session.selectedLabels.isEmpty { session.edit("delete"); return .handled }
            }
            return .ignored
        }
    }

    private var correctionBar: some View {
        HStack(spacing: 10) {
            Toggle("Draw object", isOn: $session.drawingPolygon).toggleStyle(.button)
                .onChange(of: session.drawingPolygon) { _, _ in session.polygon = [] }
            if session.drawingPolygon {
                Button("Save polygon") { session.edit("polygon") }.disabled(session.polygon.count < 3)
                Button("Clear") { session.polygon = [] }
                Text("Click vertices. Return saves; Delete removes the last vertex; Escape clears.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Delete", action: { session.edit("delete") }).disabled(session.selectedLabels.isEmpty)
                Button("Merge", action: { session.edit("merge") }).disabled(session.selectedLabels.count < 2)
                Button("Undo correction", action: session.undo)
                Text("\(session.selectedLabels.count) selected").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .disabled(session.busy || session.isPreview || session.parametersChanged ||
                  session.selectedImage == nil || session.preview == nil)
    }

    private var measurements: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !session.parametersChanged {
                WorkbenchSupportNote(support: session.validSupport).padding(.horizontal, 10)
            }
            if !session.isPreview { WorkbenchMeasurementPageControls(session: session, page: session.measurementPage).padding(.horizontal, 10) }
            else { Text("Unsaved preview: \(session.cells.count) displayed rows of \(session.measurementPage.total) objects. Run analysis for paged measurements.").font(.caption).padding(.horizontal, 10) }
            Table(session.parametersChanged ? [] : session.cells, selection: Binding(get: {
                session.selectedLabels.intersection(Set(session.cells.map(\.id)))
            }, set: { next in
                let outside = session.selectedLabels.subtracting(Set(session.cells.map(\.id)))
                session.selectSavedLabels(outside.union(next))
            })) {
                TableColumn("Object") { cell in Text(String(cell.id)) }.width(min: 55, ideal: 65)
                TableColumn("Area (px²)") { cell in Text(cell.areaPx, format: .number.precision(.fractionLength(0))) }
                TableColumn("Area (µm²)") { cell in Text(formatted(cell.areaUm2)) }
                TableColumn("Diameter (µm)") { cell in Text(formatted(cell.diameterUm)) }
                TableColumn("Mean intensity") { cell in Text(formatted(cell.meanIntensity)) }
            }
        }
        .font(.caption.monospacedDigit())
        .disabled(session.busy || session.isPreview)
    }

    private func formatted(_ value: Double?) -> String {
        value.map { String(format: "%.3f", $0) } ?? "—"
    }

    private func numberField(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
        }
    }

    private func integerField(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
        }
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        guard let image = session.selectedImage else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / Double(image.width), size.height / Double(image.height))
        let width = Double(image.width) * scale, height = Double(image.height) * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func contourPath(_ points: [[Double]], rect: CGRect, scale: Double, closed: Bool = true) -> Path {
        var path = Path()
        for (index, pair) in points.enumerated() where pair.count == 2 {
            let point = CGPoint(x: rect.minX + pair[0] * scale, y: rect.minY + pair[1] * scale)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        if closed { path.closeSubpath() }
        return path
    }

    private func objectPath(_ cell: WorkbenchCell, rect: CGRect, scale: Double) -> Path {
        var path = Path()
        for contour in cell.contours { path.addPath(contourPath(contour, rect: rect, scale: scale)) }
        return path
    }

    private func select(at point: CGPoint, rect: CGRect) {
        guard !session.busy, !session.parametersChanged, rect.contains(point), let image = session.selectedImage else { return }
        let scale = rect.width / Double(image.width)
        let sourcePoint = CGPoint(x: (point.x - rect.minX) / scale, y: (point.y - rect.minY) / scale)
        if session.task == .segmentation && session.drawingPolygon && !session.isPreview {
            if session.polygon.count < 2048 { session.polygon.append([sourcePoint.x, sourcePoint.y]) }
            return
        }
        guard session.task == .segmentation || session.task == .measurements, !session.isPreview else { return }
        session.pickSavedLabel(x: sourcePoint.x, y: sourcePoint.y,
            extending: NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command))
    }

 }
