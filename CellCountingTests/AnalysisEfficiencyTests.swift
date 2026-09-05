import Foundation
import SwiftUI
import Testing
@testable import CellCounting

struct AnalysisEfficiencyTests {
    @Test func elongatedContoursRemainVisibleAndPickableBeyondEquivalentDiameter() {
        let elongated = DetectedCell(cx: 500, cy: 10, diameter: 50, diameterPx: 50,
                                     contourPx: [CGPoint(x: 0, y: 0), CGPoint(x: 1000, y: 0),
                                                 CGPoint(x: 1000, y: 20), CGPoint(x: 0, y: 20)])
        let cells = [elongated]
        let index = CellSpatialIndex(cells: cells)
        #expect(index.query(CGRect(x: 940, y: 5, width: 10, height: 10)).indices == [0])
        #expect(index.hitIndex(at: CGPoint(x: 950, y: 10), cells: cells,
                              outline: false, manualRadius: 7) == 0)
        #expect(index.hitIndex(at: CGPoint(x: 950, y: 30), cells: cells,
                              outline: false, manualRadius: 7) == nil)
    }

    @Test func pickingUsesExactConcaveShapeDrawOrderAndFixedMarkerSize() {
        let polygon = [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 20, y: 4),
                       CGPoint(x: 4, y: 4), CGPoint(x: 4, y: 20), CGPoint(x: 0, y: 20)]
        let a = DetectedCell(cx: 10, cy: 10, diameter: 30, diameterPx: 30, contourPx: polygon)
        let pin = DetectedCell(cx: 50, cy: 50, diameter: 100, diameterPx: 100, isManual: true)
        let b = DetectedCell(cx: 2, cy: 2, diameter: 2, diameterPx: 2)
        let cells = [a, pin, b]
        let index = CellSpatialIndex(cells: cells)
        #expect(index.hitIndex(at: CGPoint(x: 15, y: 15), cells: cells,
                              outline: false, manualRadius: 7) == nil)
        #expect(index.hitIndex(at: CGPoint(x: 2, y: 2), cells: cells,
                              outline: false, manualRadius: 7) == 2)
        #expect(index.hitIndex(at: CGPoint(x: 56, y: 50), cells: cells,
                              outline: false, manualRadius: 7) == 1)
        #expect(index.hitIndex(at: CGPoint(x: 56, y: 50), cells: cells,
                              outline: false, manualRadius: 3.5) == nil)
        #expect(index.hitIndex(at: CGPoint(x: 80, y: 50), cells: cells,
                              outline: false, manualRadius: 7) == nil)
    }

    @Test func denseViewportQueriesExamineOnlyLocalEntriesAndKeepManualOrdinals() {
        var cells: [DetectedCell] = []
        cells.reserveCapacity(40_000)
        for offset in 0..<40_000 {
            let x = Double(offset % 200) * 20.0
            let y = Double(offset / 200) * 20.0
            let manual = offset % 100 == 0
            cells.append(DetectedCell(cx: x, cy: y, diameter: 5, diameterPx: 5, isManual: manual))
        }
        let index = CellSpatialIndex(cells: cells)
        let query = index.query(CGRect(x: 995, y: 995, width: 70, height: 70))
        let expected = cells.indices.filter {
            let rect = CellSpatialIndex.sourceBounds(cells[$0])
            return rect.minX <= 1065 && rect.maxX >= 995 && rect.minY <= 1065 && rect.maxY >= 995
        }
        #expect(query.indices == expected)
        #expect(!query.indices.isEmpty)
        #expect(query.examinedEntries < 200)
        #expect(index.manualOrdinals[20_000] == 201)
        #expect(index.query(CGRect(x: 0, y: 2000, width: 0, height: 0)).indices.contains(20_000))
        #expect(index.query(CGRect(x: -100, y: -100, width: 1, height: 1)).indices.isEmpty)
    }

    @Test @MainActor func geometryCacheReusesSourcePathsAndInvalidatesEditsWithinBounds() {
        let points = [CGPoint(x: 3, y: 5), CGPoint(x: 91, y: 8), CGPoint(x: 8, y: 41)]
        var cells = [DetectedCell(cx: 10, cy: 10, diameter: 5, diameterPx: 5, contourPx: points)]
        let cache = OverlayGeometryCache(maxVertices: 8, maxPaths: 2)
        _ = cache.prepare(cells: cells, revision: 1)
        let path = cache.path(for: cells[0].id, contour: points)
        #expect(path.boundingRect == CGRect(x: 3, y: 5, width: 88, height: 36))
        #expect(path.contains(CGPoint(x: 10, y: 10)))
        _ = cache.prepare(cells: cells, revision: 1)
        _ = cache.path(for: cells[0].id, contour: points)
        #expect(cache.indexBuildCount == 1)
        #expect(cache.cachedPathCount == 1)
        for _ in 0..<50 { _ = cache.path(for: UUID(), contour: points) }
        #expect(cache.cachedPathCount <= 2)
        #expect(cache.cachedVertices <= 8)
        cells[0].contourPx = points.map { CGPoint(x: $0.x + 100, y: $0.y) }
        let edited = cache.prepare(cells: cells, revision: 2)
        #expect(cache.cachedVertices == 0)
        #expect(cache.indexBuildCount == 2)
        #expect(edited.query(CGRect(x: 185, y: 7, width: 2, height: 2)).indices == [0])
        let newPath = cache.path(for: cells[0].id, contour: cells[0].contourPx!)
        #expect(newPath.boundingRect.minX == 103)
        // Callers without a revision token still detect same-ID geometry edits.
        _ = cache.prepare(cells: cells, revision: nil)
        cells[0].cx = 500
        let noToken = cache.prepare(cells: cells, revision: nil)
        #expect(noToken.bounds[0].maxX == 500)
    }

    @Test func assayWorkerReusesProcessAndRestartsAfterHelperChanges() async throws {
        let fixture = try AssayFixture()
        defer { fixture.remove() }
        let service = AssayWorkerService()
        let first = try await service.run(pythonURL: fixture.python, scriptURL: fixture.assay, args: [])
        let second = try await service.run(pythonURL: fixture.python, scriptURL: fixture.assay, args: [])
        let a = try JSONDecoder().decode(AssayEcho.self, from: first.stdout)
        let b = try JSONDecoder().decode(AssayEcho.self, from: second.stdout)
        #expect(a.pid == b.pid)
        #expect(a.count == 1 && b.count == 2)
        let content = try String(contentsOf: fixture.assay, encoding: .utf8)
        try (content + "\n# revised helper\n").write(to: fixture.assay, atomically: true, encoding: .utf8)
        let third = try await service.run(pythonURL: fixture.python, scriptURL: fixture.assay, args: [])
        let c = try JSONDecoder().decode(AssayEcho.self, from: third.stdout)
        #expect(c.pid != a.pid)
        #expect(c.count == 1)
        await service.shutdown()
    }

    @Test func queuedCancellationDoesNotStopActiveAssayAndActiveCancellationRetiresWorker() async throws {
        let fixture = try AssayFixture()
        defer { fixture.remove() }
        let service = AssayWorkerService()
        let active = Task {
            try await service.run(pythonURL: fixture.python, scriptURL: fixture.assay,
                                  args: ["--wait", fixture.marker.path])
        }
        try await waitFor { FileManager.default.fileExists(atPath: fixture.marker.path) }
        let activePID = try String(contentsOf: fixture.marker, encoding: .utf8)
        let queued = Task {
            try await service.run(pythonURL: fixture.python, scriptURL: fixture.assay, args: [])
        }
        try await waitFor { await service.pendingRequestCount == 1 }
        queued.cancel()
        do { _ = try await queued.value; Issue.record("Queued assay unexpectedly completed") }
        catch is CancellationError { }
        #expect(await service.hasActiveRequest)
        #expect(await service.pendingRequestCount == 0)
        active.cancel()
        do { _ = try await active.value; Issue.record("Active assay unexpectedly completed") }
        catch DetectionError.cancelled { }
        catch is CancellationError { }
        let recovered = try await service.run(pythonURL: fixture.python, scriptURL: fixture.assay, args: [])
        let echo = try JSONDecoder().decode(AssayEcho.self, from: recovered.stdout)
        #expect(String(echo.pid) != activePID)
        #expect(echo.count == 1)
        await service.shutdown()
    }

    @Test func idleAssayProcessRetires() async throws {
        let fixture = try AssayFixture()
        defer { fixture.remove() }
        let service = AssayWorkerService(idleSeconds: 0.05)
        let first = try await service.run(pythonURL: fixture.python, scriptURL: fixture.assay, args: [])
        let a = try JSONDecoder().decode(AssayEcho.self, from: first.stdout)
        try await Task.sleep(for: .milliseconds(250))
        let second = try await service.run(pythonURL: fixture.python, scriptURL: fixture.assay, args: [])
        let b = try JSONDecoder().decode(AssayEcho.self, from: second.stdout)
        #expect(a.pid != b.pid)
        #expect(b.count == 1)
        await service.shutdown()
    }

    private func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()) {
            if ContinuousClock.now >= deadline { throw AssayTestError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum AssayTestError: Error { case timeout, missingBundledWorker }
private struct AssayEcho: Decodable { let pid: Int; let count: Int }
private struct AssayFixture {
    let directory: URL
    let assay: URL
    let marker: URL
    let python = URL(fileURLWithPath: "/usr/bin/python3")
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cc-assay-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        assay = directory.appendingPathComponent("area_assays_detect.py")
        marker = directory.appendingPathComponent("active-pid.txt")
        guard let source = Bundle.main.url(forResource: "_assay_worker", withExtension: "py", subdirectory: "python")
                ?? Bundle.main.url(forResource: "_assay_worker", withExtension: "py") else {
            throw AssayTestError.missingBundledWorker
        }
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent("_assay_worker.py"))
        try """
        import json, os, sys, time
        count = 0
        def main():
            global count
            count += 1
            if "--wait" in sys.argv:
                with open(sys.argv[-1], "w") as handle:
                    handle.write(str(os.getpid()))
                time.sleep(30)
            print(json.dumps({"pid": os.getpid(), "count": count}))
        """.write(to: assay, atomically: true, encoding: .utf8)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
