import Foundation
import CoreGraphics
import ImageIO

enum MaskPrompt: Sendable {
    case point(x: Double, y: Double)
    case box(x0: Double, y0: Double, x1: Double, y1: Double)

    nonisolated var center: CGPoint {
        switch self {
        case .point(let x, let y): return CGPoint(x: x, y: y)
        case .box(let x0, let y0, let x1, let y1):
            return CGPoint(x: (x0 + x1) / 2, y: (y0 + y1) / 2)
        }
    }
}

struct PromptRefinementResult: Sendable {
    enum Backend: String, Sendable {
        case cachedMicroSAM = "micro_sam · cached embedding"
        case adaptiveFallback = "adaptive contour fallback"
    }
    let cell: DetectedCell
    let backend: Backend
}

/// Point/box mask refinement. A compatible installed micro_sam model is used
/// first and writes reusable per-image embeddings; the native adaptive
/// connected-component fallback keeps the interaction useful offline and for
/// non-SAM detectors.
///
/// micro_sam requests go to a warm `sam_detect.py --serve` worker per model
/// type (`PromptSegmentationRunner`). It keeps the model loaded and the
/// embeddings of the last images clicked in memory, so after the first click
/// on an image a click runs only SAM's prompt decoder. The fallback crops
/// each click from a grey plane of the image drawn once
/// (`PromptImagePlaneCache`).
enum PromptRefinementService {
    static func refine(imageURL: URL, imageId: UUID, modelId: String,
                       prompt: MaskPrompt, pxPerUm: Double,
                       expectedDiameterPx: Double,
                       replacingId: UUID?) async throws -> PromptRefinementResult {
        if let modelType = SAMDownloader.modelType(for: modelId),
           let result = try? await PromptSegmentationRunner.run(
                imageURL: imageURL, imageId: imageId, modelType: modelType,
                prompt: prompt, pxPerUm: pxPerUm),
           let first = result.cells.first {
            return PromptRefinementResult(
                cell: reidentified(first, id: replacingId ?? UUID()),
                backend: .cachedMicroSAM)
        }

        let source = try await PromptImagePlaneCache.shared.source(for: imageURL)
        let cell = try await Task.detached(priority: .userInitiated) {
            try adaptiveCell(source: source, prompt: prompt,
                             pxPerUm: pxPerUm,
                             expectedDiameterPx: expectedDiameterPx,
                             id: replacingId ?? UUID())
        }.value
        return PromptRefinementResult(cell: cell, backend: .adaptiveFallback)
    }

    private nonisolated static func reidentified(_ cell: DetectedCell, id: UUID) -> DetectedCell {
        DetectedCell(id: id, cx: cell.cx, cy: cell.cy,
                     diameter: cell.diameter, diameterPx: cell.diameterPx,
                     confidence: cell.confidence,
                     areaMicrons2: cell.areaMicrons2,
                     perimeterMicrons: cell.perimeterMicrons,
                     circularity: cell.circularity,
                     eccentricity: cell.eccentricity,
                     meanIntensity: cell.meanIntensity,
                     integratedDensity: cell.integratedDensity,
                     centroidUmX: cell.centroidUmX,
                     centroidUmY: cell.centroidUmY,
                     aspectRatio: cell.aspectRatio,
                     solidity: cell.solidity,
                     edgeTouching: cell.edgeTouching,
                     likelyClump: cell.likelyClump,
                     likelyDebris: cell.likelyDebris,
                     sizeClass: cell.sizeClass,
                     isManual: cell.isManual,
                     contourPx: cell.contourPx,
                     channelIntensities: cell.channelIntensities)
    }

    /// The native fallback for one click: in the crop around the prompt, the
    /// Otsu-thresholded connected component under (or nearest to) the
    /// prompt's centre.
    nonisolated static func adaptiveCell(source: PromptPixelSource, prompt: MaskPrompt,
                                         pxPerUm: Double,
                                         expectedDiameterPx: Double,
                                         id: UUID) throws -> DetectedCell {
        let width: Int, height: Int
        let cropPixels: (_ x: Int, _ y: Int, _ width: Int, _ height: Int) throws -> [UInt8]
        switch source {
        case .plane(let plane):
            width = plane.width
            height = plane.height
            cropPixels = { plane.crop(x: $0, y: $1, width: $2, height: $3) }
        case .file(let url):
            let image = try PromptImagePlane.decodeImage(url)
            width = image.width
            height = image.height
            cropPixels = { try PromptImagePlane.drawCrop(of: image, x: $0, y: $1, width: $2, height: $3) }
        }
        let center = prompt.center
        let crop = cropRect(prompt: prompt, center: center,
                            expectedDiameter: expectedDiameterPx,
                            imageWidth: width, imageHeight: height)
        let cropX = Int(crop.minX), cropY = Int(crop.minY)
        let cropW = max(1, Int(crop.width)), cropH = max(1, Int(crop.height))
        let pixels = try cropPixels(cropX, cropY, cropW, cropH)

        let threshold = otsuThreshold(pixels)
        var seedX = min(cropW - 1, max(0, Int(center.x) - cropX))
        var seedY = min(cropH - 1, max(0, Int(center.y) - cropY))
        let seedMean = localMean(pixels, width: cropW, height: cropH,
                                 x: seedX, y: seedY, radius: 3)
        let globalMean = pixels.isEmpty ? 0
            : Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count)
        let foreground: (UInt8) -> Bool = seedMean < globalMean
            ? { $0 <= threshold }
            : { $0 >= threshold }
        if !foreground(pixels[seedY * cropW + seedX]),
           let nearest = nearestForeground(pixels, width: cropW, height: cropH,
                                           x: seedX, y: seedY, test: foreground) {
            seedX = nearest.0; seedY = nearest.1
        }

        let component = floodFill(pixels, width: cropW, height: cropH,
                                  seedX: seedX, seedY: seedY, test: foreground)
        guard component.count >= 9 else {
            throw DetectionError.sidecarFailed(exitCode: 0,
                                                stderr: "Prompt did not isolate a usable object.")
        }
        let xs = component.map { Double($0 % cropW + cropX) }
        let ys = component.map { Double($0 / cropW + cropY) }
        let cx = xs.reduce(0, +) / Double(xs.count)
        let cy = ys.reduce(0, +) / Double(ys.count)
        let areaPx = Double(component.count)
        let diameterPx = 2 * sqrt(areaPx / .pi)
        let contour = radialContour(component: component, width: cropW,
                                    cropX: cropX, cropY: cropY,
                                    cx: cx, cy: cy)
        let perimeterPx = approximatePerimeter(component: Set(component),
                                               width: cropW, height: cropH)
        let scale = max(pxPerUm, 0.000_001)
        let perimeterUm = perimeterPx / scale
        let areaUm = areaPx / (scale * scale)
        let circularity = perimeterUm > 0
            ? min(1, 4 * Double.pi * areaUm / (perimeterUm * perimeterUm)) : nil
        return DetectedCell(id: id, cx: cx, cy: cy,
                            diameter: diameterPx / scale,
                            diameterPx: diameterPx, confidence: 1,
                            areaMicrons2: areaUm,
                            perimeterMicrons: perimeterUm,
                            circularity: circularity,
                            centroidUmX: cx / scale,
                            centroidUmY: cy / scale,
                            contourPx: contour)
    }

    private nonisolated static func cropRect(prompt: MaskPrompt, center: CGPoint,
                                 expectedDiameter: Double,
                                 imageWidth: Int, imageHeight: Int) -> CGRect {
        let base: CGRect
        switch prompt {
        case .point:
            let side = min(1024, max(96, expectedDiameter * 4))
            base = CGRect(x: center.x - side / 2, y: center.y - side / 2,
                          width: side, height: side)
        case .box(let x0, let y0, let x1, let y1):
            let raw = CGRect(x: min(x0, x1), y: min(y0, y1),
                             width: abs(x1 - x0), height: abs(y1 - y0))
            base = raw.insetBy(dx: -max(12, raw.width * 0.2),
                               dy: -max(12, raw.height * 0.2))
        }
        let x = max(0, min(Double(imageWidth - 1), base.minX))
        let y = max(0, min(Double(imageHeight - 1), base.minY))
        return CGRect(x: x, y: y,
                      width: min(Double(imageWidth) - x, max(1, base.width)),
                      height: min(Double(imageHeight) - y, max(1, base.height)))
    }

    private nonisolated static func otsuThreshold(_ values: [UInt8]) -> UInt8 {
        var histogram = [Int](repeating: 0, count: 256)
        for value in values { histogram[Int(value)] += 1 }
        let total = values.count
        guard total > 0 else { return 127 }
        let sum = histogram.indices.reduce(0.0) { $0 + Double($1 * histogram[$1]) }
        var backgroundWeight = 0
        var backgroundSum = 0.0
        var bestVariance = -1.0
        var best = 127
        for threshold in 0..<256 {
            backgroundWeight += histogram[threshold]
            guard backgroundWeight > 0 else { continue }
            let foregroundWeight = total - backgroundWeight
            guard foregroundWeight > 0 else { break }
            backgroundSum += Double(threshold * histogram[threshold])
            let meanBackground = backgroundSum / Double(backgroundWeight)
            let meanForeground = (sum - backgroundSum) / Double(foregroundWeight)
            let variance = Double(backgroundWeight * foregroundWeight)
                * pow(meanBackground - meanForeground, 2)
            if variance > bestVariance { bestVariance = variance; best = threshold }
        }
        return UInt8(best)
    }

    private nonisolated static func localMean(_ values: [UInt8], width: Int, height: Int,
                                  x: Int, y: Int, radius: Int) -> Double {
        var sum = 0, count = 0
        for yy in max(0, y - radius)...min(height - 1, y + radius) {
            for xx in max(0, x - radius)...min(width - 1, x + radius) {
                sum += Int(values[yy * width + xx]); count += 1
            }
        }
        return count > 0 ? Double(sum) / Double(count) : 0
    }

    private nonisolated static func nearestForeground(_ pixels: [UInt8], width: Int, height: Int,
                                          x: Int, y: Int,
                                          test: (UInt8) -> Bool) -> (Int, Int)? {
        for radius in 1...12 {
            for yy in max(0, y - radius)...min(height - 1, y + radius) {
                for xx in max(0, x - radius)...min(width - 1, x + radius)
                    where test(pixels[yy * width + xx]) {
                    return (xx, yy)
                }
            }
        }
        return nil
    }

    private nonisolated static func floodFill(_ pixels: [UInt8], width: Int, height: Int,
                                  seedX: Int, seedY: Int,
                                  test: (UInt8) -> Bool) -> [Int] {
        let seed = seedY * width + seedX
        guard pixels.indices.contains(seed), test(pixels[seed]) else { return [] }
        var visited = [Bool](repeating: false, count: pixels.count)
        var queue = [seed]
        visited[seed] = true
        var cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]; cursor += 1
            let x = index % width, y = index / width
            for neighbor in [index - 1, index + 1, index - width, index + width] {
                guard neighbor >= 0, neighbor < pixels.count else { continue }
                let nx = neighbor % width, ny = neighbor / width
                guard abs(nx - x) + abs(ny - y) == 1,
                      !visited[neighbor], test(pixels[neighbor]) else { continue }
                visited[neighbor] = true
                queue.append(neighbor)
            }
            // A pathological flat image should not allocate indefinitely.
            if queue.count > 1_500_000 { break }
        }
        return queue
    }

    private nonisolated static func radialContour(component: [Int], width: Int,
                                      cropX: Int, cropY: Int,
                                      cx: Double, cy: Double) -> [CGPoint]? {
        let buckets = 96
        var farthest = [(distance: Double, point: CGPoint)?](repeating: nil, count: buckets)
        for index in component {
            let x = Double(index % width + cropX) + 0.5
            let y = Double(index / width + cropY) + 0.5
            var angle = atan2(y - cy, x - cx)
            if angle < 0 { angle += 2 * .pi }
            let bucket = min(buckets - 1, Int(angle / (2 * .pi) * Double(buckets)))
            let distance = hypot(x - cx, y - cy)
            if farthest[bucket] == nil || distance > farthest[bucket]!.distance {
                farthest[bucket] = (distance, CGPoint(x: x, y: y))
            }
        }
        let points = farthest.compactMap { $0?.point }
        return points.count >= 8 ? points : nil
    }

    private nonisolated static func approximatePerimeter(component: Set<Int>,
                                             width: Int, height: Int) -> Double {
        var edges = 0
        for index in component {
            let x = index % width, y = index / width
            if x == 0 || !component.contains(index - 1) { edges += 1 }
            if x == width - 1 || !component.contains(index + 1) { edges += 1 }
            if y == 0 || !component.contains(index - width) { edges += 1 }
            if y == height - 1 || !component.contains(index + width) { edges += 1 }
        }
        return Double(edges)
    }
}

/// micro_sam point/box requests on a warm `sam_detect.py --serve` worker
/// (`ServedDetection.samPromptSignature`), with the one-shot process as the
/// fallback when the worker can't start or fails. The worker answers exactly
/// as a one-shot run of the same arguments would.
enum PromptSegmentationRunner {
    static func run(imageURL: URL, imageId: UUID, modelType: String,
                    prompt: MaskPrompt, pxPerUm: Double) async throws -> DetectionResult {
        let python = FileStore.shared.pythonInterpreterURL
        guard FileManager.default.isExecutableFile(atPath: python.path),
              let script = PythonRuntime.stagedScriptURL(named: "sam_detect.py")
                ?? PythonRuntime.bundledPythonURL(named: "sam_detect.py") else {
            throw DetectionError.modelNotInstalled(modelId: modelType)
        }
        let embeddings = FileStore.shared.embeddingsDir
        try? FileManager.default.createDirectory(at: embeddings,
                                                 withIntermediateDirectories: true)
        let args = requestArgs(
            imageURL: imageURL, modelType: modelType, pxPerUm: pxPerUm,
            embeddingCache: embeddingCacheURL(in: embeddings, imageId: imageId, modelType: modelType),
            prompt: prompt)
        let outcome = try await outcome(
            key: workerKey(pythonURL: python, scriptURL: script, modelType: modelType),
            pythonURL: python, scriptURL: script, requestArgs: args,
            pool: PersistentSidecarPool.shared, oneShot: ServedDetection.processOneShot)
        try outcome.throwIfFailed()
        return try await SidecarPayload.decodeResultOffMain(stdout: outcome.stdout,
                                                            exitCode: outcome.exitCode)
    }

    /// `Embeddings/<image UUID>-<model type>.zarr`; `EmbeddingCacheJanitor`
    /// relies on this name.
    nonisolated static func embeddingCacheURL(in directory: URL, imageId: UUID,
                                              modelType: String) -> URL {
        let safeModel = modelType.replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent("\(imageId.uuidString)-\(safeModel).zarr")
    }

    /// The per-click arguments, without the script path: the warm worker is
    /// already running it, and a one-shot fallback prepends it.
    nonisolated static func requestArgs(imageURL: URL, modelType: String, pxPerUm: Double,
                                        embeddingCache: URL, prompt: MaskPrompt) -> [String] {
        var args = ["--image", imageURL.path,
                    "--model", modelType, "--pxPerUm", String(pxPerUm),
                    "--prompts", "interactive",
                    "--embedding-cache", embeddingCache.path]
        switch prompt {
        case .point(let x, let y):
            args += ["--prompt-point", String(x), String(y)]
        case .box(let x0, let y0, let x1, let y1):
            args += ["--prompt-box", String(x0), String(y0), String(x1), String(y1)]
        }
        return args
    }

    /// Warm-worker identity: the environment, the script and the micro_sam
    /// model type. Refinement always uses micro_sam's default device.
    nonisolated static func workerKey(pythonURL: URL, scriptURL: URL,
                                      modelType: String) -> PersistentSidecarKey {
        ServedDetection.key(pythonURL: pythonURL, scriptURL: scriptURL,
                            signature: ServedDetection.samPromptSignature(modelType: modelType))
    }

    /// Runs one request on `pool`, falling back to `oneShot` as
    /// `ServedDetection.run` decides.
    ///
    /// Like the one-shot process it replaces, a click the caller stops
    /// waiting for (the Results view closed) still runs to the end: the
    /// request runs in its own task, so the caller's cancellation does not
    /// stop the worker. Stopping it would throw away the loaded model and
    /// embeddings, and could leave a half-written embedding cache on disk.
    /// The Cancel button and app quit still stop the worker, which is a
    /// tracked detection process, and the click then ends as cancelled.
    nonisolated static func outcome(key: PersistentSidecarKey, pythonURL: URL, scriptURL: URL,
                                    requestArgs: [String], pool: PersistentSidecarPool,
                                    oneShot: @escaping ServedDetection.OneShotLauncher) async throws -> SidecarOutcome {
        try await Task.detached(priority: .userInitiated) {
            try await ServedDetection.run(key: key, pythonURL: pythonURL, scriptURL: scriptURL,
                                          requestArgs: requestArgs, pool: pool, oneShot: oneShot)
        }.value
    }
}
