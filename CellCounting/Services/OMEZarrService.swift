import Foundation
import CoreGraphics
import Compression

nonisolated enum OMEZarrError: LocalizedError, Equatable {
    case notDirectory
    case metadataMissing(String)
    case malformedMetadata(String)
    case unsafePath(String)
    case unsupportedVersion(Int)
    case unsupportedCodec(String)
    case unsupportedDataType(String)
    case unsupportedArrayOrder(String)
    case chunkMissing(String)
    case corruptChunk(String)
    case planeTooLarge(Int)
    case resourceLimitExceeded(resource: String, requestedBytes: Int, limitBytes: Int)

    var errorDescription: String? {
        switch self {
        case .notDirectory: return "Choose a local OME-Zarr directory."
        case .metadataMissing(let path): return "OME-Zarr metadata is missing at \(path)."
        case .malformedMetadata(let detail): return "OME-Zarr metadata is invalid: \(detail)"
        case .unsafePath(let path): return "OME-Zarr contains an unsafe relative path: \(path)"
        case .unsupportedVersion(let version): return "Zarr format version \(version) is not supported by this release."
        case .unsupportedCodec(let codec): return "The OME-Zarr codec “\(codec)” is not supported locally. Re-encode as uncompressed or zlib."
        case .unsupportedDataType(let type): return "The OME-Zarr data type “\(type)” is not supported."
        case .unsupportedArrayOrder(let order): return "OME-Zarr array order “\(order)” is not supported; use C order."
        case .chunkMissing(let path): return "OME-Zarr chunk is missing: \(path)"
        case .corruptChunk(let detail): return "OME-Zarr chunk is corrupt: \(detail)"
        case .planeTooLarge(let pixels): return "The requested plane contains \(pixels) pixels and exceeds the local safety limit."
        case .resourceLimitExceeded(let resource, let requestedBytes, let limitBytes):
            return "OME-Zarr \(resource) needs \(requestedBytes) bytes, exceeding the local safety limit of \(limitBytes) bytes."
        }
    }
}

/// Hard resource ceilings for local OME-Zarr work. Cache limits are byte-costed,
/// so unusually shaped chunks cannot turn an entry-count limit into unbounded memory.
nonisolated struct OMEZarrResourceLimits: Equatable, Sendable {
    var maxMetadataBytes: Int
    var maxEncodedChunkBytes: Int
    var maxDecodedChunkBytes: Int
    var maxDecodedChunkCacheBytes: Int
    var maxPlanePixels: Int
    var maxPlaneBytes: Int
    var maxCacheablePlaneBytes: Int
    var maxPlaneCacheBytes: Int

    init(maxMetadataBytes: Int = 16 * 1_024 * 1_024,
         maxEncodedChunkBytes: Int = 128 * 1_024 * 1_024,
         maxDecodedChunkBytes: Int = 64 * 1_024 * 1_024,
         maxDecodedChunkCacheBytes: Int = 128 * 1_024 * 1_024,
         maxPlanePixels: Int = 64_000_000,
         maxPlaneBytes: Int = 256 * 1_024 * 1_024,
         maxCacheablePlaneBytes: Int = 16 * 1_024 * 1_024,
         maxPlaneCacheBytes: Int = 32 * 1_024 * 1_024) {
        self.maxMetadataBytes = max(0, maxMetadataBytes)
        self.maxEncodedChunkBytes = max(0, maxEncodedChunkBytes)
        self.maxDecodedChunkBytes = max(0, maxDecodedChunkBytes)
        self.maxDecodedChunkCacheBytes = max(0, maxDecodedChunkCacheBytes)
        self.maxPlanePixels = max(0, maxPlanePixels)
        self.maxPlaneBytes = max(0, maxPlaneBytes)
        self.maxCacheablePlaneBytes = min(max(0, maxCacheablePlaneBytes), max(0, maxPlaneCacheBytes))
        self.maxPlaneCacheBytes = max(0, maxPlaneCacheBytes)
    }

    static let `default` = OMEZarrResourceLimits()
}

nonisolated struct OMEZarrCacheStats: Equatable, Sendable {
    var metadataHits = 0
    var metadataMisses = 0
    var decodedChunkHits = 0
    var decodedChunkMisses = 0
    var planeHits = 0
    var planeMisses = 0
    var invalidations = 0
    var decodedChunkEntries = 0
    var decodedChunkBytes = 0
    var planeEntries = 0
    var planeBytes = 0
}

nonisolated struct OMEZarrAxisDescriptor: Hashable, Sendable {
    var name: String
    var kind: WorkspaceAxisKind
    var unit: String?
    var scale: Double
}

nonisolated struct OMEZarrArrayDescriptor: Identifiable, Hashable, Sendable {
    var id: String { path }
    var rootURL: URL
    var path: String
    var shape: [Int]
    var chunks: [Int]
    var dataType: String
    var compressorID: String?
    var order: String
    var dimensionSeparator: String
    var axes: [OMEZarrAxisDescriptor]
    var coordinateScale: [Double]
}

nonisolated struct OMEZarrDataset: Hashable, Sendable {
    var rootURL: URL
    var name: String
    var arrays: [OMEZarrArrayDescriptor]
    var plate: WorkspacePlate?
}

nonisolated struct OMEZarrPlane: Sendable {
    var width: Int
    var height: Int
    var pixels: [Float]

    func displayBytes() -> [UInt8] {
        guard !pixels.isEmpty else { return [] }
        var minimum = Float.greatestFiniteMagnitude
        var maximum = -Float.greatestFiniteMagnitude
        for value in pixels where value.isFinite {
            minimum = min(minimum, value)
            maximum = max(maximum, value)
        }
        guard minimum.isFinite, maximum.isFinite else { return Array(repeating: 0, count: pixels.count) }
        let span = max(maximum - minimum, Float.leastNonzeroMagnitude)
        return pixels.map { value in
            guard value.isFinite else { return 0 }
            return UInt8(clamping: Int(((value - minimum) / span * 255).rounded()))
        }
    }

    func makeCGImage() -> CGImage? {
        let bytes = displayBytes()
        guard bytes.count == width * height,
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                       decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}

actor OMEZarrService {
    static let shared = OMEZarrService()

    private var metadataCache: [URL: OMEZarrDataset] = [:]
    private var limits: OMEZarrResourceLimits
    private var counters = OMEZarrCacheStats()
    private var epoch: UInt64 = 0
    private var rootGenerations: [URL: UInt64] = [:]
    private var accessClock: UInt64 = 0

    private nonisolated struct Generation: Hashable {
        var epoch: UInt64
        var root: UInt64
    }

    private nonisolated struct ArrayCacheIdentity: Hashable {
        var rootPath: String
        var arrayPath: String
        var shape: [Int]
        var chunks: [Int]
        var dataType: String
        var compressorID: String?
        var order: String
        var dimensionSeparator: String
        var xAxis: Int
        var yAxis: Int
    }

    private nonisolated struct ChunkCacheKey: Hashable {
        var array: ArrayCacheIdentity
        var coordinates: [Int]
        var generation: Generation
    }

    private nonisolated struct PlaneIndex: Hashable {
        var name: String
        var value: Int
    }

    private nonisolated struct PlaneCacheKey: Hashable {
        var array: ArrayCacheIdentity
        var fixedIndices: [PlaneIndex]
        var generation: Generation
    }

    private nonisolated struct CacheEntry<Value> {
        var value: Value
        var cost: Int
        var lastAccess: UInt64
    }

    private var decodedChunkCache: [ChunkCacheKey: CacheEntry<Data>] = [:]
    private var planeCache: [PlaneCacheKey: CacheEntry<OMEZarrPlane>] = [:]
    private var decodedChunkCacheBytes = 0
    private var planeCacheBytes = 0

    init(limits: OMEZarrResourceLimits = .default) {
        self.limits = limits
    }

    func inspect(rootURL: URL, useCache: Bool = true) throws -> OMEZarrDataset {
        let root = rootURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw OMEZarrError.notDirectory }
        if useCache, let cached = metadataCache[root] {
            counters.metadataHits += 1
            return cached
        }
        counters.metadataMisses += 1
        if !useCache {
            metadataCache[root] = nil
            invalidateDerivedCaches(for: root, countInvalidation: false)
        }
        let dataset = try Self.parseDataset(rootURL: root, maxMetadataBytes: limits.maxMetadataBytes)
        metadataCache[root] = dataset
        return dataset
    }

    func invalidate(rootURL: URL? = nil) {
        counters.invalidations += 1
        if let rootURL {
            let root = rootURL.standardizedFileURL
            metadataCache[root] = nil
            invalidateDerivedCaches(for: root, countInvalidation: false)
        } else {
            metadataCache.removeAll(keepingCapacity: false)
            decodedChunkCache.removeAll(keepingCapacity: false)
            planeCache.removeAll(keepingCapacity: false)
            decodedChunkCacheBytes = 0
            planeCacheBytes = 0
            rootGenerations.removeAll(keepingCapacity: false)
            epoch &+= 1
        }
    }

    /// Snapshot suitable for diagnostics and deterministic cache tests.
    func cacheStats() -> OMEZarrCacheStats {
        var result = counters
        result.decodedChunkEntries = decodedChunkCache.count
        result.decodedChunkBytes = decodedChunkCacheBytes
        result.planeEntries = planeCache.count
        result.planeBytes = planeCacheBytes
        return result
    }

    func resetCacheStatistics() {
        counters = OMEZarrCacheStats()
    }

    /// Internal test hook. It also advances the cache generation so stale
    /// descriptors can never address values created before the reset.
    func resetCachesForTesting(limits newLimits: OMEZarrResourceLimits = .default) {
        limits = newLimits
        metadataCache.removeAll(keepingCapacity: false)
        decodedChunkCache.removeAll(keepingCapacity: false)
        planeCache.removeAll(keepingCapacity: false)
        decodedChunkCacheBytes = 0
        planeCacheBytes = 0
        rootGenerations.removeAll(keepingCapacity: false)
        epoch &+= 1
        counters = OMEZarrCacheStats()
    }

    /// Chooses the coarsest pyramid level that still supplies at least one
    /// source pixel per backing-store pixel. If none does, the finest level wins.
    nonisolated static func arrayForViewport(in dataset: OMEZarrDataset,
                                             viewportSize: CGSize,
                                             backingScaleFactor: CGFloat = 1) throws -> OMEZarrArrayDescriptor {
        guard viewportSize.width.isFinite, viewportSize.height.isFinite,
              backingScaleFactor.isFinite,
              viewportSize.width > 0, viewportSize.height > 0, backingScaleFactor > 0 else {
            throw OMEZarrError.malformedMetadata("viewport dimensions must be finite and positive")
        }
        guard !dataset.arrays.isEmpty else {
            throw OMEZarrError.malformedMetadata("multiscale pyramid has no arrays")
        }
        let targetWidth = Double(viewportSize.width * backingScaleFactor)
        let targetHeight = Double(viewportSize.height * backingScaleFactor)
        guard targetWidth.isFinite, targetHeight.isFinite else {
            throw OMEZarrError.malformedMetadata("viewport backing dimensions overflow")
        }
        let candidates = try dataset.arrays.map { array -> (OMEZarrArrayDescriptor, Int, Int, Int) in
            let rank = array.shape.count
            guard rank >= 2, array.axes.count == rank,
                  array.shape.allSatisfy({ $0 > 0 }) else {
                throw OMEZarrError.malformedMetadata("array rank and axes disagree at \(array.path)")
            }
            let x = array.axes.lastIndex(where: { $0.kind == .x }) ?? rank - 1
            let y = array.axes.lastIndex(where: { $0.kind == .y }) ?? rank - 2
            guard x != y else {
                throw OMEZarrError.malformedMetadata("x and y axes overlap at \(array.path)")
            }
            let area = array.shape[x].multipliedReportingOverflow(by: array.shape[y])
            guard !area.overflow else { throw OMEZarrError.malformedMetadata("array dimensions overflow at \(array.path)") }
            return (array, array.shape[x], array.shape[y], area.partialValue)
        }
        let adequate = candidates.filter { Double($0.1) >= targetWidth && Double($0.2) >= targetHeight }
        if let selected = adequate.min(by: { $0.3 < $1.3 }) { return selected.0 }
        return candidates.max(by: { $0.3 < $1.3 })!.0
    }

    func readPlane(array: OMEZarrArrayDescriptor,
                   fixedIndices: [String: Int] = [:],
                   maxPixels: Int = 64_000_000) async throws -> OMEZarrPlane {
        try Task.checkCancellation()
        guard array.order.uppercased() == "C" else {
            throw OMEZarrError.unsupportedArrayOrder(array.order)
        }
        let rank = array.shape.count
        guard rank >= 2, array.chunks.count == rank, array.axes.count == rank,
              array.shape.allSatisfy({ $0 > 0 }), array.chunks.allSatisfy({ $0 > 0 }) else {
            throw OMEZarrError.malformedMetadata("array rank, chunks, and axes disagree")
        }
        guard array.dimensionSeparator == "." || array.dimensionSeparator == "/" else {
            throw OMEZarrError.malformedMetadata("unsupported chunk dimension separator")
        }
        let xAxis = array.axes.lastIndex(where: { $0.kind == .x }) ?? rank - 1
        let yAxis = array.axes.lastIndex(where: { $0.kind == .y }) ?? rank - 2
        guard xAxis != yAxis else { throw OMEZarrError.malformedMetadata("x and y axes overlap") }
        let width = array.shape[xAxis]
        let height = array.shape[yAxis]
        let pixelCount = width.multipliedReportingOverflow(by: height)
        guard !pixelCount.overflow else { throw OMEZarrError.planeTooLarge(Int.max) }
        let effectivePixelLimit = min(max(0, maxPixels), limits.maxPlanePixels)
        guard pixelCount.partialValue <= effectivePixelLimit else {
            throw OMEZarrError.planeTooLarge(pixelCount.partialValue)
        }
        let planeBytes = pixelCount.partialValue.multipliedReportingOverflow(by: MemoryLayout<Float>.stride)
        guard !planeBytes.overflow, planeBytes.partialValue <= limits.maxPlaneBytes else {
            throw OMEZarrError.resourceLimitExceeded(resource: "plane buffer",
                                                     requestedBytes: planeBytes.overflow ? Int.max : planeBytes.partialValue,
                                                     limitBytes: limits.maxPlaneBytes)
        }

        let dataType = try ZarrDataType(array.dataType)
        let normalizedIndices = normalizedFixedIndices(array: array, fixedIndices: fixedIndices,
                                                       xAxis: xAxis, yAxis: yAxis)
        let planeKey = PlaneCacheKey(array: cacheIdentity(for: array, xAxis: xAxis, yAxis: yAxis),
                                     fixedIndices: normalizedIndices,
                                     generation: generation(for: array.rootURL))
        if var cached = planeCache[planeKey] {
            counters.planeHits += 1
            cached.lastAccess = nextAccess()
            planeCache[planeKey] = cached
            return cached.value
        }
        counters.planeMisses += 1
        var output = Array(repeating: Float(0), count: pixelCount.partialValue)
        var baseCoordinates = Array(repeating: 0, count: rank)
        for axisIndex in 0..<rank where axisIndex != xAxis && axisIndex != yAxis {
            let name = array.axes[axisIndex].name
            let selected = min(max(0, fixedIndices[name, default: 0]), array.shape[axisIndex] - 1)
            baseCoordinates[axisIndex] = selected / array.chunks[axisIndex]
        }

        let yChunkCount = (height + array.chunks[yAxis] - 1) / array.chunks[yAxis]
        let xChunkCount = (width + array.chunks[xAxis] - 1) / array.chunks[xAxis]
        let chunkStrides = Self.rowMajorStrides(array.chunks)
        for chunkY in 0..<yChunkCount {
            for chunkX in 0..<xChunkCount {
                try Task.checkCancellation()
                var coordinates = baseCoordinates
                coordinates[yAxis] = chunkY
                coordinates[xAxis] = chunkX
                let chunk = try readChunk(array: array,
                                          coordinates: coordinates,
                                          dataType: dataType)
                let yStart = chunkY * array.chunks[yAxis]
                let xStart = chunkX * array.chunks[xAxis]
                let yCount = min(array.chunks[yAxis], height - yStart)
                let xCount = min(array.chunks[xAxis], width - xStart)
                var fixedLinearIndex = 0
                for axisIndex in 0..<rank where axisIndex != xAxis && axisIndex != yAxis {
                    let name = array.axes[axisIndex].name
                    let selected = min(max(0, fixedIndices[name, default: 0]), array.shape[axisIndex] - 1)
                    fixedLinearIndex += (selected % array.chunks[axisIndex]) * chunkStrides[axisIndex]
                }
                chunk.withUnsafeBytes { bytes in
                    for localY in 0..<yCount {
                        let rowLinearIndex = fixedLinearIndex + localY * chunkStrides[yAxis]
                        let outputRow = (yStart + localY) * width + xStart
                        for localX in 0..<xCount {
                            let linearIndex = rowLinearIndex + localX * chunkStrides[xAxis]
                            output[outputRow + localX] = dataType.decodeUnchecked(
                                bytes: bytes, index: linearIndex)
                        }
                    }
                }
            }
        }
        let plane = OMEZarrPlane(width: width, height: height, pixels: output)
        if planeBytes.partialValue <= limits.maxCacheablePlaneBytes {
            insertPlane(plane, for: planeKey, cost: planeBytes.partialValue)
        }
        return plane
    }

    // MARK: Cache management

    private func generation(for rootURL: URL) -> Generation {
        Generation(epoch: epoch, root: rootGenerations[rootURL.standardizedFileURL, default: 0])
    }

    private func nextAccess() -> UInt64 {
        accessClock &+= 1
        return accessClock
    }

    private func normalizedFixedIndices(array: OMEZarrArrayDescriptor,
                                        fixedIndices: [String: Int],
                                        xAxis: Int, yAxis: Int) -> [PlaneIndex] {
        array.axes.indices.compactMap { index in
            guard index != xAxis, index != yAxis else { return nil }
            let name = array.axes[index].name
            return PlaneIndex(name: name,
                              value: min(max(0, fixedIndices[name, default: 0]), array.shape[index] - 1))
        }
    }

    private func cacheIdentity(for array: OMEZarrArrayDescriptor,
                               xAxis: Int? = nil, yAxis: Int? = nil) -> ArrayCacheIdentity {
        let rank = array.shape.count
        return ArrayCacheIdentity(
            rootPath: array.rootURL.standardizedFileURL.path,
            arrayPath: array.path,
            shape: array.shape,
            chunks: array.chunks,
            dataType: array.dataType,
            compressorID: array.compressorID,
            order: array.order,
            dimensionSeparator: array.dimensionSeparator,
            xAxis: xAxis ?? array.axes.lastIndex(where: { $0.kind == .x }) ?? max(0, rank - 1),
            yAxis: yAxis ?? array.axes.lastIndex(where: { $0.kind == .y }) ?? max(0, rank - 2))
    }

    private func invalidateDerivedCaches(for rootURL: URL, countInvalidation: Bool) {
        let root = rootURL.standardizedFileURL
        if countInvalidation { counters.invalidations += 1 }
        rootGenerations[root, default: 0] &+= 1

        let chunkKeys = decodedChunkCache.keys.filter {
            $0.array.rootPath == root.path
        }
        for key in chunkKeys {
            if let removed = decodedChunkCache.removeValue(forKey: key) {
                decodedChunkCacheBytes -= removed.cost
            }
        }
        let planeKeys = planeCache.keys.filter {
            $0.array.rootPath == root.path
        }
        for key in planeKeys {
            if let removed = planeCache.removeValue(forKey: key) {
                planeCacheBytes -= removed.cost
            }
        }
    }

    private func insertDecodedChunk(_ data: Data, for key: ChunkCacheKey) {
        let cost = data.count
        guard cost > 0, cost <= limits.maxDecodedChunkCacheBytes else { return }
        if let replaced = decodedChunkCache.removeValue(forKey: key) {
            decodedChunkCacheBytes -= replaced.cost
        }
        while decodedChunkCacheBytes > limits.maxDecodedChunkCacheBytes - cost,
              let oldest = decodedChunkCache.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            decodedChunkCache.removeValue(forKey: oldest.key)
            decodedChunkCacheBytes -= oldest.value.cost
        }
        decodedChunkCache[key] = CacheEntry(value: data, cost: cost, lastAccess: nextAccess())
        decodedChunkCacheBytes += cost
    }

    private func insertPlane(_ plane: OMEZarrPlane, for key: PlaneCacheKey, cost: Int) {
        guard cost > 0, cost <= limits.maxPlaneCacheBytes else { return }
        if let replaced = planeCache.removeValue(forKey: key) {
            planeCacheBytes -= replaced.cost
        }
        while planeCacheBytes > limits.maxPlaneCacheBytes - cost,
              let oldest = planeCache.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            planeCache.removeValue(forKey: oldest.key)
            planeCacheBytes -= oldest.value.cost
        }
        planeCache[key] = CacheEntry(value: plane, cost: cost, lastAccess: nextAccess())
        planeCacheBytes += cost
    }

    // MARK: Metadata

    private static func parseDataset(rootURL: URL, maxMetadataBytes: Int) throws -> OMEZarrDataset {
        let attrsURL = rootURL.appendingPathComponent(".zattrs")
        guard FileManager.default.fileExists(atPath: attrsURL.path) else {
            if FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("zarr.json").path) {
                throw OMEZarrError.unsupportedVersion(3)
            }
            throw OMEZarrError.metadataMissing(".zattrs")
        }
        let attributes: RootAttributes = try decode(RootAttributes.self, at: attrsURL,
                                                    maxBytes: maxMetadataBytes)
        guard let multiscale = attributes.multiscales?.first,
              !multiscale.datasets.isEmpty else {
            throw OMEZarrError.malformedMetadata("multiscales[0].datasets is missing")
        }
        guard multiscale.datasets.count <= 256 else {
            throw OMEZarrError.malformedMetadata("too many multiscale levels")
        }

        var arrays: [OMEZarrArrayDescriptor] = []
        for dataset in multiscale.datasets {
            let path = try safeRelativePath(dataset.path)
            let arrayURL = rootURL.appendingPathComponent(path, isDirectory: true)
            let zarrayURL = arrayURL.appendingPathComponent(".zarray")
            guard FileManager.default.fileExists(atPath: zarrayURL.path) else {
                throw OMEZarrError.metadataMissing("\(path)/.zarray")
            }
            let metadata: ArrayMetadata = try decode(ArrayMetadata.self, at: zarrayURL,
                                                     maxBytes: maxMetadataBytes)
            guard metadata.zarrFormat == 2 else { throw OMEZarrError.unsupportedVersion(metadata.zarrFormat) }
            guard metadata.shape.count == metadata.chunks.count,
                  metadata.shape.allSatisfy({ $0 > 0 }), metadata.chunks.allSatisfy({ $0 > 0 }) else {
                throw OMEZarrError.malformedMetadata("invalid shape or chunk dimensions at \(path)")
            }
            let dimensionSeparator = metadata.dimensionSeparator ?? "."
            guard dimensionSeparator == "." || dimensionSeparator == "/" else {
                throw OMEZarrError.malformedMetadata("unsupported chunk dimension separator at \(path)")
            }
            _ = try ZarrDataType(metadata.dtype)
            let axes = try resolvedAxes(multiscale.axes, rank: metadata.shape.count,
                                        scales: dataset.coordinateTransformations?.first(where: { $0.type == "scale" })?.scale)
            arrays.append(OMEZarrArrayDescriptor(
                rootURL: rootURL, path: path, shape: metadata.shape, chunks: metadata.chunks,
                dataType: metadata.dtype, compressorID: metadata.compressor?.id,
                order: metadata.order, dimensionSeparator: dimensionSeparator,
                axes: axes,
                coordinateScale: axes.map(\.scale)))
        }

        let plate = try attributes.plate.map {
            try parsePlate($0, rootURL: rootURL, maxMetadataBytes: maxMetadataBytes)
        }
        let name = multiscale.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return OMEZarrDataset(rootURL: rootURL,
                              name: name?.isEmpty == false ? name! : rootURL.deletingPathExtension().lastPathComponent,
                              arrays: arrays,
                              plate: plate)
    }

    private static func parsePlate(_ metadata: PlateMetadata, rootURL: URL,
                                   maxMetadataBytes: Int) throws -> WorkspacePlate {
        let rows = metadata.rows?.map(\.name) ?? []
        let columns = metadata.columns?.map(\.name) ?? []
        var wells: [WorkspaceWell] = []
        for well in metadata.wells ?? [] {
            let path = try safeRelativePath(well.path)
            let components = path.split(separator: "/").map(String.init)
            let rowName = components.first ?? ""
            let columnName = components.dropFirst().first ?? ""
            let row = rows.firstIndex(of: rowName) ?? Self.plateRowIndex(rowName)
            let column = columns.firstIndex(of: columnName) ?? max(0, (Int(columnName) ?? 1) - 1)
            let wellAttrsURL = rootURL.appendingPathComponent(path, isDirectory: true)
                .appendingPathComponent(".zattrs")
            let images: [WellImageMetadata]
            if FileManager.default.fileExists(atPath: wellAttrsURL.path),
               let attrs = try? decode(WellAttributes.self, at: wellAttrsURL,
                                       maxBytes: maxMetadataBytes) {
                images = attrs.well?.images ?? []
            } else {
                images = []
            }
            let fields = try images.enumerated().map { index, image in
                let imagePath = try safeRelativePath(image.path)
                return WorkspaceField(name: "Field \(index + 1)",
                                      path: path + "/" + imagePath)
            }
            wells.append(WorkspaceWell(row: row, column: column,
                                       label: rowName + columnName,
                                       path: path, fields: fields))
        }
        return WorkspacePlate(name: metadata.name ?? rootURL.lastPathComponent,
                              rows: rows, columns: columns, wells: wells)
    }

    private static func resolvedAxes(_ metadata: [AxisMetadata]?, rank: Int,
                                     scales: [Double]?) throws -> [OMEZarrAxisDescriptor] {
        let defaults = defaultAxisNames(rank: rank)
        let source = metadata?.count == rank ? metadata! : defaults.map {
            AxisMetadata(name: $0, type: nil, unit: nil)
        }
        guard source.count == rank else { throw OMEZarrError.malformedMetadata("axis rank mismatch") }
        return source.enumerated().map { index, axis in
            let lower = axis.name.lowercased()
            let kind: WorkspaceAxisKind
            switch axis.type?.lowercased() ?? lower {
            case "x": kind = .x
            case "y": kind = .y
            case "z": kind = .z
            case "space" where lower == "x": kind = .x
            case "space" where lower == "y": kind = .y
            case "space" where lower == "z": kind = .z
            case "t", "time": kind = .time
            case "c", "channel": kind = .channel
            default:
                if lower == "x" { kind = .x }
                else if lower == "y" { kind = .y }
                else if lower == "z" { kind = .z }
                else if lower == "t" { kind = .time }
                else if lower == "c" { kind = .channel }
                else { kind = .other }
            }
            let scale = scales?.indices.contains(index) == true ? scales![index] : 1
            return OMEZarrAxisDescriptor(name: axis.name, kind: kind,
                                         unit: axis.unit,
                                         scale: scale.isFinite && scale > 0 ? scale : 1)
        }
    }

    private static func defaultAxisNames(rank: Int) -> [String] {
        switch rank {
        case 1: return ["x"]
        case 2: return ["y", "x"]
        case 3: return ["c", "y", "x"]
        case 4: return ["z", "c", "y", "x"]
        case 5: return ["t", "z", "c", "y", "x"]
        default:
            return (0..<(rank - 5)).map { "axis\($0)" } + ["t", "z", "c", "y", "x"]
        }
    }

    private static func safeRelativePath(_ raw: String) throws -> String {
        guard !raw.isEmpty, !raw.hasPrefix("/"), !raw.hasPrefix("~") else {
            throw OMEZarrError.unsafePath(raw)
        }
        let components = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw OMEZarrError.unsafePath(raw)
        }
        return components.joined(separator: "/")
    }

    private static func plateRowIndex(_ name: String) -> Int {
        max(0, name.uppercased().unicodeScalars.reduce(0) { value, scalar in
            guard scalar.value >= 65, scalar.value <= 90 else { return value }
            return value * 26 + Int(scalar.value - 64)
        } - 1)
    }

    // MARK: Chunks

    private func readChunk(array: OMEZarrArrayDescriptor,
                           coordinates: [Int], dataType: ZarrDataType) throws -> Data {
        let key = ChunkCacheKey(array: cacheIdentity(for: array), coordinates: coordinates,
                                generation: generation(for: array.rootURL))
        if var cached = decodedChunkCache[key] {
            counters.decodedChunkHits += 1
            cached.lastAccess = nextAccess()
            decodedChunkCache[key] = cached
            return cached.value
        }
        counters.decodedChunkMisses += 1
        let name = coordinates.map(String.init).joined(separator: array.dimensionSeparator)
        let chunkURL: URL
        if array.dimensionSeparator == "/" {
            chunkURL = coordinates.reduce(array.rootURL.appendingPathComponent(array.path, isDirectory: true)) {
                $0.appendingPathComponent(String($1))
            }
        } else {
            chunkURL = array.rootURL.appendingPathComponent(array.path, isDirectory: true)
                .appendingPathComponent(name)
        }
        guard FileManager.default.fileExists(atPath: chunkURL.path) else {
            throw OMEZarrError.chunkMissing(array.path + "/" + name)
        }
        let encodedBytes: Int
        do {
            encodedBytes = try chunkURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        } catch {
            throw OMEZarrError.chunkMissing(array.path + "/" + name)
        }
        guard encodedBytes <= limits.maxEncodedChunkBytes else {
            throw OMEZarrError.resourceLimitExceeded(resource: "encoded chunk",
                                                     requestedBytes: encodedBytes,
                                                     limitBytes: limits.maxEncodedChunkBytes)
        }
        let encoded: Data
        do { encoded = try Data(contentsOf: chunkURL, options: .mappedIfSafe) }
        catch { throw OMEZarrError.chunkMissing(array.path + "/" + name) }
        let elementCount = try Self.checkedProduct(array.chunks)
        let expectedBytes = elementCount.multipliedReportingOverflow(by: dataType.byteCount)
        guard !expectedBytes.overflow else { throw OMEZarrError.corruptChunk("byte count overflow") }
        guard expectedBytes.partialValue <= limits.maxDecodedChunkBytes else {
            throw OMEZarrError.resourceLimitExceeded(resource: "decoded chunk",
                                                     requestedBytes: expectedBytes.partialValue,
                                                     limitBytes: limits.maxDecodedChunkBytes)
        }
        let decoded: Data
        switch array.compressorID?.lowercased() {
        case nil:
            guard encoded.count == expectedBytes.partialValue else {
                throw OMEZarrError.corruptChunk("\(name) has \(encoded.count) bytes; expected \(expectedBytes.partialValue)")
            }
            decoded = encoded
        case "zlib":
            var output = Data(count: expectedBytes.partialValue)
            let decodedCount = output.withUnsafeMutableBytes { outputBytes in
                encoded.withUnsafeBytes { inputBytes in
                    compression_decode_buffer(
                        outputBytes.bindMemory(to: UInt8.self).baseAddress!, expectedBytes.partialValue,
                        inputBytes.bindMemory(to: UInt8.self).baseAddress!, encoded.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            guard decodedCount == expectedBytes.partialValue else {
                throw OMEZarrError.corruptChunk("zlib decode failed for \(name)")
            }
            decoded = output
        case let codec?: throw OMEZarrError.unsupportedCodec(codec)
        }
        insertDecodedChunk(decoded, for: key)
        return decoded
    }

    private static func checkedProduct(_ values: [Int]) throws -> Int {
        var total = 1
        for value in values {
            let next = total.multipliedReportingOverflow(by: value)
            guard !next.overflow else { throw OMEZarrError.corruptChunk("dimension product overflow") }
            total = next.partialValue
        }
        return total
    }

    private static func rowMajorStrides(_ shape: [Int]) -> [Int] {
        guard !shape.isEmpty else { return [] }
        var strides = Array(repeating: 1, count: shape.count)
        if shape.count > 1 {
            for index in stride(from: shape.count - 2, through: 0, by: -1) {
                strides[index] = strides[index + 1] * shape[index + 1]
            }
        }
        return strides
    }

    private static func decode<T: Decodable>(_ type: T.Type, at url: URL,
                                             maxBytes: Int) throws -> T {
        do {
            let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard fileSize <= maxBytes else {
                throw OMEZarrError.resourceLimitExceeded(resource: "metadata",
                                                         requestedBytes: fileSize,
                                                         limitBytes: maxBytes)
            }
            return try JSONDecoder().decode(type, from: Data(contentsOf: url, options: .mappedIfSafe))
        }
        catch let error as OMEZarrError { throw error }
        catch { throw OMEZarrError.malformedMetadata("\(url.lastPathComponent): \(error.localizedDescription)") }
    }
}

// MARK: - Metadata decoding

private nonisolated struct RootAttributes: Decodable {
    var multiscales: [MultiscaleMetadata]?
    var plate: PlateMetadata?
}

private nonisolated struct MultiscaleMetadata: Decodable {
    var name: String?
    var axes: [AxisMetadata]?
    var datasets: [DatasetMetadata]
}

private nonisolated struct AxisMetadata: Decodable {
    var name: String
    var type: String?
    var unit: String?

    init(name: String, type: String?, unit: String?) {
        self.name = name
        self.type = type
        self.unit = unit
    }

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let name = try? single.decode(String.self) {
            self.init(name: name, type: nil, unit: nil)
            return
        }
        let object = try decoder.container(keyedBy: CodingKeys.self)
        let name = try object.decode(String.self, forKey: .name)
        let type = try object.decodeIfPresent(String.self, forKey: .type)
        let unit = try object.decodeIfPresent(String.self, forKey: .unit)
        self.init(name: name, type: type, unit: unit)
    }

    private enum CodingKeys: String, CodingKey { case name, type, unit }
}

private nonisolated struct DatasetMetadata: Decodable {
    var path: String
    var coordinateTransformations: [CoordinateTransformation]?
}

private nonisolated struct CoordinateTransformation: Decodable {
    var type: String
    var scale: [Double]?
}

private nonisolated struct ArrayMetadata: Decodable {
    var zarrFormat: Int
    var shape: [Int]
    var chunks: [Int]
    var dtype: String
    var compressor: CompressorMetadata?
    var order: String
    var dimensionSeparator: String?

    private enum CodingKeys: String, CodingKey {
        case zarrFormat = "zarr_format"
        case shape, chunks, dtype, compressor, order
        case dimensionSeparator = "dimension_separator"
    }
}

private nonisolated struct CompressorMetadata: Decodable { var id: String }
private nonisolated struct PlateMetadata: Decodable {
    var name: String?
    var rows: [PlateNameMetadata]?
    var columns: [PlateNameMetadata]?
    var wells: [PlateWellMetadata]?
}
private nonisolated struct PlateNameMetadata: Decodable { var name: String }
private nonisolated struct PlateWellMetadata: Decodable { var path: String }
private nonisolated struct WellAttributes: Decodable { var well: WellMetadata? }
private nonisolated struct WellMetadata: Decodable { var images: [WellImageMetadata]? }
private nonisolated struct WellImageMetadata: Decodable { var path: String }

private nonisolated struct ZarrDataType: Equatable {
    enum Scalar: Equatable { case unsigned, signed, float }
    let scalar: Scalar
    let byteCount: Int
    let littleEndian: Bool

    init(_ raw: String) throws {
        guard raw.count >= 2 else { throw OMEZarrError.unsupportedDataType(raw) }
        let chars = Array(raw)
        let endian = chars[0]
        let type = chars[1]
        guard let bytes = Int(String(chars.dropFirst(2))), [1, 2, 4, 8].contains(bytes) else {
            throw OMEZarrError.unsupportedDataType(raw)
        }
        switch type {
        case "u": scalar = .unsigned
        case "i": scalar = .signed
        case "f" where bytes == 4 || bytes == 8: scalar = .float
        default: throw OMEZarrError.unsupportedDataType(raw)
        }
        byteCount = bytes
        littleEndian = endian != ">"
    }

    /// The caller validates exact decoded chunk length once, before entering
    /// the pixel loop. This keeps bounds/error construction out of the hot path.
    func decodeUnchecked(bytes: UnsafeRawBufferPointer, index: Int) -> Float {
        let element = bytes.bindMemory(to: UInt8.self).baseAddress!
            .advanced(by: index * byteCount)
        var bits: UInt64 = 0
        if littleEndian {
            for shift in 0..<byteCount { bits |= UInt64(element[shift]) << UInt64(shift * 8) }
        } else {
            for position in 0..<byteCount { bits = (bits << 8) | UInt64(element[position]) }
        }
        switch (scalar, byteCount) {
        case (.unsigned, _): return Float(bits)
        case (.signed, 1): return Float(Int8(bitPattern: UInt8(bits)))
        case (.signed, 2): return Float(Int16(bitPattern: UInt16(bits)))
        case (.signed, 4): return Float(Int32(bitPattern: UInt32(bits)))
        case (.signed, 8): return Float(Int64(bitPattern: bits))
        case (.float, 4): return Float(bitPattern: UInt32(bits))
        case (.float, 8): return Float(Double(bitPattern: bits))
        default: preconditionFailure("ZarrDataType validates scalar widths at initialization")
        }
    }
}
