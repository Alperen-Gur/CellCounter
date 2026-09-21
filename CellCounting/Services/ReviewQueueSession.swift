import Foundation
import Observation
import SwiftData

struct ReviewQueuePosition: Equatable {
    let confidence: Double
    let sortKey: String

    init(_ candidate: ReviewCandidateRecord) {
        confidence = candidate.confidence
        sortKey = candidate.sortKey
    }
}

struct ReviewItem: Identifiable {
    let id: UUID
    let position: ReviewQueuePosition
    let candidate: ReviewCandidateRecord
    let cell: DetectedCell
    let image: ImageRecord
    let detection: DetectionRecord
    let pxPerUm: Double
    let batchName: String
    // View and image-loader inputs remain usable during deletion animations.
    let fileName: String
    let widthPx: Int
    let heightPx: Int
    let displayURL: URL
    let thumbURL: URL

    var confidenceFraction: Double? {
        guard cell.confidence.isFinite else { return nil }
        return min(1, max(0, cell.confidence))
    }

    var confidenceLabel: String {
        confidenceFraction.map { "\(Int($0 * 100))%" } ?? "Invalid confidence"
    }

    var hasValidGeometry: Bool {
        widthPx > 0 && heightPx > 0 &&
        cell.cx.isFinite && cell.cy.isFinite &&
        cell.cx >= 0 && cell.cy >= 0 &&
        cell.cx <= Double(widthPx) && cell.cy <= Double(heightPx) &&
        cell.diameter.isFinite && cell.diameter > 0 &&
        cell.diameterPx.isFinite && cell.diameterPx > 0 &&
        cell.diameterPx <= Double(max(widthPx, heightPx)) * 2 &&
        (cell.diameter * pxPerUm).isFinite &&
        pxPerUm.isFinite && pxPerUm > 0
    }

    var diameterEditRange: ClosedRange<Double> {
        let diameter = cell.diameter.isFinite && cell.diameter > 0 ? cell.diameter : 1
        // Submicron cells previously formed an inverted 2...(<2) range,
        // which traps as soon as the diameter editor is rendered.
        let lower = min(diameter, max(0.01, diameter * 0.3))
        return lower...max(diameter, min(Double.greatestFiniteMagnitude, diameter * 2.5))
    }

    var hasLiveOwners: Bool {
        !candidate.isDeleted && candidate.modelContext != nil &&
        !image.isDeleted && image.modelContext != nil &&
        !detection.isDeleted && detection.modelContext != nil
    }

    var hasCurrentCalibration: Bool {
        guard hasLiveOwners, let batch = image.batch,
              !batch.isDeleted, batch.modelContext != nil else { return false }
        return batch.pxPerUm == pxPerUm
    }

    init?(_ candidate: ReviewCandidateRecord, image: ImageRecord, detection: DetectionRecord) {
        // Resolve owners by their scalar IDs in Repositories. Old index rows
        // can retain relationship faults after their owners were deleted.
        guard !candidate.isDeleted, candidate.modelContext != nil,
              !image.isDeleted, image.modelContext != nil,
              !detection.isDeleted, detection.modelContext != nil,
              let batch = image.batch, !batch.isDeleted, batch.modelContext != nil,
              image.id == candidate.imageId,
              detection.id == candidate.detectionId,
              image.detection?.id == detection.id else { return nil }
        id = candidate.id
        position = ReviewQueuePosition(candidate)
        self.candidate = candidate
        cell = candidate.fallbackCell
        self.image = image
        self.detection = detection
        pxPerUm = batch.pxPerUm
        batchName = batch.displayName
        fileName = image.fileName
        widthPx = image.widthPx
        heightPx = image.heightPx
        displayURL = image.displayURL
        thumbURL = image.thumbURL
    }
}

/// A bounded window over the persistent queue. Moving past a page uses its
/// last stable sort key, so skipped cells neither loop back nor hide later
/// pages. Skipping never changes persisted review state.
@Observable @MainActor
final class ReviewQueueSession {
    static let pageSize = 96
    private(set) var items: [ReviewItem] = []
    private(set) var cursor = 0
    private(set) var skippedCount = 0
    private(set) var errorMessage: String?
    private var pageStart: ReviewQueuePosition?
    private var includeStart = false
    private var pageEnd: ReviewQueuePosition?

    var current: ReviewItem? { items.indices.contains(cursor) ? items[cursor] : nil }

    func reload(using repos: Repositories, preservingCurrent: Bool = false) {
        if preservingCurrent, let current {
            pageStart = current.position
            includeStart = true
        } else if !preservingCurrent {
            pageStart = nil
            includeStart = false
            skippedCount = 0
        }
        load(using: repos)
    }

    func skip(using repos: Repositories) {
        guard current != nil else { return }
        skippedCount += 1
        cursor += 1
        if cursor >= items.count { nextPage(using: repos) }
    }

    func remove(_ id: UUID, using repos: Repositories) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        if index < cursor { cursor -= 1 }
        if cursor >= items.count { nextPage(using: repos) }
    }

    func restore(_ candidate: ReviewCandidateRecord, using repos: Repositories) {
        // Seek directly to the restored cell, including it in the result. It
        // can belong to an earlier page and need not be in the first 96 rows.
        pageStart = ReviewQueuePosition(candidate)
        includeStart = true
        load(using: repos)
    }

    private func nextPage(using repos: Repositories) {
        guard let pageEnd else { items = []; cursor = 0; return }
        pageStart = pageEnd
        includeStart = false
        load(using: repos)
    }

    private func load(using repos: Repositories) {
        cursor = 0
        errorMessage = nil
        // A deleted/orphaned image must not strand navigation before the next
        // valid page. Only one page of model references is retained at a time.
        do {
            // Even a damaged legacy index must not trap the main actor in an
            // unbounded scan or repeat the same cursor indefinitely.
            for _ in 0..<32 {
                let rows = try repos.pendingReviewCandidates(
                    limit: Self.pageSize, after: pageStart, includingBoundary: includeStart)
                let end = rows.last.map(ReviewQueuePosition.init)
                let loaded = try repos.reviewItems(for: rows)
                pageEnd = end
                items = loaded
                if !items.isEmpty || rows.count < Self.pageSize { return }
                guard end != pageStart else { break }
                pageStart = end
                includeStart = false
            }
            errorMessage = "The review index contains stale entries. Close and reopen CellCounter to finish repairing it, then retry."
        } catch {
            errorMessage = "Could not load the review queue: \(error.localizedDescription)"
        }
        items = []
    }
}
