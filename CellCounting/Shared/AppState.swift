import SwiftUI
import Observation
import AppKit
import UniformTypeIdentifiers
import SwiftData

enum AppView: String, Hashable, CaseIterable {
    case home, processing, results, batch, workspace, workbench, models, fineTune, settings, queue, reviewQueue, compare, imagesLibrary
}

@MainActor
private struct PendingCellEdit {
    let detection: DetectionRecord
    let image: ImageRecord
    let baseRevision: Int
    var cells: [DetectedCell]
    var corrections: [CorrectionSpec]
    var revision: Int
}

@Observable
@MainActor
final class AppState {
    // Routing
    var view: AppView = .workbench

    /// Workspace lifetime follows the app, not the conditional navigation branch.
    /// Large decoded caches can therefore be trimmed deliberately instead of being
    /// destroyed and recreated every time the user checks another screen.
    @ObservationIgnored
    let workspaceSession = WorkspaceSession()
    let workbenchSession = WorkbenchSession()

    let jobScheduler = AnalysisJobScheduler(store: AnalysisJobStore(
        url: FileStore.shared.analysisJobsURL))
    /// Which data library is open, plus New/Open/Recent Library switching.
    let libraries = LibraryController()
    var analysisSetupJobId: UUID?
    var isPreparingImport = false
    var showLibraryMigration = false
    var preparingLibraryMigration = false
    var libraryMigrationError: String?

    // Modals
    var showCalibration = false
    var showOnboarding = false
    var showInstallCellpose: Bool = false
    /// Pass-16 (C3): present the Cellpose-SAM (cellpose 4.x) install sheet.
    /// Separate from `showInstallCellpose` so the two install flows don't
    /// share UI state — opening one must NOT close the other, and the
    /// toolbar pill / Models row routes to whichever matches the active
    /// model's family.
    var showInstallCellpose4: Bool = false
    /// The Cellpose-SAM sheet was opened by "Update Cellpose-SAM" and starts
    /// the update itself. Reset when the sheet closes.
    var cellpose4UpdateRequested: Bool = false

    /// Presents the analysis-protocol library sheet (save/apply a named,
    /// versioned snapshot of the current detection + calibration +
    /// preprocessing settings, so a whole lab can run identical settings or
    /// cite an exact configuration in a methods section). See
    /// `Services/AnalysisProtocolStore.swift` (model + persistence +
    /// `apply`/`makeAnalysisProtocolSnapshot`) and
    /// `Views/Modals/AnalysisProtocolSheet.swift` (the sheet UI).
    var showAnalysisProtocols: Bool = false

    /// When true, didSet observers skip writing back to UserDefaults. Used by
    /// `refreshFromDefaults()` so observing UserDefaults.didChangeNotification
    /// doesn't ping-pong values back into UserDefaults (and re-trigger ourselves).
    private var suppressDefaultsWriteback: Bool = false

    /// Token for the UserDefaults.didChangeNotification observer registered
    /// in `init`. Held so `deinit` can deregister it. `@ObservationIgnored`
    /// because NSObjectProtocol can't be Observable-wrapped (the generated
    /// init-accessor can't yield through an existential).
    @ObservationIgnored
    private var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored private var trainingActivityObserver: NSObjectProtocol?

    // Analysis params (live UI state — persisted via @AppStorage where applicable)
    var thresholds: [Double] {
        didSet {
            guard !suppressDefaultsWriteback else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(thresholds), forKey: "cc-thresholds")
        }
    }
    /// The user's default scale for images without one (px/µm); 0 when not
    /// set. New batches take it as their scale for images without one. It
    /// never replaces a scale recorded in a file.
    var pxPerUm: Double {
        didSet {
            guard !suppressDefaultsWriteback else { return }
            if pxPerUm > 0 { UserDefaults.standard.set(pxPerUm, forKey: "cc-pxperum") }
            else { UserDefaults.standard.removeObject(forKey: "cc-pxperum") }
        }
    }
    /// The default scale, nil when not set.
    var defaultScale: ImageScale.Value? { ImageScale.Value(pxPerUm, source: ImageScale.defaultSource) }
    var confidence: Double {
        didSet {
            guard !suppressDefaultsWriteback else { return }
            UserDefaults.standard.set(confidence, forKey: "cc-confidence")
        }
    }
    /// Explicit expected cell diameter in MICROMETERS, used as the Cellpose
    /// size prior. `0` means "Auto": the Python sidecar derives the prior from
    /// the size bins (`(small_threshold + large_threshold)/2`) — the historical
    /// behavior, where editing the bins silently re-steers segmentation. Any
    /// value `> 0` is forwarded to the sidecar as `--diameter <µm>`, decoupling
    /// segmentation from the size-bin breakpoints (the large-cell accuracy fix).
    /// Persisted under `cc-expected-diameter` with the same didSet +
    /// writeback-guard pattern as `confidence`/`pxPerUm`.
    var expectedDiameterUm: Double {
        didSet {
            guard !suppressDefaultsWriteback else { return }
            UserDefaults.standard.set(expectedDiameterUm, forKey: "cc-expected-diameter")
        }
    }
    /// Defaults for new Omnipose runs. Jobs and results capture their own copy.
    var omniposeSettings: OmniposeSegmentationSettings {
        didSet {
            guard !suppressDefaultsWriteback else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(omniposeSettings),
                                      forKey: "cc-omnipose-settings")
        }
    }
    /// The currently active detector. Persisted under `cc-active-model`.
    /// Distinct from `cc-default-model` (Settings → General "Default model"),
    /// which is the *fallback* model id used at first launch when no active
    /// model has ever been chosen. Once the user activates anything,
    /// `cc-active-model` takes precedence — see `init`.
    var activeModelId: String {
        didSet {
            guard !suppressDefaultsWriteback else { return }
            UserDefaults.standard.set(activeModelId, forKey: "cc-active-model")
        }
    }
    /// Active fluorescence channel selection. Persisted as JSON-encoded Data.
    var channels: DetectionChannels {
        didSet {
            guard !suppressDefaultsWriteback else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(channels),
                                      forKey: "cc-channels-cyto")
        }
    }
    /// Default diameter (µm) for manually-placed markers. Persisted via UserDefaults.
    var manualMarkerDiameter: Double {
        didSet {
            guard !suppressDefaultsWriteback else { return }
            UserDefaults.standard.set(manualMarkerDiameter, forKey: "cc-manual-diameter")
        }
    }
    /// Apply rolling-ball background subtraction before detection (pass 5).
    var backgroundSubtract: Bool {
        didSet {
            guard !suppressDefaultsWriteback else { return }
            UserDefaults.standard.set(backgroundSubtract, forKey: "cc-bg-subtract")
        }
    }
    /// Rolling-ball radius for background subtraction in pixels (pass 5).
    var rollingBallRadius: Int {
        didSet {
            guard !suppressDefaultsWriteback else { return }
            UserDefaults.standard.set(rollingBallRadius, forKey: "cc-rolling-ball")
        }
    }
    /// Optional ImageJ-inspired preprocessing for the next detection run.
    var preprocessingPreset: PreprocessingPreset {
        didSet {
            guard !suppressDefaultsWriteback else { return }
            UserDefaults.standard.set(preprocessingPreset.rawValue,
                                      forKey: "cc-preprocessing-preset-v1")
        }
    }
    /// A3: When true, the next detection pass runs a distance-transform watershed
    /// to split touching cells. Persisted under `cc-watershed`. Default false.
    var watershedSplit: Bool {
        didSet {
            guard !suppressDefaultsWriteback else { return }
            UserDefaults.standard.set(watershedSplit, forKey: "cc-watershed")
        }
    }
    /// C3 (pass 6): Minimum distance between watershed seed peaks, in micrometers.
    /// Passed as `--watershed-min-distance` to the sidecar. Default 8 µm.
    var watershedMinDistanceUm: Int {
        didSet {
            guard !suppressDefaultsWriteback else { return }
            UserDefaults.standard.set(watershedMinDistanceUm, forKey: "cc-watershed-min-distance-um")
        }
    }
    /// Use GPU when available (Apple Neural Engine / Metal). Default true.
    /// Wired through to the Python sidecar as `--no-gpu` when false.
    var useGPU: Bool {
        didSet {
            guard !suppressDefaultsWriteback else { return }
            UserDefaults.standard.set(useGPU, forKey: "cc-use-gpu")
        }
    }
    /// Verify SHA-256 checksums on model weight downloads. Default true.
    /// Wired through to WeightDownloader.download.
    var verifyChecksums: Bool {
        didSet {
            guard !suppressDefaultsWriteback else { return }
            UserDefaults.standard.set(verifyChecksums, forKey: "cc-verify-checksums")
        }
    }
    /// Max parallel images to detect in `importAndAnalyze`. Default 4.
    var maxParallel: Int {
        didSet {
            guard !suppressDefaultsWriteback else { return }
            UserDefaults.standard.set(maxParallel, forKey: "cc-max-parallel")
        }
    }

    /// How much CPU and memory model processes may use (Settings → General →
    /// Model resource use). Every launch site reads the stored keys through
    /// `ModelResourceLimits.current`, so each is written before the warm
    /// pool is told about the change. Default Balanced.
    var modelResourcePreset: ModelResourcePreset {
        didSet {
            if !suppressDefaultsWriteback {
                UserDefaults.standard.set(modelResourcePreset.rawValue, forKey: ModelResourceChoice.presetKey)
            }
            modelResourcesDidChange()
        }
    }
    /// Custom CPU cores; 0 until chosen (Balanced's value applies).
    var modelResourceCustomCores: Int {
        didSet {
            if !suppressDefaultsWriteback {
                UserDefaults.standard.set(modelResourceCustomCores, forKey: ModelResourceChoice.customCPUCoresKey)
            }
            modelResourcesDidChange()
        }
    }
    /// Custom memory limit in GB; 0 until chosen (Balanced's value applies).
    var modelResourceCustomMemoryGB: Int {
        didSet {
            if !suppressDefaultsWriteback {
                UserDefaults.standard.set(modelResourceCustomMemoryGB, forKey: ModelResourceChoice.customMemoryGBKey)
            }
            modelResourcesDidChange()
        }
    }
    /// The limits the warm pool was last configured with.
    @ObservationIgnored private var appliedModelResourceLimits: ModelResourceLimits?
    /// Confirmation shown (RootView) when Model resource use changes while a
    /// model is running: what applied now and what waits.
    var modelResourceNotice: String?
    @ObservationIgnored private var modelResourceNoticeToken = 0
    /// Settings opens on this section once, then clears it.
    var settingsSectionRequest: SettingsSection?

    /// Size-bin swatches and overlay rendering colors. Persisted as one Codable
    /// value so future plugin overlays can reuse the same appearance contract.
    var overlayPalette: OverlayPalette {
        didSet {
            guard !suppressDefaultsWriteback else { return }
            overlayPalette.save()
        }
    }

    // Processing UX
    /// Set while a real detection is in progress so ProcessingView can drive a determinate bar.
    var processingProgress: Double = 0
    /// Pass-13: latest stderr line from the running detection subprocess.
    /// Cellpose 3.x has no granular numeric progress callback, but it logs
    /// stage transitions (loading model, computing flows, post-processing).
    /// Showing the live line is honest — and keeps the watchdog from firing
    /// "stuck" when the subprocess is making visible progress.
    var processingStageLine: String = ""
    /// Wall-clock of the last `processingStageLine` update. Watchdog reads
    /// this to distinguish "no progress for N seconds" from "actively
    /// emitting log lines."
    var lastStageUpdateAt: Date = Date()
    /// Pass-14: device the running detection subprocess reported via its
    /// `using device: <name>` log line. Empty until the subprocess emits it;
    /// reset between runs. ProcessingView's label reads this for the real
    /// device instead of the `useGPU` user-toggle guess.
    var processingDevice: String = ""

    // Models
    var models: [DetectionModelInfo] = ModelCatalog.all
    var modelFilter: ModelFamily = .all
    var modelsBannerDismissed: Bool = UserDefaults.standard.bool(forKey: "cc-models-banner-dismissed")

    // Repository access (MainActor)
    let repos: Repositories
    /// Detection service in use. Nil until a real model is installed for the
    /// active id — pass-8 removed all mock fallbacks. Callers must check
    /// `canRunDetection` before invoking the drop flow.
    var detector: DetectionService?

    // MARK: — Observable library/review stats (pass-11)
    //
    // Repositories is `@MainActor final class` but NOT `@Observable`, so SwiftUI
    // never re-renders when the SwiftData store changes. These properties are the
    // observation boundary for views (Sidebar counts, Review badge, Home Recents).
    // They are refreshed by `refreshLibraryStats()` on the relevant triggers:
    // app launch, after each `importAndAnalyze` image, after `recordCorrection`,
    // after batch/image deletes, and on `ccCorrectionsChanged` / `ccLibraryChanged`
    // notifications. Views should read these, never call repos directly in `body`.
    private(set) var libraryImageCount: Int = 0
    private(set) var libraryBatchCount: Int = 0
    private(set) var recentBatchSummaries: [BatchSummary] = []
    private(set) var reviewQueueCount: Int = 0
    private(set) var isReviewIndexing = true
    private(set) var reviewIndexError: String?

    /// Confidence cutoff used for the Review queue badge count. Kept here so the
    /// notification listener and the on-launch refresh agree on the threshold.
    private static let reviewQueueConfidenceCutoff: Double = 0.65

    /// Recompute the cached library stats from `repos`. Cheap (SwiftData fetches
    /// are not expensive at our scale) and called only on mutation triggers.
    func refreshLibraryStats() {
        libraryImageCount = repos.totalImageCount()
        libraryBatchCount = repos.totalBatchCount()
        recentBatchSummaries = repos.recentBatchSummaries(limit: 5)
        reviewQueueCount = repos.uncorrectedCellCount(below: Self.reviewQueueConfidenceCutoff)
    }

    @ObservationIgnored
    private var recentSummariesTask: Task<Void, Never>?

    /// Debounced `recentBatchSummaries` refresh for rapid edit notifications.
    private func scheduleRecentSummariesRefresh() {
        recentSummariesTask?.cancel()
        recentSummariesTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.recentBatchSummaries = self.repos.recentBatchSummaries(limit: 5)
        }
    }

    /// Observer token for `ccLibraryChanged` — held so we don't leak (matches the
    /// `defaultsObserver` pattern above).
    @ObservationIgnored
    private var libraryChangedObserver: NSObjectProtocol?
    @ObservationIgnored
    private var correctionsChangedObserver: NSObjectProtocol?
    /// Pass-12 K1: tokens for venv/install lifecycle notifications. Held so
    /// they survive for the AppState's lifetime; process-lifetime in practice.
    @ObservationIgnored
    private var venvChangedObserver: NSObjectProtocol?
    @ObservationIgnored
    private var installCompletedObserver: NSObjectProtocol?
    @ObservationIgnored
    private var detectionStageObserver: NSObjectProtocol?
    /// Registering or removing a bring-your-own model changes the CATALOG, not
    /// just an install state — `ModelCatalog.all` reads `CustomModelStore`, so
    /// `models` has to be re-read. Held for the AppState's lifetime.
    @ObservationIgnored
    private var customModelsObserver: NSObjectProtocol?
    /// Pass-16: venv4 (cellpose 4.x) lifecycle observers. Distinct from the
    /// 3.x observers so changes to one venv don't kick the other's UI re-probe.
    @ObservationIgnored
    private var venv4ChangedObserver: NSObjectProtocol?
    @ObservationIgnored
    private var cellposeSAMInstallCompletedObserver: NSObjectProtocol?
    /// Central registry — knows how to download/install each model family and produce the right service per model id.
    let detectorRegistry: DetectorRegistry
    /// Pass-11: per-AppState install-state cache. Views read from this rather
    /// than calling `detectorRegistry.isInstalled` in body — that would fork
    /// a subprocess on the main thread for every row, every render. The cache
    /// refreshes off-main on view appear, after install completion, and on
    /// user-triggered "Refresh" in the Models view.
    let installStateCache: InstallStateCache

    /// Last detection error surfaced to the UI (alert in HomeView, banner in ResultsView).
    var lastDetectionError: String? = nil
    /// Drives the `.alert` on the root view. Set to true when `lastDetectionError` becomes non-nil.
    var showDetectionError: Bool = false

    // MARK: — Pass-17 Lane C: EXIF calibration note

    /// Non-blocking informational banner shown in ResultsView after EXIF-based
    /// calibration is applied. Auto-dismisses after 5 s (driven by a Task in
    /// `proceedWithImport`). Nil when no note is pending.
    var lastCalibrationNote: String? = nil

    // MARK: — Export feedback (keyboard-shortcut exports)

    /// Non-blocking toast shown after a keyboard-shortcut export (⌘E / ⌘⇧E in
    /// Results, ⌘E in Compare). Mirrors the inline confirmation the
    /// ResultsExportPanel buttons already show, so shortcut exports aren't
    /// silent. `isError` picks the success (check) vs failure (warning) styling.
    /// Nil when no toast is pending; auto-dismissed by `flashExport`.
    var exportToast: (message: String, isError: Bool)? = nil
    private var exportToastToken: Int = 0

    /// Show an export result toast and auto-dismiss it after 2 s, matching the
    /// ResultsExportPanel feedback timing. Safe to call from the main actor from
    /// any export shortcut handler.
    func flashExport(_ message: String, isError: Bool) {
        exportToast = (message, isError)
        exportToastToken &+= 1
        let token = exportToastToken
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.exportToastToken == token else { return }
            withAnimation(Tokens.Motion.ease) { self.exportToast = nil }
        }
    }

    // MARK: — Pass-17: Duplicate import prompt

    /// When a drop session contains files that already exist in the library,
    /// this is set before the import proceeds so the UI can present the
    /// DuplicateImportSheet. The sheet reads this and clears it when dismissed.
    var pendingDuplicateSession: DuplicateImportSession? = nil
    /// Set to true when `pendingDuplicateSession` is populated. Drives `.sheet`.
    var showDuplicateImportSheet: Bool = false

    /// Pass-14: image ids whose re-run detection is currently in flight. Used
    /// to make `reRunDetection(on:)` idempotent against button double-taps,
    /// SwiftUI onChange storms, and any caller that re-fires while the
    /// previous subprocess is still alive. Views read `isRerunning(_:)` to
    /// disable the Re-run button while a task is mid-flight.
    private(set) var inFlightRerunImageIds: Set<UUID> = []

    /// True if a re-run is currently dispatched for this image. Views bind to
    /// this to disable the Re-run button (preventing the user from spawning
    /// a second cellpose subprocess that the Cancel button would later have
    /// to clean up — which is exactly what produced the three back-to-back
    /// "detection cancelled" log lines reported by the user).
    func isRerunning(_ image: ImageRecord) -> Bool {
        inFlightRerunImageIds.contains(image.id)
    }

    /// True when a real detector is resolved for `activeModelId` — Home gates buttons on this.
    var canRunDetection: Bool { detector != nil }

    /// Pass-12 K1: cached install-state of the *currently active* model.
    /// Mirrors `installStateCache.get(activeModelId)` but is exposed directly
    /// on AppState so views (Toolbar pill, Models row) can react without each
    /// one recomputing the lookup, and so a single notification handler can
    /// keep it in sync with on-disk reality.
    ///
    /// Authoritative writers:
    /// - `refreshActiveModelInstallState()` — called after `refreshDetector`,
    ///   after `activate`, on `ccVenvChanged`, and on install-completed.
    var activeModelInstallState: ModelInstallState = .unknown

    // Working batch — what Results / Processing is currently looking at.
    var currentBatchId: UUID? {
        didSet {
            currentBatchCache = nil
            currentBatchCacheId = nil
            orderedImagesCache = nil
            UserDefaults.standard.set(currentBatchId?.uuidString, forKey: "cc-current-batch")
        }
    }
    /// Index into the current batch's images that Results is showing.
    var currentImageIdx: Int = 0

    /// SwiftUI asks for `currentBatch`/`currentImage` many times per render.
    /// Avoid a SwiftData fetch and 700-element sort at every call while still
    /// invalidating when imports/deletes change the relationship count.
    @ObservationIgnored private var currentBatchCacheId: UUID?
    @ObservationIgnored private var currentBatchCache: BatchRecord?
    @ObservationIgnored private var orderedImagesCache: (batchId: UUID, count: Int, images: [ImageRecord])?
    /// Coalesce rapid overlay edits while their payload is encoded off the UI thread.
    @ObservationIgnored private var pendingCellEdits: [UUID: PendingCellEdit] = [:]
    @ObservationIgnored private var pendingCellEditTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var calibrationTask: Task<Bool, Error>?
    /// Images a recalibration rewrites between saves, so its pending changes
    /// (and the write-ahead log) stay bounded on large batches.
    @ObservationIgnored var recalibrationSaveInterval = 16
    private var calibrationUpdatesInFlight = 0
    var isRecalibrating: Bool { calibrationUpdatesInFlight > 0 }

    var activeModelName: String {
        models.first(where: { $0.id == activeModelId })?.name ?? "Cellpose cyto3"
    }

    init(repos: Repositories) {
        self.repos = repos
        self.detectorRegistry = DetectorRegistry()
        self.installStateCache = InstallStateCache()
        // Pass-8: no mock fallback. Detector starts nil; `refreshDetector()`
        // resolves it from the active model id once downloaders are registered.
        self.detector = nil

        // Register family-specific downloaders. Each M-agent contributes one.
        detectorRegistry.register(CellposeDownloader())
        // Pass-16: Cellpose-SAM (4.x) downloader — installs into venv4/ and
        // produces the CellposeSAMDetectionService at lookup time. Sits beside
        // the 3.x downloader; the family-keyed dict inside DetectorRegistry
        // routes by `ModelFamily.cellpose4`.
        detectorRegistry.register(CellposeSAMDownloader())
        detectorRegistry.register(StarDistDownloader())
        detectorRegistry.register(SAMDownloader())
        // Omnipose — bacteria / filamentous cells. Installs into its own
        // `venv_omni/` for the same pin-conflict reason cp4 owns `venv4/`.
        detectorRegistry.register(OmniposeDownloader())
        // Classical threshold + watershed. No weights and no install step, so
        // this is the one family available on any machine where the base
        // Python environment exists.
        detectorRegistry.register(ClassicalDownloader())
        // Bring-your-own models the user registered from the Models tab.
        detectorRegistry.register(CustomModelDownloader())
        // "Second opinion" — composes two of the above. Registered last so the
        // members it resolves are already in the registry.
        detectorRegistry.register(EnsembleDownloader())
        // Wire the install-state cache so the registry can refresh it on
        // install start/completion. Held weakly on the registry side.
        detectorRegistry.installStateCache = installStateCache

        // restore persisted analysis params
        if let data = UserDefaults.standard.data(forKey: "cc-thresholds"),
           let arr = try? JSONDecoder().decode([Double].self, from: data), !arr.isEmpty {
            self.thresholds = arr
        } else {
            self.thresholds = [20, 30]
        }
        let storedPx = UserDefaults.standard.double(forKey: "cc-pxperum")
        // No built-in scale: a stored value is the user's own default for
        // images without a scale; nothing stored means "not set" (0).
        self.pxPerUm = storedPx.isFinite && storedPx > 0 ? storedPx : 0
        let storedConf = UserDefaults.standard.double(forKey: "cc-confidence")
        self.confidence = storedConf > 0 ? storedConf : 0.50
        // Explicit expected diameter defaults to 0 == "Auto" (bin-derived size
        // prior — current behavior). `UserDefaults.double` returns 0 for a
        // missing key, which is exactly the Auto default; only a value the user
        // explicitly set (> 0) overrides the sidecar's bin-derived prior.
        self.expectedDiameterUm = UserDefaults.standard.double(forKey: "cc-expected-diameter")
        self.omniposeSettings = UserDefaults.standard.data(forKey: "cc-omnipose-settings")
            .flatMap { try? JSONDecoder().decode(OmniposeSegmentationSettings.self, from: $0) } ?? .init()
        self.activeModelId = UserDefaults.standard.string(forKey: "cc-active-model") ?? "cp-cyto3"

        if let data = UserDefaults.standard.data(forKey: "cc-channels-cyto"),
           let ch = try? JSONDecoder().decode(DetectionChannels.self, from: data) {
            self.channels = ch
        } else {
            self.channels = .grayscale
        }
        let storedManualDiam = UserDefaults.standard.double(forKey: "cc-manual-diameter")
        self.manualMarkerDiameter = storedManualDiam > 0 ? storedManualDiam : 20.0

        self.backgroundSubtract = UserDefaults.standard.bool(forKey: "cc-bg-subtract")
        let storedRadius = UserDefaults.standard.integer(forKey: "cc-rolling-ball")
        self.rollingBallRadius = storedRadius > 0 ? storedRadius : 50
        self.preprocessingPreset = PreprocessingPreset(
            rawValue: UserDefaults.standard.string(forKey: "cc-preprocessing-preset-v1") ?? "")
            ?? .none
        self.watershedSplit = UserDefaults.standard.bool(forKey: "cc-watershed")
        let storedWatershedDist = UserDefaults.standard.integer(forKey: "cc-watershed-min-distance-um")
        self.watershedMinDistanceUm = storedWatershedDist > 0 ? storedWatershedDist : 8

        // cc-use-gpu defaults to true (Apple Neural Engine + Metal where supported).
        // UserDefaults.bool returns false for missing keys, so we check existence.
        if UserDefaults.standard.object(forKey: "cc-use-gpu") != nil {
            self.useGPU = UserDefaults.standard.bool(forKey: "cc-use-gpu")
        } else {
            self.useGPU = true
        }
        if UserDefaults.standard.object(forKey: "cc-verify-checksums") != nil {
            self.verifyChecksums = UserDefaults.standard.bool(forKey: "cc-verify-checksums")
        } else {
            self.verifyChecksums = true
        }
        // Pass-13: drop default parallelism from 4 → 1. Cellpose CPU
        // inference is CPU-bound on the matrix kernels, and 4 in parallel on
        // typical 8-core Macs makes EACH image ~3-4× slower instead of
        // speeding up the batch (they fight for the same vector units and
        // memory bandwidth). User can still raise it in Settings if they
        // have a workstation that benefits.
        let storedParallel = UserDefaults.standard.integer(forKey: "cc-max-parallel")
        self.maxParallel = storedParallel > 0 ? storedParallel : 1
        let resourceChoice = ModelResourceChoice.load(from: .standard)
        self.modelResourcePreset = resourceChoice.preset
        self.modelResourceCustomCores = resourceChoice.customCPUCores
        self.modelResourceCustomMemoryGB = resourceChoice.customMemoryGB
        // `PersistentSidecarPool.shared` reads the same stored choice when
        // it is created, so nothing needs configuring until it changes. The
        // live control file starts with it too.
        let initialResourceLimits = ModelResourceLimits.resolve(resourceChoice, machine: .current)
        self.appliedModelResourceLimits = initialResourceLimits
        ModelResourceControl.publish(initialResourceLimits.liveState)
        self.overlayPalette = OverlayPalette.load()

        if let raw = UserDefaults.standard.string(forKey: "cc-model-filter"),
           let f = ModelFamily(rawValue: raw) {
            self.modelFilter = f
        }
        // The Workbench empty state owns first-run project setup. The existing
        // library tour remains available explicitly without changing its preference.
        self.showOnboarding = false

        // restore current batch
        if let str = UserDefaults.standard.string(forKey: "cc-current-batch"),
           let id = UUID(uuidString: str) {
            self.currentBatchId = id
        }

        // Honor cc-default-model only when no explicit cc-active-model has been picked.
        if UserDefaults.standard.string(forKey: "cc-active-model") == nil,
           let defaultId = UserDefaults.standard.string(forKey: "cc-default-model"),
           !defaultId.isEmpty {
            self.activeModelId = defaultId
        }
        // A model older versions offered but CellCounter can't run (Cellpose-
        // DINO) would fail every run; fall back to Cellpose-SAM, its family's
        // default.
        if let info = models.first(where: { $0.id == activeModelId }), info.unavailableReason != nil {
            NSLog("CellCounter: active model %@ is unavailable (%@); using Cellpose-SAM",
                  activeModelId, info.unavailableReason ?? "")
            self.activeModelId = "cpsam"
        }

        // Now that downloaders are registered and the active model id is loaded,
        // resolve the detector for the current selection (nil if not installed).
        refreshDetector()

        // Observe UserDefaults changes so Settings-side @AppStorage edits propagate
        // back into our in-memory mirror. Without this, toggles like
        // "Subtract background" change UserDefaults but the in-memory
        // backgroundSubtract stays whatever it was at init.
        self.defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshFromDefaults() }
        }

        // Pass-12: cleanup orphan empty batches on launch. These accumulate when
        // imports fail mid-flow in earlier app versions, or when the user closes
        // before any image lands. Run BEFORE seeding library stats so the
        // sidebar count and Recents list don't briefly show ghost rows.
        repos.cleanupEmptyBatches()

        // If the persisted `currentBatchId` pointed at one of the deleted empty
        // batches, clear it so Results doesn't try to open a now-dead record.
        if let id = self.currentBatchId, repos.batch(id: id) == nil {
            self.currentBatchId = nil
        }

        // Seed the @Observable library/review stats from the store, then listen
        // for mutation notifications. `ccCorrectionsChanged` is posted by the
        // existing correction/split sites; `ccLibraryChanged` is posted by
        // `importAndAnalyze` and from views that delete batches/images.
        refreshLibraryStats()
        // One-time notice: the store was copied before this launch upgraded it.
        libraries.upgradeBackupURL = repos.upgradeBackupURL
        self.correctionsChangedObserver = NotificationCenter.default.addObserver(
            forName: .ccCorrectionsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Notifications are delivered through deferred main-actor
                // tasks. A reset or index refresh may already include this
                // change; applying an old delta would count it twice or
                // resurrect a badge after every image was deleted.
                self.reviewQueueCount = self.repos.pendingReviewCandidateCount()
                // Cell edits can change the denormalized total in a recent row;
                // refresh it once a burst of edits settles.
                self.scheduleRecentSummariesRefresh()
            }
        }
        self.libraryChangedObserver = NotificationCenter.default.addObserver(
            forName: .ccLibraryChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshLibraryStats() }
        }

        // Upgrade pre-index rows in yielding chunks. App launch and Home render
        // stay immediate; the Review badge fills in as legacy detections are
        // normalized once, then remains O(1)/fetchCount on future launches.
        // Review opens as soon as the queue's own index work is done; the
        // stale-row check and legacy batch totals follow in the background.
        repos.onStaleReviewRows = { [weak self] in
            Task { @MainActor [weak self] in await self?.runIndexMaintenance() }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareReviewIndex()
            // Saved mask versions are compacted, and detection cells still
            // stored inline are moved to their own rows, at low priority and
            // only once the review index is ready, so launch never waits on it.
            // Each job starts only while the library's upkeep note says it
            // may have work (`BackgroundUpkeepNote`); a library already
            // upgraded is not read at all.
            self.repos.scheduleDetectionStorageMigration()
            self.repos.scheduleVariantCompaction()
            // Compact cell metrics for detections saved before they existed.
            CellMetricsBackfill.shared.start(repos: self.repos)
        }

        // Pass-12 K1: keep `activeModelInstallState` (and `detector`) coherent
        // with the actual on-disk venv. Settings → Reset, CellposeInstaller,
        // and InstallCellposeSheet all post `ccVenvChanged` after touching
        // the venv directory. The install-completed notification covers the
        // happy path where InstallStateCache flips `notInstalled → installed`.
        self.venvChangedObserver = NotificationCenter.default.addObserver(
            forName: .ccVenvChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await PersistentSidecarPool.shared.retire(modelSignaturePrefix: "cellpose3|")
                guard let self else { return }
                self.refreshDetector()
                self.refreshActiveModelInstallState()
            }
        }
        self.installCompletedObserver = NotificationCenter.default.addObserver(
            forName: .ccCellposeInstallCompleted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshDetector()
                self.refreshActiveModelInstallState()
            }
        }
        // Pass-16: mirror the 3.x observers but on the venv4 channel. Filtering
        // by notification name keeps a 3.x install (`ccVenvChanged`) from
        // re-probing the 4.x detector and vice versa — both observers do the
        // same refresh work but the AppState mirror they target differs only
        // when the active model is in the other family.
        self.venv4ChangedObserver = NotificationCenter.default.addObserver(
            forName: .ccVenv4Changed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await PersistentSidecarPool.shared.retire(modelSignaturePrefix: "cellpose4|")
                guard let self else { return }
                self.refreshDetector()
                self.refreshActiveModelInstallState()
            }
        }
        self.cellposeSAMInstallCompletedObserver = NotificationCenter.default.addObserver(
            forName: .ccCellposeSAMInstallCompleted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshDetector()
                self.refreshActiveModelInstallState()
            }
        }

        // Bring-your-own models live in UserDefaults, not the catalog literal,
        // so a registration has to re-project `ModelCatalog.all` into `models`
        // for the new row to appear anywhere in the app.
        self.customModelsObserver = NotificationCenter.default.addObserver(
            forName: CustomModelStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.models = ModelCatalog.all
                self.refreshDetector()
                self.refreshActiveModelInstallState()
            }
        }

        // Seed the mirror once the cache and detector are wired.
        refreshActiveModelInstallState()

        // Pass-13: stream cellpose subprocess stderr lines into the UI.
        // CellposeDetectionService posts these as they arrive; we cache the
        // latest one and a wall-clock timestamp so ProcessingView can show
        // real activity instead of a 0% bar.
        self.detectionStageObserver = NotificationCenter.default.addObserver(
            forName: .ccDetectionStage,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let line = note.userInfo?["line"] as? String else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Pass-14: sniff the device line BEFORE prettify-filtering, so
                // we capture the real device the subprocess picked. The line
                // looks like:
                //   [cellpose_detect] using device: mps (torch 2.8.0)
                if let dev = Self.parseProcessingDevice(line) {
                    self.processingDevice = dev
                }
                // Trim cellpose's noisy tqdm progress bars; keep semantic lines.
                let pretty = Self.prettifyStageLine(line)
                guard !pretty.isEmpty else { return }
                self.processingStageLine = pretty
                self.lastStageUpdateAt = Date()
            }
        }
        installStateCache.onStateChange = { [weak self] ids in
            guard let self, ids.contains(self.activeModelId) else { return }
            let next = self.installStateCache.get(self.activeModelId)
            self.activeModelInstallState = next
            switch next {
            case .notInstalled, .broken: self.detector = nil
            default: break
            }
            if next == .installed && self.detector == nil { self.refreshDetector() }
        }
        trainingActivityObserver = NotificationCenter.default.addObserver(
            forName: TrainingService.activityChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.jobScheduler.modelExecutionBecameAvailable() }
        }
        jobScheduler.configure(prepare: { [weak self] item, settings, batchId in
            guard let self else { throw CancellationError() }
            return try await self.prepareJobImage(item, settings: settings, batchId: batchId)
        }, analyze: { [weak self] imageId, settings in
            guard let self else { throw CancellationError() }
            try await self.analyzeJobImage(imageId, settings: settings)
        })
        Task { [weak self] in await self?.jobScheduler.restore() }
    }

    /// Cellpose emits tqdm progress bars on the same stderr stream as its
    /// semantic log lines. Drop the noisy `xx%|...| N/M ...` rows and keep
    /// the descriptive ones — both `[cellpose_detect]` from our sidecar and
    /// cellpose's own status messages.
    /// Pass-14: pull the device token out of the sidecar's "using device:"
    /// log line. Returns e.g. "mps" or "cpu" (uppercased for display), or nil
    /// when the line isn't the device announcement.
    static func parseProcessingDevice(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard let range = s.range(of: "using device: ") else { return nil }
        let tail = s[range.upperBound...]
        // Take everything up to the first whitespace or '(' — covers
        // "mps", "cpu", "cuda:0", "mps (torch 2.8.0)".
        var token = ""
        for ch in tail {
            if ch == " " || ch == "(" || ch == "\t" { break }
            token.append(ch)
        }
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.uppercased()
    }

    private static func prettifyStageLine(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "" }
        // tqdm bars look like "  3%|▎         | 31.6M/1.15G [00:06<03:37, ..."
        if s.contains("|") && s.contains("%") && s.contains("/") { return "" }
        // Drop the prefix in our own log lines for a cleaner display.
        if let range = s.range(of: "[cellpose_detect] ") {
            return String(s[range.upperBound...])
        }
        return s
    }

    // Note: no explicit deinit. AppState lives for the lifetime of the app, and
    // a `@MainActor` class can't safely touch isolated stored properties from a
    // nonisolated deinit. The NotificationCenter observer is cleaned up when
    // the process terminates.

    /// Re-reads every cc-* analysis key from UserDefaults into the in-memory
    /// mirror. Skips writeback to avoid posting another didChangeNotification.
    /// Internal so Settings can force a refresh after batch import edits.
    func refreshFromDefaults() {
        let ud = UserDefaults.standard
        suppressDefaultsWriteback = true
        defer { suppressDefaultsWriteback = false }

        if let data = ud.data(forKey: "cc-thresholds"),
           let arr = try? JSONDecoder().decode([Double].self, from: data),
           !arr.isEmpty,
           arr != thresholds {
            thresholds = arr
        }
        let storedPx = ud.double(forKey: "cc-pxperum")
        // A removed key clears the default (0 = not set).
        let defaultPx = storedPx.isFinite && storedPx > 0 ? storedPx : 0
        if defaultPx != pxPerUm { pxPerUm = defaultPx }
        let storedConf = ud.double(forKey: "cc-confidence")
        if storedConf > 0 && storedConf != confidence { confidence = storedConf }
        // 0 is a valid value here ("Auto"), so compare with != rather than > 0 —
        // the user may reset an explicit diameter back to Auto from Settings.
        let storedDiam = ud.double(forKey: "cc-expected-diameter")
        if storedDiam != expectedDiameterUm { expectedDiameterUm = storedDiam }
        let storedOmnipose = ud.data(forKey: "cc-omnipose-settings")
            .flatMap { try? JSONDecoder().decode(OmniposeSegmentationSettings.self, from: $0) } ?? .init()
        if storedOmnipose != omniposeSettings { omniposeSettings = storedOmnipose }
        if let id = ud.string(forKey: "cc-active-model"), id != activeModelId {
            activeModelId = id
            refreshDetector()
        }
        if let data = ud.data(forKey: "cc-channels-cyto"),
           let ch = try? JSONDecoder().decode(DetectionChannels.self, from: data),
           ch != channels {
            channels = ch
        }
        let storedManualDiam = ud.double(forKey: "cc-manual-diameter")
        if storedManualDiam > 0 && storedManualDiam != manualMarkerDiameter {
            manualMarkerDiameter = storedManualDiam
        }
        let bg = ud.bool(forKey: "cc-bg-subtract")
        if bg != backgroundSubtract { backgroundSubtract = bg }
        let storedRadius = ud.integer(forKey: "cc-rolling-ball")
        if storedRadius > 0 && storedRadius != rollingBallRadius {
            rollingBallRadius = storedRadius
        }
        let preprocessing = PreprocessingPreset(
            rawValue: ud.string(forKey: "cc-preprocessing-preset-v1") ?? "") ?? .none
        if preprocessing != preprocessingPreset { preprocessingPreset = preprocessing }
        let ws = ud.bool(forKey: "cc-watershed")
        if ws != watershedSplit { watershedSplit = ws }
        let storedWatershedDist = ud.integer(forKey: "cc-watershed-min-distance-um")
        if storedWatershedDist > 0 && storedWatershedDist != watershedMinDistanceUm {
            watershedMinDistanceUm = storedWatershedDist
        }
        if ud.object(forKey: "cc-use-gpu") != nil {
            let g = ud.bool(forKey: "cc-use-gpu")
            if g != useGPU { useGPU = g }
        }
        if ud.object(forKey: "cc-verify-checksums") != nil {
            let v = ud.bool(forKey: "cc-verify-checksums")
            if v != verifyChecksums { verifyChecksums = v }
        }
        let mp = ud.integer(forKey: "cc-max-parallel")
        if mp > 0 && mp != maxParallel { maxParallel = mp }
        let resources = ModelResourceChoice.load(from: ud)
        if resources.preset != modelResourcePreset { modelResourcePreset = resources.preset }
        if resources.customCPUCores != modelResourceCustomCores { modelResourceCustomCores = resources.customCPUCores }
        if resources.customMemoryGB != modelResourceCustomMemoryGB {
            modelResourceCustomMemoryGB = resources.customMemoryGB
        }
        let storedPalette = OverlayPalette.load(defaults: ud)
        if storedPalette != overlayPalette { overlayPalette = storedPalette }
    }

    // MARK: — Model resource use

    var modelResourceChoice: ModelResourceChoice {
        ModelResourceChoice(preset: modelResourcePreset,
                            customCPUCores: modelResourceCustomCores,
                            customMemoryGB: modelResourceCustomMemoryGB)
    }

    /// What the current choice means on this Mac.
    var modelResourceLimits: ModelResourceLimits {
        ModelResourceLimits.resolve(modelResourceChoice, machine: .current)
    }

    /// Switching to Custom for the first time starts from the values that
    /// were in effect, so the steppers begin somewhere familiar.
    func selectModelResourcePreset(_ preset: ModelResourcePreset) {
        if preset == .custom {
            let effective = modelResourceLimits
            if modelResourceCustomCores <= 0 {
                modelResourceCustomCores = effective.cpuThreads ?? effective.totalCPUCores
            }
            if modelResourceCustomMemoryGB <= 0 {
                let range = MachineResources.current.customMemoryRangeGB
                let start = effective.memoryLimitGB ?? range.upperBound
                modelResourceCustomMemoryGB = min(range.upperBound, max(range.lowerBound, start))
            }
        }
        modelResourcePreset = preset
    }

    /// Opens Settings → General, where Model resource use lives.
    func openModelResourceSettings() {
        settingsSectionRequest = .general
        view = .settings
    }

    /// A model is analysing images now (a processing job, training or a
    /// single-image run).
    var isModelWorkActive: Bool {
        jobScheduler.activeCount > 0 || TrainingService.isTrainingActive || processingProgress > 0
    }

    /// Applies a new choice to everything already running, without reloading
    /// any model (see `ModelResourceChange`):
    /// - the live control file is rewritten, then every running model process
    ///   gets the background state (Light) set or cleared and is asked to
    ///   re-read the file: PyTorch's thread count and a higher or removed GPU
    ///   memory cap apply at once, a lower cap after the current image;
    /// - the warm pool takes the new number of models and unload time;
    /// - what only a new process picks up (launch priority class, soft memory
    ///   limit, thread counts of non-PyTorch libraries) applies when a model
    ///   next starts. Nothing is restarted for it.
    private func modelResourcesDidChange() {
        let limits = modelResourceLimits
        guard limits != appliedModelResourceLimits else { return }
        let change = appliedModelResourceLimits.map { ModelResourceChange(from: $0, to: limits) }
        appliedModelResourceLimits = limits
        ModelResourceControl.publish(limits.liveState)
        ChildProcessTracker.shared.applyModelResourceLimits(background: limits.runsInBackground)
        Task {
            await PersistentSidecarPool.shared.configure(maxWarmWorkers: limits.maxWarmWorkers,
                                                         idleTimeout: limits.idleTimeout)
        }
        if let change, !change.isEmpty, isModelWorkActive {
            showModelResourceNotice(change.confirmation(for: limits))
        }
    }

    private func showModelResourceNotice(_ message: String) {
        modelResourceNotice = message
        modelResourceNoticeToken &+= 1
        let token = modelResourceNoticeToken
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.modelResourceNoticeToken == token else { return }
            withAnimation(Tokens.Motion.ease) { self.modelResourceNotice = nil }
        }
    }

    // MARK: — Convenience

    var currentBatch: BatchRecord? {
        guard let id = currentBatchId else { return nil }
        if currentBatchCacheId == id, let currentBatchCache { return currentBatchCache }
        let fetched = repos.batch(id: id)
        currentBatchCacheId = id
        currentBatchCache = fetched
        return fetched
    }

    func orderedImages(in batch: BatchRecord) -> [ImageRecord] {
        let count = batch.images.count
        if let cached = orderedImagesCache,
           cached.batchId == batch.id,
           cached.count == count {
            return cached.images
        }
        let ordered = batch.images.sorted {
            let lhs = $0.sourceOrder ?? Int.max, rhs = $1.sourceOrder ?? Int.max
            if lhs != rhs { return lhs < rhs }
            return $0.importedAt < $1.importedAt
        }
        orderedImagesCache = (batch.id, count, ordered)
        return ordered
    }

    /// Returns an already-decoded cell snapshot without touching the JSON
    /// payload. Useful on interaction paths that must remain synchronous.
    func cachedCells(for detection: DetectionRecord) -> [DetectedCell]? {
        detection.cachedCells
    }

    /// Decode a detection once off the MainActor and share the result between
    /// every Results/Review consumer. The serial worker rechecks the shared
    /// cache, and stale results are discarded if an edit lands meanwhile.
    func loadCells(for detection: DetectionRecord) async -> [DetectedCell] {
        (try? await loadReviewCells(for: detection)) ?? []
    }

    /// Review writes must fail visibly on unreadable saved measurements.
    func loadReviewCells(for detection: DetectionRecord) async throws -> [DetectedCell] {
        let timing = LocalPerformanceRecorder.shared.begin(.reviewLoad)
        do { let cells = try await loadReviewCellsImpl(for: detection); timing?.finish(success: true); return cells }
        catch { timing?.finish(success: false); throw error }
    }
    private func loadReviewCellsImpl(for detection: DetectionRecord) async throws -> [DetectedCell] {
        try await finishPendingCellEdits(for: detection)
        if let cached = cachedCells(for: detection), !cached.isEmpty { return cached }

        let id = detection.id
        let revision = detection.cellsRevision
        let data = detection.cellsData
        let cells = try await CellDecodeWorker.shared.decode(id: id, revision: revision, data: data)
        try Task.checkCancellation()
        guard !detection.isDeleted, detection.modelContext != nil else { throw CancellationError() }
        guard detection.cellsRevision == revision else {
            return try await loadReviewCells(for: detection)
        }
        detection.cacheDecodedCells(cells, revision: revision)
        return cells
    }

    /// A Results edit can still be encoding when the user opens Review. Drain
    /// it before reading or triaging the detection, so it cannot later replace
    /// the review decision with an older cell array.
    func finishPendingCellEdits(for detection: DetectionRecord) async throws {
        try Task.checkCancellation()
        guard !detection.isDeleted, detection.modelContext != nil else { throw CancellationError() }
        let id = detection.id
        while let task = pendingCellEditTasks[id] {
            await task.value
            try Task.checkCancellation()
            guard !detection.isDeleted, detection.modelContext != nil else { throw CancellationError() }
        }
    }

    /// Drain pending edits before asking the same installed app binary for a
    /// read-only snapshot. No canonical operation writes into the native store.
    func prepareLibraryMigration(imageIDs: Set<UUID> = []) {
        guard !preparingLibraryMigration, !isPreparingImport, jobScheduler.activeCount == 0,
              !TrainingService.isTrainingActive, workbenchSession.canRefreshWithoutDiscardingEdits,
              !workbenchSession.hasActiveWorkers else {
            libraryMigrationError = "Finish pending Workbench edits and pause library analysis or training before copying the library."
            return
        }
        preparingLibraryMigration = true
        libraryMigrationError = nil
        Task {
            defer { preparingLibraryMigration = false }
            do {
                for pending in Array(pendingCellEdits.values) { try await finishPendingCellEdits(for: pending.detection) }
                try repos.context.save()
                workbenchSession.migration.sourceDirectory = FileStore.shared.libraryRoot.path
                workbenchSession.migration.selectedLegacyIDs = imageIDs.map(\.uuidString).sorted()
                workbenchSession.migration.clearPreview()
                showLibraryMigration = true
            } catch {
                libraryMigrationError = "Library edits could not be saved before capture: \(error.localizedDescription)"
            }
        }
    }

    /// Drains in-flight Results edits and saves, so this library can be
    /// closed when the app relaunches into another one.
    func saveForLibrarySwitch() async throws {
        for pending in Array(pendingCellEdits.values) { try await finishPendingCellEdits(for: pending.detection) }
        try repos.context.save()
    }

    func retryReviewIndex() {
        guard !isReviewIndexing else { return }
        isReviewIndexing = true
        Task { await prepareReviewIndex() }
    }

    /// Only the index work the queue's contents and order depend on keeps
    /// Review waiting (legacy detections without review rows, legacy sort
    /// keys); with nothing to upgrade that is two indexed queries. The rest
    /// runs after Review is available, since the queue already hides stale rows.
    private func prepareReviewIndex() async {
        reviewIndexError = nil
        do {
            let upgraded = try await repos.prepareReviewQueueIndex()
            if upgraded { refreshReviewIndexStats() }
        } catch {
            reviewIndexError = "Could not prepare the review queue: \(error.localizedDescription)"
            isReviewIndexing = false
            return
        }
        isReviewIndexing = false
        await runIndexMaintenance()
    }

    @ObservationIgnored private var indexMaintenanceRunning = false
    @ObservationIgnored private var indexMaintenanceRequested = false

    /// Stale-row check (only when the library's note asks for it) and legacy
    /// batch totals, without blocking Review. Home is refreshed once, at the
    /// end, and only if something changed. A request made while a pass runs
    /// starts one more pass afterwards. A failure leaves the check pending for
    /// the next launch; until then the queue keeps hiding stale rows.
    private func runIndexMaintenance() async {
        guard !indexMaintenanceRunning else {
            indexMaintenanceRequested = true
            return
        }
        indexMaintenanceRunning = true
        defer { indexMaintenanceRunning = false }
        repeat {
            indexMaintenanceRequested = false
            do {
                if try await repos.performDeferredIndexMaintenance() { refreshReviewIndexStats() }
            } catch {
                NSLog("CellCounter: review index upkeep failed and will be retried: %@",
                      error.localizedDescription)
                return
            }
        } while indexMaintenanceRequested && !Task.isCancelled
    }

    private func refreshReviewIndexStats() {
        reviewQueueCount = repos.pendingReviewCandidateCount()
        recentBatchSummaries = repos.recentBatchSummaries(limit: 5)
    }

    var currentImage: ImageRecord? {
        guard let batch = currentBatch else { return nil }
        // Pass-14: removed the per-batch `_sortedImageCache` that was here.
        // It was keyed on `batch.id` alone and never invalidated when
        // `batch.images` grew mid-import. The user would land on Results
        // with `currentImageIdx = 0` but the cache still holding an empty
        // image list from when the batch was first created — `images[0]`
        // returned nil, sidebar said "0 cells detected", and the canvas
        // stayed blank even though detection had saved 130 cells. The
        // BatchStrip thumbnail read batch.images directly and showed the
        // count, masking the inconsistency.
        //
        // SwiftData fetches scale linearly with image count; sorting a few
        // dozen records on each access is sub-millisecond and orders of
        // magnitude cheaper than a stale-cache bug like the one above.
        let images = orderedImages(in: batch)
        guard images.indices.contains(currentImageIdx) else { return nil }
        return images[currentImageIdx]
    }
    var recentBatches: [BatchRecord] { repos.allBatches() }

    // MARK: — Effective confidence (pass 15)
    //
    // The confidence slider is now a UI/analysis filter: cells with
    // `confidence < effectiveConfidence` are hidden from the overlay, counts,
    // bins, histogram, measurements, and exports — but never deleted from the
    // SwiftData store. Pulling the slider slides the cutoff across the same
    // saved detection in real time.
    //
    // `confidenceOverride` lives on `ImageRecord` so each image can carry its
    // own cutoff (clinical workflow: "this slide needs a stricter filter").
    // Override wins over the global; nil = inherit global.

    /// Returns the cutoff to use for filtering `image`'s cells. Pass this into
    /// any code that decides whether a cell is "visible".
    func effectiveConfidence(for image: ImageRecord) -> Double {
        if let v = image.confidenceOverride { return v }
        return image.detection?.runSettings?.confidence ?? confidence
    }

    /// Writes an override for `image`. Pass nil to clear (i.e. fall back to
    /// the global `confidence`). Always saves the context; safe to call from
    /// SwiftUI bindings.
    func setConfidenceOverride(_ value: Double?, on image: ImageRecord) {
        image.confidenceOverride = value
        try? repos.context.save()
    }

    func setFilter(_ f: ModelFamily) {
        modelFilter = f
        UserDefaults.standard.set(f.rawValue, forKey: "cc-model-filter")
    }
    func dismissModelsBanner() {
        modelsBannerDismissed = true
        UserDefaults.standard.set(true, forKey: "cc-models-banner-dismissed")
    }
    func completeOnboarding() {
        showOnboarding = false
        UserDefaults.standard.set(true, forKey: "cc-onboarded")
    }

    /// Opens the install sheet. Called by the Models banner CTA and the post-install
    /// fallback messaging when a user tries to detect with no sidecar present.
    func installCellposeIfNeeded() {
        showInstallCellpose = true
    }

    /// Pass-16: opens the Cellpose-SAM (4.x) install sheet. Distinct entry-point
    /// so the toolbar pill / Models row can route to the correct sheet based on
    /// the active model's family.
    func installCellposeSAMIfNeeded() {
        showInstallCellpose4 = true
    }

    /// Resolve the detector for the active model id. Sets `detector = nil` when
    /// the active model isn't installed (or — for cellpose-family ids — when
    /// the Python venv isn't available yet). Pass-8: no mock fallback.
    ///
    /// Pass-11: the inner `CellposeAvailability.detect()` call is filesystem-
    /// heavy and (after K2 lands) will subprocess into Python to verify the
    /// venv. Either way it's not something we can run synchronously on the
    /// main thread at app launch — that's the 10s spinner on first launch.
    ///
    /// Signature stays sync (callers don't care about completion); the body
    /// kicks a detached probe and assigns `self.detector` back on @MainActor
    /// when it resolves.
    func refreshDetector() {
        // Snapshot what the probe needs so the detached task captures values,
        // not the actor.
        let activeId = activeModelId
        let modelsSnapshot = models
        let registry = detectorRegistry
        guard let info = modelsSnapshot.first(where: { $0.id == activeId }) else {
            self.detector = nil
            // Pass-12 K1: keep the active-model install-state mirror coherent
            // even when the active id no longer maps to a known model.
            self.activeModelInstallState = .notInstalled
            return
        }

        // Non-cellpose families don't depend on the Python venv — resolution
        // is cheap, do it inline so simple cases don't flicker through a
        // "resolving" state.
        //
        // Pass-16: `.cellpose4` (CPSAM) is handled separately below — its venv
        // lives at a different path and we ask `Cellpose4Availability.detect()`
        // instead of `CellposeAvailability.detect()`. The two probes are
        // mutually exclusive based on the active model's family.
        if info.family != .cellpose && info.family != .cellpose4 {
            self.detector = registry.detector(for: activeId, models: modelsSnapshot)
            refreshActiveModelInstallState()
            return
        }

        // Cellpose-family probe — same shape for both 3.x and 4.x, just hits
        // a different availability checker.
        let isCellpose4 = info.family == .cellpose4
        Task.detached(priority: .userInitiated) { [weak self] in
            let isAvailable: Bool = {
                if isCellpose4 {
                    if case .available = Cellpose4Availability.detect() { return true }
                    return false
                } else {
                    if case .available = CellposeAvailability.detect() { return true }
                    return false
                }
            }()
            await MainActor.run {
                guard let self else { return }
                // The probe ran off-actor and may finish AFTER the user switched
                // models (or a newer refreshDetector already resolved). Bail if
                // the active model is no longer the one we probed, so a stale
                // late completion can't install the previous model's detector
                // (or nil it) over the current one — a detector/model mismatch.
                guard self.activeModelId == activeId else { return }
                if isAvailable {
                    self.detector = registry.detector(for: activeId, models: modelsSnapshot)
                } else {
                    // Pass-12 K1: when the venv has gone missing/broken under
                    // an active cellpose-family model, the detector MUST be
                    // nil and `canRunDetection` MUST report false. Preserve
                    // `activeModelId` — the user's intent survives a venv wipe.
                    self.detector = nil
                }
                self.refreshActiveModelInstallState()
            }
        }
    }

    /// Pass-12 K1: refresh the `activeModelInstallState` mirror from the cache
    /// and kick a re-probe for the active model so the value lands correctly
    /// even if the cache hasn't been populated yet (e.g. at app launch before
    /// the user opens Models).
    func refreshActiveModelInstallState() {
        let id = activeModelId
        let cached = installStateCache.get(id)
        activeModelInstallState = cached
        if case .unknown = cached {
            installStateCache.refresh(modelId: id, registry: detectorRegistry, models: models)
        }
    }

    func activate(_ id: String) {
        // Pass-19: hard refuse coming-soon models even if some other path
        // tried to activate them. The ModelsView already gates the UI; this
        // is defense-in-depth in case a future code path (URL handler,
        // restore-from-defaults, etc.) bypasses the UI.
        if let info = models.first(where: { $0.id == id }), info.comingSoon {
            NSLog("CellCounter: activate(%@) refused — coming-soon model", id)
            return
        }
        // Listed but cannot run with what CellCounter installs (Cellpose-DINO).
        if let info = models.first(where: { $0.id == id }), info.unavailableReason != nil {
            NSLog("CellCounter: activate(%@) refused — unavailable model", id)
            return
        }
        // Guard: only activate a model that's actually installed.
        // For Cellpose-family models, open the install sheet instead.
        guard detectorRegistry.isInstalled(id, models: models) else {
            if let info = models.first(where: { $0.id == id }) {
                switch info.family {
                case .cellpose:
                    installCellposeIfNeeded()
                case .cellpose4:
                    installCellposeSAMIfNeeded()
                default:
                    NSLog("CellCounter: activate(%@) skipped — model not installed", id)
                }
            } else {
                NSLog("CellCounter: activate(%@) skipped — model not installed", id)
            }
            return
        }
        activeModelId = id
        // Swap the live detector to the family-specific one for this model.
        // May be nil if e.g. the venv isn't present yet — UI will gate on that.
        self.detector = detectorRegistry.detector(for: id, models: models)
        // Pass-12 K1: keep the active-model install-state mirror coherent.
        refreshActiveModelInstallState()
    }
    func download(_ id: String) {
        if let i = models.firstIndex(where: { $0.id == id }), models[i].state == .off {
            models[i].state = .downloaded
        }
    }

    // MARK: — Drop flow

    /// Real drop flow: user dropped URLs onto Home. Creates a batch, imports the files,
    /// runs detection in the background, saves DetectionRecords, navigates to Results.
    /// Returns the new batch's id.
    ///
    /// Pass-17: Before creating the batch, hashes all dropped files off-main and checks
    /// for duplicates. If any are found, sets `pendingDuplicateSession` and presents
    /// the DuplicateImportSheet instead of proceeding immediately. The sheet calls
    /// `proceedWithImport(urls:condition:)` once the user decides.
    @discardableResult
    func importAndAnalyze(urls: [URL], condition: String? = nil) -> UUID? {
        let supported = urls.filter { ImageLoader.supported.contains($0.pathExtension.lowercased()) }
        guard !supported.isEmpty, !isPreparingImport else { return nil }
        isPreparingImport = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isPreparingImport = false }
            await self.jobScheduler.restore()
            // One chunked read per file. The digest also records the file's
            // size and modification time, so the import can reuse the hash.
            let pairs = await Task.detached(priority: .userInitiated) {
                supported.map { ($0, ImportFileDigest.digest(of: $0)) }
            }.value
            // Only images sharing a dropped file's hash, via the fileHash index.
            let existing = self.repos.firstImagesByFileHash(Set(pairs.compactMap { $0.1?.hash }))
            var digests: [URL: ImportSourceDigest] = [:]
            var seen: Set<String> = []
            var unique: [URL] = []
            var duplicates: [DuplicateCandidate] = []
            for (url, digest) in pairs {
                if let digest {
                    let hash = digest.hash
                    digests[url] = digest
                    if let image = existing[hash] { duplicates.append(.init(url: url, hash: hash, existingRecord: image)) }
                    if !seen.insert(hash).inserted { continue }
                }
                unique.append(url)
            }
            if duplicates.isEmpty {
                await self.importNewBatch(urls: unique, condition: condition, knownDigests: digests)
            } else {
                self.pendingDuplicateSession = DuplicateImportSession(allURLs: unique, condition: condition,
                    duplicates: duplicates, onProceed: { [weak self] urls in
                        self?.proceedWithImport(urls: urls, condition: condition, knownDigests: digests)
                    })
                self.showDuplicateImportSheet = true
            }
        }
        return nil
    }

    /// Create a durable draft and import the representative image. Inference is
    /// an explicit choice in AnalysisSetupSheet; native import needs no model.
    func proceedWithImport(urls: [URL], condition: String?, svc: DetectionService? = nil,
                           knownDigests: [URL: ImportSourceDigest] = [:]) {
        guard !urls.isEmpty else { return }
        Task { [weak self] in
            await self?.importNewBatch(urls: urls, condition: condition, knownDigests: knownDigests)
        }
    }

    /// `proceedWithImport`'s work. The job items (a security bookmark, the
    /// file size and the image header of every file) are built off the main
    /// actor before the batch is created.
    private func importNewBatch(urls: [URL], condition: String?,
                                knownDigests: [URL: ImportSourceDigest]) async {
        guard !urls.isEmpty else { return }
        let parentNames = Set(urls.map { $0.deletingLastPathComponent().lastPathComponent })
        let title = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent
            : (parentNames.count == 1 ? parentNames.first! : "Batch · \(urls.count) images · \(Self.shortDate())")
        let settings = AnalysisRunSettings.capture(state: self)
        let items = await AnalysisJobItem.make(urls.map { url in
            AnalysisJobItem.Source(url: url, knownHash: knownDigests[url]?.hash,
                                   knownHashStamp: knownDigests[url]?.stamp)
        })
        // Each image keeps the scale its own file records (read into the
        // items above). The batch's scale for images without one starts as
        // the user's default, when set; there is no built-in value.
        let batch = repos.createBatch(displayName: title, modelId: settings.modelId,
                                      pxPerUm: settings.pxPerUm, thresholds: settings.thresholds, condition: condition)
        if settings.pxPerUm > 0 { batch.pxPerUmSource = settings.calibrationSource; try? repos.context.save() }
        let job = AnalysisJob(batchId: batch.id, title: title, settings: settings, items: items)
        currentBatchId = batch.id; currentImageIdx = 0
        refreshLibraryStats()
        Task { [weak self] in
            guard let self else { return }
            do {
                await self.jobScheduler.restore()
                try await self.jobScheduler.add(job)
                self.analysisSetupJobId = job.id
                if let first = job.items.first {
                    _ = try await self.jobScheduler.prepareSample(job.id, itemId: first.id)
                    // Keep the presenting screen stable while setup is open.
                    // Import already selected this batch/image; navigation is an
                    // explicit setup action, not a second layout during presentation.
                }
            } catch {
                self.lastDetectionError = error.localizedDescription; self.showDetectionError = true
            }
        }
    }

    /// Batches whose Analysis setup job is still being built.
    @ObservationIgnored private var analysisSetupsInPreparation: Set<UUID> = []

    func openAnalysisSetup(for batch: BatchRecord) {
        if let draft = jobScheduler.jobs.last(where: { $0.batchId == batch.id && $0.status == .draft }) {
            analysisSetupJobId = draft.id; return
        }
        if let active = jobScheduler.jobs.first(where: { $0.batchId == batch.id && [.running, .queued, .pausing].contains($0.status) }) {
            flashExport("Pause \(active.title) before changing its analysis setup.", isError: false)
            view = .queue; return
        }
        // The draft for this batch is on its way; a second one must not be added.
        guard !analysisSetupsInPreparation.contains(batch.id) else { return }
        let images = orderedImages(in: batch)
        let sample = currentImage?.batch?.id == batch.id ? currentImage : images.first
        var settings = sample?.detection?.runSettings ?? AnalysisRunSettings.capture(state: self)
        // The job's scale is the batch's scale for images without one; each
        // image keeps its own (`ImageScale`).
        settings.pxPerUm = batch.pxPerUm
        settings.calibrationSource = batch.pxPerUmSource ?? (batch.pxPerUm > 0 ? "manual" : ImageScale.unsetSource)
        settings.thresholds = batch.thresholds
        let sources = images.map { image in
            AnalysisJobItem.Source(url: image.storedURL, imageId: image.id, knownHash: image.fileHash,
                                   displayName: image.fileName, fileScale: image.fileScale,
                                   ownScale: image.ownScale)
        }
        let savedRunSettings = images.map { $0.detection?.runSettingsData }
        let scales = images.map(\.effectiveScale)
        let batchId = batch.id, title = batch.displayName
        analysisSetupsInPreparation.insert(batchId)
        Task { [weak self] in
            let items = await Self.analysisSetupItems(sources, savedRunSettings: savedRunSettings,
                                                      scales: scales, settings: settings)
            guard let self else { return }
            defer { self.analysisSetupsInPreparation.remove(batchId) }
            let job = AnalysisJob(batchId: batchId, title: title, settings: settings, items: items)
            do { try await self.jobScheduler.add(job); self.analysisSetupJobId = job.id }
            catch { self.flashExport(error.localizedDescription, isError: true) }
        }
    }

    /// Analysis setup items, built off the main actor: the image header of
    /// every image and the comparison with each image's saved run settings
    /// (`DetectionRecord.runSettings` decodes `runSettingsData` the same way).
    /// Same items, order and statuses as building them on the main actor.
    /// An image counts as done when it was analysed with these settings at
    /// its own scale (`scales`, one per source).
    @concurrent
    private static func analysisSetupItems(_ sources: [AnalysisJobItem.Source], savedRunSettings: [Data?],
                                           scales: [ImageScale.Resolved?],
                                           settings: AnalysisRunSettings) async -> [AnalysisJobItem] {
        var items = await AnalysisJobItem.make(sources)
        for (index, data) in zip(items.indices, savedRunSettings) {
            let saved = data.flatMap { try? JSONDecoder().decode(AnalysisRunSettings.self, from: $0) }
            let scale = index < scales.count ? scales[index] : nil
            if scale != nil, saved?.hasSameInputs(as: settings.withScale(scale)) == true {
                items[index].status = .completed
            }
        }
        return items
    }

    func commitAnalysisSetup(_ jobId: UUID) async throws {
        guard let job = jobScheduler.job(jobId), let batch = repos.batch(id: job.batchId) else { return }
        if let error = job.settings.validationError {
            throw NSError(domain: "AnalysisJobs", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
        // Preview and Run both commit; pressing either again with the same
        // settings changes nothing, rewrites nothing and wakes no screen.
        // Scales are per image: committing records the batch's scale for
        // images without one and the scales set for single images. No stored
        // numbers are rescaled here; images whose scale changed are analysed
        // again by this job, and until then keep their numbers (and say so).
        var changed = try await pinLegacyMeasurementScales(batch)
        guard !batch.isDeleted, batch.modelContext != nil else { throw CancellationError() }
        let fallback = ImageScale.isUsable(job.settings.pxPerUm) ? job.settings.pxPerUm : 0
        let fallbackSource: String? = fallback > 0 ? job.settings.calibrationSource : nil
        if batch.pxPerUm != fallback || (fallback > 0 && batch.pxPerUmSource != fallbackSource) {
            batch.pxPerUm = fallback
            batch.pxPerUmSource = fallbackSource
            changed = true
        }
        let imagesById = Dictionary(orderedImages(in: batch).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in job.items {
            guard let imageId = item.imageId, let image = imagesById[imageId] else { continue }
            let own = item.ownScale
            if image.scalePxPerUm != own?.pxPerUm || image.scaleSource != own?.source {
                image.scalePxPerUm = own?.pxPerUm
                image.scaleSource = own?.source
                changed = true
            }
        }
        if batch.modelId != job.settings.modelId {
            batch.modelId = job.settings.modelId
            changed = true
        }
        if batch.thresholds != job.settings.thresholds {
            batch.thresholds = job.settings.thresholds
            changed = true
        }
        if changed { batch.contentRevision &+= 1 }
        try repos.context.save()
        if changed { NotificationCenter.default.post(name: .ccCorrectionsChanged, object: nil) }
    }

    /// One image's scale in Analysis setup.
    struct SetupScaleEntry: Identifiable, Equatable {
        /// The job item's id.
        let id: UUID
        let imageId: UUID?
        let fileName: String
        let file: ImageScale.Value?
        let own: ImageScale.Value?
        let scale: ImageScale.Resolved?
        /// A microscope file whose scale is read when it is imported.
        let readOnImport: Bool

        var summaryEntry: ImageScale.Entry {
            if let scale { return .scale(scale.value) }
            return readOnImport ? .readOnImport : .missing
        }
    }

    /// Every image's scale in a setup job: imported images from their record,
    /// the others from what their file recorded when the job was made.
    /// `ownScales` are scales chosen in the open sheet (a nil value removes
    /// one); `fallback` is the job's scale for images without one.
    func setupScaleEntries(jobId: UUID, fallback: ImageScale.Value?,
                           ownScales: [UUID: ImageScale.Value?] = [:]) -> [SetupScaleEntry] {
        guard let job = jobScheduler.job(jobId) else { return [] }
        let records: [UUID: ImageRecord] = repos.batch(id: job.batchId).map { batch in
            Dictionary(orderedImages(in: batch).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } ?? [:]
        return job.items.map { item in
            let image = item.imageId.flatMap { records[$0] }
            let file: ImageScale.Value? = image.map { $0.fileScale } ?? item.fileScale
            let own: ImageScale.Value?
            if let change = ownScales[item.id] { own = change } else { own = item.ownScale }
            return SetupScaleEntry(id: item.id, imageId: item.imageId, fileName: item.fileName,
                                   file: file, own: own,
                                   scale: ImageScale.resolve(explicit: own, file: file, fallback: fallback),
                                   readOnImport: image == nil && item.scaleReadOnImport)
        }
    }

    /// Saves Analysis setup's draft with the scales chosen for single images.
    /// Only images whose scale changes are analysed again.
    func saveAnalysisSetupDraft(_ jobId: UUID, settings: AnalysisRunSettings, preset: AnalysisTaskPreset,
                                ownScales: [UUID: ImageScale.Value?]) async throws {
        guard let job = jobScheduler.job(jobId) else { return }
        let before = setupScaleEntries(jobId: jobId, fallback: ImageScale.Value(job.settings.pxPerUm,
                                                                                source: job.settings.calibrationSource))
        let after = setupScaleEntries(jobId: jobId, fallback: ImageScale.Value(settings.pxPerUm, source: settings.calibrationSource),
                                      ownScales: ownScales)
        var resets = Set<UUID>()
        for (old, new) in zip(before, after) where old.scale?.pxPerUm != new.scale?.pxPerUm { resets.insert(new.id) }
        try await jobScheduler.updateDraft(jobId, settings: settings, preset: preset,
                                           itemScales: ownScales, scaleResets: resets)
    }

    /// O(1): the scheduler keeps a per-image status index up to date.
    func jobStatus(for imageId: UUID) -> String? { jobScheduler.statusLabel(for: imageId) }

    private func prepareJobImage(_ item: AnalysisJobItem, settings: AnalysisRunSettings,
                                 batchId: UUID) async throws -> UUID {
        guard let batch = repos.batch(id: batchId) else {
            throw NSError(domain: "AnalysisJobs", code: 1, userInfo: [NSLocalizedDescriptionKey: "The batch was deleted. Remove this job from Processing."])
        }
        if let recovered = repos.image(jobItemId: item.id) { return recovered.id }
        let url = try item.resolvedURL()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let imported: ImportResult
        if ImageLoader.isVendorExtension(url.pathExtension) {
            let interpreters = PythonRuntime.vendorReaderInterpreters(preferredFamily: ModelFamily(rawValue: settings.modelFamily))
            imported = try await ImageLoader.importVendorFile(url, knownHash: item.knownHash,
                knownHashStamp: item.knownHashStamp,
                interpreters: interpreters, zProjection: settings.zProjection)
        } else {
            imported = try await Task.detached(priority: .utility) {
                try ImageLoader.importFile(url, knownHash: item.knownHash, knownHashStamp: item.knownHashStamp)
            }.value
        }
        let image = imported.record
        let importedURLs = Set([image.storedURL, image.thumbURL, image.displayURL])
        func discardImportedFiles() {
            for url in importedURLs { try? FileManager.default.removeItem(at: url) }
        }
        guard !batch.isDeleted, batch.modelContext != nil else {
            discardImportedFiles()
            throw CancellationError()
        }
        // A queued source can be replaced between selection and preparation.
        // Verify the owned copy before trusting the original dedup identity.
        // `fileHash` is the stored copy's hash: computed while copying, or the
        // drop-time hash when the source still has the size and modification
        // time it had when that hash was taken.
        let actualHash = imported.fileHash
        if actualHash.isEmpty || (item.knownHash != nil && item.knownHash != actualHash) {
            discardImportedFiles()
            throw NSError(domain: "AnalysisJobs", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "The source changed after this job was created. Import it again to review the updated image."])
        }
        image.fileHash = actualHash
        image.sourcePxPerUm = imported.exifPxPerUm
        image.sourceCalibrationSource = imported.exifSource
        // A scale set for this image in Analysis setup before it was imported.
        image.scalePxPerUm = item.ownScale?.pxPerUm
        image.scaleSource = item.ownScale?.source
        image.jobItemId = item.id
        image.sourceOrder = jobScheduler.jobs.first(where: { $0.batchId == batchId && $0.items.contains(where: { $0.id == item.id }) })?.items.firstIndex(where: { $0.id == item.id })
        repos.attach(image: image, to: batch, save: false)
        try repos.context.save()
        refreshLibraryStats()
        NotificationCenter.default.post(name: .ccLibraryChanged, object: nil)
        return image.id
    }

    /// Resolve the exact models captured by a run, including its ensemble pair.
    func detectionService(for settings: AnalysisRunSettings) throws -> DetectionService {
        if settings.modelId == EnsembleDownloader.modelId {
            guard let aId = settings.ensemblePrimaryId, let bId = settings.ensembleSecondaryId,
                  aId != bId, aId != settings.modelId, bId != settings.modelId,
                  let a = detectorRegistry.detector(for: aId, models: models),
                  let b = detectorRegistry.detector(for: bId, models: models) else {
                throw DetectionError.modelNotInstalled(modelId: "saved ensemble members")
            }
            return EnsembleDetectionService(primary: a, secondary: b, primaryModelId: aId, secondaryModelId: bId)
        } else {
            guard let selected = detectorRegistry.detector(for: settings.modelId, models: models) else {
                throw DetectionError.modelNotInstalled(modelId: settings.modelId)
            }
            return selected
        }
    }

    /// Fresh measurements at the image's own current scale, which may have
    /// changed while the model ran; returns the scale they are stored at.
    func cellsAtImageScale(_ cells: [DetectedCell], for image: ImageRecord,
                           measuredAt sourceScale: Double,
                           source: String) -> (cells: [DetectedCell], scale: ImageScale.Value) {
        let target = image.effectiveScale?.value ?? ImageScale.Value(pxPerUm: sourceScale, source: source)
        return (Self.cellsAtScale(cells, batchScale: target.pxPerUm, measuredAt: sourceScale), target)
    }

    nonisolated static func cellsAtScale(_ cells: [DetectedCell], batchScale: Double?,
                                         measuredAt sourceScale: Double) -> [DetectedCell] {
        guard let scale = batchScale, scale > 0, scale != sourceScale else { return cells }
        return calibratedCells(cells, pxPerUm: scale, fallbackScale: sourceScale)
    }

    private func analyzeJobImage(_ imageId: UUID, settings jobSettings: AnalysisRunSettings) async throws {
        guard let image = repos.image(id: imageId) else { throw DetectionError.imageDecodeFailed }
        // Each image is analysed at its own scale: its own value, else its
        // file's, else the batch's for images without one. A value that
        // disagrees with the file is only accepted as an explicit override.
        if let problem = ImageScale.mismatch(explicit: image.ownScale, file: image.fileScale) {
            throw NSError(domain: "AnalysisJobs", code: 2, userInfo: [NSLocalizedDescriptionKey: problem])
        }
        guard let scale = image.effectiveScale else {
            throw NSError(domain: "AnalysisJobs", code: 4, userInfo: [NSLocalizedDescriptionKey: ImageScale.missingMessage])
        }
        // The size hint in pixels follows the image's scale.
        let settings = jobSettings.withScale(scale)
        let svc = try detectionService(for: settings)
        // Finish committed corrections before saving the previous mask variant.
        if let detection = image.detection { try await finishPendingCellEdits(for: detection) }
        guard !image.isDeleted, image.modelContext != nil else { throw CancellationError() }
        inFlightRerunImageIds.insert(imageId)
        defer { inFlightRerunImageIds.remove(imageId) }
        let source = settings.sourceURL(for: image)
        processingStageLine = "Preparing \(image.fileName)"; lastStageUpdateAt = Date()
        var recordedSettings = settings
        if let family = ModelFamily(rawValue: settings.modelFamily) {
            recordedSettings.detectorVersion = ProvenanceMetadata.detectorVersion(for: family)
            recordedSettings.weightsSHA256 = ProvenanceMetadata.weightsHash(for: family, modelId: settings.modelId)
        }
        let result = try await svc.detectWithLocalTiming(settings.detectionInput(imageURL: source))
        guard !image.isDeleted, image.modelContext != nil else { throw CancellationError() }
        // What the sidecar reports it ran replaces the values probed above.
        recordedSettings = recordedSettings.recording(result.runtime)
        // Scale, encode, hash and compress the cells on a detached task, so
        // the main actor only links rows. Redone if the image's scale changes
        // meanwhile: the cells are stored at its current scale.
        let rawCells = result.cells, sourceScale = settings.pxPerUm
        var target = scale.value
        var measuredCells: [DetectedCell] = []
        var storage: DetectionRecord.CellsStorageSnapshot
        repeat {
            target = image.effectiveScale?.value ?? scale.value
            let targetScale = target.pxPerUm
            (measuredCells, storage) = await Task.detached(priority: .userInitiated) {
                let cells = Self.cellsAtScale(rawCells, batchScale: targetScale, measuredAt: sourceScale)
                return (cells, DetectionRecord.makeStorageSnapshot(cells))
            }.value
            try Task.checkCancellation()
            guard !image.isDeleted, image.modelContext != nil else { throw CancellationError() }
            // Edits made while inference was running belong to the saved previous
            // variant. Drain them before replacing its detection record.
            while let detection = image.detection, let pending = pendingCellEditTasks[detection.id] {
                await pending.value
                try Task.checkCancellation()
                guard !image.isDeleted, image.modelContext != nil else { throw CancellationError() }
            }
        } while (image.effectiveScale?.value ?? scale.value) != target
        // The model and run inputs are captured before awaiting inference.
        // The replaced detection is kept as a version at its own scale, so
        // the image's new scale is recorded after it is saved.
        repos.saveDetection(snapshot: storage, cells: measuredCells,
                            detectorId: "\(type(of: svc))/\(settings.modelId)",
                            for: image, imageStats: result.imageStats, runSettings: recordedSettings, save: false)
        image.measuredPxPerUm = target.pxPerUm
        image.measuredScaleSource = target.source
        try repos.context.save()
        refreshLibraryStats()
        // Name the image so open screens refresh only that row or tile.
        NotificationCenter.default.post(name: .ccCorrectionsChanged, object: imageId)
    }

    /// Reanalysis is a durable one-image background job; navigation stays usable.
    func canRerunSavedImage(_ image: ImageRecord) -> Bool {
        let modelId = image.detection?.runSettings?.modelId ?? activeModelId
        return !isRerunning(image) && detectorRegistry.isInstalled(modelId, models: models)
    }

    func reRunDetection(on image: ImageRecord, useSavedSettings: Bool = false) {
        guard !isRerunning(image), let batch = image.batch,
              !jobScheduler.jobs.contains(where: { [.queued, .running, .pausing].contains($0.status) && $0.items.contains(where: { $0.imageId == image.id }) }) else { return }
        guard image.effectiveScale != nil else {
            flashExport("This image has no pixel scale. Set one with Calibrate… first.", isError: true)
            return
        }
        var settings = useSavedSettings ? (image.detection?.runSettings ?? AnalysisRunSettings.capture(state: self))
            : AnalysisRunSettings.capture(state: self)
        // The job's scale is the batch's for images without one; the image is
        // analysed at its own scale.
        settings.pxPerUm = batch.pxPerUm
        settings.calibrationSource = batch.pxPerUmSource ?? (batch.pxPerUm > 0 ? "manual" : ImageScale.unsetSource)
        settings.thresholds = batch.thresholds
        let job = AnalysisJob(batchId: batch.id, title: image.fileName, settings: settings,
            items: [AnalysisJobItem(url: image.storedURL, imageId: image.id, knownHash: image.fileHash, displayName: image.fileName)])
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.jobScheduler.add(job)
                self.jobScheduler.maxParallel = self.maxParallel
                try await self.jobScheduler.enqueue(job.id)
            } catch { self.flashExport(error.localizedDescription, isError: true) }
        }
    }

    // MARK: — Open existing batch (from Recent rows / Batches view)

    func openBatch(_ batch: BatchRecord) {
        currentBatchId = batch.id
        currentImageIdx = 0
        view = .results
    }

    func openBatch(id: UUID) {
        guard repos.batch(id: id) != nil else { return }
        currentBatchId = id
        currentImageIdx = 0
        view = .results
    }

    // MARK: — Corrections

    /// Coalesce rapid overlay events, serialize the large JSON blob off-main,
    /// then commit the newest cell snapshot and every audit row together.
    /// This is the critical manual-edit fast path: pointer feedback is purely
    /// in-memory and no full detection encode/save/global recount runs inside
    /// the click or drag handler.
    func scheduleCellEdit(cells: [DetectedCell],
                          corrections: [CorrectionSpec],
                          detection: DetectionRecord,
                          image: ImageRecord) {
        guard !detection.isDeleted, detection.modelContext != nil,
              !image.isDeleted, image.modelContext != nil,
              image.detection?.id == detection.id else { return }
        let id = detection.id
        let nextRevision = (pendingCellEdits[id]?.revision ?? 0) &+ 1
        if var pending = pendingCellEdits[id] {
            pending.cells = cells
            pending.corrections.append(contentsOf: corrections)
            pending.revision = nextRevision
            pendingCellEdits[id] = pending
        } else {
            pendingCellEdits[id] = PendingCellEdit(
                detection: detection, image: image, baseRevision: detection.cellsRevision, cells: cells,
                corrections: corrections, revision: nextRevision)
        }

        pendingCellEditTasks[id]?.cancel()
        pendingCellEditTasks[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { return }
            guard let self, let pending = self.pendingCellEdits[id],
                  pending.revision == nextRevision else { return }
            defer {
                if self.pendingCellEdits[id]?.revision == nextRevision {
                    self.pendingCellEdits[id] = nil
                    self.pendingCellEditTasks[id] = nil
                }
            }
            guard !pending.detection.isDeleted, pending.detection.modelContext != nil,
                  !pending.image.isDeleted, pending.image.modelContext != nil else { return }

            let snapshotCells = pending.cells
            let storage = await Task.detached(priority: .userInitiated) {
                DetectionRecord.makeStorageSnapshot(snapshotCells)
            }.value
            guard !Task.isCancelled,
                  let latest = self.pendingCellEdits[id],
                  latest.revision == nextRevision else { return }
            guard !latest.detection.isDeleted, latest.detection.modelContext != nil,
                  !latest.image.isDeleted, latest.image.modelContext != nil,
                  latest.image.detection?.id == id else { return }
            guard latest.detection.cellsRevision == latest.baseRevision else {
                self.flashExport("The analysis changed before the edit could be saved. Please reopen the image and try again.", isError: true)
                return
            }

            do {
                let result = try self.repos.commitReviewCellEdit(
                    storage: storage,
                    corrections: latest.corrections,
                    detection: latest.detection,
                    image: latest.image)
                self.postCorrectionsChanged(imageId: latest.image.id,
                                            reviewDelta: result.reviewCountDelta)
            } catch {
                self.flashExport("The edit could not be saved: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func postCorrectionsChanged(imageId: UUID?, reviewDelta: Int) {
        NotificationCenter.default.post(
            name: .ccCorrectionsChanged,
            object: imageId,
            userInfo: ["reviewDelta": reviewDelta])
    }

    /// Compose toolbar and sequence edits with the latest overlay snapshot,
    /// including changes whose JSON is still being encoded.
    private func cellsForEditing(in image: ImageRecord) -> [DetectedCell]? {
        guard !image.isDeleted, image.modelContext != nil,
              let detection = image.detection,
              !detection.isDeleted, detection.modelContext != nil else { return nil }
        if let pending = pendingCellEdits[detection.id],
           pending.image.id == image.id, pending.detection.id == detection.id,
           pending.baseRevision == detection.cellsRevision {
            return pending.cells
        }
        if let cached = detection.cachedCells, !cached.isEmpty { return cached }
        do {
            let cells = try DetectionRecord.decodeCellsDataForReview(detection.cellsData)
            detection.cacheDecodedCells(cells, revision: detection.cellsRevision)
            return cells
        } catch {
            flashExport("The saved cell measurements could not be read. The original data was preserved.", isError: true)
            return nil
        }
    }

    /// Delete every cell in `ids` from the current image's detection, persist,
    /// and record a "remove" correction per cell for the audit trail. The single
    /// owner of this mutation — both the Results keyboard shortcut and the editor
    /// toolbar's Remove override route through here so the two can't drift.
    /// Empty selection (or an empty intersection) is a no-op.
    func removeCells(_ ids: Set<UUID>) {
        guard !ids.isEmpty,
              let image = currentImage,
              let detection = image.detection,
              var cells = cellsForEditing(in: image) else { return }
        let victims = cells.filter { ids.contains($0.id) }
        guard !victims.isEmpty else { return }
        cells.removeAll { ids.contains($0.id) }
        scheduleCellEdit(cells: cells,
                         corrections: victims.map { CorrectionSpec(kind: "remove", cell: $0) },
                         detection: detection,
                         image: image)
    }

    /// Merge a multi-selection into one contour/circle without forcing the
    /// user through pairwise Merge clicks. The convex hull is used when any
    /// selected mask has contour geometry; otherwise an equivalent enclosing
    /// circle is produced.
    func mergeSelectedCells(_ ids: Set<UUID>) {
        guard ids.count >= 2,
              let image = currentImage,
              let detection = image.detection,
              var cells = cellsForEditing(in: image) else { return }
        let selected = cells.filter { ids.contains($0.id) }
        guard selected.count >= 2 else { return }
        let points = selected.flatMap { cell -> [CGPoint] in
            if let contour = cell.contourPx, contour.count >= 3 { return contour }
            let radius = CGFloat(cell.diameterPx / 2)
            return (0..<24).map { index in
                let angle = Double(index) / 24 * .pi * 2
                return CGPoint(x: cell.cx + Double(radius) * cos(angle),
                               y: cell.cy + Double(radius) * sin(angle))
            }
        }
        let hull = Self.convexHull(points)
        let areaPx = abs(Self.polygonArea(hull))
        let cx = selected.reduce(0) { $0 + $1.cx } / Double(selected.count)
        let cy = selected.reduce(0) { $0 + $1.cy } / Double(selected.count)
        let diameterPx = areaPx > 0 ? 2 * sqrt(areaPx / .pi)
            : selected.map(\.diameterPx).max() ?? 1
        // The image's own scale: the one its other cells are stored at.
        let px = image.currentPxPerUm > 0 ? image.currentPxPerUm : pxPerUm
        let merged = DetectedCell(cx: cx, cy: cy,
                                  diameter: diameterPx / max(px, 0.000_001),
                                  diameterPx: diameterPx, confidence: 1,
                                  areaMicrons2: areaPx / pow(max(px, 0.000_001), 2),
                                  centroidUmX: cx / max(px, 0.000_001),
                                  centroidUmY: cy / max(px, 0.000_001),
                                  contourPx: hull.count >= 3 ? hull : nil)
        cells.removeAll { ids.contains($0.id) }
        cells.append(merged)
        var specs = selected.map { CorrectionSpec(kind: "merge-remove", cell: $0) }
        specs.append(CorrectionSpec(kind: "merge-add", cell: merged))
        scheduleCellEdit(cells: cells, corrections: specs,
                         detection: detection, image: image)
    }

    /// Propagate the selected current-frame masks through the remaining
    /// ordered sequence, compensating for robustly estimated acquisition
    /// drift and skipping any destination that already contains a nearby mask.
    func propagateSelectedCells(_ ids: Set<UUID>, useDrift: Bool) async -> String {
        guard !ids.isEmpty, let batch = currentBatch,
              let sourceImage = currentImage,
              sourceImage.detection != nil else {
            return "Select one or more masks first."
        }
        let images = orderedImages(in: batch)
        guard let sourceFrame = images.firstIndex(where: { $0.id == sourceImage.id }),
              sourceFrame + 1 < images.count else {
            return "Open a frame that has later frames in this batch."
        }
        let sourceCells = (cellsForEditing(in: sourceImage) ?? []).filter { ids.contains($0.id) }
        guard !sourceCells.isEmpty else { return "The selected masks are no longer available." }

        var frames: [[DetectedCell]] = []
        for (index, image) in images.enumerated() {
            frames.append(cellsForEditing(in: image) ?? [])
            if index % 8 == 7 { await Task.yield() }
        }
        let offsets = useDrift
            ? await Task.detached(priority: .userInitiated) {
                SequenceWorkflowService.estimateDrift(frames: frames)
            }.value
            : frames.indices.map { .init(frame: $0, dxPx: 0, dyPx: 0, matchedObjects: 0) }
        let targetFrames = Array((sourceFrame + 1)..<images.count)
        let propagation = await Task.detached(priority: .userInitiated) {
            SequenceWorkflowService.propagate(sourceCells: sourceCells,
                                               sourceFrame: sourceFrame,
                                               frames: frames,
                                               offsets: offsets,
                                               targetFrames: targetFrames)
        }.value

        var added = 0
        var reviewDelta = 0
        defer { if added > 0 { postCorrectionsChanged(imageId: nil, reviewDelta: reviewDelta) } }
        for frame in targetFrames {
            let image = images[frame]
            guard !image.isDeleted, image.modelContext != nil,
                  let additions = propagation.cellsByFrame[frame],
                  let detection = image.detection else { continue }
            do { try await finishPendingCellEdits(for: detection) }
            catch { return "Propagation stopped: \(error.localizedDescription)" }
            guard !image.isDeleted, image.modelContext != nil,
                  image.detection?.id == detection.id,
                  let currentCells = cellsForEditing(in: image) else { continue }
            let px = image.currentPxPerUm > 0 ? image.currentPxPerUm : pxPerUm
            let calibrated = additions.filter { candidate in
                candidate.cx >= 0 && candidate.cy >= 0
                    && candidate.cx < Double(image.widthPx) && candidate.cy < Double(image.heightPx)
                    && !currentCells.contains { existing in
                        hypot(existing.cx - candidate.cx, existing.cy - candidate.cy)
                            <= max(4, min(existing.diameterPx, candidate.diameterPx) * 0.45)
                    }
            }.map { cell -> DetectedCell in
                var cell = cell
                cell.centroidUmX = cell.cx / max(px, 0.000_001)
                cell.centroidUmY = cell.cy / max(px, 0.000_001)
                return cell
            }
            // Frames of one batch can have different scales: sizes are
            // converted to this frame's own scale (outlines stay in pixels).
            let scaled = px > 0 ? Self.calibratedCells(calibrated, pxPerUm: px, fallbackScale: px) : calibrated
            guard !scaled.isEmpty else { continue }
            let result = repos.commitCellEdit(
                cells: currentCells + scaled,
                corrections: scaled.map { CorrectionSpec(kind: "propagate", cell: $0) },
                detection: detection, image: image)
            reviewDelta += result.reviewCountDelta
            added += calibrated.count
            await Task.yield()
        }
        return added == 0
            ? "No masks added; nearby labels already cover the predicted positions."
            : "Propagated \(added) mask\(added == 1 ? "" : "s") across \(targetFrames.count) frame\(targetFrames.count == 1 ? "" : "s")."
    }

    /// Interpolate one selected anchor to the nearest matching mask in the
    /// final frame and fill only missing intermediate labels.
    func interpolateSelectedCellToLast(_ ids: Set<UUID>) async -> String {
        guard ids.count == 1, let selectedId = ids.first,
              let batch = currentBatch, let sourceImage = currentImage,
              let source = cellsForEditing(in: sourceImage)?.first(where: { $0.id == selectedId }) else {
            return "Select exactly one anchor mask."
        }
        let images = orderedImages(in: batch)
        guard let start = images.firstIndex(where: { $0.id == sourceImage.id }),
              start + 1 < images.count,
              images.last?.detection != nil else {
            return "This needs a later detected frame in the same batch."
        }
        let end = cellsForEditing(in: images[images.count - 1])?.min {
            hypot($0.cx - source.cx, $0.cy - source.cy)
                < hypot($1.cx - source.cx, $1.cy - source.cy)
        }
        guard let end, hypot(end.cx - source.cx, end.cy - source.cy) <= max(200, source.diameterPx * 5) else {
            return "No plausible matching anchor was found in the final frame."
        }
        let generated = await Task.detached(priority: .userInitiated) {
            SequenceWorkflowService.interpolate(start: source, startFrame: start,
                                                end: end, endFrame: images.count - 1)
        }.value
        var added = 0
        defer { if added > 0 { postCorrectionsChanged(imageId: nil, reviewDelta: 0) } }
        for frame in generated.keys.sorted() {
            let image = images[frame]
            guard !image.isDeleted, image.modelContext != nil,
                  let candidate = generated[frame], let detection = image.detection else { continue }
            do { try await finishPendingCellEdits(for: detection) }
            catch { return "Interpolation stopped: \(error.localizedDescription)" }
            guard !image.isDeleted, image.modelContext != nil,
                  image.detection?.id == detection.id,
                  let currentCells = cellsForEditing(in: image) else { continue }
            let conflict = currentCells.contains {
                hypot($0.cx - candidate.cx, $0.cy - candidate.cy)
                    <= max(4, min($0.diameterPx, candidate.diameterPx) * 0.45)
            }
            guard !conflict else { continue }
            let result = repos.commitCellEdit(
                cells: currentCells + [candidate],
                corrections: [CorrectionSpec(kind: "interpolate", cell: candidate)],
                detection: detection, image: images[frame])
            _ = result
            added += 1
            await Task.yield()
        }
        return added == 0
            ? "Every intermediate frame already has a nearby label."
            : "Interpolated \(added) missing label\(added == 1 ? "" : "s")."
    }

    /// Returns a persisted batch snapshot immediately when valid; otherwise
    /// materializes SwiftData in yielding chunks and computes plots off-main.
    func batchInsights(force: Bool = false) async -> BatchInsightsSnapshot? {
        guard let batch = currentBatch else { return nil }
        if !force, batch.insightsRevision == batch.contentRevision,
           let data = batch.insightsData,
           let cached = try? JSONDecoder().decode(BatchInsightsSnapshot.self, from: data) {
            return cached
        }

        let revision = batch.contentRevision
        let input = BatchInsightsEncodedInput(
            revision: revision,
            images: orderedImages(in: batch).map { image in
                .init(id: image.id, fileName: image.fileName,
                      cellsData: image.detection?.cellsData,
                      imageStatsData: image.detection?.imageStatsData)
            })
        let snapshot = await Task.detached(priority: .utility) {
            BatchInsightsService.compute(input)
        }.value
        guard batch.contentRevision == revision else { return snapshot }
        batch.insightsData = try? JSONEncoder().encode(snapshot)
        batch.insightsRevision = revision
        try? repos.context.save()
        return snapshot
    }

    func openImage(id: UUID) {
        guard let batch = currentBatch,
              let index = orderedImages(in: batch).firstIndex(where: { $0.id == id }) else { return }
        currentImageIdx = index
        view = .results
    }

    private static func polygonArea(_ points: [CGPoint]) -> Double {
        guard points.count >= 3 else { return 0 }
        var sum = 0.0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            sum += Double(points[index].x * next.y - next.x * points[index].y)
        }
        return sum / 2
    }

    private static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 3 else { return points }
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for point in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower.last!, point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [CGPoint] = []
        for point in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper.last!, point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        lower.removeLast(); upper.removeLast()
        return lower + upper
    }

    private static func shortDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f.string(from: Date())
    }

    /// Sets the user's default scale for images without one (Home and
    /// Settings). It is used by batches imported from now on and never
    /// replaces a scale recorded in a file. With `updateCurrentBatch`, the
    /// open batch's scale for images without one changes too: its analysed
    /// images that use that scale have their sizes converted (the calibration
    /// sheet offers re-segmenting instead, through `applyScaleChange`).
    func applyCalibration(_ newPxPerUm: Double,
                          source: String,
                          updateCurrentBatch: Bool = true) {
        guard newPxPerUm.isFinite, newPxPerUm > 0 else { return }
        if updateCurrentBatch, let batch = currentBatch,
           jobScheduler.jobs.contains(where: { $0.batchId == batch.id && [.queued, .running, .pausing].contains($0.status) }) {
            flashExport("Pause this batch in Processing before changing its calibration.", isError: true)
            return
        }
        pxPerUm = newPxPerUm
        // Home owns the default for FUTURE imports. Reaching an old batch via
        // `currentBatchId` must not make a Home calibration silently rewrite
        // that analyzed batch's measurements or scale bar.
        guard updateCurrentBatch, let batch = currentBatch,
              let context = scaleChangeContext(for: batch) else { return }
        let plan = ScaleChange.plan(.init(value: ImageScale.Value(pxPerUm: newPxPerUm, source: source),
                                          scope: .imagesWithoutOwnScale),
                                    context: context)
        applyScaleChange(plan, batchId: batch.id, resegment: false)
    }

    // MARK: — Per-image scale

    @ObservationIgnored private var calibrationNoteToken = 0

    /// Shows a calibration note in Results for a few seconds.
    func showCalibrationNote(_ text: String) {
        lastCalibrationNote = text
        calibrationNoteToken &+= 1
        let token = calibrationNoteToken
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, self.calibrationNoteToken == token else { return }
            withAnimation(Tokens.Motion.ease) { self.lastCalibrationNote = nil }
        }
    }

    /// Every image of `batch` as the calibration sheet sees it.
    func scaleChangeContext(for batch: BatchRecord, currentImageId: UUID? = nil) -> ScaleChange.Context? {
        guard !batch.isDeleted, batch.modelContext != nil else { return nil }
        let images = orderedImages(in: batch).map { image -> ScaleChange.ImageState in
            let run = image.detection?.runSettings
            let depends = run.map { ImageScale.segmentationDependsOnScale($0) }
                ?? ImageScale.segmentationDependsOnScale(modelFamily: "", modelId: batch.modelId,
                                                         expectedDiameterUm: 0, watershedSplit: false)
            return ScaleChange.ImageState(id: image.id, fileName: image.fileName,
                                          explicit: image.ownScale, file: image.fileScale,
                                          measured: image.measuredScale,
                                          segmentationDependsOnScale: depends)
        }
        return ScaleChange.Context(batchId: batch.id, images: images, fallback: batch.fallbackScale,
                                   currentImageId: currentImageId)
    }

    /// Applies a scale change from the calibration sheet. Analysed images
    /// whose scale changes are segmented again at their new scale when
    /// `resegment` is set and their outlines depend on the scale; all others
    /// keep their outlines and have their sizes converted, and are then marked
    /// "segmented at X, measured at Y". Refused while a job runs on the batch.
    func applyScaleChange(_ plan: ScaleChange.Plan, batchId: UUID, resegment: Bool) {
        guard !plan.isEmpty, let batch = repos.batch(id: batchId) else { return }
        if jobScheduler.jobs.contains(where: { $0.batchId == batchId && $0.isActive }) {
            flashExport("Pause this batch in Processing before changing its scale.", isError: true)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.pinLegacyMeasurementScales(batch)
                guard !batch.isDeleted, batch.modelContext != nil else { return }
                if let fallback = plan.fallback {
                    batch.pxPerUm = fallback.pxPerUm
                    batch.pxPerUmSource = fallback.source
                }
                let images = Dictionary(self.orderedImages(in: batch).map { ($0.id, $0) },
                                        uniquingKeysWith: { first, _ in first })
                for (id, own) in plan.explicit {
                    guard let image = images[id] else { continue }
                    image.scalePxPerUm = own?.pxPerUm
                    image.scaleSource = own?.source
                }
                for (id, label) in plan.relabel {
                    guard let image = images[id], image.measuredPxPerUm == label.pxPerUm else { continue }
                    image.measuredScaleSource = label.source
                }
                batch.contentRevision &+= 1
                try self.repos.context.save()
                let rerun = resegment ? plan.resegment : []
                let rescale = plan.changed.filter { !rerun.contains($0.key) }
                if !rescale.isEmpty { try await self.rescaleImages(rescale, in: batch, notify: false) }
                if !rerun.isEmpty { self.rerunImages(rerun, in: batch) }
                NotificationCenter.default.post(name: .ccCorrectionsChanged, object: nil)
                self.showCalibrationNote(Self.scaleChangeNote(plan, rescaled: rescale.count, rerun: rerun.count))
            } catch { self.flashExport(error.localizedDescription, isError: true) }
        }
    }

    private static func scaleChangeNote(_ plan: ScaleChange.Plan, rescaled: Int, rerun: Int) -> String {
        var parts: [String] = []
        if let fallback = plan.fallback {
            parts.append("\(ImageScale.format(fallback.pxPerUm)) px/µm for images without a scale")
        } else if plan.explicit.count == 1, let own = plan.explicit.values.first {
            parts.append(own.map { "\(ImageScale.format($0.pxPerUm)) px/µm for this image" } ?? "this image uses its file's scale")
        }
        if plan.overridden > 0 { parts.append("file's scale overridden for \(ImageScale.countText(plan.overridden))") }
        if rescaled > 0 { parts.append("sizes of \(ImageScale.countText(rescaled)) converted") }
        if rerun > 0 { parts.append("\(ImageScale.countText(rerun)) queued to segment again") }
        return "Scale updated: " + parts.joined(separator: "; ") + "."
    }

    /// Records the scale of the batch on each image analysed before images
    /// had their own scale, which is what their numbers are at, so changing
    /// the batch's scale for images without one never changes what those
    /// numbers mean. A batch-wide pass that stopped partway is completed
    /// first. Changes are saved by the caller.
    @discardableResult
    func pinLegacyMeasurementScales(_ batch: BatchRecord) async throws -> Bool {
        var changed = false
        if batch.recalibrationPending {
            let source = batch.pxPerUmSource
            changed = try await recalibrateBatchIfNeeded(batch, pxPerUm: batch.pxPerUm,
                                                         source: source ?? "manual", notify: false)
            batch.pxPerUmSource = source
        }
        guard !batch.isDeleted, batch.modelContext != nil, ImageScale.isUsable(batch.pxPerUm) else { return changed }
        let legacy = ImageScale.batchSource(batch.pxPerUmSource)
        for image in orderedImages(in: batch) where image.measuredPxPerUm == nil && image.detection != nil {
            image.measuredPxPerUm = batch.pxPerUm
            image.measuredScaleSource = legacy
            changed = true
        }
        return changed
    }

    /// Keeps an analysed image's numbers at the scale they were measured at,
    /// as an explicit override of its file's scale: the answer to "measured
    /// at X; the file says Y" when X was right.
    func keepMeasuredScale(of image: ImageRecord) {
        guard let measured = image.measuredScale, let file = image.fileScale, let batch = image.batch else { return }
        if jobScheduler.jobs.contains(where: { $0.batchId == batch.id && $0.isActive }) {
            flashExport("Pause this batch in Processing before changing its scale.", isError: true)
            return
        }
        let override = ImageScale.Value(pxPerUm: measured.pxPerUm,
                                        source: ImageScale.overrideSource(filePxPerUm: file.pxPerUm))
        image.scalePxPerUm = override.pxPerUm
        image.scaleSource = override.source
        image.measuredPxPerUm = override.pxPerUm
        image.measuredScaleSource = override.source
        batch.contentRevision &+= 1
        try? repos.context.save()
        NotificationCenter.default.post(name: .ccCorrectionsChanged, object: image.id)
    }

    /// Queues segmentation again for `ids`, each image at its own current
    /// scale and with the settings it was analysed with.
    func rerunImages(_ ids: Set<UUID>, in batch: BatchRecord) {
        let busy = Set(jobScheduler.jobs.filter(\.isActive).flatMap { $0.items.compactMap(\.imageId) })
        let images = orderedImages(in: batch).filter { ids.contains($0.id) && !busy.contains($0.id) && !isRerunning($0) }
        guard !images.isEmpty else { return }
        // One job per distinct saved settings.
        var groups: [(settings: AnalysisRunSettings, images: [ImageRecord])] = []
        for image in images {
            var settings = image.detection?.runSettings ?? AnalysisRunSettings.capture(state: self)
            settings.pxPerUm = batch.pxPerUm
            settings.calibrationSource = batch.pxPerUmSource ?? (batch.pxPerUm > 0 ? "manual" : ImageScale.unsetSource)
            settings.thresholds = batch.thresholds
            if let index = groups.firstIndex(where: { $0.settings.hasSameInputs(as: settings) }) {
                groups[index].images.append(image)
            } else {
                groups.append((settings, [image]))
            }
        }
        for group in groups {
            let sources = group.images.map { image in
                AnalysisJobItem.Source(url: image.storedURL, imageId: image.id, knownHash: image.fileHash,
                                       displayName: image.fileName)
            }
            let title = group.images.count == 1 ? group.images[0].fileName
                : "\(batch.displayName) · \(group.images.count) images at their new scale"
            let settings = group.settings, batchId = batch.id
            Task { [weak self] in
                let items = await AnalysisJobItem.make(sources)
                guard let self else { return }
                let job = AnalysisJob(batchId: batchId, title: title, settings: settings, items: items)
                do {
                    try await self.jobScheduler.add(job)
                    self.jobScheduler.maxParallel = self.maxParallel
                    try await self.jobScheduler.enqueue(job.id)
                } catch { self.flashExport(error.localizedDescription, isError: true) }
            }
        }
    }

    /// The scales in use in `batch`: each analysed image at its measurements'
    /// scale, each other image at the scale it will be analysed at. Cached
    /// per batch until its contents change.
    func scaleSummary(for batch: BatchRecord) -> ImageScale.Summary {
        let count = batch.images.count
        if let cached = scaleSummaryCache[batch.id], cached.revision == batch.contentRevision,
           cached.count == count, cached.fallback == batch.pxPerUm {
            return cached.summary
        }
        let summary = ImageScale.summarize(orderedImages(in: batch).map { image in
            image.currentScale.map { ImageScale.Entry.scale($0) } ?? .missing
        })
        scaleSummaryCache[batch.id] = (batch.contentRevision, count, batch.pxPerUm, summary)
        return summary
    }
    @ObservationIgnored private var scaleSummaryCache: [UUID: (revision: Int, count: Int, fallback: Double, summary: ImageScale.Summary)] = [:]

    /// Brings the stored µm values of analysed images to new per-image scales
    /// and records them on the images; pixel outlines are kept. Serialized
    /// with every other calibration change, saved every
    /// `recalibrationSaveInterval` images, and safe against concurrent edits,
    /// like `recalibrateBatchIfNeeded`.
    @discardableResult
    func rescaleImages(_ targets: [UUID: ImageScale.Value], in batch: BatchRecord,
                       notify: Bool = true) async throws -> Bool {
        calibrationUpdatesInFlight += 1
        defer { calibrationUpdatesInFlight -= 1 }
        let previous = calibrationTask
        let task = Task { @MainActor () throws -> Bool in
            _ = try? await previous?.value
            try Task.checkCancellation()
            guard !batch.isDeleted, batch.modelContext != nil else { throw CancellationError() }
            var changed = false
            var rewrittenSinceSave = 0
            for image in self.orderedImages(in: batch) {
                guard let target = targets[image.id], ImageScale.isUsable(target.pxPerUm),
                      !image.isDeleted, image.modelContext != nil, image.detection != nil else { continue }
                let oldScale = image.measuredScale?.pxPerUm ?? target.pxPerUm
                if oldScale != target.pxPerUm {
                    guard try await self.rewriteStoredMeasurements(of: image, in: batch,
                                                                   to: target.pxPerUm, from: oldScale) else { continue }
                    rewrittenSinceSave += 1
                }
                // Recorded in the same save as the rewritten cells.
                image.measuredPxPerUm = target.pxPerUm
                image.measuredScaleSource = target.source
                changed = true
                if rewrittenSinceSave >= max(1, self.recalibrationSaveInterval) {
                    rewrittenSinceSave = 0
                    try self.repos.context.save()
                    await LibraryTransferPacing.breathe()
                }
            }
            guard !batch.isDeleted, batch.modelContext != nil else { throw CancellationError() }
            if changed { batch.contentRevision &+= 1 }
            try self.repos.context.save()
            if changed, notify { NotificationCenter.default.post(name: .ccCorrectionsChanged, object: nil) }
            return changed
        }
        calibrationTask = task
        return try await task.value
    }

    /// Rewrites one image's stored µm values at `scale` (pixel outlines are
    /// kept), waiting for pending edits and starting over when its cells
    /// change meanwhile. False when the image or its detection went away.
    private func rewriteStoredMeasurements(of image: ImageRecord, in batch: BatchRecord,
                                           to scale: Double, from oldScale: Double) async throws -> Bool {
        while !image.isDeleted, image.modelContext != nil, let detection = image.detection {
            try Task.checkCancellation()
            guard !batch.isDeleted, batch.modelContext != nil else { throw CancellationError() }
            if let pending = pendingCellEditTasks[detection.id] { await pending.value; continue }
            let revision = detection.cellsRevision
            let cells = try await loadReviewCells(for: detection)
            let snapshot = await Task.detached(priority: .utility) {
                DetectionRecord.makeStorageSnapshot(Self.calibratedCells(cells, pxPerUm: scale, fallbackScale: oldScale))
            }.value
            try Task.checkCancellation()
            guard !batch.isDeleted, batch.modelContext != nil else { throw CancellationError() }
            guard !image.isDeleted, image.modelContext != nil,
                  !detection.isDeleted, detection.modelContext != nil else { return false }
            guard image.detection?.id == detection.id,
                  detection.cellsRevision == revision,
                  pendingCellEditTasks[detection.id] == nil else { continue }
            guard !snapshot.data.isEmpty else {
                throw NSError(domain: "CellCounter.Calibration", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "The calibrated measurements could not be encoded. The original measurements were preserved."
                ])
            }
            try repos.recalibrateReviewCandidates(for: detection, pxPerUm: scale)
            detection.applyStorageSnapshot(snapshot)
            repos.noteUpkeepWork(for: detection)
            return true
        }
        return false
    }

    /// Serialize calibration requests and only apply a prepared snapshot if no
    /// correction arrived while it was encoded. Memory is bounded to one image.
    ///
    /// The batch-wide recalibration of images analysed before images had
    /// their own scale (no `measuredPxPerUm`); the app now uses it only to
    /// complete such a pass that stopped partway (`pinLegacyMeasurementScales`),
    /// and changes scales per image with `rescaleImages`.
    /// Every such image of a batch is stored at the batch's `pxPerUm`,
    /// except while a pass is under way or after one stopped partway, which
    /// `recalibrationPending` records. So when the batch already has this
    /// scale and no pass is pending, nothing is rewritten (a different
    /// `source` is stored on its own). Otherwise every analysed image is
    /// rewritten exactly as before, with a save every
    /// `recalibrationSaveInterval` images and a short pause after each, and
    /// the marker is cleared in the final save.
    ///
    /// Posts one `ccCorrectionsChanged` at the end when something changed.
    func recalibrateBatch(_ batch: BatchRecord, pxPerUm scale: Double, source: String) async throws {
        _ = try await recalibrateBatchIfNeeded(batch, pxPerUm: scale, source: source)
    }

    /// `recalibrateBatch`, returning whether anything was changed. With
    /// `notify` false nothing is posted, for callers that change more of the
    /// batch afterwards and post once themselves.
    @discardableResult
    func recalibrateBatchIfNeeded(_ batch: BatchRecord, pxPerUm scale: Double, source: String,
                                  notify: Bool = true) async throws -> Bool {
        calibrationUpdatesInFlight += 1
        defer { calibrationUpdatesInFlight -= 1 }
        let previous = calibrationTask
        let task = Task { @MainActor () throws -> Bool in
            _ = try? await previous?.value
            try Task.checkCancellation()
            guard !batch.isDeleted, batch.modelContext != nil else { throw CancellationError() }
            guard scale.isFinite, scale > 0 else { return false }
            if batch.pxPerUm == scale, !batch.recalibrationPending {
                guard batch.pxPerUmSource != source else { return false }
                batch.pxPerUmSource = source
                try self.repos.context.save()
                if notify { NotificationCenter.default.post(name: .ccCorrectionsChanged, object: nil) }
                return true
            }
            let oldScale = batch.pxPerUm
            batch.pxPerUm = scale; batch.pxPerUmSource = source
            // Saved with the first rewritten images (or by any other save
            // meanwhile), and cleared only once every image has been visited.
            batch.recalibrationPending = true
            var rewrittenSinceSave = 0
            // Per-cell scale inference makes this idempotent, so a pass that
            // completes one stopped partway visits every image again. Images
            // with their own recorded scale are not at the batch's scale and
            // are left alone (`rescaleImages` moves those).
            for image in self.orderedImages(in: batch) where image.measuredPxPerUm == nil {
                if try await self.rewriteStoredMeasurements(of: image, in: batch, to: scale, from: oldScale) {
                    rewrittenSinceSave += 1
                }
                if rewrittenSinceSave >= max(1, self.recalibrationSaveInterval) {
                    rewrittenSinceSave = 0
                    try self.repos.context.save()
                    await LibraryTransferPacing.breathe()
                }
            }
            guard !batch.isDeleted, batch.modelContext != nil else { throw CancellationError() }
            batch.recalibrationPending = false
            batch.contentRevision &+= 1
            try self.repos.context.save()
            if notify { NotificationCenter.default.post(name: .ccCorrectionsChanged, object: nil) }
            return true
        }
        calibrationTask = task
        return try await task.value
    }

    nonisolated static func calibratedCells(_ cells: [DetectedCell], pxPerUm scale: Double,
                                           fallbackScale: Double) -> [DetectedCell] {
        cells.map { original in
            var cell = original
            // A concurrent correction may already use the new batch scale.
            // Infer each cell's stored scale from its paired pixel/µm diameter
            // so repeated calibration cannot scale its area or perimeter twice.
            let ownScale = original.diameter > 0 && original.diameterPx > 0
                ? original.diameterPx / original.diameter : fallbackScale
            let ratio = ownScale / scale
            cell.diameter = original.diameterPx / scale
            cell.centroidUmX = original.cx / scale
            cell.centroidUmY = original.cy / scale
            if let area = original.areaMicrons2 { cell.areaMicrons2 = area * ratio * ratio }
            if let perimeter = original.perimeterMicrons { cell.perimeterMicrons = perimeter * ratio }
            return cell
        }
    }
}
