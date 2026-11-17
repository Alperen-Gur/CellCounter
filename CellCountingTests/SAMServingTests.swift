import Foundation
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CellCounting

/// Warm workers for SAM detection and point/box refinement, and the grey
/// planes the native refinement fallback crops from. No Python process is
/// started: the pool runs in-memory stand-in workers and the one-shot
/// launcher records its calls. The payload equivalence of a served and a
/// one-shot `sam_detect.py` run is covered by
/// `CellCounting/python/tests/test_sam_serving.py`.
struct SAMServingTests {
    private static let python = URL(fileURLWithPath: "/runtime/venv/bin/python3")
    private static let script = URL(fileURLWithPath: "/runtime/sam_detect.py")

    // MARK: - Worker keys

    @Test func detectionWorkerIsKeyedByEnvironmentScriptModelTypeAndGPUSetting() {
        let key = SAMDetectionService.workerKey(pythonURL: Self.python, scriptURL: Self.script,
                                                modelType: "vit_b_lm", useGPU: true)
        #expect(key.pythonPath == "/runtime/venv/bin/python3")
        #expect(key.scriptPath == "/runtime/sam_detect.py")
        #expect(key.modelSignature == "cellpose3|sam|vit_b_lm|gpu=true")
        #expect(key == SAMDetectionService.workerKey(pythonURL: Self.python, scriptURL: Self.script,
                                                     modelType: "vit_b_lm", useGPU: true))
        #expect(key != SAMDetectionService.workerKey(pythonURL: Self.python, scriptURL: Self.script,
                                                     modelType: "vit_b_lm", useGPU: false))
        #expect(key != SAMDetectionService.workerKey(pythonURL: Self.python, scriptURL: Self.script,
                                                     modelType: "vit_t", useGPU: true))
    }

    @Test func refinementWorkerIsKeyedByEnvironmentScriptAndModelTypeApartFromDetection() {
        let key = PromptSegmentationRunner.workerKey(pythonURL: Self.python, scriptURL: Self.script,
                                                     modelType: "vit_b_lm")
        #expect(key.modelSignature == "cellpose3|sam-prompt|vit_b_lm|device=default")
        #expect(key != PromptSegmentationRunner.workerKey(pythonURL: Self.python, scriptURL: Self.script,
                                                          modelType: "vit_b_histopathology"))
        for gpu in [true, false] {
            #expect(key != SAMDetectionService.workerKey(pythonURL: Self.python, scriptURL: Self.script,
                                                         modelType: "vit_b_lm", useGPU: gpu))
        }
        // Two spellings of one environment share a worker; another
        // environment does not.
        #expect(key == PromptSegmentationRunner.workerKey(
            pythonURL: URL(fileURLWithPath: "/runtime/venv/bin/../bin/python3"),
            scriptURL: URL(fileURLWithPath: "/runtime/./sam_detect.py"), modelType: "vit_b_lm"))
        #expect(key != PromptSegmentationRunner.workerKey(
            pythonURL: URL(fileURLWithPath: "/elsewhere/venv/bin/python3"),
            scriptURL: Self.script, modelType: "vit_b_lm"))
    }

    /// micro_sam is installed into the base environment, which
    /// `DetectorRegistry.install` and `AppState` retire by this prefix.
    @Test func samWorkersRetireWithTheBaseEnvironment() async throws {
        #expect(ServedDetection.samSignature(modelType: "vit_t", useGPU: false)
            .hasPrefix(ServedDetection.baseRuntimePrefix))
        #expect(ServedDetection.samPromptSignature(modelType: "vit_t")
            .hasPrefix(ServedDetection.baseRuntimePrefix))

        let launcher = StandInLauncher()
        let pool = PersistentSidecarPool(maxWarmWorkers: 8, idleTimeout: nil, launcher: launcher.launcher)
        let detection = SAMDetectionService.workerKey(pythonURL: Self.python, scriptURL: Self.script,
                                                      modelType: "vit_b_lm", useGPU: true)
        let refinement = PromptSegmentationRunner.workerKey(pythonURL: Self.python, scriptURL: Self.script,
                                                            modelType: "vit_b_lm")
        let cellpose4 = ServedDetection.key(
            pythonURL: URL(fileURLWithPath: "/runtime/venv4/bin/python3"),
            scriptURL: URL(fileURLWithPath: "/runtime/custom_detect.py"),
            signature: ServedDetection.customSignature(path: "/m", kind: "cellpose",
                                                       usesCellpose4Runtime: true, useGPU: true))
        for key in [detection, refinement, cellpose4] {
            _ = try await pool.run(key: key, pythonURL: Self.python, scriptURL: Self.script, args: [])
        }
        await pool.retire(modelSignaturePrefix: ServedDetection.baseRuntimePrefix)
        #expect(await !pool.hasWorker(for: detection))
        #expect(await !pool.hasWorker(for: refinement))
        #expect(await pool.hasWorker(for: cellpose4))
        await pool.retireAll()
    }

    @Test func refinementArgumentsAreTheOneShotCommandLineWithoutTheScript() throws {
        let id = try #require(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        let cache = PromptSegmentationRunner.embeddingCacheURL(
            in: URL(fileURLWithPath: "/library/Embeddings"), imageId: id, modelType: "vit/b")
        // `EmbeddingCacheJanitor` relies on this name.
        #expect(cache.path == "/library/Embeddings/6F9619FF-8B86-D011-B42D-00C04FC964FF-vit-b.zarr")

        let image = URL(fileURLWithPath: "/library/Images/a.png")
        let common = ["--image", "/library/Images/a.png", "--model", "vit_b_lm", "--pxPerUm", "2.5",
                      "--prompts", "interactive", "--embedding-cache", cache.path]
        #expect(PromptSegmentationRunner.requestArgs(
            imageURL: image, modelType: "vit_b_lm", pxPerUm: 2.5, embeddingCache: cache,
            prompt: .point(x: 10.5, y: 20)) == common + ["--prompt-point", "10.5", "20.0"])
        #expect(PromptSegmentationRunner.requestArgs(
            imageURL: image, modelType: "vit_b_lm", pxPerUm: 2.5, embeddingCache: cache,
            prompt: .box(x0: 1, y0: 2, x1: 30, y1: 40))
            == common + ["--prompt-box", "1.0", "2.0", "30.0", "40.0"])
    }

    // MARK: - Fallback decision

    @Test func detectionWorkerThatCannotStartFallsBackToOneShot() async throws {
        let launcher = StandInLauncher(launchError: .launchFailed("no interpreter"))
        let pool = PersistentSidecarPool(idleTimeout: nil, launcher: launcher.launcher)
        let oneShot = OneShotRecorder()
        let args = ["--image", "/a.png", "--model", "vit_b_lm", "--pxPerUm", "1", "--prompts", "auto"]

        let outcome = try await ServedDetection.run(
            key: SAMDetectionService.workerKey(pythonURL: Self.python, scriptURL: Self.script,
                                               modelType: "vit_b_lm", useGPU: true),
            pythonURL: Self.python, scriptURL: Self.script, requestArgs: args,
            pool: pool, oneShot: oneShot.launcher)

        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "one-shot")
        #expect(oneShot.calls.map(\.args) == [[Self.script.path] + args])
    }

    @Test func refinementUsesAHealthyWorkerWithoutAFallback() async throws {
        let launcher = StandInLauncher()
        let pool = PersistentSidecarPool(idleTimeout: nil, launcher: launcher.launcher)
        let oneShot = OneShotRecorder()
        let key = PromptSegmentationRunner.workerKey(pythonURL: Self.python, scriptURL: Self.script,
                                                     modelType: "vit_b_lm")
        let args = ["--image", "/a.png", "--prompt-point", "1.0", "2.0"]

        let outcome = try await PromptSegmentationRunner.outcome(
            key: key, pythonURL: Self.python, scriptURL: Self.script, requestArgs: args,
            pool: pool, oneShot: oneShot.launcher)

        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "served")
        #expect(oneShot.calls.isEmpty)
        #expect(launcher.worker(for: key)?.requests == [args])
        await pool.retireAll()
    }

    @Test func crashedRefinementWorkerFallsBackToOneShot() async throws {
        let crash = PersistentSidecarError.processTerminated(status: 1, stderr: Data("Traceback".utf8))
        let launcher = StandInLauncher(failure: crash)
        let pool = PersistentSidecarPool(idleTimeout: nil, launcher: launcher.launcher)
        let oneShot = OneShotRecorder()
        let args = ["--image", "/a.png", "--prompt-point", "1.0", "2.0"]

        let outcome = try await PromptSegmentationRunner.outcome(
            key: PromptSegmentationRunner.workerKey(pythonURL: Self.python, scriptURL: Self.script,
                                                    modelType: "vit_b_lm"),
            pythonURL: Self.python, scriptURL: Self.script, requestArgs: args,
            pool: pool, oneShot: oneShot.launcher)

        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "one-shot")
        #expect(oneShot.calls.map(\.args) == [[Self.script.path] + args])
        #expect(await pool.workerCount == 0)
    }

    @Test func stoppedRefinementWorkerReportsCancellationWithoutAFallback() async throws {
        // The Cancel button or app quit terminated the worker.
        let stopped = PersistentSidecarError.processTerminated(status: 15, stderr: Data())
        let launcher = StandInLauncher(failure: stopped)
        let pool = PersistentSidecarPool(idleTimeout: nil, launcher: launcher.launcher)
        let oneShot = OneShotRecorder()

        let outcome = try await PromptSegmentationRunner.outcome(
            key: PromptSegmentationRunner.workerKey(pythonURL: Self.python, scriptURL: Self.script,
                                                    modelType: "vit_b_lm"),
            pythonURL: Self.python, scriptURL: Self.script, requestArgs: [],
            pool: pool, oneShot: oneShot.launcher)

        #expect(outcome.exitCode == 15)
        #expect(oneShot.calls.isEmpty)
        #expect(throws: DetectionError.self) { try outcome.throwIfFailed() }
    }

    /// A one-shot refinement process ran to the end even when the Results
    /// view stopped waiting for it. The warm worker does too, so closing the
    /// view mid-click keeps the model and embeddings loaded.
    @Test func refinementRequestOutlivesItsCaller() async throws {
        let worker = GatedWorker()
        let pool = PersistentSidecarPool(idleTimeout: nil, launcher: { _, _, _, _ in worker })
        let oneShot = OneShotRecorder()
        let key = PromptSegmentationRunner.workerKey(pythonURL: Self.python, scriptURL: Self.script,
                                                     modelType: "vit_b_lm")

        let caller = Task {
            try await PromptSegmentationRunner.outcome(
                key: key, pythonURL: Self.python, scriptURL: Self.script, requestArgs: ["click"],
                pool: pool, oneShot: oneShot.launcher)
        }
        try await worker.waitForRequests(1)
        caller.cancel()
        worker.open()
        let outcome = try await caller.value

        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "served")
        #expect(worker.terminateCount == 0)
        #expect(await pool.hasWorker(for: key))
        #expect(oneShot.calls.isEmpty)
        await pool.retireAll()
    }

    /// A detection request, by contrast, stops its worker when cancelled.
    @Test func cancelledDetectionRequestStopsItsWorker() async throws {
        let worker = GatedWorker()
        let pool = PersistentSidecarPool(idleTimeout: nil, launcher: { _, _, _, _ in worker })
        let oneShot = OneShotRecorder()
        let key = SAMDetectionService.workerKey(pythonURL: Self.python, scriptURL: Self.script,
                                                modelType: "vit_b_lm", useGPU: true)

        let caller = Task {
            try await ServedDetection.run(key: key, pythonURL: Self.python, scriptURL: Self.script,
                                          requestArgs: ["image"], pool: pool, oneShot: oneShot.launcher)
        }
        try await worker.waitForRequests(1)
        caller.cancel()
        let outcome = try await caller.value

        #expect(outcome.exitCode == 15)
        #expect(worker.terminateCount >= 1)
        #expect(await !pool.hasWorker(for: key))
        #expect(oneShot.calls.isEmpty)
    }

    @Test func refinementFallsBackEvenAfterItsCallerStoppedWaiting() async throws {
        let launcher = StandInLauncher(launchError: .launchFailed("no interpreter"))
        let pool = PersistentSidecarPool(idleTimeout: nil, launcher: launcher.launcher)
        let oneShot = OneShotRecorder()

        let caller = Task { () -> SidecarOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PromptSegmentationRunner.outcome(
                key: PromptSegmentationRunner.workerKey(pythonURL: Self.python, scriptURL: Self.script,
                                                        modelType: "vit_b_lm"),
                pythonURL: Self.python, scriptURL: Self.script, requestArgs: ["click"],
                pool: pool, oneShot: oneShot.launcher)
        }
        let outcome = try await caller.value
        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "one-shot")
        #expect(oneShot.calls.count == 1)
    }

    // MARK: - Grey planes for the native fallback

    @Test func planeCropsEqualPerClickCrops() throws {
        let url = try writeImage(width: 173, height: 121, rgb: true) { x, y in
            UInt8((x * 7 + y * 13 + (x * y) % 17) % 256)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try PromptImagePlane.decodeImage(url)
        let plane = try PromptImagePlane.draw(image)
        #expect(plane.width == 173 && plane.height == 121)
        let rects = [(0, 0, 173, 121), (0, 0, 40, 30), (133, 91, 40, 30), (57, 3, 96, 96),
                     (1, 60, 1, 1), (100, 0, 73, 121), (20, 110, 150, 11)]
        for (x, y, width, height) in rects {
            #expect(plane.crop(x: x, y: y, width: width, height: height)
                == (try PromptImagePlane.drawCrop(of: image, x: x, y: y, width: width, height: height)),
                    "crop \(x),\(y) \(width)x\(height)")
        }
        // Outside the image reads 0, as an undrawn context does.
        let past = plane.crop(x: 170, y: 118, width: 6, height: 6)
        #expect(past[0] == plane.pixels[118 * 173 + 170])
        #expect(past[5] == 0 && past[35] == 0)
    }

    @MainActor
    @Test func fallbackFindsTheObjectUnderTheClick() throws {
        // A bright disc near the top and nothing at its mirror position near
        // the bottom: the fallback used to crop the mirrored rectangle.
        let center = (x: 40.0, y: 20.0), radius = 8.0
        let url = try writeImage(width: 120, height: 100, rgb: false) { x, y in
            let inside = hypot(Double(x) - center.x, Double(y) - center.y) <= radius
            return inside ? 220 : UInt8(20 + (x * 3 + y * 5) % 9)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let plane = try PromptImagePlane.draw(PromptImagePlane.decodeImage(url))
        let id = UUID()
        for prompt in [MaskPrompt.point(x: 41, y: 19),
                       .box(x0: 30, y0: 10, x1: 50, y1: 30)] {
            let fromPlane = try PromptRefinementService.adaptiveCell(
                source: .plane(plane), prompt: prompt, pxPerUm: 2, expectedDiameterPx: 16, id: id)
            let fromFile = try PromptRefinementService.adaptiveCell(
                source: .file(url), prompt: prompt, pxPerUm: 2, expectedDiameterPx: 16, id: id)
            #expect(fromPlane == fromFile)
            #expect(abs(fromPlane.cx - center.x) < 1 && abs(fromPlane.cy - center.y) < 1,
                    "found \(fromPlane.cx), \(fromPlane.cy)")
            #expect(abs(fromPlane.diameterPx - 2 * radius) < 2.5)
        }
    }

    @Test func planeCacheKeepsTheMostRecentImages() async throws {
        let urls = try (0..<3).map { index in
            try writeImage(width: 20 + index, height: 10, rgb: false) { x, _ in UInt8(x * 10) }
        }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let cache = PromptImagePlaneCache(countLimit: 2, byteLimit: 1_000_000)

        for url in urls { _ = try await cache.source(for: url) }
        #expect(await cache.cachedCount == 2)
        #expect(await !cache.isCached(urls[0]))
        #expect(await cache.isCached(urls[1]))
        #expect(await cache.isCached(urls[2]))
        #expect(await cache.cachedBytes == 21 * 10 + 22 * 10)

        _ = try await cache.source(for: urls[1])   // now the most recent
        _ = try await cache.source(for: urls[0])   // evicts urls[2]
        #expect(await cache.isCached(urls[0]))
        #expect(await cache.isCached(urls[1]))
        #expect(await !cache.isCached(urls[2]))

        await cache.removeAll()
        #expect(await cache.cachedCount == 0)
        #expect(await cache.cachedBytes == 0)
    }

    @Test func imagesLargerThanTheBudgetAreReadPerClick() async throws {
        let url = try writeImage(width: 64, height: 64, rgb: false) { x, y in UInt8((x + y) % 256) }
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = PromptImagePlaneCache(countLimit: 2, byteLimit: 64 * 64 - 1)
        guard case .file(let fileURL) = try await cache.source(for: url) else {
            Issue.record("An image over the budget must not be kept as a plane")
            return
        }
        #expect(fileURL == url)
        #expect(await cache.cachedCount == 0)
    }

    @Test func aReplacedFileIsReadAgain() async throws {
        let url = try writeImage(width: 30, height: 10, rgb: false) { _, _ in 10 }
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = PromptImagePlaneCache()
        guard case .plane(let first) = try await cache.source(for: url) else {
            Issue.record("Expected a plane"); return
        }
        #expect(first.width == 30)

        _ = try writeImage(width: 31, height: 12, rgb: false, to: url) { _, _ in 200 }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: url.path)
        guard case .plane(let second) = try await cache.source(for: url) else {
            Issue.record("Expected a plane"); return
        }
        #expect(second.width == 31 && second.height == 12)
        #expect(second.pixels.allSatisfy { $0 == 200 })
    }

    @Test func aCancelledClickDecodesNothing() async throws {
        let url = try writeImage(width: 16, height: 16, rgb: false) { _, _ in 50 }
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = PromptImagePlaneCache()
        let caller = Task { () -> PromptPixelSource in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cache.source(for: url)
        }
        await #expect(throws: CancellationError.self) { _ = try await caller.value }
        #expect(await cache.cachedCount == 0)
    }

    @Test func anUndecodableFileFailsAsBefore() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cc-not-an-image-\(UUID()).png")
        try Data("not an image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: DetectionError.self) {
            _ = try await PromptImagePlaneCache().source(for: url)
        }
    }

    // MARK: - Helpers

    /// Writes a PNG whose grey level at (x, y), origin top left, is `level`.
    @discardableResult
    private func writeImage(width: Int, height: Int, rgb: Bool, to existing: URL? = nil,
                            level: (Int, Int) -> UInt8) throws -> URL {
        let url = existing ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-sam-plane-\(UUID()).png")
        let components = rgb ? 4 : 1
        var bytes = [UInt8](repeating: 255, count: width * height * components)
        for y in 0..<height {
            for x in 0..<width {
                let value = level(x, y)
                let offset = (y * width + x) * components
                if rgb {
                    bytes[offset] = value
                    bytes[offset + 1] = value &+ 40
                    bytes[offset + 2] = 255 &- value
                } else {
                    bytes[offset] = value
                }
            }
        }
        let space = rgb ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray()
        let info = rgb ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.none.rawValue
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
                                         bitsPerPixel: 8 * components, bytesPerRow: width * components,
                                         space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                                         provider: provider, decode: nil, shouldInterpolate: false,
                                         intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}

// MARK: - Stand-ins

/// In-memory worker that answers every request the same way.
private final class StandInWorker: PersistentSidecarWorkerHandle, @unchecked Sendable {
    private let lock = NSLock()
    private let failure: PersistentSidecarError?
    private var healthy = true
    private var received: [[String]] = []

    init(failure: PersistentSidecarError?) { self.failure = failure }

    var isHealthy: Bool { lock.withLock { healthy } }
    var requests: [[String]] { lock.withLock { received } }

    func request(args: [String], onStderrLine: (@Sendable (String) -> Void)?) async throws -> SidecarOutcome {
        lock.withLock { received.append(args) }
        if let failure { throw failure }
        return SidecarOutcome(exitCode: 0, stdout: Data("served".utf8), stderr: Data())
    }

    func terminate() { lock.withLock { healthy = false } }
    func shutdown() { lock.withLock { healthy = false } }
}

private final class StandInLauncher: @unchecked Sendable {
    private let lock = NSLock()
    private let failure: PersistentSidecarError?
    private let launchError: PersistentSidecarError?
    private var launched: [PersistentSidecarKey: StandInWorker] = [:]

    init(failure: PersistentSidecarError? = nil, launchError: PersistentSidecarError? = nil) {
        self.failure = failure
        self.launchError = launchError
    }

    var launcher: PersistentSidecarPool.Launcher {
        { [self] key, _, _, _ in
            if let launchError { throw launchError }
            let worker = StandInWorker(failure: failure)
            lock.withLock { launched[key] = worker }
            return worker
        }
    }

    func worker(for key: PersistentSidecarKey) -> StandInWorker? {
        lock.withLock { launched[key] }
    }
}

/// A worker whose requests wait until `open()`. Terminating it fails the
/// waiting request the way a stopped process does (status 15).
private final class GatedWorker: PersistentSidecarWorkerHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var healthy = true
    private var received = 0
    private var terminations = 0

    var isHealthy: Bool { lock.withLock { healthy } }
    var terminateCount: Int { lock.withLock { terminations } }

    func open() { lock.withLock { isOpen = true } }

    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<2_000 {
            if lock.withLock({ received >= count }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The worker never received \(count) request(s)")
    }

    func request(args: [String], onStderrLine: (@Sendable (String) -> Void)?) async throws -> SidecarOutcome {
        lock.withLock { received += 1 }
        while true {
            let state = lock.withLock { (isOpen, healthy) }
            if !state.1 {
                throw PersistentSidecarError.processTerminated(status: 15, stderr: Data())
            }
            if state.0 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return SidecarOutcome(exitCode: 0, stdout: Data("served".utf8), stderr: Data())
    }

    func terminate() {
        lock.withLock {
            healthy = false
            terminations += 1
        }
    }

    func shutdown() { lock.withLock { healthy = false } }
}

private final class OneShotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(python: URL, args: [String])] = []

    var calls: [(python: URL, args: [String])] { lock.withLock { recorded } }

    var launcher: ServedDetection.OneShotLauncher {
        { [self] python, args, _ in
            lock.withLock { recorded.append((python, args)) }
            return SidecarOutcome(exitCode: 0, stdout: Data("one-shot".utf8), stderr: Data())
        }
    }
}
