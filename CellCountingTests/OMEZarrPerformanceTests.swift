import CoreGraphics
import Foundation
import Testing
@testable import CellCounting

struct OMEZarrPerformanceTests {
    @Test func decodedChunkLRUIsBoundedByBytes() async throws {
        let root = try makeFourChunkFixture()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let service = OMEZarrService(limits: OMEZarrResourceLimits(
            maxDecodedChunkCacheBytes: 8,
            maxCacheablePlaneBytes: 0,
            maxPlaneCacheBytes: 0))
        let dataset = try await service.inspect(rootURL: root)
        let array = try #require(dataset.arrays.first)

        _ = try await service.readPlane(array: array)
        let stats = await service.cacheStats()
        #expect(stats.decodedChunkMisses == 4)
        #expect(stats.decodedChunkEntries == 2)
        #expect(stats.decodedChunkBytes == 8)
        #expect(stats.decodedChunkBytes <= 8)
    }

    @Test func repeatedPlaneReadUsesEachDecodedChunkOnce() async throws {
        let root = try makeFourChunkFixture()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let service = OMEZarrService(limits: OMEZarrResourceLimits(
            maxDecodedChunkCacheBytes: 16,
            maxCacheablePlaneBytes: 0,
            maxPlaneCacheBytes: 0))
        let dataset = try await service.inspect(rootURL: root)
        let array = try #require(dataset.arrays.first)

        let first = try await service.readPlane(array: array)
        let firstStats = await service.cacheStats()
        let second = try await service.readPlane(array: array)
        let secondStats = await service.cacheStats()

        #expect(first.pixels == (0..<16).map(Float.init))
        #expect(second.pixels == first.pixels)
        #expect(firstStats.decodedChunkMisses == 4)
        #expect(firstStats.decodedChunkHits == 0)
        #expect(secondStats.decodedChunkMisses == 4)
        #expect(secondStats.decodedChunkHits == 4)
        #expect(secondStats.decodedChunkEntries == 4)
        #expect(secondStats.decodedChunkBytes == 16)
        #expect(secondStats.decodedChunkBytes <= 16)
        #expect(secondStats.planeEntries == 0)
    }

    @Test func planeCacheHonorsPerPlaneBudgetAndInvalidationGeneration() async throws {
        let root = try makeFourChunkFixture()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let service = OMEZarrService(limits: OMEZarrResourceLimits(
            maxDecodedChunkCacheBytes: 16,
            maxCacheablePlaneBytes: 64,
            maxPlaneCacheBytes: 64))
        let dataset = try await service.inspect(rootURL: root)
        let array = try #require(dataset.arrays.first)

        _ = try await service.readPlane(array: array)
        _ = try await service.readPlane(array: array)
        var stats = await service.cacheStats()
        #expect(stats.planeHits == 1)
        #expect(stats.planeEntries == 1)
        #expect(stats.planeBytes == 64)

        try Data([100, 101, 104, 105]).write(to: root.appendingPathComponent("0/0.0"))
        await service.invalidate(rootURL: root)
        let refreshed = try await service.readPlane(array: array)
        stats = await service.cacheStats()
        #expect(refreshed.pixels[0] == 100)
        #expect(refreshed.pixels[1] == 101)
        #expect(stats.invalidations == 1)
        #expect(stats.decodedChunkMisses == 8)
        #expect(stats.planeMisses == 2)
    }

    @Test func oversizedPlaneIsNotCachedAndMemoryLimitsAreTyped() async throws {
        let root = try makeFourChunkFixture()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let nonCachingService = OMEZarrService(limits: OMEZarrResourceLimits(
            maxDecodedChunkCacheBytes: 16,
            maxCacheablePlaneBytes: 32,
            maxPlaneCacheBytes: 32))
        let dataset = try await nonCachingService.inspect(rootURL: root)
        let array = try #require(dataset.arrays.first)
        _ = try await nonCachingService.readPlane(array: array)
        _ = try await nonCachingService.readPlane(array: array)
        let nonCachingStats = await nonCachingService.cacheStats()
        #expect(nonCachingStats.planeEntries == 0)
        #expect(nonCachingStats.planeHits == 0)
        #expect(nonCachingStats.decodedChunkHits == 4)

        let boundedService = OMEZarrService(limits: OMEZarrResourceLimits(
            maxDecodedChunkBytes: 3,
            maxDecodedChunkCacheBytes: 16,
            maxCacheablePlaneBytes: 32,
            maxPlaneCacheBytes: 32))

        await #expect(throws: OMEZarrError.resourceLimitExceeded(
            resource: "decoded chunk", requestedBytes: 4, limitBytes: 3)) {
            try await boundedService.readPlane(array: array)
        }
        let stats = await boundedService.cacheStats()
        #expect(stats.planeEntries == 0)
        #expect(stats.decodedChunkEntries == 0)

        let planeBoundedService = OMEZarrService(limits: OMEZarrResourceLimits(
            maxPlaneBytes: 63, maxCacheablePlaneBytes: 0, maxPlaneCacheBytes: 0))
        await #expect(throws: OMEZarrError.resourceLimitExceeded(
            resource: "plane buffer", requestedBytes: 64, limitBytes: 63)) {
            try await planeBoundedService.readPlane(array: array)
        }
    }

    @Test func viewportPyramidSelectionBoundsSourceWork() throws {
        let axes = [
            OMEZarrAxisDescriptor(name: "y", kind: .y, unit: nil, scale: 1),
            OMEZarrAxisDescriptor(name: "x", kind: .x, unit: nil, scale: 1),
        ]
        let root = URL(fileURLWithPath: "/tmp/pyramid.ome.zarr", isDirectory: true)
        func array(path: String, side: Int) -> OMEZarrArrayDescriptor {
            OMEZarrArrayDescriptor(rootURL: root, path: path,
                                   shape: [side, side], chunks: [256, 256],
                                   dataType: "|u1", compressorID: nil, order: "C",
                                   dimensionSeparator: ".", axes: axes,
                                   coordinateScale: [1, 1])
        }
        let dataset = OMEZarrDataset(rootURL: root, name: "Pyramid",
                                     arrays: [array(path: "0", side: 4_096),
                                              array(path: "1", side: 1_024),
                                              array(path: "2", side: 256)], plate: nil)

        #expect(try OMEZarrService.arrayForViewport(
            in: dataset, viewportSize: CGSize(width: 800, height: 600)).path == "1")
        #expect(try OMEZarrService.arrayForViewport(
            in: dataset, viewportSize: CGSize(width: 120, height: 120),
            backingScaleFactor: 2).path == "2")
        #expect(try OMEZarrService.arrayForViewport(
            in: dataset, viewportSize: CGSize(width: 1_500, height: 1_500)).path == "0")
    }

    private func makeFourChunkFixture() throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-zarr-performance-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("fixture.ome.zarr", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("0"),
                                                withIntermediateDirectories: true)
        let attributes = """
        {"multiscales":[{"name":"Cache fixture","axes":["y","x"],
          "datasets":[{"path":"0"}]}]}
        """
        let array = """
        {"zarr_format":2,"shape":[4,4],"chunks":[2,2],"dtype":"|u1",
         "compressor":null,"fill_value":0,"order":"C","filters":null,"dimension_separator":"."}
        """
        try Data(attributes.utf8).write(to: root.appendingPathComponent(".zattrs"))
        try Data(array.utf8).write(to: root.appendingPathComponent("0/.zarray"))
        try Data([0, 1, 4, 5]).write(to: root.appendingPathComponent("0/0.0"))
        try Data([2, 3, 6, 7]).write(to: root.appendingPathComponent("0/0.1"))
        try Data([8, 9, 12, 13]).write(to: root.appendingPathComponent("0/1.0"))
        try Data([10, 11, 14, 15]).write(to: root.appendingPathComponent("0/1.1"))
        return root
    }
}
