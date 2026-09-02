import Foundation
import Testing
@testable import CellCounting

@MainActor
struct WorkspaceLineagePerformanceTests {
    @Test func spatialMatcherMatchesDeterministicExhaustiveGreedyResult() async throws {
        let first = [
            point("00000000-0000-0000-0000-000000000001", x: 0, y: 0),
            point("00000000-0000-0000-0000-000000000002", x: 0.2, y: 0),
            point("00000000-0000-0000-0000-000000000003", x: 10, y: 10),
            point("00000000-0000-0000-0000-000000000004", x: -8, y: 4),
        ]
        let second = [
            point("00000000-0000-0000-0000-000000000011", x: 0.1, y: 0),
            point("00000000-0000-0000-0000-000000000012", x: 0.4, y: 0),
            point("00000000-0000-0000-0000-000000000013", x: 11, y: 10),
            point("00000000-0000-0000-0000-000000000014", x: 100, y: 100),
        ]
        let third = [
            point("00000000-0000-0000-0000-000000000021", x: 0.2, y: 0.1),
            point("00000000-0000-0000-0000-000000000022", x: 0.5, y: 0.1),
            point("00000000-0000-0000-0000-000000000023", x: 11.5, y: 10),
        ]
        let recorder = LineageProgressRecorder()

        let result = try await WorkspaceLineageService.build(
            frames: [
                WorkspaceLineageFrame(frame: 2, points: third),
                WorkspaceLineageFrame(frame: 0, points: first),
                WorkspaceLineageFrame(frame: 1, points: second),
            ],
            maxDistancePixels: 2
        ) { update in
            await recorder.append(update)
        }

        let expected01 = exhaustiveGreedy(parents: first, children: second,
                                          maximumDistance: 2)
        let expected12 = exhaustiveGreedy(parents: second, children: third,
                                          maximumDistance: 2)
        let expected = Set(expected01 + expected12)
        #expect(sourceEdges(in: result.graph) == expected)
        #expect(result.graph.validationIssues().isEmpty)
        #expect(result.statistics.nodeCount == first.count + second.count + third.count)
        #expect(result.statistics.edgeCount == expected.count)
        #expect(result.statistics.frameTransitions == 2)
        let progress = await recorder.values
        #expect(progress.map(\.completedTransitions) == [1, 2])
        #expect(progress.last?.linkedObservations == expected.count)
    }

    @Test func spatialWorkScalesWithLocalDensityRatherThanFrameProduct() async throws {
        let pointsPerFrame = 4_096
        let frameCount = 4
        let frames = (0..<frameCount).map { frame in
            WorkspaceLineageFrame(frame: frame, points: (0..<pointsPerFrame).map { index in
                let column = index % 64
                let row = index / 64
                return WorkspacePoint(
                    coordinate: WorkspaceCoordinate(
                        x: Double(column * 8) + Double(frame) * 0.2,
                        y: Double(row * 8) + Double(frame) * 0.15))
            })
        }

        let result = try await WorkspaceLineageService.build(
            frames: frames, maxDistancePixels: 2)
        let transitions = frameCount - 1
        let exhaustivePairCount = transitions * pointsPerFrame * pointsPerFrame

        #expect(result.graph.edges.count == transitions * pointsPerFrame)
        #expect(result.statistics.collisionRetries == 0)
        #expect(result.statistics.distanceEvaluations <= transitions * pointsPerFrame * 2)
        #expect(result.statistics.distanceEvaluations * 1_000 < exhaustivePairCount)
        #expect(result.graph.validationIssues().isEmpty)
    }

    @Test func buildCooperativelyCancelsLargeJobs() async {
        let pointCount = 80_000
        let points = (0..<pointCount).map { index in
            WorkspacePoint(coordinate: WorkspaceCoordinate(
                x: Double(index % 400), y: Double(index / 400)))
        }
        let frames = [
            WorkspaceLineageFrame(frame: 0, points: points),
            WorkspaceLineageFrame(frame: 1, points: points),
        ]
        let task = Task.detached {
            try await WorkspaceLineageService.build(frames: frames, maxDistancePixels: 3)
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("A cancelled lineage build should not return a partial graph")
        } catch is CancellationError {
            // Expected: cancellation is surfaced rather than returning partial data.
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }
    }

    @Test func invalidDistanceIsRejectedBeforeWorkBegins() async {
        do {
            _ = try await WorkspaceLineageService.build(
                frames: [], maxDistancePixels: .infinity)
            Issue.record("An infinite distance must be rejected")
        } catch let error as WorkspaceLineageBuildError {
            #expect(error == .invalidMaximumDistance)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func point(_ id: String, x: Double, y: Double) -> WorkspacePoint {
        WorkspacePoint(id: UUID(uuidString: id)!, coordinate: .init(x: x, y: y))
    }

    private func exhaustiveGreedy(
        parents: [WorkspacePoint],
        children: [WorkspacePoint],
        maximumDistance: Double
    ) -> [LineageSourceEdge] {
        struct Candidate {
            let distanceSquared: Double
            let parent: Int
            let child: Int
        }
        let maximumSquared = maximumDistance * maximumDistance
        var candidates: [Candidate] = []
        for parent in parents.indices {
            for child in children.indices {
                let dx = parents[parent].coordinate.x - children[child].coordinate.x
                let dy = parents[parent].coordinate.y - children[child].coordinate.y
                let distanceSquared = dx * dx + dy * dy
                if distanceSquared <= maximumSquared {
                    candidates.append(Candidate(distanceSquared: distanceSquared,
                                                parent: parent, child: child))
                }
            }
        }
        candidates.sort {
            if $0.distanceSquared != $1.distanceSquared {
                return $0.distanceSquared < $1.distanceSquared
            }
            if $0.parent != $1.parent { return $0.parent < $1.parent }
            return $0.child < $1.child
        }
        var usedParents = Set<Int>()
        var usedChildren = Set<Int>()
        var matches: [LineageSourceEdge] = []
        for candidate in candidates
        where !usedParents.contains(candidate.parent) && !usedChildren.contains(candidate.child) {
            usedParents.insert(candidate.parent)
            usedChildren.insert(candidate.child)
            matches.append(LineageSourceEdge(parent: parents[candidate.parent].id,
                                             child: children[candidate.child].id))
        }
        return matches
    }

    private func sourceEdges(in graph: WorkspaceLineageGraph) -> Set<LineageSourceEdge> {
        let sources = Dictionary(uniqueKeysWithValues: graph.nodes.compactMap { node in
            node.sourceCellID.map { (node.id, $0) }
        })
        return Set(graph.edges.compactMap { edge in
            guard let parent = sources[edge.parentID], let child = sources[edge.childID] else {
                return nil
            }
            return LineageSourceEdge(parent: parent, child: child)
        })
    }
}

private struct LineageSourceEdge: Hashable {
    let parent: UUID
    let child: UUID
}

private actor LineageProgressRecorder {
    private(set) var values: [WorkspaceLineageBuildProgress] = []

    func append(_ value: WorkspaceLineageBuildProgress) {
        values.append(value)
    }
}
