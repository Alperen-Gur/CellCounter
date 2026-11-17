import Foundation

// Small, pure decisions shared by the Results viewer, its sidebar and the
// per-image assay panels. They are kept apart from the views so the tests can
// exercise them without SwiftUI or SwiftData.

// MARK: — Overlay resync

/// What the Results canvas last prepared: the inputs it was prepared from
/// (`preparation.revision` is the detection's `cellsRevision`) and the
/// canvas's own edit counter right after that preparation.
nonisolated struct ResultsOverlaySyncState: Hashable, Sendable {
    let preparation: ReviewDataKey
    let liveRevision: Int
}

nonisolated enum ResultsOverlaySyncPolicy {
    /// True when a resync would rebuild exactly what the canvas already shows:
    /// same image, detection, cell revision, cutoff, ROIs and calibration, no
    /// unsaved local edit since, and no failed load waiting for a retry.
    static func canSkip(current: ResultsOverlaySyncState,
                        synced: ResultsOverlaySyncState?,
                        loadedCellsMatch: Bool,
                        hasLoadError: Bool) -> Bool {
        guard let synced, loadedCellsMatch, !hasLoadError else { return false }
        return synced == current
    }

    /// Whether a `ccCorrectionsChanged` notification can be about `imageId`:
    /// a broadcast (nil object) or that image's id. Any other object is about
    /// another image.
    static func concerns(_ object: Any?, imageId: UUID) -> Bool {
        guard let object else { return true }
        return (object as? UUID) == imageId
    }
}

// MARK: — Assay result invalidation

/// The image and detection revision an assay result was computed from.
nonisolated struct AssayDetectionStamp: Hashable, Sendable {
    let imageId: UUID
    let detectionId: UUID?
    let cellsRevision: Int

    init(imageId: UUID, detectionId: UUID?, cellsRevision: Int) {
        self.imageId = imageId
        self.detectionId = detectionId
        self.cellsRevision = cellsRevision
    }

    @MainActor init(_ image: ImageRecord) {
        self.init(imageId: image.id, detectionId: image.detection?.id,
                  cellsRevision: image.detection?.cellsRevision ?? 0)
    }
}

nonisolated enum AssayResultInvalidation {
    /// Whether a `ccCorrectionsChanged` notification must drop a result.
    ///
    /// - `object` is an image id: only when it is the result's own image.
    /// - Otherwise (a broadcast): only when the result's image is the open
    ///   one (`current` is non-nil and has the same image id) and its
    ///   detection id or revision has moved. When the open image is another
    ///   one, the result is already hidden, and it is shown again only if its
    ///   stamp still matches when the user returns (see `isCurrent`).
    static func shouldClear(object: Any?, result: AssayDetectionStamp?,
                            current: AssayDetectionStamp?) -> Bool {
        guard let result else { return false }
        if let imageId = object as? UUID { return imageId == result.imageId }
        guard let current, current.imageId == result.imageId else { return false }
        return current != result
    }

    /// A result is shown only against the detection revision it came from.
    static func isCurrent(result: AssayDetectionStamp?, current: AssayDetectionStamp?) -> Bool {
        result != nil && result == current
    }
}

// MARK: — Memoization

/// One-entry memo: the value is recomputed only when the key changes.
/// Held by a view in `@State` (a reference), so filling it while SwiftUI
/// evaluates `body` does not invalidate the view.
nonisolated final class KeyedMemo<Key: Equatable, Value> {
    private var entry: (key: Key, value: Value)?
    private(set) var computeCount = 0

    func value(for key: Key, compute: () -> Value) -> Value {
        if let entry, entry.key == key { return entry.value }
        let value = compute()
        entry = (key, value)
        computeCount += 1
        return value
    }
}

/// Identifies one filtered cell array handed to the sidebar panels. The
/// sidebar's `ReviewDataKey` fixes the array; the count and end ids are a
/// cheap guard against a caller passing a different array with that key.
nonisolated struct ResultsCellsIdentity: Hashable, Sendable {
    let revision: ReviewDataKey
    let count: Int
    let firstId: UUID?
    let lastId: UUID?

    /// Nil when there is no revision to vouch for `cells`; callers then
    /// compute directly instead of memoizing.
    init?(revision: ReviewDataKey?, cells: [DetectedCell]) {
        guard let revision else { return nil }
        self.revision = revision
        count = cells.count
        firstId = cells.first?.id
        lastId = cells.last?.id
    }
}

/// Decoded forms of a detection's small JSON blobs, memoized on the exact
/// bytes (plus the other inputs) so a changed blob is always decoded again,
/// whatever its revision. Keeps the per-render JSON decode out of the
/// Results viewer's cell binding, the sidebar and the assay panels.
@MainActor
final class ResultsDerivedValues {
    static let shared = ResultsDerivedValues()

    /// Every input `AppState.effectiveConfidence(for:)` reads. Keep in step
    /// with that function if it ever reads more.
    private struct ConfidenceInputs: Equatable {
        let override: Double?
        let runSettingsData: Data?
        let globalConfidence: Double
    }

    private var confidence: [UUID: (inputs: ConfidenceInputs, value: Double)] = [:]
    private var stats: [UUID: (data: Data?, value: [String: Double])] = [:]
    private let entryLimit = 64

    /// Same value as `state.effectiveConfidence(for: image)`.
    func effectiveConfidence(for image: ImageRecord, state: AppState) -> Double {
        let inputs = ConfidenceInputs(override: image.confidenceOverride,
                                      runSettingsData: image.detection?.runSettingsData,
                                      globalConfidence: state.confidence)
        if let cached = confidence[image.id], cached.inputs == inputs { return cached.value }
        let value = state.effectiveConfidence(for: image)
        if confidence.count >= entryLimit { confidence.removeAll(keepingCapacity: true) }
        confidence[image.id] = (inputs, value)
        return value
    }

    /// Same value as `detection.imageStats`.
    func imageStats(of detection: DetectionRecord?) -> [String: Double] {
        guard let detection else { return [:] }
        let data = detection.imageStatsData
        if let cached = stats[detection.id], cached.data == data { return cached.value }
        let value = detection.imageStats
        if stats.count >= entryLimit { stats.removeAll(keepingCapacity: true) }
        stats[detection.id] = (data, value)
        return value
    }
}
