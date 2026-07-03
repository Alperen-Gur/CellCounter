import SwiftUI
import Observation
import AppKit
import UniformTypeIdentifiers
import SwiftData

enum AppView: String, Hashable, CaseIterable {
    case home, processing, results, batch, models, fineTune, settings, queue, reviewQueue, compare, imagesLibrary
}

@Observable
@MainActor
final class AppState {
    // Routing
    var view: AppView = .home

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
    private(set) var recentBatchIds: [UUID] = []
    private(set) var reviewQueueCount: Int = 0

    /// Confidence cutoff used for the Review queue badge count. Kept here so the
    /// notification listener and the on-launch refresh agree on the threshold.
    private static let reviewQueueConfidenceCutoff: Double = 0.65

    /// Recompute the cached library stats from `repos`. Cheap (SwiftData fetches
    /// are not expensive at our scale) and called only on mutation triggers.
    func refreshLibraryStats() {
        libraryImageCount = repos.totalImageCount()
        libraryBatchCount = repos.totalBatchCount()
        recentBatchIds = repos.allBatches().map(\.id)
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
            UserDefaults.standard.set(currentBatchId?.uuidString, forKey: "cc-current-batch")
        }
    }
    /// Index into the current batch's images that Results is showing.
    var currentImageIdx: Int = 0

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
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshLibraryStats() }
        }
        self.libraryChangedObserver = NotificationCenter.default.addObserver(
            forName: .ccLibraryChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshLibraryStats() }
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
    }

    // MARK: — Convenience

    var currentBatch: BatchRecord? {
        guard let id = currentBatchId else { return nil }
        return repos.batch(id: id)
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
        let images = batch.images.sorted(by: { $0.importedAt < $1.importedAt })
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
        return confidence
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
    /// main thread at app launch — that's the 10s spinner the user saw.
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
        // Even if the cache says .installed, double-check the venv for
        // cellpose-family ids — the cache may be stale after a Finder-side
        // delete that hasn't been observed yet. The next async probe will
        // overwrite if needed.
        if let info = models.first(where: { $0.id == id }),
           info.family == .cellpose,
           case .installed = cached {
            // Spot-check the venv directory synchronously. This is a cheap
            // filesystem stat, not a subprocess.
            let venv = FileStore.shared.pythonVenvDir
            let sentinel = FileStore.shared.installIncompleteSentinel
            if !FileManager.default.fileExists(atPath: venv.path) {
                activeModelInstallState = .notInstalled
                installStateCache.refresh(modelId: id,
                                          registry: detectorRegistry,
                                          models: models)
                return
            }
        }
        // Pass-16: same spot-check for `.cellpose4` against venv4.
        if let info = models.first(where: { $0.id == id }),
           info.family == .cellpose4,
           case .installed = cached {
            let venv4 = FileStore.shared.pythonVenv4Dir
            if !FileManager.default.fileExists(atPath: venv4.path) {
                activeModelInstallState = .notInstalled
                installStateCache.refresh(modelId: id,
                                          registry: detectorRegistry,
                                          models: models)
                return
            }
        }
        if let info = models.first(where: { $0.id == id }),
           info.family == .cellpose,
           case .installed = cached {
            let sentinel = FileStore.shared.installIncompleteSentinel
            // Pass-13: a leftover install-incomplete sentinel beats whatever the
            // cache says — the previous run crashed or was cancelled before
            // cellpose finished installing. Mark broken here so views (Models
            // banner, Toolbar pill) downgrade immediately, then kick the
            // async probe to overwrite once the deep check finishes.
            if FileManager.default.fileExists(atPath: sentinel.path) {
                let reason = "Previous install was cancelled or crashed mid-flight."
                activeModelInstallState = .broken(reason: reason)
                installStateCache.markBroken(id, reason: reason)
                installStateCache.refresh(modelId: id,
                                          registry: detectorRegistry,
                                          models: models)
                return
            }
        }
        activeModelInstallState = cached
        // If the cache hasn't resolved yet, ask it to. This is idempotent.
        if case .unknown = cached {
            installStateCache.refresh(modelId: id,
                                      registry: detectorRegistry,
                                      models: models)
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
        guard !supported.isEmpty else { return nil }

        // Pass-8: resolve the detector up front. If nothing is installed for the
        // active model id, surface a user-visible error and abort — no batch is
        // created, no mock detection is run.
        guard let svc = detectorRegistry.detector(for: activeModelId, models: models) else {
            lastDetectionError = "No detector available for \(activeModelName). Install the model first."
            showDetectionError = true
            return nil
        }

        // Pass-17: compute hashes off-main, then check for duplicates on main.
        // We do this before creating a batch so no phantom batch is created.
        let reposRef = repos
        Task { [weak self] in
            guard let self else { return }

            // Hash all files off-main (detached so we don't block MainActor).
            let hashPairs: [(URL, String?)] = await Task.detached(priority: .userInitiated) {
                supported.map { url in (url, ImageLoader.sha256Hex(of: url)) }
            }.value

            // Back on main: check each hash against the store.
            let dupes: [DuplicateCandidate] = hashPairs.compactMap { (url, hash) in
                guard let hash, !hash.isEmpty else { return nil }
                guard let existing = reposRef.imageRecord(matchingHash: hash,
                                                           fileName: url.lastPathComponent) else {
                    return nil
                }
                return DuplicateCandidate(url: url, hash: hash, existingRecord: existing)
            }

            // Reuse the hashes we just computed so the import pipeline doesn't
            // read + SHA-256 every file a second time (audit: double-hash-per-import).
            var knownHashes: [URL: String] = [:]
            for (url, hash) in hashPairs {
                if let hash, !hash.isEmpty { knownHashes[url] = hash }
            }

            if !dupes.isEmpty {
                // Present the sheet — block the import until user decides.
                self.pendingDuplicateSession = DuplicateImportSession(
                    allURLs: supported,
                    condition: condition,
                    duplicates: dupes,
                    onProceed: { [weak self] urlsToImport in
                        self?.proceedWithImport(urls: urlsToImport, condition: condition, svc: svc, knownHashes: knownHashes)
                    }
                )
                self.showDuplicateImportSheet = true
            } else {
                // No duplicates — proceed immediately.
                self.proceedWithImport(urls: supported, condition: condition, svc: svc, knownHashes: knownHashes)
            }
        }

        // Return nil here — the batch ID is not yet known; the caller should
        // observe `currentBatchId` instead. The batch is created inside proceedWithImport.
        return nil
    }

    /// Internal: actually creates the batch and runs the import/detect pipeline.
    /// Called either directly (no duplicates) or from the duplicate sheet's confirm action.
    func proceedWithImport(urls: [URL], condition: String?, svc: DetectionService, knownHashes: [URL: String] = [:]) {
        guard !urls.isEmpty else { return }

        let displayName = urls.count == 1
            ? urls[0].deletingPathExtension().lastPathComponent
            : "Batch · \(urls.count) images · \(Self.shortDate())"
        let batch = repos.createBatch(displayName: displayName,
                                       modelId: activeModelId,
                                       pxPerUm: pxPerUm,
                                       thresholds: thresholds,
                                       condition: condition)
        currentBatchId = batch.id
        currentImageIdx = 0
        processingProgress = 0
        processingStageLine = ""
        processingDevice = ""
        lastStageUpdateAt = Date()
        view = .processing

        // Pass-10: honour Settings → "Max parallel images". The loop ran one-at-a-time
        // before. Now we process up to `parallelism` images concurrently using a
        // TaskGroup, which respects the user's memory/perf preference.
        let parallelism = max(1, maxParallel)

        Task { [weak self] in
            guard let self else { return }
            var anyImported = false
            var lastError: String? = nil
            var finished = 0

            // Pass-6 C1: derive size-class thresholds from the user's bin breakpoints.
            let smallT = self.thresholds.first ?? 20
            let largeT = self.thresholds.last ?? 30
            // Snapshot scalar settings that the worker tasks need. Capturing
            // `self.useGPU` etc. inside the group would force MainActor hops.
            let pxPerUmSnap = self.pxPerUm
            let confSnap = self.confidence
            let channelsSnap = self.channels.asArray
            let bgSnap = self.backgroundSubtract
            let rollSnap = self.rollingBallRadius
            let wsSnap = self.watershedSplit
            let wsdSnap = self.watershedMinDistanceUm
            let modelIdSnap = self.activeModelId
            let useGPUSnap = self.useGPU
            let svcRef = svc
            let knownHashesSnap = knownHashes

            // Pass-17 Lane C: collect EXIF px/µm from each import result so we
            // can auto-apply a batch-level calibration when all images agree.
            var collectedExifPxPerUm: [Double] = []

            await withTaskGroup(of: (URL, Swift.Result<DetectionResult, Error>?, ImageRecord?, Double?, Error?).self) { group in
                var iterator = urls.makeIterator()
                var inFlight = 0

                func dispatch(url: URL) {
                    group.addTask {
                        do {
                            let imported = try await Task.detached(priority: .utility) {
                                try ImageLoader.importFile(url, precomputedHash: knownHashesSnap[url])
                            }.value
                            let input = DetectionInput(imageURL: imported.record.storedURL,
                                                       modelId: modelIdSnap,
                                                       pxPerUm: pxPerUmSnap,
                                                       confidenceThreshold: confSnap,
                                                       channels: channelsSnap,
                                                       backgroundSubtract: bgSnap,
                                                       rollingBallRadius: rollSnap,
                                                       watershedSplit: wsSnap,
                                                       watershedMinDistance: wsdSnap,
                                                       smallThreshold: smallT,
                                                       largeThreshold: largeT,
                                                       useGPU: useGPUSnap)
                            do {
                                let r = try await svcRef.detect(input)
                                return (url, .success(r), imported.record, imported.exifPxPerUm, nil)
                            } catch {
                                return (url, .failure(error), imported.record, imported.exifPxPerUm, nil)
                            }
                        } catch {
                            return (url, nil, nil, nil, error)
                        }
                    }
                }

                // Seed up to `parallelism` tasks
                while inFlight < parallelism, let next = iterator.next() {
                    dispatch(url: next)
                    inFlight += 1
                }

                while let result = await group.next() {
                    inFlight -= 1
                    let (url, detResult, importedRecord, exifPx, importError) = result
                    if let importError {
                        lastError = importError.localizedDescription
                        NSLog("CellCounter import failed for %@: %@",
                              url.lastPathComponent, importError.localizedDescription)
                    } else if let imported = importedRecord {
                        self.repos.attach(image: imported, to: batch)
                        anyImported = true
                        // Accumulate EXIF px/µm values.
                        if let px = exifPx { collectedExifPxPerUm.append(px) }
                        switch detResult {
                        case .success(let r):
                            self.repos.saveDetection(r.cells,
                                                     detectorId: "\(type(of: svcRef))/\(modelIdSnap)",
                                                     for: imported,
                                                     imageStats: r.imageStats)
                        case .failure(let err):
                            // Pass-13: don't surface user-initiated cancels as
                            // failures. They produce exit code 15/9 which
                            // CellposeDetectionService now translates to
                            // DetectionError.cancelled.
                            if case DetectionError.cancelled = err {
                                NSLog("CellCounter detection cancelled for %@", url.lastPathComponent)
                            } else {
                                lastError = err.localizedDescription
                                NSLog("CellCounter detection failed for %@: %@",
                                      url.lastPathComponent, err.localizedDescription)
                            }
                        case .none:
                            break
                        }
                        // Pass-11: refresh @Observable library stats so the
                        // Sidebar counts, Home Recents, and Review badge update
                        // live as each image finishes importing/detecting.
                        self.refreshLibraryStats()
                    }
                    finished += 1
                    self.processingProgress = Double(finished) / Double(urls.count)

                    if let next = iterator.next() {
                        dispatch(url: next)
                        inFlight += 1
                    }
                }
            }

            // Pass-17 Lane C: apply EXIF-derived calibration to this batch if:
            //  • EVERY imported image reported EXIF calibration (no un-calibrated
            //    image silently inheriting a scale it never carried), AND
            //  • they all returned the SAME px/µm value (within 0.1%), AND
            //  • that value differs from the user's current global by > 5%
            if !collectedExifPxPerUm.isEmpty,
               collectedExifPxPerUm.count == urls.count {
                let allSame = collectedExifPxPerUm.allSatisfy {
                    abs($0 - collectedExifPxPerUm[0]) / collectedExifPxPerUm[0] < 0.001
                }
                if allSame {
                    let exifPx = collectedExifPxPerUm[0]
                    let diffFraction = abs(exifPx - pxPerUmSnap) / max(pxPerUmSnap, 0.001)
                    if diffFraction > 0.05 {
                        // Apply to THIS batch only — global state.pxPerUm is untouched.
                        batch.pxPerUm = exifPx
                        NSLog("[EXIFCalibration] Applied %.4f px/µm to batch (was %.4f, diff %.1f%%)",
                              exifPx, pxPerUmSnap, diffFraction * 100)

                        // Build the objective label (mirrors ScalePanel.objectiveLabel).
                        let objLabel = Self.objectiveLabel(for: exifPx)
                        let noteText = String(format: "Calibrated from image metadata: %.2f px/µm (%@).",
                                              exifPx, objLabel)
                        self.lastCalibrationNote = noteText
                        // Auto-dismiss after 5 s.
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            guard let self else { return }
                            if self.lastCalibrationNote == noteText {
                                withAnimation { self.lastCalibrationNote = nil }
                            }
                        }
                    }
                }
            }

            if let lastError {
                self.lastDetectionError = lastError
                self.showDetectionError = true
            }
            if anyImported {
                self.processingDone()
            } else {
                self.view = .home
            }

            // Pass-12: don't leave an empty `BatchRecord` behind when every
            // import failed (unsupported format, decode error, detector throw
            // before any attach). Without this, the sidebar shows a phantom
            // batch with 0 images, and Recents renders a "0 cells · 0 images"
            // row that — pre-fix — routed into Results and rendered the
            // procedural ghost strip.
            if batch.images.isEmpty {
                self.repos.deleteBatch(batch)
                if self.currentBatchId == batch.id {
                    self.currentBatchId = nil
                }
                NotificationCenter.default.post(
                    name: .ccLibraryChanged, object: nil)
            }
        }
    }

    /// Pass-8: re-run detection for a single already-imported image. Used by the
    /// "Re-run detection" button in ResultsView when the original run failed.
    ///
    /// Pass-13: also drives the ProcessingView so the user sees a progress
    /// indicator instead of clicking the button and watching nothing happen.
    /// The view flips back to .results when the detection lands (or fails).
    func reRunDetection(on image: ImageRecord) {
        // Pass-14: idempotent guard. The Re-run button + DetectionFailedBanner
        // can both fire `onRerun` in the same tick (button double-tap, or a
        // SwiftUI onChange storm during view transitions). Each extra call
        // spawned a fresh cellpose subprocess; the Cancel button then SIGTERM'd
        // every tracked process in a tight loop, producing three back-to-back
        // "detection cancelled" log lines. One in-flight task per image only.
        if inFlightRerunImageIds.contains(image.id) {
            NSLog("[AppState] reRunDetection ignored — already running for image \(image.id)")
            return
        }
        guard let svc = detectorRegistry.detector(for: activeModelId, models: models) else {
            lastDetectionError = "No detector available for \(activeModelName). Install the model first."
            showDetectionError = true
            return
        }
        inFlightRerunImageIds.insert(image.id)
        let smallT = self.thresholds.first ?? 20
        let largeT = self.thresholds.last ?? 30
        let input = DetectionInput(imageURL: image.storedURL,
                                    modelId: activeModelId,
                                    pxPerUm: pxPerUm,
                                    confidenceThreshold: confidence,
                                    channels: channels.asArray,
                                    backgroundSubtract: backgroundSubtract,
                                    rollingBallRadius: rollingBallRadius,
                                    watershedSplit: watershedSplit,
                                    watershedMinDistance: watershedMinDistanceUm,
                                    smallThreshold: smallT,
                                    largeThreshold: largeT,
                                    useGPU: useGPU)
        let returnView = self.view
        processingProgress = 0
        processingStageLine = ""
        processingDevice = ""
        lastStageUpdateAt = Date()
        view = .processing
        let rerunImageId = image.id
        Task { [weak self] in
            guard let self else { return }
            // Pass-14: clear the in-flight marker on every exit path. `defer`
            // inside a Task is fine — the cleanup runs whether the detect()
            // call returns normally, throws, or is cancelled.
            defer { self.inFlightRerunImageIds.remove(rerunImageId) }
            do {
                let result = try await svc.detect(input)
                self.repos.saveDetection(result.cells,
                                          detectorId: "\(type(of: svc))/\(self.activeModelId)",
                                          for: image,
                                          imageStats: result.imageStats)
                NotificationCenter.default.post(name: .ccCorrectionsChanged, object: nil)
                self.processingProgress = 1
                self.view = .results
            } catch {
                // Pass-13: swallow user-initiated cancels — no banner needed.
                if case DetectionError.cancelled = error {
                    self.view = returnView
                } else {
                    self.lastDetectionError = error.localizedDescription
                    self.showDetectionError = true
                    self.view = returnView
                }
            }
        }
    }

    // MARK: — Open existing batch (from Recent rows / Batches view)

    func openBatch(_ batch: BatchRecord) {
        currentBatchId = batch.id
        currentImageIdx = 0
        view = .results
    }

    // MARK: — Corrections

    /// Convenience to record a correction against the current image's detection.
    func recordCorrection(kind: String, cellId: UUID, cx: Double, cy: Double, diameter: Double) {
        guard let det = currentImage?.detection else { return }
        repos.recordCorrection(
            CorrectionRecord(kind: kind, cellId: cellId, cx: cx, cy: cy, diameter: diameter),
            on: det)
        NotificationCenter.default.post(name: .ccCorrectionsChanged, object: nil)
    }

    /// Delete every cell in `ids` from the current image's detection, persist,
    /// and record a "remove" correction per cell for the audit trail. The single
    /// owner of this mutation — both the Results keyboard shortcut and the editor
    /// toolbar's Remove override route through here so the two can't drift.
    /// Empty selection (or an empty intersection) is a no-op.
    func removeCells(_ ids: Set<UUID>) {
        guard !ids.isEmpty,
              let detection = currentImage?.detection else { return }
        let victims = detection.cells.filter { ids.contains($0.id) }
        guard !victims.isEmpty else { return }
        detection.cells.removeAll { ids.contains($0.id) }
        try? repos.context.save()
        for c in victims {
            recordCorrection(kind: "remove", cellId: c.id,
                             cx: c.cx, cy: c.cy, diameter: c.diameter)
        }
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
}
