import Foundation
import Testing
@testable import CellCounting

@Suite(.serialized) @MainActor
struct WorkbenchSessionTests {
    @MainActor private final class Engine {
        var revision = 4
        var mutationRevisions: [Int?] = []
        var previewParameters: WorkbenchJSON = .null
        var previewCalls = 0
        var operations: [String] = []
        var hasJob = false
        var jobStatus = "pending"
        var completed = 0
        var onAdvance: (() -> Void)?
        let dataURL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP1sAAAAASUVORK5CYII="

        let saved: WorkbenchJSON = .object([
            "method": .string("manual"), "threshold": .number(220),
            "polarity": .string("dark"), "minAreaPx": .number(32),
            "minDistancePx": .number(9), "channel": .number(2),
            "zProjection": .string("mean")
        ])

        var job: WorkbenchJSON {
            .object([
                "id": .string("job"), "name": .string("Saved workflow"),
                "status": .string(jobStatus), "outputsCurrent": .bool(true),
                "progress": .object(["completed": .number(Double(completed)), "total": .number(3)])
            ])
        }

        func request(_ operation: String, _ path: String, _ expected: Int?,
                     _ arguments: [String: WorkbenchJSON]) async throws -> WorkbenchJSON {
            operations.append(operation)
            let result: WorkbenchJSON
            switch operation {
            case "project.inspect", "project.snapshot":
                result = .object([
                    "project": .object(["id": .string("project"), "name": .string("Fixture"),
                                        "revision": .number(Double(revision))]),
                    "jobs": hasJob ? .array([job]) : .array([]),
                    "images": .array([.object([
                        "id": .string("image"), "name": .string("Three-channel image"),
                        "width": .number(64), "height": .number(64), "channels": .number(3),
                        "cellCount": .number(1), "pxPerUm": .number(2),
                        "status": .string("analyzed"), "parameters": saved
                    ])])
                ])
            case "image.list":
                let snapshot = try await request("project.snapshot", path, nil, [:])
                result = .object(["images": snapshot["result"]["images"], "total": .number(1), "sourceRevision": .number(Double(revision))])
            case "mask.overlay":
                result = .object(["maskDataUrl": .string(dataURL)])
            case "image.preview":
                previewCalls += 1
                previewParameters = arguments["parameters"] ?? .null
                result = .object(["dataUrl": .string(dataURL)])
            case "measurements.get", "measurements.page", "analysis.preview":
                if operation == "analysis.preview" { previewParameters = arguments["parameters"] ?? .null }
                result = .object(["dataUrl": .string(dataURL), "imageId": .string("image"), "total": .number(1), "sourceRevision": .number(Double(revision)), "cells": .array([.object([
                    "labelId": .number(1), "areaPx": .number(30),
                    "cx": .number(20), "cy": .number(20)
                ])])])
            case "calibration.set":
                mutationRevisions.append(expected)
                guard expected == revision else {
                    throw WorkbenchFailure(code: "revision-conflict", message: "Another client changed the project.")
                }
                revision += 1
                result = .object([:])
            case "job.advance", "job.pause", "job.resume", "job.cancel":
                mutationRevisions.append(expected)
                guard expected == revision else {
                    throw WorkbenchFailure(code: "revision-conflict", message: "Checkpoint used a stale revision.")
                }
                revision += 1
                if operation == "job.advance" {
                    completed += 1
                    jobStatus = completed == 3 ? "completed" : "running"
                    onAdvance?()
                } else if operation == "job.pause" { jobStatus = "paused" }
                else if operation == "job.resume" { jobStatus = "running" }
                else { jobStatus = "cancelled" }
                result = .object(["job": job])
            case "summary.get":
                result = .object([
                    "sourceRevision": .number(Double(revision)), "imageCount": .number(1),
                    "analyzedImageCount": .number(1), "cellCount": .number(1), "images": .array([])
                ])
            default:
                throw WorkbenchFailure(code: "unexpected-operation", message: operation)
            }
            return .object([
                "schemaVersion": .number(1), "ok": .bool(true), "operation": .string(operation),
                "revision": .number(Double(revision)), "result": result
            ])
        }
    }

    private func settled(_ session: WorkbenchSession) async -> Bool {
        for _ in 0..<1_000 {
            if !session.busy { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return !session.busy
    }

    @Test func reopeningRestoresAnalysisPlaneAndPreviewUsesUnsavedSettingsWithoutWriting() async throws {
        let suite = "workbench-session-tests-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let engine = Engine()
        let session = WorkbenchSession(preferences: preferences, request: engine.request)

        session.open(path: "/tmp/native-workbench-fixture")
        #expect(await settled(session))
        #expect(session.error == nil)
        #expect(session.selectedImage?.channels == 3)
        #expect(session.channel == 2 && session.projection == "mean")
        #expect(session.method == "manual" && session.threshold == 220)
        #expect(engine.previewParameters["channel"].integer == 2)
        #expect(session.cells.count == 1 && session.preview != nil)

        session.channel = 1
        session.projection = "middle"
        session.method = "otsu"
        #expect(session.parametersChanged)
        session.selectedLabels = [1]
        session.edit("delete")
        #expect(!session.busy && engine.mutationRevisions.isEmpty)
        session.analyze(previewOnly: true)
        #expect(await settled(session))
        #expect(session.error == nil && session.isPreview)
        #expect(!session.parametersChanged)
        #expect(engine.previewCalls == 1)
        #expect(engine.previewParameters["channel"].integer == 1)
        #expect(engine.previewParameters["zProjection"].string == "middle")
        #expect(engine.previewParameters["threshold"].number == nil)
        #expect(engine.mutationRevisions.isEmpty)
        #expect(session.revision == 4)
    }

    @Test func agentMutationRejectsStaleGUIWriteAndRequiresExplicitRetry() async throws {
        let suite = "workbench-session-tests-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let engine = Engine()
        let session = WorkbenchSession(preferences: preferences, request: engine.request)
        session.open(path: "/tmp/native-workbench-fixture")
        #expect(await settled(session))
        session.selectedLabels = [1]
        engine.revision = 5

        session.applyCalibration()
        #expect(await settled(session))
        #expect(engine.mutationRevisions.count == 1)
        #expect(engine.mutationRevisions.first! == 4)
        #expect(session.revision == 4)
        #expect(session.selectedLabels == [1] && !session.isPreview)
        #expect(session.error?.contains("preserved") == true)

        session.selectedLabels = []
        session.refresh()
        #expect(await settled(session))
        #expect(session.revision == 5)
        session.applyCalibration()
        #expect(await settled(session))
        #expect(engine.mutationRevisions.count == 2)
        #expect(engine.mutationRevisions.last! == 5)
        #expect(session.revision == 6 && session.error == nil)
    }

    @Test func readResultFromNewRevisionRefreshesWithoutAuthorizingAnUnseenWrite() async throws {
        let suite = "workbench-session-tests-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let engine = Engine()
        let session = WorkbenchSession(preferences: preferences, request: engine.request)
        session.open(path: "/tmp/native-workbench-fixture")
        #expect(await settled(session))
        session.analyze(previewOnly: true)
        #expect(await settled(session))
        #expect(session.isPreview)

        engine.revision = 5
        session.summarize()
        #expect(await settled(session))
        #expect(session.summary == nil && session.isPreview)
        #expect(session.revision == 4)
        #expect(session.error?.contains("preserved") == true)
        #expect(engine.mutationRevisions.isEmpty)

        session.refresh()
        #expect(await settled(session))
        #expect(session.revision == 5 && !session.isPreview)
    }

    @Test func workflowsPauseAtCheckpointAndResumeWithEachCommittedRevision() async throws {
        let suite = "workbench-session-tests-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let engine = Engine()
        engine.hasJob = true
        let session = WorkbenchSession(preferences: preferences, request: engine.request)
        session.open(path: "/tmp/native-workbench-fixture")
        #expect(await settled(session))
        engine.onAdvance = {
            session.requestJobStop(cancel: false)
            engine.onAdvance = nil
        }

        session.advanceJob("job", remaining: true)
        #expect(await settled(session))
        #expect(session.jobs.first?.status == "paused")
        #expect(session.jobs.first?.completed == 1)
        #expect(engine.mutationRevisions == [4, 5])
        #expect(session.runningJobID == nil && session.requestedJobAction == nil)

        session.changeJob("job", action: "resume")
        #expect(await settled(session))
        session.advanceJob("job", remaining: true)
        #expect(await settled(session))
        #expect(session.jobs.first?.status == "completed")
        #expect(session.jobs.first?.completed == 3)
        #expect(engine.mutationRevisions == [4, 5, 6, 7, 8])
        #expect(!engine.operations.contains("workflow.list"))
        #expect(!engine.operations.contains("job.list"))
        #expect(!engine.operations.contains("experiment.get"))
        #expect(session.error == nil)
    }
}
