import Foundation
import Testing
@testable import CellCounting

@Suite(.serialized) @MainActor
struct WorkbenchVolumeSessionTests {
    @MainActor private final class Engine {
        var revision = 3
        var hasWorkflow = false
        var requests: [(String, Int?, [String: WorkbenchJSON])] = []
        let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP1sAAAAASUVORK5CYII="
        let parameters: WorkbenchJSON = .object([
            "method": .string("manual"), "threshold": .number(64), "polarity": .string("bright"),
            "minVolumeVox": .number(6), "minDistanceVox": .number(2)
        ])
        let display: WorkbenchJSON = .object([
            "dataBase64": .string("AA=="), "dimensions": .array([.number(1), .number(1), .number(1)]),
            "originalDimensions": .array([.number(20), .number(30), .number(10)])
        ])
        var cell: WorkbenchJSON { .object([
            "labelId": .number(4), "voxelCount": .number(32), "volumeUm3": .number(16),
            "cx": .number(2.5), "cy": .number(3.5), "cz": .number(4.5)
        ]) }
        func request(_ operation: String, _ path: String, _ expected: Int?,
                     _ arguments: [String: WorkbenchJSON]) async throws -> WorkbenchJSON {
            requests.append((operation, expected, arguments))
            let result: WorkbenchJSON
            switch operation {
            case "project.inspect", "project.snapshot":
                result = .object([
                    "project": .object(["name": .string("Volume fixture"), "revision": .number(Double(revision))]),
                    "workflows": hasWorkflow ? .array([.object(["id": .string("workflow"), "name": .string("Volume"), "version": .number(1)])]) : .array([]),
                    "images": .array([.object([
                        "id": .string("volume"), "width": .number(20), "height": .number(30),
                        "zCount": .number(10), "timeCount": .number(3), "channels": .number(2),
                        "volumeFrameCount": .number(2)
                    ])])
                ])
            case "image.list":
                let snapshot = try await request("project.snapshot", path, nil, [:])
                result = .object(["images": snapshot["result"]["images"], "total": .number(1), "sourceRevision": .number(Double(revision))])
            case "mask.overlay": result = .object(["maskDataUrl": .string(png)])
            case "volume.inspect":
                result = .object([
                    "dimensions": .array([.number(20), .number(30), .number(10)]),
                    "channels": .number(2), "timeCount": .number(3),
                    "voxelSizeUm": .object(["x": .number(0.5), "y": .number(0.5), "z": .number(2)]),
                    "timeStepSeconds": .number(10), "tracks": .object(["status": .string("none")]),
                    "frames": .array((0..<3).map { .object([
                        "timeIndex": .number(Double($0)), "channel": .number(0), "parameters": parameters
                    ]) })
                ])
            case "volume.display": result = display
            case "volume.slice":
                result = .object([
                    "dataUrl": .string(png), "width": .number(20), "height": .number(10),
                    "contours": .array([])
                ])
            case "volume.measurements.get", "measurements.page": result = .object(["cells": .array([cell]), "total": .number(1), "sourceRevision": .number(Double(revision))])
            case "volume.analysis.preview":
                result = .object(["display": display, "cells": .array([cell])])
            case "volume.mask.edit", "volume.mask.undo", "volume.analysis.run", "volume.calibration.set", "workflow.save", "job.create":
                guard expected == revision else {
                    throw WorkbenchFailure(code: "revision-conflict", message: "Concurrent agent edit.")
                }
                revision += 1
                if operation == "workflow.save" { hasWorkflow = true }
                result = .object(["workflow": .object(["id": .string("workflow")])])
            default: throw WorkbenchFailure(code: "unexpected-operation", message: operation)
            }
            return .object(["schemaVersion": .number(1), "ok": .bool(true),
                            "revision": .number(Double(revision)), "result": result])
        }
    }

    private func settled(_ session: WorkbenchSession) async -> Bool {
        for _ in 0..<1000 {
            if !session.busy { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return !session.busy
    }
    private func preferences() throws -> (UserDefaults, String) {
        let suite = "workbench-volume-tests-\(UUID())"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test func volumeModeRestoresFrameSettingsAndLoadsUnresizedSourcePlane() async throws {
        let (preferences, suite) = try preferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let engine = Engine(), session = WorkbenchSession(preferences: preferences, request: engine.request)
        session.open(path: "/tmp/volume-fixture")
        #expect(await settled(session))
        #expect(session.error == nil && session.viewingVolume)
        #expect(session.volume.dimensions == [20, 30, 10])
        #expect(session.volume.cells.first?.volumeUm3 == 16)
        #expect(session.volume.canEdit && session.volume.threshold == 64)
        #expect(engine.requests.last(where: { $0.0 == "volume.slice" })?.2["maxSize"] == nil)
        #expect(!engine.requests.contains { $0.0 == "image.preview" })

        session.changeVolumeFrame(timeIndex: 2, channel: 1)
        #expect(await settled(session))
        #expect(session.volume.timeIndex == 2 && session.volume.channel == 1)
        #expect(!session.volume.hasSavedAnalysis && session.volume.cells.isEmpty)
        let lastDisplay = try #require(engine.requests.last(where: { $0.0 == "volume.display" }))
        #expect(lastDisplay.2["timeIndex"]?.integer == 2 && lastDisplay.2["channel"]?.integer == 1)
    }

    @Test func previewAndDirtySettingsPreventSavedGeometryEdits() async throws {
        let (preferences, suite) = try preferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let engine = Engine(), session = WorkbenchSession(preferences: preferences, request: engine.request)
        session.open(path: "/tmp/volume-fixture")
        #expect(await settled(session))
        session.volume.threshold = 99
        session.volume.selectedLabels = [4]
        #expect(session.volume.parametersChanged && !session.volume.canEdit)
        session.editVolume("delete")
        #expect(!session.busy && !engine.requests.contains { $0.0 == "volume.mask.edit" })
        let sourceCalls = engine.requests.filter { $0.0 == "volume.display" || $0.0 == "volume.slice" }.count
        session.analyzeVolume(previewOnly: true)
        #expect(await settled(session))
        #expect(session.volume.isPreview && !session.volume.canEdit && session.volume.sliceImage == nil)
        #expect(session.volume.cells.count == 1 && !session.volume.parametersChanged)
        #expect(engine.requests.filter { $0.0 == "volume.display" || $0.0 == "volume.slice" }.count == sourceCalls)
        #expect(engine.requests.allSatisfy { $0.1 == nil })
    }

    @Test func exactPlaneBrushUsesVoxelCentersAndOldViewerEventsAreIgnored() async throws {
        let (preferences, suite) = try preferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let engine = Engine(), session = WorkbenchSession(preferences: preferences, request: engine.request)
        session.open(path: "/tmp/volume-fixture")
        #expect(await settled(session))
        let previous = session.volume.crosshair
        session.handleVolumePointer(voxel: [2, 7, 4], plane: "xz", generation: session.volume.generation - 1)
        #expect(!session.busy && session.volume.crosshair == previous)
        session.handleVolumePointer(voxel: [2, 7, 4], plane: "xz", generation: session.volume.generation)
        #expect(await settled(session))
        #expect(session.volume.plane == "xz" && session.volume.index == 7)
        session.volume.editMode = "paint"
        session.volume.paintLabel = 4
        session.editVolume("brush", point: [2.2, 4.9])
        #expect(await settled(session))
        let edit = try #require(engine.requests.last(where: { $0.0 == "volume.mask.edit" }))
        #expect(edit.1 == 3)
        #expect(edit.2["center"] == .array([.number(2.5), .number(7.5), .number(4.5)]))
        #expect(edit.2["mode"]?.string == "paint")
        #expect(session.revision == 4 && session.error == nil)
    }

    @Test func calibrationCanClearUnknownAxesAndVolumeWorkflowCapturesTimeScope() async throws {
        let (preferences, suite) = try preferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let engine = Engine(), session = WorkbenchSession(preferences: preferences, request: engine.request)
        session.open(path: "/tmp/volume-fixture")
        #expect(await settled(session))
        session.volume.knownZ = false; session.volume.knownTime = false
        session.applyVolumeCalibration()
        #expect(await settled(session))
        let calibration = try #require(engine.requests.last(where: { $0.0 == "volume.calibration.set" }))
        #expect(calibration.2["voxelSizeUm"]?["z"] == .null)
        #expect(calibration.2["timeStepSeconds"] == .null)
        #expect(calibration.2["voxelSizeUm"]?["x"].number == 0.5)
        session.saveWorkflow(name: "Volume", updateID: nil, includeExport: false)
        #expect(await settled(session))
        let workflow = try #require(engine.requests.last(where: { $0.0 == "workflow.save" }))
        #expect(workflow.2["steps"]?.array.first?["type"].string == "volume-analysis")
        #expect(workflow.2["steps"]?.array.first?["channel"].integer == 0)
        session.selectedWorkflowID = "workflow"
        session.createJob(imageIDs: ["volume"], exportDestination: nil, timeIndices: [1])
        #expect(await settled(session))
        let job = try #require(engine.requests.last(where: { $0.0 == "job.create" }))
        #expect(job.2["timeIndices"] == .array([.number(1)]))
        #expect(job.1 == 5 && session.revision == 6)
    }
}
