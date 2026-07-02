import Foundation
import Combine

/// Live progress for a model download / install. The Models UI observes this.
enum ModelInstallStage: Equatable {
    case notStarted
    case checkingDependencies
    case downloading(progress: Double, bytesPerSec: Int64?)  // progress in [0, 1]
    case installingDependencies(line: String)                 // pip / brew progress line
    case verifying
    case ready
    case failed(String)
}

@MainActor
final class ModelInstallProgress: ObservableObject, @unchecked Sendable {
    @Published var stage: ModelInstallStage = .notStarted
    @Published var lastLogLines: [String] = []      // last ~20 lines for the inline UI
    let modelId: String
    init(modelId: String) { self.modelId = modelId }

    func append(_ line: String) {
        lastLogLines.append(line)
        if lastLogLines.count > 20 { lastLogLines.removeFirst(lastLogLines.count - 20) }
    }
}

/// One per family. Knows how to download weights, verify, and produce a DetectionService.
///
/// `isInstalled(modelId:)` MUST be non-blocking — file existence checks and
/// cache lookups only. NO subprocess invocations. The slow truth-check (e.g.
/// `python -c "import cellpose"`) belongs in `probeInstalled(modelId:)` which
/// the cache calls off the main thread.
protocol ModelDownloader: Sendable {
    /// What "family" of model this downloader serves.
    var family: ModelFamily { get }

    /// Non-blocking, main-thread-safe answer based on cached/cheap signals.
    /// Used during view body evaluation; never spawns a Process.
    func isInstalled(modelId: String) -> Bool

    /// Deep async probe — may spawn subprocesses. Always runs off the MainActor.
    /// The cache layer (`InstallStateCache`) is the only routine caller.
    func probeInstalled(modelId: String) async -> Bool

    /// Download + install whatever's needed for `modelId`. Reports progress via `progress`.
    /// Throws on user cancellation or unrecoverable errors.
    func install(modelId: String, progress: ModelInstallProgress) async throws

    /// Remove all on-disk artifacts for this model.
    @MainActor func uninstall(modelId: String) throws

    /// On-disk size of the installed artifacts (0 if not installed).
    @MainActor func diskUsageBytes(modelId: String) -> Int64

    /// Return a configured DetectionService for this model id, or nil if not installed.
    @MainActor func detector(for modelId: String) -> DetectionService?
}

/// Central lookup. AppState holds one of these.
@MainActor
final class DetectorRegistry: ObservableObject {
    private var downloaders: [ModelFamily: any ModelDownloader] = [:]
    /// Live install progress objects, keyed by modelId.
    @Published var installs: [String: ModelInstallProgress] = [:]
    /// Optional cache hook — set by AppState so the registry can flip the cache
    /// state to .installing when an install kicks off and refresh it on
    /// completion. Weak so the cache's lifecycle isn't tied to the registry's.
    weak var installStateCache: InstallStateCache?

    init() {}

    /// Register a family-specific downloader. Called from `AppState.init` after
    /// the M1–M4 agent files declare them.
    func register(_ downloader: any ModelDownloader) {
        downloaders[downloader.family] = downloader
    }

    /// Resolve a `DetectionService` for a model id, or `nil` when the model isn't
    /// installed (or its family has no registered downloader). There is no mock
    /// fallback — callers must handle `nil` and surface an error.
    func detector(for modelId: String, models: [DetectionModelInfo]) -> DetectionService? {
        guard let info = models.first(where: { $0.id == modelId }),
              let dl = downloaders[info.family],
              let service = dl.detector(for: modelId) else {
            return nil
        }
        return service
    }

    /// Cheap, main-safe install check. Defers to each downloader's
    /// non-blocking `isInstalled` (file existence + cached probe results).
    func isInstalled(_ modelId: String, models: [DetectionModelInfo]) -> Bool {
        guard let info = models.first(where: { $0.id == modelId }),
              let dl = downloaders[info.family] else { return false }
        return dl.isInstalled(modelId: modelId)
    }

    /// Deep async probe — calls the downloader's off-main `probeInstalled`.
    /// Used by `InstallStateCache.refresh(...)`. Never invoked from `body`.
    /// The `family` parameter lets us avoid sending the full `[DetectionModelInfo]`
    /// array across actor boundaries.
    func probeInstalled(_ modelId: String, models: [DetectionModelInfo]) async -> Bool {
        // Resolve the downloader on the MainActor (cheap dict lookup), then
        // jump off to do the deep probe.
        guard let info = models.first(where: { $0.id == modelId }),
              let dl = downloaders[info.family] else { return false }
        // `probeInstalled` is intentionally non-isolated; the implementations
        // hop to detached tasks for the actual subprocess work.
        return await dl.probeInstalled(modelId: modelId)
    }

    /// Kicks off installation in the background; returns the progress object the UI
    /// can subscribe to. Idempotent — calling twice for the same id returns the same handle.
    @discardableResult
    func install(_ modelId: String, models: [DetectionModelInfo]) -> ModelInstallProgress {
        if let existing = installs[modelId] { return existing }
        let progress = ModelInstallProgress(modelId: modelId)
        installs[modelId] = progress
        guard let info = models.first(where: { $0.id == modelId }),
              let dl = downloaders[info.family] else {
            progress.stage = .failed("Unknown model family")
            return progress
        }
        installStateCache?.markInstalling(modelId)
        Task { [weak self] in
            defer {
                // Always re-probe so the cache reflects truth — whether the
                // install succeeded, failed, or was cancelled.
                if let self {
                    self.installStateCache?.refresh(modelId: modelId,
                                                    registry: self,
                                                    models: models)
                }
            }
            do {
                progress.stage = .checkingDependencies
                try await dl.install(modelId: modelId, progress: progress)
                progress.stage = .ready
            } catch is CancellationError {
                progress.stage = .failed("Cancelled")
            } catch {
                progress.stage = .failed(error.localizedDescription)
            }
        }
        return progress
    }

    func uninstall(_ modelId: String, models: [DetectionModelInfo]) throws {
        guard let info = models.first(where: { $0.id == modelId }),
              let dl = downloaders[info.family] else { return }
        try dl.uninstall(modelId: modelId)
        installs[modelId] = nil
    }

    func diskUsageBytes(_ modelId: String, models: [DetectionModelInfo]) -> Int64 {
        guard let info = models.first(where: { $0.id == modelId }),
              let dl = downloaders[info.family] else { return 0 }
        return dl.diskUsageBytes(modelId: modelId)
    }
}
