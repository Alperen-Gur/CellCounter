import Foundation

/// One process-wide budget for decoded contours. Retaining a cache on each
/// SwiftData record kept every processed image alive even after the UI's own
/// six-image cache evicted it. Records now share this strictly bounded LRU.
final class DecodedCellCache: @unchecked Sendable {
    static let shared = DecodedCellCache()

    private struct Entry {
        let revision: Int
        let cells: [DetectedCell]
        let bytes: Int
    }

    private let lock = NSLock()
    private let countLimit: Int
    private let byteLimit: Int
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var bytes = 0

    init(countLimit: Int = 6, byteLimit: Int = 64 * 1024 * 1024) {
        self.countLimit = max(0, countLimit)
        self.byteLimit = max(0, byteLimit)
    }

    func cells(for id: UUID, revision: Int) -> [DetectedCell]? {
        lock.withLock {
            guard let entry = entries[id], entry.revision == revision else { return nil }
            order.removeAll { $0 == id }
            order.append(id)
            return entry.cells
        }
    }

    func insert(_ cells: [DetectedCell], for id: UUID, revision: Int) {
        let cost = Self.estimatedBytes(cells)
        lock.withLock {
            removeLocked(id)
            // Oversized detections are still returned to the active consumer;
            // they simply do not occupy a second, long-lived cache slot.
            guard countLimit > 0, cost <= byteLimit else { return }
            while order.count >= countLimit || bytes > byteLimit - cost {
                guard let oldest = order.first else { break }
                removeLocked(oldest)
            }
            entries[id] = Entry(revision: revision, cells: cells, bytes: cost)
            order.append(id)
            bytes += cost
        }
    }

    func remove(_ id: UUID) { lock.withLock { removeLocked(id) } }

    var retainedCount: Int { lock.withLock { entries.count } }
    var retainedBytes: Int { lock.withLock { bytes } }

    private func removeLocked(_ id: UUID) {
        if let entry = entries.removeValue(forKey: id) { bytes -= entry.bytes }
        order.removeAll { $0 == id }
    }

    static func estimatedBytes(_ cells: [DetectedCell]) -> Int {
        cells.reduce(cells.count * MemoryLayout<DetectedCell>.stride) { total, cell in
            let channels = cell.channelIntensities?.reduce(0) { bytes, channel in
                bytes + MemoryLayout<ChannelIntensity>.stride + (channel.name?.utf8.count ?? 0)
            } ?? 0
            return total + (cell.contourPx?.count ?? 0) * MemoryLayout<CGPoint>.stride + channels
        }
    }
}
