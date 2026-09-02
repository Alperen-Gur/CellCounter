import Foundation
import CoreGraphics

nonisolated struct WorkspacePixelPlane: Hashable, Sendable {
    var width: Int
    var height: Int
    var pixels: [Float]

    init(width: Int, height: Int, pixels: [Float]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    var isValid: Bool {
        guard width > 0, height > 0 else { return false }
        let count = width.multipliedReportingOverflow(by: height)
        return !count.overflow && pixels.count == count.partialValue
    }

    subscript(x: Int, y: Int) -> Float {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return pixels[y * width + x]
    }

    func makeCGImage() -> CGImage? {
        guard isValid else { return nil }
        var minValue = Float.greatestFiniteMagnitude
        var maxValue = -Float.greatestFiniteMagnitude
        for value in pixels where value.isFinite {
            minValue = min(minValue, value)
            maxValue = max(maxValue, value)
        }
        let span = max(maxValue - minValue, Float.leastNonzeroMagnitude)
        let bytes = pixels.map { value -> UInt8 in
            guard value.isFinite else { return 0 }
            return UInt8(clamping: Int(((value - minValue) / span * 255).rounded()))
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

nonisolated struct WorkspaceRegistrationResult: Hashable, Sendable {
    var transform: WorkspaceAffineTransform
    var score: Double
    var samples: Int
}

nonisolated struct WorkspaceTile: Identifiable, Hashable, Sendable {
    var id: UUID
    var plane: WorkspacePixelPlane
    var transform: WorkspaceAffineTransform

    init(id: UUID = UUID(), plane: WorkspacePixelPlane,
         transform: WorkspaceAffineTransform = .identity) {
        self.id = id
        self.plane = plane
        self.transform = transform
    }
}

nonisolated enum WorkspaceStitchBlend: String, Codable, CaseIterable, Sendable {
    case average, maximum
}

nonisolated struct WorkspaceStitchResult: Sendable {
    var plane: WorkspacePixelPlane
    var originX: Int
    var originY: Int
    var tileTransforms: [UUID: WorkspaceAffineTransform]
}

nonisolated struct WorkspaceImageProcessingProgress: Sendable, Equatable {
    var phase: String
    var completedUnits: Int
    var totalUnits: Int

    var fraction: Double {
        guard totalUnits > 0 else { return 1 }
        return min(max(Double(completedUnits) / Double(totalUnits), 0), 1)
    }
}

nonisolated struct WorkspaceStitchMemoryEstimate: Sendable, Equatable {
    var outputBytes: Int
    var coverageBytes: Int
    var liveInputBytes: Int
    var previewBytes: Int
    var fixedReserveBytes: Int

    var totalBytes: Int {
        [outputBytes, coverageBytes, liveInputBytes, previewBytes, fixedReserveBytes]
            .reduce(0) { partial, value in
                let sum = partial.addingReportingOverflow(value)
                return sum.overflow ? Int.max : sum.partialValue
            }
    }
}

nonisolated enum ImageRegistrationError: LocalizedError, Equatable {
    case invalidPlane
    case invalidGeometry
    case noOverlap
    case outputTooLarge(Int)
    case workingMemoryExceeded(requiredBytes: Int, limitBytes: Int)

    var errorDescription: String? {
        switch self {
        case .invalidPlane: return "Registration requires non-empty grayscale image planes."
        case .invalidGeometry: return "Tile transforms produced invalid or unrepresentable output bounds."
        case .noOverlap: return "The images do not have enough overlap to register reliably."
        case .outputTooLarge(let pixels): return "The stitched image would contain \(pixels) pixels and exceeds the safety limit."
        case .workingMemoryExceeded(let required, let limit):
            return "Stitching requires about \(required) bytes of working memory, above the \(limit)-byte safety budget."
        }
    }
}

nonisolated enum ImageRegistrationService {
    typealias CancellationCheck = @Sendable () throws -> Void
    typealias ProgressHandler = @Sendable (WorkspaceImageProcessingProgress) -> Void
    /// Estimates a translation that maps the moving plane into reference coordinates.
    /// A sparse normalized-correlation pyramid keeps the search bounded for large images.
    nonisolated static func estimateTranslation(reference: WorkspacePixelPlane,
                                                moving: WorkspacePixelPlane,
                                                maxShift: Int = 96,
                                                progress: ProgressHandler? = nil,
                                                cancellationCheck: CancellationCheck = {
                                                    try Task<Never, Never>.checkCancellation()
                                                }) throws -> WorkspaceRegistrationResult {
        guard reference.isValid, moving.isValid else { throw ImageRegistrationError.invalidPlane }
        try cancellationCheck()
        let boundedShift = max(0, min(maxShift, max(reference.width, reference.height)))
        let pixelStride = max(1, min(reference.width, reference.height, moving.width, moving.height) / 160)
        var step = max(1, boundedShift / 8)
        let bestDX = 0
        let bestDY = 0
        let bestScore = -Double.infinity
        let bestSamples = 0

        var passPreview: [(radius: Int, step: Int)] = [(boundedShift, step)]
        var previewStep = step
        while previewStep > 1 {
            previewStep = max(1, previewStep / 2)
            passPreview.append((max(2, previewStep * 2), previewStep))
            if previewStep == 1 { break }
        }
        let totalRows = max(1, passPreview.reduce(0) { partial, pass in
            partial + (pass.radius * 2 / max(1, pass.step)) + 1
        })
        var completedRows = 0
        progress?(.init(phase: "Registering", completedUnits: 0, totalUnits: totalRows))

        func search(centerX: Int, centerY: Int, radius: Int, stride shiftStep: Int,
                    currentBest: inout (dx: Int, dy: Int, score: Double, samples: Int)) throws {
            let xRange = stride(from: max(-boundedShift, centerX - radius),
                                through: min(boundedShift, centerX + radius), by: shiftStep)
            let yValues = stride(from: max(-boundedShift, centerY - radius),
                                 through: min(boundedShift, centerY + radius), by: shiftStep)
            for dy in yValues {
                try cancellationCheck()
                for dx in xRange {
                    let scored = try correlation(reference: reference, moving: moving,
                                                 dx: dx, dy: dy, pixelStride: pixelStride,
                                                 cancellationCheck: cancellationCheck)
                    if scored.samples >= 16,
                       scored.score > currentBest.score {
                        currentBest = (dx, dy, scored.score, scored.samples)
                    }
                }
                completedRows += 1
                progress?(.init(phase: "Registering", completedUnits: completedRows,
                                totalUnits: totalRows))
            }
        }

        var candidate = (dx: bestDX, dy: bestDY, score: bestScore, samples: bestSamples)
        try search(centerX: 0, centerY: 0, radius: boundedShift,
                   stride: step, currentBest: &candidate)
        while step > 1 {
            step = max(1, step / 2)
            try search(centerX: candidate.dx, centerY: candidate.dy,
                       radius: max(2, step * 2), stride: step,
                       currentBest: &candidate)
            if step == 1 { break }
        }
        guard candidate.score.isFinite else { throw ImageRegistrationError.noOverlap }
        progress?(.init(phase: "Registering", completedUnits: totalRows, totalUnits: totalRows))
        return WorkspaceRegistrationResult(
            transform: .translation(x: Double(candidate.dx), y: Double(candidate.dy)),
            score: candidate.score, samples: candidate.samples)
    }

    nonisolated static func registerSequence(_ planes: [WorkspacePixelPlane],
                                             maxShift: Int = 96,
                                             progress: ProgressHandler? = nil,
                                             cancellationCheck: CancellationCheck = {
                                                 try Task<Never, Never>.checkCancellation()
                                             }) throws -> [WorkspaceAffineTransform] {
        guard let first = planes.first, first.isValid else { return [] }
        var transforms: [WorkspaceAffineTransform] = [.identity]
        transforms.reserveCapacity(planes.count)
        for index in planes.indices.dropFirst() {
            try cancellationCheck()
            let pair = try estimateTranslation(reference: planes[index - 1],
                                               moving: planes[index], maxShift: maxShift,
                                               progress: { update in
                let completed = (index - 1) * 1_000 + Int(update.fraction * 1_000)
                progress?(.init(phase: "Registering sequence", completedUnits: completed,
                                totalUnits: max(1, planes.count - 1) * 1_000))
            }, cancellationCheck: cancellationCheck)
            transforms.append(pair.transform.concatenating(transforms[index - 1]))
        }
        return transforms
    }

    /// Creates deterministic row-major transforms before optional registration refinement.
    nonisolated static func gridTransforms(planes: [WorkspacePixelPlane], columns: Int,
                                           overlapFraction: Double) -> [WorkspaceAffineTransform] {
        let safeColumns = max(1, columns)
        let overlap = min(max(overlapFraction, 0), 0.95)
        return planes.enumerated().map { index, plane in
            let row = index / safeColumns
            let column = index % safeColumns
            return .translation(x: Double(column) * Double(plane.width) * (1 - overlap),
                                y: Double(row) * Double(plane.height) * (1 - overlap))
        }
    }

    nonisolated static func stitch(tiles: [WorkspaceTile],
                                   blend: WorkspaceStitchBlend = .average,
                                   maxOutputPixels: Int = 80_000_000,
                                   maxWorkingBytes: Int = 768 * 1_024 * 1_024,
                                   progress: ProgressHandler? = nil,
                                   cancellationCheck: CancellationCheck = {
                                       try Task<Never, Never>.checkCancellation()
                                   }) throws -> WorkspaceStitchResult {
        guard !tiles.isEmpty, tiles.allSatisfy({ $0.plane.isValid }) else {
            throw ImageRegistrationError.invalidPlane
        }
        try cancellationCheck()
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for tile in tiles {
            try cancellationCheck()
            let corners = [
                WorkspaceCoordinate(x: 0, y: 0),
                WorkspaceCoordinate(x: Double(tile.plane.width), y: 0),
                WorkspaceCoordinate(x: 0, y: Double(tile.plane.height)),
                WorkspaceCoordinate(x: Double(tile.plane.width), y: Double(tile.plane.height)),
            ].map(tile.transform.applying)
            minX = min(minX, corners.map(\.x).min() ?? 0)
            minY = min(minY, corners.map(\.y).min() ?? 0)
            maxX = max(maxX, corners.map(\.x).max() ?? 0)
            maxY = max(maxY, corners.map(\.y).max() ?? 0)
        }
        guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite,
              maxX >= minX, maxY >= minY,
              let originX = Int(exactly: floor(minX)),
              let originY = Int(exactly: floor(minY)),
              let boundX = Int(exactly: ceil(maxX)),
              let boundY = Int(exactly: ceil(maxY)) else {
            throw ImageRegistrationError.invalidGeometry
        }
        let widthResult = boundX.subtractingReportingOverflow(originX)
        let heightResult = boundY.subtractingReportingOverflow(originY)
        guard !widthResult.overflow, !heightResult.overflow else {
            throw ImageRegistrationError.invalidGeometry
        }
        let width = max(1, widthResult.partialValue)
        let height = max(1, heightResult.partialValue)
        let count = width.multipliedReportingOverflow(by: height)
        guard !count.overflow, count.partialValue <= max(0, maxOutputPixels) else {
            throw ImageRegistrationError.outputTooLarge(count.overflow ? Int.max : count.partialValue)
        }
        let memory = memoryEstimate(tiles: tiles, outputPixels: count.partialValue, blend: blend)
        guard maxWorkingBytes >= 0, memory.totalBytes <= maxWorkingBytes else {
            throw ImageRegistrationError.workingMemoryExceeded(
                requiredBytes: memory.totalBytes, limitBytes: max(0, maxWorkingBytes))
        }
        var values = Array(repeating: blend == .maximum ? -Float.infinity : Float(0),
                           count: count.partialValue)
        var coverage = blend == .average ? Array(repeating: UInt16(0), count: count.partialValue) : []
        let sourceRows = tiles.reduce(0) { partial, tile in
            let sum = partial.addingReportingOverflow(tile.plane.height)
            return sum.overflow ? Int.max : sum.partialValue
        }
        let rowTotal = sourceRows.addingReportingOverflow(height)
        let totalRows = max(1, rowTotal.overflow ? Int.max : rowTotal.partialValue)
        var completedRows = 0
        progress?(.init(phase: "Stitching", completedUnits: 0, totalUnits: totalRows))
        for tile in tiles {
            for y in 0..<tile.plane.height {
                try cancellationCheck()
                for x in 0..<tile.plane.width {
                    let destination = tile.transform.applying(
                        to: WorkspaceCoordinate(x: Double(x), y: Double(y)))
                    let destinationX = Int(destination.x.rounded()) - originX
                    let destinationY = Int(destination.y.rounded()) - originY
                    guard destinationX >= 0, destinationY >= 0,
                          destinationX < width, destinationY < height else { continue }
                    let index = destinationY * width + destinationX
                    let source = tile.plane[x, y]
                    switch blend {
                    case .average:
                        if coverage[index] < UInt16.max {
                            values[index] += source
                            coverage[index] += 1
                        }
                    case .maximum:
                        values[index] = max(values[index], source)
                    }
                }
                completedRows += 1
                if y.isMultiple(of: 8) || y == tile.plane.height - 1 {
                    progress?(.init(phase: "Stitching", completedUnits: completedRows,
                                    totalUnits: totalRows))
                }
            }
        }
        if blend == .average {
            for y in 0..<height {
                try cancellationCheck()
                let rowStart = y * width
                for index in rowStart..<(rowStart + width) where coverage[index] > 0 {
                    values[index] /= Float(coverage[index])
                }
                completedRows += 1
                if y.isMultiple(of: 16) || y == height - 1 {
                    progress?(.init(phase: "Blending", completedUnits: completedRows,
                                    totalUnits: totalRows))
                }
            }
        } else {
            for y in 0..<height {
                try cancellationCheck()
                let rowStart = y * width
                for index in rowStart..<(rowStart + width) where !values[index].isFinite {
                    values[index] = 0
                }
                completedRows += 1
                if y.isMultiple(of: 16) || y == height - 1 {
                    progress?(.init(phase: "Finalizing", completedUnits: completedRows,
                                    totalUnits: totalRows))
                }
            }
        }
        progress?(.init(phase: "Complete", completedUnits: totalRows, totalUnits: totalRows))
        return WorkspaceStitchResult(
            plane: WorkspacePixelPlane(width: width, height: height, pixels: values),
            originX: originX, originY: originY,
            tileTransforms: Dictionary(uniqueKeysWithValues: tiles.map { ($0.id, $0.transform) }))
    }

    nonisolated static func memoryEstimate(tiles: [WorkspaceTile], outputPixels: Int,
                                           blend: WorkspaceStitchBlend) -> WorkspaceStitchMemoryEstimate {
        func bytes(_ count: Int, _ stride: Int) -> Int {
            guard count >= 0, stride >= 0 else { return Int.max }
            let result = count.multipliedReportingOverflow(by: stride)
            return result.overflow ? Int.max : result.partialValue
        }
        let inputPixels = tiles.reduce(0) { partial, tile in
            let sum = partial.addingReportingOverflow(tile.plane.pixels.count)
            return sum.overflow ? Int.max : sum.partialValue
        }
        return WorkspaceStitchMemoryEstimate(
            outputBytes: bytes(outputPixels, MemoryLayout<Float>.stride),
            coverageBytes: blend == .average ? bytes(outputPixels, MemoryLayout<UInt16>.stride) : 0,
            liveInputBytes: bytes(inputPixels, MemoryLayout<Float>.stride),
            // A conservative RGBA-sized reserve covers preview/display conversion.
            previewBytes: bytes(outputPixels, 4),
            fixedReserveBytes: 1_024 * 1_024)
    }

    nonisolated static func grayscalePlane(from image: CGImage,
                                           maxDimension: Int = 2048) throws -> WorkspacePixelPlane {
        let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var bytes = Array(repeating: UInt8(0), count: width * height)
        guard let context = CGContext(data: &bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw ImageRegistrationError.invalidPlane
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return WorkspacePixelPlane(width: width, height: height,
                                   pixels: bytes.map { Float($0) / 255 })
    }

    private nonisolated static func correlation(reference: WorkspacePixelPlane,
                                                moving: WorkspacePixelPlane,
                                                dx: Int, dy: Int,
                                                pixelStride: Int,
                                                cancellationCheck: CancellationCheck) throws -> (score: Double, samples: Int) {
        let minX = max(0, dx)
        let maxX = min(reference.width, moving.width + dx)
        let minY = max(0, dy)
        let maxY = min(reference.height, moving.height + dy)
        guard maxX - minX >= 4, maxY - minY >= 4 else { return (-Double.infinity, 0) }
        var count = 0
        var sumA = 0.0
        var sumB = 0.0
        var sumAA = 0.0
        var sumBB = 0.0
        var sumAB = 0.0
        for y in stride(from: minY, to: maxY, by: pixelStride) {
            if ((y - minY) / max(1, pixelStride)).isMultiple(of: 32) {
                try cancellationCheck()
            }
            for x in stride(from: minX, to: maxX, by: pixelStride) {
                let a = Double(reference[x, y])
                let b = Double(moving[x - dx, y - dy])
                sumA += a; sumB += b
                sumAA += a * a; sumBB += b * b; sumAB += a * b
                count += 1
            }
        }
        guard count > 1 else { return (-Double.infinity, count) }
        let n = Double(count)
        let covariance = sumAB - sumA * sumB / n
        let varianceA = max(0, sumAA - sumA * sumA / n)
        let varianceB = max(0, sumBB - sumB * sumB / n)
        let denominator = sqrt(varianceA * varianceB)
        return denominator > 1e-12 ? (covariance / denominator, count) : (-Double.infinity, count)
    }
}
