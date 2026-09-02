import Foundation

/// An immutable snapshot of the detections belonging to one acquisition frame.
/// Multiple snapshots with the same frame number are coalesced in input order.
nonisolated struct WorkspaceLineageFrame: Sendable {
    let frame: Int
    let points: [WorkspacePoint]

    init(frame: Int, points: [WorkspacePoint]) {
        self.frame = frame
        self.points = points
    }
}

nonisolated struct WorkspaceLineageBuildProgress: Equatable, Sendable {
    let completedTransitions: Int
    let totalTransitions: Int
    let linkedObservations: Int
}

/// Deterministic work counters make lineage performance testable without relying
/// on machine-dependent wall-clock thresholds.
nonisolated struct WorkspaceLineageBuildStatistics: Equatable, Sendable {
    fileprivate(set) var nodeCount = 0
    fileprivate(set) var edgeCount = 0
    fileprivate(set) var frameTransitions = 0
    fileprivate(set) var gridBucketCount = 0
    fileprivate(set) var distanceEvaluations = 0
    fileprivate(set) var heapPushes = 0
    fileprivate(set) var heapPops = 0
    fileprivate(set) var collisionRetries = 0
    fileprivate(set) var skippedNonFinitePoints = 0
}

nonisolated struct WorkspaceLineageBuildResult: Sendable {
    let graph: WorkspaceLineageGraph
    let statistics: WorkspaceLineageBuildStatistics
}

nonisolated enum WorkspaceLineageBuildError: LocalizedError, Equatable {
    case invalidMaximumDistance

    var errorDescription: String? {
        switch self {
        case .invalidMaximumDistance:
            return "The lineage matching distance must be finite and greater than zero."
        }
    }
}

/// Builds consecutive-frame lineages off the main actor.
///
/// The matcher preserves global distance-ordered greedy semantics without
/// materializing every parent/child pair. A spatial grid finds each parent's
/// closest currently available child, while a min-heap chooses the globally
/// closest proposal. When two parents propose the same child, only the losing
/// parent is queried again.
nonisolated enum WorkspaceLineageService {
    typealias ProgressHandler = @Sendable (WorkspaceLineageBuildProgress) async -> Void

    nonisolated static func build(
        frames: [WorkspaceLineageFrame],
        maxDistancePixels: Double,
        progress: ProgressHandler? = nil
    ) async throws -> WorkspaceLineageBuildResult {
        guard maxDistancePixels.isFinite, maxDistancePixels > 0 else {
            throw WorkspaceLineageBuildError.invalidMaximumDistance
        }
        try Task.checkCancellation()

        let normalizedFrames = coalesced(frames)
        var statistics = WorkspaceLineageBuildStatistics()
        statistics.frameTransitions = max(0, normalizedFrames.count - 1)

        var nodes: [WorkspaceLineageNode] = []
        nodes.reserveCapacity(normalizedFrames.reduce(0) { $0 + $1.points.count })
        var nodeIDsByFrame: [[UUID]] = []
        nodeIDsByFrame.reserveCapacity(normalizedFrames.count)

        for snapshot in normalizedFrames {
            try Task.checkCancellation()
            var nodeIDs: [UUID] = []
            nodeIDs.reserveCapacity(snapshot.points.count)
            for (pointIndex, point) in snapshot.points.enumerated() {
                if pointIndex & 1_023 == 0 { try Task.checkCancellation() }
                let node = WorkspaceLineageNode(
                    frame: snapshot.frame,
                    coordinate: point.coordinate,
                    sourceCellID: point.id,
                    label: point.label,
                    features: point.features)
                nodes.append(node)
                nodeIDs.append(node.id)
            }
            nodeIDsByFrame.append(nodeIDs)
        }
        statistics.nodeCount = nodes.count

        var edges: [WorkspaceLineageEdge] = []
        if normalizedFrames.count > 1 {
            let likelyEdgeCount = normalizedFrames.dropLast().reduce(0) { partial, frame in
                partial + frame.points.count
            }
            edges.reserveCapacity(likelyEdgeCount)
        }

        for transition in 0..<statistics.frameTransitions {
            try Task.checkCancellation()
            let parents = normalizedFrames[transition].points
            let children = normalizedFrames[transition + 1].points
            let grid = SpatialGrid(points: children, cellSize: maxDistancePixels,
                                   statistics: &statistics)
            var usedParents = [Bool](repeating: false, count: parents.count)
            var usedChildren = [Bool](repeating: false, count: children.count)
            var proposals = CandidateHeap()
            proposals.reserveCapacity(parents.count)

            for parentIndex in parents.indices {
                if parentIndex & 255 == 0 { try Task.checkCancellation() }
                if let candidate = try nearestCandidate(
                    parentIndex: parentIndex,
                    parent: parents[parentIndex],
                    children: children,
                    grid: grid,
                    usedChildren: usedChildren,
                    maximumDistanceSquared: maxDistancePixels * maxDistancePixels,
                    statistics: &statistics) {
                    proposals.push(candidate)
                    statistics.heapPushes += 1
                }
            }

            while let candidate = proposals.pop() {
                statistics.heapPops += 1
                if statistics.heapPops & 1_023 == 0 { try Task.checkCancellation() }
                guard !usedParents[candidate.parentIndex] else { continue }
                if usedChildren[candidate.childIndex] {
                    statistics.collisionRetries += 1
                    if let replacement = try nearestCandidate(
                        parentIndex: candidate.parentIndex,
                        parent: parents[candidate.parentIndex],
                        children: children,
                        grid: grid,
                        usedChildren: usedChildren,
                        maximumDistanceSquared: maxDistancePixels * maxDistancePixels,
                        statistics: &statistics) {
                        proposals.push(replacement)
                        statistics.heapPushes += 1
                    }
                    continue
                }

                usedParents[candidate.parentIndex] = true
                usedChildren[candidate.childIndex] = true
                edges.append(WorkspaceLineageEdge(
                    parentID: nodeIDsByFrame[transition][candidate.parentIndex],
                    childID: nodeIDsByFrame[transition + 1][candidate.childIndex],
                    kind: .continuation))
            }

            statistics.edgeCount = edges.count
            if let progress {
                await progress(WorkspaceLineageBuildProgress(
                    completedTransitions: transition + 1,
                    totalTransitions: statistics.frameTransitions,
                    linkedObservations: edges.count))
            }
            await Task.yield()
        }

        try Task.checkCancellation()
        statistics.edgeCount = edges.count
        return WorkspaceLineageBuildResult(
            graph: WorkspaceLineageGraph(nodes: nodes, edges: edges),
            statistics: statistics)
    }

    private nonisolated static func coalesced(
        _ frames: [WorkspaceLineageFrame]
    ) -> [WorkspaceLineageFrame] {
        let ordered = frames.enumerated().sorted {
            if $0.element.frame != $1.element.frame {
                return $0.element.frame < $1.element.frame
            }
            return $0.offset < $1.offset
        }
        var result: [WorkspaceLineageFrame] = []
        var currentFrame: Int?
        var currentPoints: [WorkspacePoint] = []
        for item in ordered {
            if currentFrame != item.element.frame {
                if let currentFrame {
                    result.append(WorkspaceLineageFrame(frame: currentFrame,
                                                        points: currentPoints))
                }
                currentFrame = item.element.frame
                currentPoints = item.element.points
            } else {
                currentPoints.append(contentsOf: item.element.points)
            }
        }
        if let currentFrame {
            result.append(WorkspaceLineageFrame(frame: currentFrame, points: currentPoints))
        }
        return result
    }

    private nonisolated static func nearestCandidate(
        parentIndex: Int,
        parent: WorkspacePoint,
        children: [WorkspacePoint],
        grid: SpatialGrid,
        usedChildren: [Bool],
        maximumDistanceSquared: Double,
        statistics: inout WorkspaceLineageBuildStatistics
    ) throws -> Candidate? {
        guard parent.coordinate.x.isFinite, parent.coordinate.y.isFinite,
              let center = GridKey(coordinate: parent.coordinate, cellSize: grid.cellSize) else {
            statistics.skippedNonFinitePoints += 1
            return nil
        }

        var best: Candidate?
        for yOffset: Int64 in -1...1 {
            let (y, yOverflow) = center.y.addingReportingOverflow(yOffset)
            guard !yOverflow else { continue }
            for xOffset: Int64 in -1...1 {
                let (x, xOverflow) = center.x.addingReportingOverflow(xOffset)
                guard !xOverflow else { continue }
                for childIndex in grid.buckets[GridKey(x: x, y: y), default: []] {
                    guard !usedChildren[childIndex] else { continue }
                    statistics.distanceEvaluations += 1
                    if statistics.distanceEvaluations & 2_047 == 0 {
                        try Task.checkCancellation()
                    }
                    let child = children[childIndex]
                    let dx = parent.coordinate.x - child.coordinate.x
                    let dy = parent.coordinate.y - child.coordinate.y
                    let distanceSquared = dx * dx + dy * dy
                    guard distanceSquared <= maximumDistanceSquared else { continue }
                    let candidate = Candidate(parentIndex: parentIndex,
                                              childIndex: childIndex,
                                              distanceSquared: distanceSquared)
                    if best == nil || candidate.isOrdered(before: best!) { best = candidate }
                }
            }
        }
        return best
    }
}

private nonisolated struct GridKey: Hashable, Sendable {
    let x: Int64
    let y: Int64

    init(x: Int64, y: Int64) {
        self.x = x
        self.y = y
    }

    init?(coordinate: WorkspaceCoordinate, cellSize: Double) {
        let gridX = floor(coordinate.x / cellSize)
        let gridY = floor(coordinate.y / cellSize)
        guard gridX.isFinite, gridY.isFinite,
              gridX >= Double(Int64.min), gridX <= Double(Int64.max),
              gridY >= Double(Int64.min), gridY <= Double(Int64.max) else { return nil }
        self.x = Int64(gridX)
        self.y = Int64(gridY)
    }
}

private nonisolated struct SpatialGrid: Sendable {
    let cellSize: Double
    let buckets: [GridKey: [Int]]

    init(points: [WorkspacePoint], cellSize: Double,
         statistics: inout WorkspaceLineageBuildStatistics) {
        self.cellSize = cellSize
        var storage: [GridKey: [Int]] = [:]
        storage.reserveCapacity(points.count)
        for (index, point) in points.enumerated() {
            if let key = GridKey(coordinate: point.coordinate, cellSize: cellSize) {
                storage[key, default: []].append(index)
            } else {
                statistics.skippedNonFinitePoints += 1
            }
        }
        statistics.gridBucketCount += storage.count
        self.buckets = storage
    }
}

private nonisolated struct Candidate: Sendable {
    let parentIndex: Int
    let childIndex: Int
    let distanceSquared: Double

    func isOrdered(before other: Candidate) -> Bool {
        if distanceSquared != other.distanceSquared {
            return distanceSquared < other.distanceSquared
        }
        if parentIndex != other.parentIndex { return parentIndex < other.parentIndex }
        return childIndex < other.childIndex
    }
}

private nonisolated struct CandidateHeap: Sendable {
    private var storage: [Candidate] = []

    mutating func reserveCapacity(_ capacity: Int) {
        storage.reserveCapacity(capacity)
    }

    mutating func push(_ candidate: Candidate) {
        storage.append(candidate)
        var child = storage.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard storage[child].isOrdered(before: storage[parent]) else { break }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Candidate? {
        guard !storage.isEmpty else { return nil }
        if storage.count == 1 { return storage.removeLast() }
        let minimum = storage[0]
        storage[0] = storage.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1
            guard left < storage.count else { break }
            let right = left + 1
            let child = right < storage.count && storage[right].isOrdered(before: storage[left])
                ? right : left
            guard storage[child].isOrdered(before: storage[parent]) else { break }
            storage.swapAt(parent, child)
            parent = child
        }
        return minimum
    }
}
