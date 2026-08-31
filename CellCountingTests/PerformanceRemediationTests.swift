import Foundation
import Testing
@testable import CellCounting

struct PerformanceRemediationTests {
    @Test func persistentSidecarReusesProcessAndRecoversAfterCrash() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-worker-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let marker = directory.appendingPathComponent("starts.txt")
        let script = directory.appendingPathComponent("worker.py")
        let markerLiteral = String(reflecting: marker.path)
        let source = """
        import json
        import os
        import sys
        import time

        MARKER = \(markerLiteral)

        if "--serve" in sys.argv[1:]:
            with open(MARKER, "a", encoding="utf-8") as handle:
                handle.write("start\\n")
            for line in sys.stdin:
                request = json.loads(line)
                args = request["args"]
                if "--crash" in args:
                    os._exit(7)
                if "--wait" in args:
                    time.sleep(30)
                payload = json.dumps({"echo": args[-1]})
                print(json.dumps({
                    "request_id": request["request_id"],
                    "exit_code": 0,
                    "stdout": payload,
                }), flush=True)
        else:
            print(json.dumps({"fallback": True}))
        """
        try source.write(to: script, atomically: true, encoding: .utf8)

        let key = PersistentSidecarKey(
            pythonPath: "/usr/bin/python3",
            scriptPath: script.path,
            modelSignature: UUID().uuidString)
        let first = try await PersistentSidecarPool.shared.run(
            key: key,
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
            scriptURL: script,
            args: ["first"])
        let second = try await PersistentSidecarPool.shared.run(
            key: key,
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
            scriptURL: script,
            args: ["second"])
        #expect(String(data: first.stdout, encoding: .utf8)?.contains("first") == true)
        #expect(String(data: second.stdout, encoding: .utf8)?.contains("second") == true)
        #expect(try String(contentsOf: marker, encoding: .utf8)
            .split(separator: "\n").count == 1)

        let cancelled = Task {
            try await PersistentSidecarPool.shared.run(
                key: key,
                pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
                scriptURL: script,
                args: ["--wait"])
        }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("Cancellation must terminate the checked-out worker")
        } catch let error as PersistentSidecarError {
            guard case .processTerminated(let status, _) = error else {
                Issue.record("Unexpected cancellation error: \(error)")
                return
            }
            #expect([15, -15, 143, 9, -9, 137].contains(status))
        }

        let afterCancellation = try await PersistentSidecarPool.shared.run(
            key: key,
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
            scriptURL: script,
            args: ["after-cancellation"])
        #expect(String(data: afterCancellation.stdout, encoding: .utf8)?
            .contains("after-cancellation") == true)
        #expect(try String(contentsOf: marker, encoding: .utf8)
            .split(separator: "\n").count == 2)

        let fallback = try await ReusableSidecarRunner.run(
            key: key,
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
            scriptURL: script,
            requestArgs: ["--crash"])
        #expect(String(data: fallback.stdout, encoding: .utf8)?.contains("fallback") == true)

        let recovered = try await PersistentSidecarPool.shared.run(
                key: key,
                pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
                scriptURL: script,
            args: ["recovered"])
        #expect(String(data: recovered.stdout, encoding: .utf8)?.contains("recovered") == true)
        #expect(try String(contentsOf: marker, encoding: .utf8)
            .split(separator: "\n").count == 3)
        await PersistentSidecarPool.shared.retireAll()
    }

    @Test func helperStagingIsANoOpUntilBundledContentChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-stage-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.py")
        let destination = directory.appendingPathComponent("staged/helper.py")
        try Data("version-one".utf8).write(to: source)

        #expect(try PythonRuntime.stageFile(
            source: source, destination: destination, permissions: 0o755))
        let firstAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let firstFileNumber = firstAttributes[.systemFileNumber] as? NSNumber

        #expect(try !PythonRuntime.stageFile(
            source: source, destination: destination, permissions: 0o755))
        let secondAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect(secondAttributes[.systemFileNumber] as? NSNumber == firstFileNumber)

        try Data("version-two".utf8).write(to: source)
        #expect(try PythonRuntime.stageFile(
            source: source, destination: destination, permissions: 0o755))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "version-two")
    }

    @Test func storageInventoryDeduplicatesRootsAndMeasuresOffTheViewPath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-inventory-test-\(UUID().uuidString)", isDirectory: true)
        let shared = directory.appendingPathComponent("shared", isDirectory: true)
        let extra = directory.appendingPathComponent("extra", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 1, count: 4_096).write(to: shared.appendingPathComponent("a.bin"))
        try Data(repeating: 2, count: 4_096).write(to: extra.appendingPathComponent("b.bin"))

        let result = await ModelStorageInventory.measure([
            .init(id: "shared-once", roots: [shared, shared.standardizedFileURL]),
            .init(id: "shared-plus-extra", roots: [shared, extra]),
        ])
        #expect((result["shared-once"] ?? 0) > 0)
        #expect((result["shared-plus-extra"] ?? 0) > (result["shared-once"] ?? 0))
    }
}
