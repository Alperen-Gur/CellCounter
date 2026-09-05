import Foundation
import ImageIO

nonisolated enum AnalysisJobStatus: String, Codable, Sendable {
    case draft, queued, running, pausing, paused, completed, failed, cancelled
    var title: String { rawValue.capitalized }
}
nonisolated enum AnalysisItemStatus: String, Codable, Sendable {
    case pending, preparing, ready, running, completed, failed
}
nonisolated struct AnalysisJobItem: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var displayName: String?
    var sourcePath: String
    var sourceBookmark: Data?
    var knownHash: String?
    var imageId: UUID?
    var status: AnalysisItemStatus = .pending
    var error: String?
    var duration: Double?
    var estimatedBytes: Int64 = 0
    var fileName: String { displayName ?? URL(fileURLWithPath: sourcePath).lastPathComponent }

    init(url: URL, imageId: UUID? = nil, knownHash: String? = nil, displayName: String? = nil) {
        self.displayName = displayName
        sourcePath = url.path
        self.imageId = imageId
        self.knownHash = knownHash
        sourceBookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        estimatedBytes = Int64(bytes)
        // Compressed file size alone is not a memory estimate. For ordinary
        // images use all source planes/channels; unknown vendor stacks disable
        // look-ahead until a reader supplies a trustworthy estimate.
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Int,
           let height = props[kCGImagePropertyPixelHeight] as? Int {
            let planes = max(1, CGImageSourceGetCount(source))
            let estimate = Double(width) * Double(height) * Double(planes) * 8
            estimatedBytes = estimate.isFinite && estimate < Double(Int64.max)
                ? max(estimatedBytes, Int64(estimate)) : Int64.max
        } else { estimatedBytes = 0 }
        status = imageId == nil ? .pending : .ready
    }

    func resolvedURL() throws -> URL {
        guard let sourceBookmark else { return URL(fileURLWithPath: sourcePath) }
        var stale = false
        return try URL(resolvingBookmarkData: sourceBookmark, options: [.withSecurityScope],
                       relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
nonisolated struct AnalysisJob: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var batchId: UUID
    var title: String
    var createdAt = Date()
    var updatedAt = Date()
    var status: AnalysisJobStatus = .draft
    var settings: AnalysisRunSettings
    var items: [AnalysisJobItem]
    var importOnly = false
    var taskPreset: AnalysisTaskPreset = .countCells
    var error: String?
    var completedCount: Int { items.filter { $0.status == .completed }.count }
    var failedCount: Int { items.filter { $0.status == .failed }.count }
    var progress: Double { items.isEmpty ? 0 : Double(completedCount + failedCount) / Double(items.count) }
    var estimatedRemainingSeconds: Double? {
        // Exclude the first cold model/image load from the steady-state estimate.
        let durations = items.compactMap(\.duration).filter { $0 > 0 && $0.isFinite }
        guard durations.count >= 2 else { return nil }
        let warm = Array(durations.dropFirst().suffix(8))
        return warm.reduce(0, +) / Double(warm.count) * Double(items.count - completedCount - failedCount)
    }
    mutating func recoverAfterLaunch() {
        if [.running, .pausing, .queued].contains(status) { status = .paused }
        for index in items.indices where [.running, .preparing].contains(items[index].status) {
            items[index].status = items[index].imageId == nil ? .pending : .ready
        }
    }
    mutating func retryFailures() {
        for index in items.indices where items[index].status == .failed {
            items[index].status = items[index].imageId == nil ? .pending : .ready
            items[index].error = nil
        }
        status = .queued; error = nil
    }
}

/// CPU preparation overlaps a single model execution only when its estimated
/// working set fits. The model stays serial to avoid duplicate GPU allocation.
nonisolated enum AnalysisSchedulingPolicy {
    static func preparationBudget(physicalMemory: UInt64) -> UInt64 {
        min(512 * 1_024 * 1_024, max(32 * 1_024 * 1_024, physicalMemory / 16))
    }
    static func canPrepareAhead(currentBytes: Int64, nextBytes: Int64,
                                physicalMemory: UInt64, maxParallel: Int) -> Bool {
        guard maxParallel > 1, currentBytes > 0, nextBytes > 0 else { return false }
        let (sum, overflow) = UInt64(currentBytes).addingReportingOverflow(UInt64(nextBytes))
        let (estimate, multiplyOverflow) = sum.multipliedReportingOverflow(by: 16)
        return !overflow && !multiplyOverflow && estimate <= preparationBudget(physicalMemory: physicalMemory)
    }
}
