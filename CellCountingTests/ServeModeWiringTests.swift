import Foundation
import Testing
@testable import CellCounting

/// Warm-worker wiring for StarDist, Omnipose, custom models and the classical
/// detector: which requests share a worker, and when a request falls back to
/// a one-shot process. No Python process is started: the pool runs scripted
/// in-memory workers and the one-shot launcher is a recording stand-in.
struct ServeModeWiringTests {
    private static let python = URL(fileURLWithPath: "/runtime/venv/bin/python3")
    private static let script = URL(fileURLWithPath: "/runtime/stardist_detect.py")
    private static let requestArgs = ["--image", "/images/a.png", "--model", "2D_versatile_fluo",
                                      "--pxPerUm", "1.0"]

    // MARK: - Model keys

    @Test func stardistWorkerIsKeyedByEnvironmentScriptAndModelName() {
        let fluo = StarDistDetectionService.workerKey(
            pythonURL: Self.python, scriptURL: Self.script, model: "2D_versatile_fluo")
        #expect(fluo.pythonPath == "/runtime/venv/bin/python3")
        #expect(fluo.scriptPath == "/runtime/stardist_detect.py")
        #expect(fluo.modelSignature == "cellpose3|stardist|2D_versatile_fluo")
        #expect(fluo == StarDistDetectionService.workerKey(
            pythonURL: Self.python, scriptURL: Self.script, model: "2D_versatile_fluo"))
        #expect(fluo != StarDistDetectionService.workerKey(
            pythonURL: Self.python, scriptURL: Self.script, model: "2D_versatile_he"))
    }

    @Test func omniposeWorkerIsKeyedByModelAndGPUSetting() {
        let script = URL(fileURLWithPath: "/runtime/omnipose_detect.py")
        let python = URL(fileURLWithPath: "/runtime/venv_omni/bin/python3")
        let gpu = OmniposeDetectionService.workerKey(
            pythonURL: python, scriptURL: script, model: "omni-cyto2", useGPU: true)
        #expect(gpu.modelSignature == "omnipose|omni-cyto2|gpu=true")
        #expect(gpu != OmniposeDetectionService.workerKey(
            pythonURL: python, scriptURL: script, model: "omni-cyto2", useGPU: false))
        #expect(gpu != OmniposeDetectionService.workerKey(
            pythonURL: python, scriptURL: script, model: "omni-bact-phase", useGPU: true))
    }

    @Test func customWorkerIsKeyedByPathKindEnvironmentAndCellposeDevice() {
        let script = URL(fileURLWithPath: "/runtime/custom_detect.py")
        let base = URL(fileURLWithPath: "/runtime/venv/bin/python3")
        let venv4 = URL(fileURLWithPath: "/runtime/venv4/bin/python3")
        func key(_ python: URL, _ path: String, _ kind: String, cp4: Bool, gpu: Bool) -> PersistentSidecarKey {
            CustomModelDetectionService.workerKey(
                pythonURL: python, scriptURL: script, modelPath: path, kind: kind,
                usesCellpose4Runtime: cp4, useGPU: gpu)
        }

        let checkpoint = key(base, "/models/CP_lab", "cellpose", cp4: false, gpu: true)
        #expect(checkpoint.modelSignature == "cellpose3|custom|cellpose|/models/CP_lab|gpu=true")
        #expect(checkpoint != key(base, "/models/CP_lab", "cellpose", cp4: false, gpu: false))
        #expect(checkpoint != key(base, "/models/CP_other", "cellpose", cp4: false, gpu: true))

        let sam = key(venv4, "/models/CP_lab", "cellpose", cp4: true, gpu: true)
        #expect(sam.modelSignature.hasPrefix("cellpose4|custom|cellpose|"))
        #expect(sam != checkpoint)

        // TensorFlow picks the device for a StarDist folder, so the GPU
        // setting does not split its worker.
        let folder = key(base, "/models/sd_lab", "stardist", cp4: false, gpu: true)
        #expect(folder.modelSignature == "cellpose3|custom|stardist|/models/sd_lab")
        #expect(folder == key(base, "/models/sd_lab", "stardist", cp4: false, gpu: false))
    }

    @Test func everyClassicalMethodSharesOneWorker() {
        let script = URL(fileURLWithPath: "/runtime/classical_detect.py")
        let key = ClassicalDetectionService.workerKey(pythonURL: Self.python, scriptURL: script)
        #expect(key.modelSignature == "cellpose3|classical")
        #expect(key.scriptPath == "/runtime/classical_detect.py")
    }

    @Test func keysUseStandardizedPathsAndSeparateEnvironments() {
        let spelled = ClassicalDetectionService.workerKey(
            pythonURL: URL(fileURLWithPath: "/runtime/venv/bin/../bin/python3"),
            scriptURL: URL(fileURLWithPath: "/runtime/./classical_detect.py"))
        let plain = ClassicalDetectionService.workerKey(
            pythonURL: URL(fileURLWithPath: "/runtime/venv/bin/python3"),
            scriptURL: URL(fileURLWithPath: "/runtime/classical_detect.py"))
        #expect(spelled == plain)

        let otherEnvironment = ClassicalDetectionService.workerKey(
            pythonURL: URL(fileURLWithPath: "/elsewhere/venv/bin/python3"),
            scriptURL: URL(fileURLWithPath: "/runtime/classical_detect.py"))
        #expect(otherEnvironment != plain)
    }

    /// `DetectorRegistry.install` and `AppState` retire workers by these
    /// literal prefixes when a Python environment changes.
    @Test func signaturesStartWithTheirEnvironmentsRetirementPrefix() {
        #expect(ServedDetection.baseRuntimePrefix == "cellpose3|")
        #expect(ServedDetection.cellpose4RuntimePrefix == "cellpose4|")
        #expect(ServedDetection.stardistSignature(model: "2D_versatile_fluo").hasPrefix("cellpose3|"))
        #expect(ServedDetection.classicalSignature.hasPrefix("cellpose3|"))
        #expect(ServedDetection.customSignature(path: "/m", kind: "cellpose",
                                                usesCellpose4Runtime: false, useGPU: true)
            .hasPrefix("cellpose3|"))
        #expect(ServedDetection.customSignature(path: "/m", kind: "cellpose",
                                                usesCellpose4Runtime: true, useGPU: true)
            .hasPrefix("cellpose4|"))
        #expect(!ServedDetection.omniposeSignature(model: "omni-cyto2", useGPU: true).hasPrefix("cellpose"))
    }

    @Test func retiringAnEnvironmentStopsOnlyTheWorkersRunningInIt() async throws {
        let launcher = ScriptedLauncher(reply: .success("{}"))
        let pool = PersistentSidecarPool(maxWarmWorkers: 8, idleTimeout: nil, launcher: launcher.launcher)
        let venv = URL(fileURLWithPath: "/runtime/venv/bin/python3")
        let venv4 = URL(fileURLWithPath: "/runtime/venv4/bin/python3")
        let omni = URL(fileURLWithPath: "/runtime/venv_omni/bin/python3")
        let stardist = StarDistDetectionService.workerKey(
            pythonURL: venv, scriptURL: Self.script, model: "2D_versatile_fluo")
        let classical = ClassicalDetectionService.workerKey(
            pythonURL: venv, scriptURL: URL(fileURLWithPath: "/runtime/classical_detect.py"))
        let customBase = CustomModelDetectionService.workerKey(
            pythonURL: venv, scriptURL: URL(fileURLWithPath: "/runtime/custom_detect.py"),
            modelPath: "/models/CP_lab", kind: "cellpose", usesCellpose4Runtime: false, useGPU: true)
        let custom4 = CustomModelDetectionService.workerKey(
            pythonURL: venv4, scriptURL: URL(fileURLWithPath: "/runtime/custom_detect.py"),
            modelPath: "/models/CPSAM_lab", kind: "cellpose", usesCellpose4Runtime: true, useGPU: true)
        let omnipose = OmniposeDetectionService.workerKey(
            pythonURL: omni, scriptURL: URL(fileURLWithPath: "/runtime/omnipose_detect.py"),
            model: "omni-cyto2", useGPU: true)
        let all = [stardist, classical, customBase, custom4, omnipose]
        for key in all {
            _ = try await pool.run(key: key, pythonURL: Self.python, scriptURL: Self.script, args: [])
        }
        #expect(await pool.workerCount == all.count)

        await pool.retire(modelSignaturePrefix: "cellpose3|")
        #expect(await !pool.hasWorker(for: stardist))
        #expect(await !pool.hasWorker(for: classical))
        #expect(await !pool.hasWorker(for: customBase))
        #expect(await pool.hasWorker(for: custom4))
        #expect(await pool.hasWorker(for: omnipose))

        await pool.retire(modelSignaturePrefix: "cellpose4|")
        #expect(await !pool.hasWorker(for: custom4))
        #expect(await pool.hasWorker(for: omnipose))
        await pool.retireAll()
    }

    // MARK: - Fallback decision

    @Test func failureResponseMatchesTheCellposeFallbackRule() {
        for status: Int32 in [15, -15, 143, 9, -9, 137] {
            let stopped = PersistentSidecarError.processTerminated(status: status, stderr: Data())
            #expect(ServedDetection.failureResponse(to: stopped, taskCancelled: false) == .reportExit(status))
            #expect(ServedDetection.failureResponse(to: stopped, taskCancelled: true) == .reportExit(status))
        }

        let failures: [Error] = [
            PersistentSidecarError.processTerminated(status: 1, stderr: Data("Traceback".utf8)),
            PersistentSidecarError.processTerminated(status: 0, stderr: Data()),
            PersistentSidecarError.launchFailed("interpreter missing"),
            PersistentSidecarError.protocolFailure("worker response id mismatch"),
            CocoaError(.fileReadNoSuchFile),
        ]
        for failure in failures {
            #expect(ServedDetection.failureResponse(to: failure, taskCancelled: false) == .runOneShot)
            #expect(ServedDetection.failureResponse(to: failure, taskCancelled: true) == .cancel)
        }

        #expect(ServedDetection.failureResponse(to: CancellationError(), taskCancelled: false) == .cancel)
    }

    @Test func healthyWorkerAnswersWithoutAFallback() async throws {
        let launcher = ScriptedLauncher(reply: .success("served"))
        let pool = PersistentSidecarPool(idleTimeout: nil, launcher: launcher.launcher)
        let oneShot = OneShotRecorder()
        let key = Self.stardistKey()

        let outcome = try await ServedDetection.run(
            key: key, pythonURL: Self.python, scriptURL: Self.script,
            requestArgs: Self.requestArgs, pool: pool, oneShot: oneShot.launcher)

        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "served")
        #expect(oneShot.calls.isEmpty)
        // The worker already runs the script; it receives only the request.
        #expect(launcher.worker(for: key)?.requests == [Self.requestArgs])
        await pool.retireAll()
    }

    @Test func crashedWorkerFallsBackToOneShotWithTheScriptPrepended() async throws {
        let crash = PersistentSidecarError.processTerminated(status: 1, stderr: Data("Traceback".utf8))
        let launcher = ScriptedLauncher(reply: .failure(crash))
        let pool = PersistentSidecarPool(idleTimeout: nil, launcher: launcher.launcher)
        let oneShot = OneShotRecorder()

        let outcome = try await ServedDetection.run(
            key: Self.stardistKey(), pythonURL: Self.python, scriptURL: Self.script,
            requestArgs: Self.requestArgs, pool: pool, oneShot: oneShot.launcher)

        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "one-shot")
        #expect(oneShot.calls.count == 1)
        #expect(oneShot.calls.first?.python == Self.python)
        #expect(oneShot.calls.first?.args == [Self.script.path] + Self.requestArgs)
        // The failed worker is not kept.
        #expect(await pool.workerCount == 0)
    }

    @Test func workerThatCannotStartFallsBackToOneShot() async throws {
        let launcher = ScriptedLauncher(reply: .success("unused"), launchError: .launchFailed("no interpreter"))
        let pool = PersistentSidecarPool(idleTimeout: nil, launcher: launcher.launcher)
        let oneShot = OneShotRecorder()

        let outcome = try await ServedDetection.run(
            key: Self.stardistKey(), pythonURL: Self.python, scriptURL: Self.script,
            requestArgs: Self.requestArgs, pool: pool, oneShot: oneShot.launcher)

        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "one-shot")
        #expect(oneShot.calls.map { $0.args } == [[Self.script.path] + Self.requestArgs])
    }

    @Test func stoppedWorkerReportsCancellationWithoutAFallback() async throws {
        let stopped = PersistentSidecarError.processTerminated(status: 15, stderr: Data("stopped".utf8))
        let launcher = ScriptedLauncher(reply: .failure(stopped))
        let pool = PersistentSidecarPool(idleTimeout: nil, launcher: launcher.launcher)
        let oneShot = OneShotRecorder()

        let outcome = try await ServedDetection.run(
            key: Self.stardistKey(), pythonURL: Self.python, scriptURL: Self.script,
            requestArgs: Self.requestArgs, pool: pool, oneShot: oneShot.launcher)

        #expect(outcome.exitCode == 15)
        #expect(String(decoding: outcome.stderr, as: UTF8.self) == "stopped")
        #expect(oneShot.calls.isEmpty)
        // The detection services map this to the silent `.cancelled`.
        do {
            try outcome.throwIfFailed()
            Issue.record("A stopped worker must not look like a successful run")
        } catch DetectionError.cancelled {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func cancelledTaskEndsAsCancelledWithoutAFallback() async throws {
        let launcher = ScriptedLauncher(reply: .failure(.protocolFailure("stopped mid-request")))
        let pool = PersistentSidecarPool(idleTimeout: nil, launcher: launcher.launcher)
        let oneShot = OneShotRecorder()
        let key = Self.stardistKey()

        let task = Task { () -> SidecarOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ServedDetection.run(
                key: key, pythonURL: Self.python, scriptURL: Self.script,
                requestArgs: Self.requestArgs, pool: pool, oneShot: oneShot.launcher)
        }
        do {
            _ = try await task.value
            Issue.record("A cancelled request must not produce a result")
        } catch DetectionError.cancelled {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(oneShot.calls.isEmpty)
        // Cancelling stops the worker, as it stops a one-shot process.
        #expect((launcher.worker(for: key)?.terminateCount ?? 0) >= 1)
        #expect(await pool.workerCount == 0)
    }

    private static func stardistKey() -> PersistentSidecarKey {
        StarDistDetectionService.workerKey(pythonURL: python, scriptURL: script, model: "2D_versatile_fluo")
    }
}

// MARK: - Stand-ins

/// In-memory worker that answers every request the same way.
private final class ScriptedServeWorker: PersistentSidecarWorkerHandle, @unchecked Sendable {
    enum Reply {
        case success(String)
        case failure(PersistentSidecarError)
    }

    private let lock = NSLock()
    private let reply: Reply
    private var healthy = true
    private var received: [[String]] = []
    private var terminations = 0

    init(reply: Reply) { self.reply = reply }

    var isHealthy: Bool { lock.withLock { healthy } }
    var requests: [[String]] { lock.withLock { received } }
    var terminateCount: Int { lock.withLock { terminations } }

    func request(
        args: [String],
        onStderrLine: (@Sendable (String) -> Void)?
    ) async throws -> SidecarOutcome {
        lock.withLock { received.append(args) }
        switch reply {
        case .success(let stdout):
            return SidecarOutcome(exitCode: 0, stdout: Data(stdout.utf8), stderr: Data())
        case .failure(let error):
            throw error
        }
    }

    func terminate() {
        lock.withLock {
            healthy = false
            terminations += 1
        }
    }

    func shutdown() { lock.withLock { healthy = false } }
}

private final class ScriptedLauncher: @unchecked Sendable {
    private let lock = NSLock()
    private let reply: ScriptedServeWorker.Reply
    private let launchError: PersistentSidecarError?
    private var launched: [PersistentSidecarKey: ScriptedServeWorker] = [:]

    init(reply: ScriptedServeWorker.Reply, launchError: PersistentSidecarError? = nil) {
        self.reply = reply
        self.launchError = launchError
    }

    var launcher: PersistentSidecarPool.Launcher {
        { [self] key, _, _, _ in
            if let launchError { throw launchError }
            let worker = ScriptedServeWorker(reply: reply)
            lock.withLock { launched[key] = worker }
            return worker
        }
    }

    func worker(for key: PersistentSidecarKey) -> ScriptedServeWorker? {
        lock.withLock { launched[key] }
    }
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
