import SwiftUI
import Observation
import AppKit
import UniformTypeIdentifiers
import SwiftData

enum AppView: String, Hashable, CaseIterable {
    case home, processing, results, batch, workspace, models, fineTune, settings, queue, reviewQueue, compare, imagesLibrary
}

@MainActor
private struct PendingCellEdit {
    let detection: DetectionRecord
    let image: ImageRecord
    var cells: [DetectedCell]
    var corrections: [CorrectionSpec]
    var revision: Int
}

@MainActor
private struct DecodedCellsCacheEntry {
    let revision: Int
    let cells: [DetectedCell]
}

@Observable
@MainActor
final class AppState {
    // Routing
    var view: AppView = .home

    /// Workspace lifetime follows the app, not the conditional navigation branch.
    /// Large decoded caches can therefore be trimmed deliberately instead of being
    /// destroyed and recreated every time the user checks another screen.
    @ObservationIgnored
    let workspaceSession = WorkspaceSession()

    let jobScheduler = AnalysisJobScheduler(store: AnalysisJobStore(
        url: FileStore.shared.root.appendingPathComponent("analysis-jobs.json")))
    var analysisSetupJobId: UUID?
    var isPreparingImport = false

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
    var pxPerUm: Double {
        didSet {
            guard !suppressDefaultsWriteback else { return }
            UserDefaults.standard.set(pxPerUm, forKey: "cc-pxperum")
        }
    }
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
    /// Small shared LRU for decoded detection payloads. The viewer, sidebar,
    /// and Review card previously decoded the same JSON independently.
    @ObservationIgnored private var decodedCellsCache: [UUID: DecodedCellsCacheEntry] = [:]
    @ObservationIgnored private var decodedCellsOrder: [UUID] = []
    @ObservationIgnored private var decodedCellsTasks: [UUID: (revision: Int, task: Task<[DetectedCell], Never>)] = [:]
    @ObservationIgnored private var pendingCellEdits: [UUID: PendingCellEdit] = [:]
    @ObservationIgnored private var pendingCellEditTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var calibrationTask: Task<Void, Error>?

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
        // Pass-15: default scale matches the seeded 10× preset (2.6 px/µm).
        // Existing users keep whatever `storedPx > 0` they had — only fresh
        // installs (storedPx == 0) pick up the new default.
        self.pxPerUm = storedPx > 0 ? storedPx : 2.6
        let storedConf = UserDefaults.standard.double(forKey: "cc-confidence")
        self.confidence = storedConf > 0 ? storedConf : 0.50
        // Explicit expected diameter defaults to 0 == "Auto" (bin-derived size
        // prior — current behavior). `UserDefaults.double` returns 0 for a
        // missing key, which is exactly the Auto default; only a value the user
        // explicitly set (> 0) overrides the sidecar's bin-derived prior.
        self.expectedDiameterUm = UserDefaults.standard.double(forKey: "cc-expected-diameter")
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
        self.overlayPalette = OverlayPalette.load()

        if let raw = UserDefaults.standard.string(forKey: "cc-model-filter"),
           let f = ModelFamily(rawValue: raw) {
            self.modelFilter = f
        }
        self.showOnboarding = !UserDefaults.standard.bool(forKey: "cc-onboarded")

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
        self.correctionsChangedObserver = NotificationCenter.default.addObserver(
            forName: .ccCorrectionsChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let delta = note.userInfo?["reviewDelta"] as? Int {
                    self.reviewQueueCount = max(0, self.reviewQueueCount + delta)
                } else {
                    self.reviewQueueCount = self.repos.pendingReviewCandidateCount()
                }
                // Cell edits can change the denormalized total in a recent row;
                // this is five lightweight batch reads, not a library scan.
                self.recentBatchSummaries = self.repos.recentBatchSummaries(limit: 5)
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.repos.rebuildPerformanceIndexes { [weak self] in
                guard let self else { return }
                self.reviewQueueCount = self.repos.pendingReviewCandidateCount()
                self.recentBatchSummaries = self.repos.recentBatchSummaries(limit: 5)
            }
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
        if storedPx > 0 && storedPx != pxPerUm { pxPerUm = storedPx }
        let storedConf = ud.double(forKey: "cc-confidence")
        if storedConf > 0 && storedConf != confidence { confidence = storedConf }
        // 0 is a valid value here ("Auto"), so compare with != rather than > 0 —
        // the user may reset an explicit diameter back to Auto from Settings.
        let storedDiam = ud.double(forKey: "cc-expected-diameter")
        if storedDiam != expectedDiameterUm { expectedDiameterUm = storedDiam }
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
        let storedPalette = OverlayPalette.load(defaults: ud)
        if storedPalette != overlayPalette { overlayPalette = storedPalette }
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
        guard let entry = decodedCellsCache[detection.id],
              entry.revision == detection.cellsRevision else { return nil }
        touchDecodedCellsCache(detection.id)
        return entry.cells
    }

    /// Decode a detection once off the MainActor and share the result between
    /// every Results/Review consumer. Concurrent requests coalesce onto the
    /// same task, and stale results are discarded if an edit lands meanwhile.
    func loadCells(for detection: DetectionRecord) async -> [DetectedCell] {
        if let cached = cachedCells(for: detection) { return cached }

        let id = detection.id
        let revision = detection.cellsRevision
        if let inFlight = decodedCellsTasks[id], inFlight.revision == revision {
            return await inFlight.task.value
        }

        decodedCellsTasks[id]?.task.cancel()
        let data = detection.cellsData
        let task: Task<[DetectedCell], Never> = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return [DetectedCell]() }
            return DetectionRecord.decodeCellsData(data)
        }
        decodedCellsTasks[id] = (revision, task)
        let cells = await task.value

        if decodedCellsTasks[id]?.revision == revision {
            decodedCellsTasks[id] = nil
        }
        if Task.isCancelled { return cells }
        guard detection.cellsRevision == revision else {
            return await loadCells(for: detection)
        }
        detection.cacheDecodedCells(cells, revision: revision)
        decodedCellsCache[id] = DecodedCellsCacheEntry(revision: revision, cells: cells)
        touchDecodedCellsCache(id)
        while decodedCellsOrder.count > 6 {
            let evicted = decodedCellsOrder.removeFirst()
            decodedCellsCache[evicted] = nil
        }
        return cells
    }

    private func touchDecodedCellsCache(_ id: UUID) {
        decodedCellsOrder.removeAll(where: { $0 == id })
        decodedCellsOrder.append(id)
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

    func processingDone() {
        view = .results
    }

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
            let pairs = await Task.detached(priority: .userInitiated) {
                supported.map { ($0, ImageLoader.sha256Hex(of: $0)) }
            }.value
            let existing = Dictionary(self.repos.allImages().compactMap { image -> (String, ImageRecord)? in
                guard let hash = image.fileHash else { return nil }
                return (hash, image)
            }, uniquingKeysWith: { first, _ in first })
            var hashes: [URL: String] = [:]
            var seen: Set<String> = []
            var unique: [URL] = []
            var duplicates: [DuplicateCandidate] = []
            for (url, hash) in pairs {
                if let hash {
                    hashes[url] = hash
                    if let image = existing[hash] { duplicates.append(.init(url: url, hash: hash, existingRecord: image)) }
                    if !seen.insert(hash).inserted { continue }
                }
                unique.append(url)
            }
            if duplicates.isEmpty {
                self.proceedWithImport(urls: unique, condition: condition, knownHashes: hashes)
            } else {
                self.pendingDuplicateSession = DuplicateImportSession(allURLs: unique, condition: condition,
                    duplicates: duplicates, onProceed: { [weak self] urls in
                        self?.proceedWithImport(urls: urls, condition: condition, knownHashes: hashes)
                    })
                self.showDuplicateImportSheet = true
            }
        }
        return nil
    }

    /// Create a durable draft and import the representative image. Inference is
    /// an explicit choice in AnalysisSetupSheet; native import needs no model.
    func proceedWithImport(urls: [URL], condition: String?, svc: DetectionService? = nil,
                           knownHashes: [URL: String] = [:]) {
        guard !urls.isEmpty else { return }
        let parentNames = Set(urls.map { $0.deletingLastPathComponent().lastPathComponent })
        let title = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent
            : (parentNames.count == 1 ? parentNames.first! : "Batch · \(urls.count) images · \(Self.shortDate())")
        let settings = AnalysisRunSettings.capture(state: self)
        let batch = repos.createBatch(displayName: title, modelId: settings.modelId,
                                      pxPerUm: settings.pxPerUm, thresholds: settings.thresholds, condition: condition)
        var job = AnalysisJob(batchId: batch.id, title: title, settings: settings,
                              items: urls.map { AnalysisJobItem(url: $0, knownHash: knownHashes[$0]) })
        job.settings.calibrationSource = "unconfirmed"
        currentBatchId = batch.id; currentImageIdx = 0
        refreshLibraryStats()
        Task { [weak self] in
            guard let self else { return }
            do {
                await self.jobScheduler.restore()
                try await self.jobScheduler.add(job)
                self.analysisSetupJobId = job.id
                if let first = job.items.first {
                    let imageId = try await self.jobScheduler.prepareSample(job.id, itemId: first.id)
                    if let image = self.repos.image(id: imageId), let px = image.sourcePxPerUm {
                        var calibrated = job.settings
                        calibrated.pxPerUm = px
                        calibrated.calibrationSource = image.sourceCalibrationSource ?? "metadata"
                        try await self.jobScheduler.updateDraft(job.id, settings: calibrated, preset: .countCells)
                        batch.pxPerUm = px; batch.pxPerUmSource = calibrated.calibrationSource
                        try self.repos.context.save()
                    }
                    // Keep the presenting screen stable while setup is open.
                    // Import already selected this batch/image; navigation is an
                    // explicit setup action, not a second layout during presentation.
                }
            } catch {
                self.lastDetectionError = error.localizedDescription; self.showDetectionError = true
            }
        }
    }

    func openAnalysisSetup(for batch: BatchRecord) {
        if let draft = jobScheduler.jobs.last(where: { $0.batchId == batch.id && $0.status == .draft }) {
            analysisSetupJobId = draft.id; return
        }
        if let active = jobScheduler.jobs.first(where: { $0.batchId == batch.id && [.running, .queued, .pausing].contains($0.status) }) {
            flashExport("Pause \(active.title) before changing its analysis setup.", isError: false)
            view = .queue; return
        }
        let sample = currentImage?.batch?.id == batch.id ? currentImage : orderedImages(in: batch).first
        var settings = sample?.detection?.runSettings ?? AnalysisRunSettings.capture(state: self)
        settings.pxPerUm = batch.pxPerUm; settings.calibrationSource = batch.pxPerUmSource ?? "manual"
        settings.thresholds = batch.thresholds
        let items = orderedImages(in: batch).map { image -> AnalysisJobItem in
            var item = AnalysisJobItem(url: image.storedURL, imageId: image.id, knownHash: image.fileHash, displayName: image.fileName)
            if image.detection?.runSettings?.hasSameInputs(as: settings) == true { item.status = .completed }
            return item
        }
        let job = AnalysisJob(batchId: batch.id, title: batch.displayName, settings: settings, items: items)
        Task { [weak self] in
            guard let self else { return }
            do { try await self.jobScheduler.add(job); self.analysisSetupJobId = job.id }
            catch { self.flashExport(error.localizedDescription, isError: true) }
        }
    }

    func commitAnalysisSetup(_ jobId: UUID) async throws {
        guard let job = jobScheduler.job(jobId), let batch = repos.batch(id: job.batchId) else { return }
        if let error = job.settings.validationError {
            throw NSError(domain: "AnalysisJobs", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
        try await recalibrateBatch(batch, pxPerUm: job.settings.pxPerUm, source: job.settings.calibrationSource)
        batch.modelId = job.settings.modelId
        batch.thresholds = job.settings.thresholds
        batch.contentRevision &+= 1
        try repos.context.save()
        NotificationCenter.default.post(name: .ccCorrectionsChanged, object: nil)
    }

    func jobStatus(for imageId: UUID) -> String? {
        for job in jobScheduler.jobs.reversed() {
            if let item = job.items.first(where: { $0.imageId == imageId }) {
                if jobScheduler.previewItemId == item.id { return "Running preview" }
                if item.status == .completed { return job.importOnly ? "Imported · ready to analyze" : "Analysis complete" }
                if item.status == .failed { return "Analysis failed · retry in Processing" }
                if job.status == .draft { return "Ready for preview" }
                return "\(job.status.title) · \(item.status.rawValue)"
            }
        }
        return nil
    }

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
            imported = try await ImageLoader.importVendorFile(url, precomputedHash: item.knownHash,
                interpreters: interpreters, zProjection: settings.zProjection)
        } else {
            imported = try await Task.detached(priority: .utility) {
                try ImageLoader.importFile(url, precomputedHash: item.knownHash)
            }.value
        }
        let image = imported.record
        // A queued source can be replaced between selection and preparation.
        // Verify the owned copy before trusting the original dedup identity.
        let copiedURL = image.storedURL
        let actualHash = await Task.detached(priority: .utility) { ImageLoader.sha256Hex(of: copiedURL) }.value ?? ""
        if actualHash.isEmpty || (item.knownHash != nil && item.knownHash != actualHash) {
            try? FileManager.default.removeItem(at: image.storedURL)
            try? FileManager.default.removeItem(at: image.thumbURL)
            if image.displayURL != image.storedURL { try? FileManager.default.removeItem(at: image.displayURL) }
            throw NSError(domain: "AnalysisJobs", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "The source changed after this job was created. Import it again to review the updated image."])
        }
        image.fileHash = actualHash
        image.sourcePxPerUm = imported.exifPxPerUm
        image.sourceCalibrationSource = imported.exifSource
        image.jobItemId = item.id
        image.sourceOrder = jobScheduler.jobs.first(where: { $0.batchId == batchId && $0.items.contains(where: { $0.id == item.id }) })?.items.firstIndex(where: { $0.id == item.id })
        repos.attach(image: image, to: batch, save: false)
        try repos.context.save()
        refreshLibraryStats()
        NotificationCenter.default.post(name: .ccLibraryChanged, object: nil)
        return image.id
    }

    private func analyzeJobImage(_ imageId: UUID, settings: AnalysisRunSettings) async throws {
        guard let image = repos.image(id: imageId) else { throw DetectionError.imageDecodeFailed }
        let svc: DetectionService
        if settings.modelId == EnsembleDownloader.modelId {
            guard let aId = settings.ensemblePrimaryId, let bId = settings.ensembleSecondaryId,
                  aId != bId, aId != settings.modelId, bId != settings.modelId,
                  let a = detectorRegistry.detector(for: aId, models: models),
                  let b = detectorRegistry.detector(for: bId, models: models) else {
                throw DetectionError.modelNotInstalled(modelId: "saved ensemble members")
            }
            svc = EnsembleDetectionService(primary: a, secondary: b, primaryModelId: aId, secondaryModelId: bId)
        } else {
            guard let selected = detectorRegistry.detector(for: settings.modelId, models: models) else {
                throw DetectionError.modelNotInstalled(modelId: settings.modelId)
            }
            svc = selected
        }
        if let sourcePx = image.sourcePxPerUm,
           settings.calibrationSource != "manual", settings.calibrationSource != "unconfirmed",
           abs(sourcePx - settings.pxPerUm) / settings.pxPerUm > 0.01 {
            throw NSError(domain: "AnalysisJobs", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "This image has a different pixel scale. Analyze it in a separate batch or explicitly confirm a manual scale."])
        }
        // Finish committed corrections before saving the previous mask variant.
        if let pending = pendingCellEditTasks[image.detection?.id ?? UUID()] { await pending.value }
        inFlightRerunImageIds.insert(imageId)
        defer { inFlightRerunImageIds.remove(imageId) }
        let source = settings.sourceURL(for: image)
        processingStageLine = "Preparing \(image.fileName)"; lastStageUpdateAt = Date()
        var recordedSettings = settings
        if let family = ModelFamily(rawValue: settings.modelFamily) {
            recordedSettings.detectorVersion = ProvenanceMetadata.detectorVersion(for: family)
            recordedSettings.weightsSHA256 = ProvenanceMetadata.weightsHash(for: family, modelId: settings.modelId)
        }
        let result = try await svc.detect(settings.detectionInput(imageURL: source))
        // Edits made while inference was running belong to the saved previous
        // variant. Drain them before replacing its detection record.
        while let detection = image.detection, let pending = pendingCellEditTasks[detection.id] {
            await pending.value
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        var measuredCells = result.cells
        if let scale = image.batch?.pxPerUm, scale > 0, scale != settings.pxPerUm {
            let ratio = settings.pxPerUm / scale
            for index in measuredCells.indices {
                measuredCells[index].diameter = measuredCells[index].diameterPx / scale
                measuredCells[index].centroidUmX = measuredCells[index].cx / scale
                measuredCells[index].centroidUmY = measuredCells[index].cy / scale
                if let area = measuredCells[index].areaMicrons2 { measuredCells[index].areaMicrons2 = area * ratio * ratio }
                if let perimeter = measuredCells[index].perimeterMicrons { measuredCells[index].perimeterMicrons = perimeter * ratio }
            }
        }
        // The model and run inputs are captured before awaiting inference.
        repos.saveDetection(measuredCells, detectorId: "\(type(of: svc))/\(settings.modelId)",
                            for: image, imageStats: result.imageStats, runSettings: recordedSettings, save: false)
        try repos.context.save()
        refreshLibraryStats()
        NotificationCenter.default.post(name: .ccCorrectionsChanged, object: nil)
    }

    /// Reanalysis is a durable one-image background job; navigation stays usable.
    func canRerunSavedImage(_ image: ImageRecord) -> Bool {
        let modelId = image.detection?.runSettings?.modelId ?? activeModelId
        return !isRerunning(image) && detectorRegistry.isInstalled(modelId, models: models)
    }

    func reRunDetection(on image: ImageRecord, useSavedSettings: Bool = false) {
        guard !isRerunning(image), let batch = image.batch,
              !jobScheduler.jobs.contains(where: { [.queued, .running, .pausing].contains($0.status) && $0.items.contains(where: { $0.imageId == image.id }) }) else { return }
        var settings = useSavedSettings ? (image.detection?.runSettings ?? AnalysisRunSettings.capture(state: self))
            : AnalysisRunSettings.capture(state: self)
        settings.pxPerUm = batch.pxPerUm; settings.calibrationSource = batch.pxPerUmSource ?? "manual"
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

    /// Convenience to record a correction against the current image's detection.
    func recordCorrection(kind: String, cellId: UUID, cx: Double, cy: Double, diameter: Double) {
        guard let image = currentImage, let det = image.detection else { return }
        let result = repos.commitCellEdit(
            cells: nil,
            corrections: [CorrectionSpec(kind: kind, cellId: cellId, cx: cx,
                                         cy: cy, diameter: diameter)],
            detection: det,
            image: image)
        postCorrectionsChanged(imageId: image.id, reviewDelta: result.reviewCountDelta)
    }

    /// Coalesce rapid overlay events, serialize the large JSON blob off-main,
    /// then commit the newest cell snapshot and every audit row together.
    /// This is the critical manual-edit fast path: pointer feedback is purely
    /// in-memory and no full detection encode/save/global recount runs inside
    /// the click or drag handler.
    func scheduleCellEdit(cells: [DetectedCell],
                          corrections: [CorrectionSpec],
                          detection: DetectionRecord,
                          image: ImageRecord) {
        let id = detection.id
        let nextRevision = (pendingCellEdits[id]?.revision ?? 0) &+ 1
        if var pending = pendingCellEdits[id] {
            pending.cells = cells
            pending.corrections.append(contentsOf: corrections)
            pending.revision = nextRevision
            pendingCellEdits[id] = pending
        } else {
            pendingCellEdits[id] = PendingCellEdit(
                detection: detection, image: image, cells: cells,
                corrections: corrections, revision: nextRevision)
        }

        pendingCellEditTasks[id]?.cancel()
        pendingCellEditTasks[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { return }
            guard let self, let pending = self.pendingCellEdits[id],
                  pending.revision == nextRevision else { return }

            let snapshotCells = pending.cells
            let storage = await Task.detached(priority: .userInitiated) {
                DetectionRecord.makeStorageSnapshot(snapshotCells)
            }.value
            guard !Task.isCancelled,
                  let latest = self.pendingCellEdits[id],
                  latest.revision == nextRevision else { return }

            let result = self.repos.commitCellEdit(
                storage: storage,
                corrections: latest.corrections,
                detection: latest.detection,
                image: latest.image)
            self.pendingCellEdits[id] = nil
            self.pendingCellEditTasks[id] = nil
            self.postCorrectionsChanged(imageId: latest.image.id,
                                        reviewDelta: result.reviewCountDelta)
        }
    }

    private func postCorrectionsChanged(imageId: UUID?, reviewDelta: Int) {
        NotificationCenter.default.post(
            name: .ccCorrectionsChanged,
            object: imageId,
            userInfo: ["reviewDelta": reviewDelta])
    }

    /// Delete every cell in `ids` from the current image's detection, persist,
    /// and record a "remove" correction per cell for the audit trail. The single
    /// owner of this mutation — both the Results keyboard shortcut and the editor
    /// toolbar's Remove override route through here so the two can't drift.
    /// Empty selection (or an empty intersection) is a no-op.
    func removeCells(_ ids: Set<UUID>) {
        guard !ids.isEmpty,
              let image = currentImage,
              let detection = image.detection else { return }
        var cells = detection.cells
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
              let detection = image.detection else { return }
        var cells = detection.cells
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
        let px = image.batch?.pxPerUm ?? pxPerUm
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
              let sourceDetection = sourceImage.detection else {
            return "Select one or more masks first."
        }
        let images = orderedImages(in: batch)
        guard let sourceFrame = images.firstIndex(where: { $0.id == sourceImage.id }),
              sourceFrame + 1 < images.count else {
            return "Open a frame that has later frames in this batch."
        }
        let sourceCells = sourceDetection.cells.filter { ids.contains($0.id) }
        guard !sourceCells.isEmpty else { return "The selected masks are no longer available." }

        var frames: [[DetectedCell]] = []
        for (index, image) in images.enumerated() {
            frames.append(image.detection?.cells ?? [])
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
        for frame in targetFrames {
            guard let additions = propagation.cellsByFrame[frame],
                  let detection = images[frame].detection else { continue }
            let image = images[frame]
            let px = image.batch?.pxPerUm ?? pxPerUm
            let calibrated = additions.filter {
                $0.cx >= 0 && $0.cy >= 0
                    && $0.cx < Double(image.widthPx) && $0.cy < Double(image.heightPx)
            }.map { cell -> DetectedCell in
                var cell = cell
                cell.centroidUmX = cell.cx / max(px, 0.000_001)
                cell.centroidUmY = cell.cy / max(px, 0.000_001)
                return cell
            }
            guard !calibrated.isEmpty else { continue }
            let result = repos.commitCellEdit(
                cells: detection.cells + calibrated,
                corrections: calibrated.map { CorrectionSpec(kind: "propagate", cell: $0) },
                detection: detection, image: image)
            reviewDelta += result.reviewCountDelta
            added += calibrated.count
            await Task.yield()
        }
        if added > 0 { postCorrectionsChanged(imageId: nil, reviewDelta: reviewDelta) }
        return added == 0
            ? "No masks added; nearby labels already cover the predicted positions."
            : "Propagated \(added) mask\(added == 1 ? "" : "s") across \(targetFrames.count) frame\(targetFrames.count == 1 ? "" : "s")."
    }

    /// Interpolate one selected anchor to the nearest matching mask in the
    /// final frame and fill only missing intermediate labels.
    func interpolateSelectedCellToLast(_ ids: Set<UUID>) async -> String {
        guard ids.count == 1, let selectedId = ids.first,
              let batch = currentBatch, let sourceImage = currentImage,
              let source = sourceImage.detection?.cells.first(where: { $0.id == selectedId }) else {
            return "Select exactly one anchor mask."
        }
        let images = orderedImages(in: batch)
        guard let start = images.firstIndex(where: { $0.id == sourceImage.id }),
              start + 1 < images.count,
              let endDetection = images.last?.detection else {
            return "This needs a later detected frame in the same batch."
        }
        let end = endDetection.cells.min {
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
        for frame in generated.keys.sorted() {
            guard let candidate = generated[frame], let detection = images[frame].detection else { continue }
            let conflict = detection.cells.contains {
                hypot($0.cx - candidate.cx, $0.cy - candidate.cy)
                    <= max(4, min($0.diameterPx, candidate.diameterPx) * 0.45)
            }
            guard !conflict else { continue }
            let result = repos.commitCellEdit(
                cells: detection.cells + [candidate],
                corrections: [CorrectionSpec(kind: "interpolate", cell: candidate)],
                detection: detection, image: images[frame])
            _ = result
            added += 1
            await Task.yield()
        }
        if added > 0 { postCorrectionsChanged(imageId: nil, reviewDelta: 0) }
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

    /// Maps a px/µm value to a human-readable objective label using the
    /// Olympus IX73 preset ladder (1.3 / 2.6 / 5.2 / 10.4 px/µm → 5× / 10× / 20× / 40×)
    /// with ±25% tolerance. Mirrors ScalePanel.objectiveLabel so the calibration
    /// toast and the scale panel agree on the objective string.
    static func objectiveLabel(for pxPerUm: Double) -> String {
        let presets: [(Double, String)] = [
            (1.3, "5×"), (2.6, "10×"), (5.2, "20×"), (10.4, "40×"),
        ]
        if let match = presets.first(where: { abs(pxPerUm - $0.0) / $0.0 < 0.25 }) {
            return "\(match.1) objective"
        }
        return "custom scale"
    }

    /// Apply a physical scale and recompute existing µm measurements from
    /// their pixel-space source values. This runs in yielding chunks so fixing
    /// calibration on a 700-image batch doesn't freeze the app.
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
        guard updateCurrentBatch, let batch = currentBatch else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.recalibrateBatch(batch, pxPerUm: newPxPerUm, source: source)
                self.lastCalibrationNote = String(format: "Calibration applied: %.5g px/µm (%@).", newPxPerUm, source)
            } catch { self.flashExport(error.localizedDescription, isError: true) }
        }
    }

    /// Serialize calibration requests and only apply a prepared snapshot if no
    /// correction arrived while it was encoded. Memory is bounded to one image.
    func recalibrateBatch(_ batch: BatchRecord, pxPerUm scale: Double, source: String) async throws {
        let previous = calibrationTask
        let task = Task { @MainActor in
            _ = try? await previous?.value
            guard scale.isFinite, scale > 0 else { return }
            let oldScale = batch.pxPerUm
            batch.pxPerUm = scale; batch.pxPerUmSource = source
            if oldScale != scale {
                for image in self.orderedImages(in: batch) {
                    while let detection = image.detection {
                        if let pending = self.pendingCellEditTasks[detection.id] { await pending.value; continue }
                        let revision = detection.cellsRevision
                        let cells = await self.loadCells(for: detection)
                        let snapshot = await Task.detached(priority: .utility) {
                            DetectionRecord.makeStorageSnapshot(Self.calibratedCells(cells, pxPerUm: scale, fallbackScale: oldScale))
                        }.value
                        guard image.detection?.id == detection.id,
                              detection.cellsRevision == revision,
                              self.pendingCellEditTasks[detection.id] == nil else { continue }
                        detection.applyStorageSnapshot(snapshot)
                        break
                    }
                }
            }
            batch.contentRevision &+= 1
            try self.repos.context.save()
            NotificationCenter.default.post(name: .ccCorrectionsChanged, object: nil)
        }
        calibrationTask = task
        try await task.value
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
