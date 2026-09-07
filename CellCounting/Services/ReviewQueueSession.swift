import Foundation
import Observation

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

    init?(_ candidate: ReviewCandidateRecord) {
        guard let detection = candidate.detection,
              let image = candidate.image,
              let batch = image.batch,
              image.detection?.id == detection.id else { return nil }
        id = candidate.id
        position = ReviewQueuePosition(candidate)
        self.candidate = candidate
        cell = candidate.fallbackCell
        self.image = image
        self.detection = detection
        pxPerUm = batch.pxPerUm
        batchName = batch.displayName
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
        // A deleted/orphaned image must not strand navigation before the next
        // valid page. Only one page of model references is retained at a time.
        repeat {
            let rows = repos.pendingReviewCandidates(
                limit: Self.pageSize, after: pageStart, includingBoundary: includeStart)
            pageEnd = rows.last.map(ReviewQueuePosition.init)
            items = rows.compactMap(ReviewItem.init)
            if !items.isEmpty || rows.count < Self.pageSize { return }
            pageStart = pageEnd
            includeStart = false
        } while pageEnd != nil
    }
}
